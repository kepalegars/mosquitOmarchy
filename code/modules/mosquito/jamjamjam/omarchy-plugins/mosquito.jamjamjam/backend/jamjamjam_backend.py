#!/usr/bin/python3
"""jamjamjam backend: key/BPM/chord detection, tuner, and metronome."""

from __future__ import annotations

import array
import argparse
import heapq
import json
import math
import os
import queue
import re
import selectors
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path

try:
    import numpy as np
    HAVE_NUMPY = True
except ImportError:
    HAVE_NUMPY = False

PLUGIN_ID = "mosquito.jamjamjam"

# Capture tools. PipeWire 1.6 does NOT expose sink monitors as nodes, so
# `pw-record --target <sink>.monitor` silently records silence (verified on
# this machine: peak 0 vs. the real signal). `parec` (pulse) reaches the
# monitor directly as a pulse source and captures the *pre-volume* mix, so it
# works whatever the output volume/mute/output device. Prefer it for monitors.
HAVE_PAREC = shutil.which("parec") is not None
HAVE_PWRECORD = shutil.which("pw-record") is not None

SAMPLE_RATE = 48000
HOP_SIZE = 1024
CHUNK_SECONDS = 1.0
ANALYSIS_CHUNK = SAMPLE_RATE * 2
CHROMAGRAM_RATE = 10
BPM_MIN = 50
BPM_MAX = 200

# Chord-progression accumulation (ChordSeq: sliding sequence + loop detection)
# is set aside for now: its detection was not reliable enough. The code is kept
# intact so it can be re-enabled by flipping this flag. While False the backend
# only reports the real-time chord estimate and no progression/loop.
PROGRESSION_ENABLED = False

NOTE_NAMES_SHARP = ("C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B")
NOTE_NAMES_FLAT = ("C", "D♭", "D", "E♭", "E", "F", "G♭", "G", "A♭", "A", "B♭", "B")

# Detection gates. Below the silence floor the analyzer reports no signal and
# never invents a key/chord/BPM from the noise floor; a chord also has to be
# tonally peaked and clearly separated from the runner-up template.
SILENCE_RMS = 0.004
QUIET_CHUNKS_TO_MUTE = 2
CHORD_PEAK_MIN = 0.16
CHORD_MARGIN = 1.05
KEY_PEAK_MIN = 0.12

# Chroma extraction: each pitch class sums the spectrum at its own fundamentals
# across octaves (harmonic 2 is the same pitch class, so it reinforces without
# leaking energy onto the fifth/third the way higher harmonics would).
CHROMA_HARMONICS = 2
CHROMA_HARMONIC_DECAY = 0.5
CHROMA_WIDTH = 0.022  # Gaussian half-width as a fraction of the frequency
CHROMA_POWER = 0.65  # compress dynamic range before matching

# Chord interval templates, in semitones from root (most specific first).
CHORD_TEMPLATES = (
    ((0, 4, 7, 11), "maj7"),
    ((0, 4, 7, 10), "7"),
    ((0, 3, 7, 10), "m7"),
    ((0, 3, 6, 10), "m7♭5"),
    ((0, 3, 6, 9), "dim7"),
    ((0, 4, 7, 9), "6"),
    ((0, 3, 7, 9), "m6"),
    ((0, 3, 7, 11), "m(maj7)"),
    ((0, 4, 7), ""),
    ((0, 3, 7), "m"),
    ((0, 3, 6), "dim"),
    ((0, 4, 8), "+"),
    ((0, 5, 7), "sus4"),
    ((0, 2, 7), "sus2"),
    ((0, 2, 4, 7), "add9"),
)

# Krumhansl-Schmuckler key profiles.
KS_MAJOR = np.array([
    6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88,
])
KS_MINOR = np.array([
    6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17,
])


def pitch_classes(notes) -> list[int]:
    return sorted({int(note) % 12 for note in notes})


def note_name(pc: int, naming: str = "flats") -> str:
    names = NOTE_NAMES_FLAT if naming == "flats" else NOTE_NAMES_SHARP
    return names[pc % 12]


def identify_chord(notes, naming: str = "flats") -> str:
    pcs = pitch_classes(notes)
    if len(pcs) < 3:
        if len(pcs) == 1:
            return note_name(pcs[0], naming)
        return ""
    names = NOTE_NAMES_FLAT if naming == "flats" else NOTE_NAMES_SHARP
    pc_set = set(pcs)
    # Check all (root, template) pairs; iterate roots in chromatic order so the
    # lowest root (most natural musical root) wins when multiple matches exist
    # (e.g. C sus4 vs F sus2 for pitch classes {0, 5, 7}).
    for root in sorted(pcs):
        for intervals, suffix in CHORD_TEMPLATES:
            if len(intervals) != len(pcs):
                continue
            candidate = {(root + interval) % 12 for interval in intervals}
            if candidate == pc_set:
                return f"{names[root]}{suffix}"
    return " · ".join(names[pc] for pc in pcs)


def major_scale_degrees(root_pc: int) -> list[int]:
    return [(root_pc + step) % 12 for step in (0, 2, 4, 5, 7, 9, 11)]


def natural_minor_scale_degrees(root_pc: int) -> list[int]:
    return [(root_pc + step) % 12 for step in (0, 2, 3, 5, 7, 8, 10)]


CONFIG_DIR = os.path.expanduser("~/.config/jamjamjam")
CONFIG_FILE = os.path.join(CONFIG_DIR, "config.json")
STATE_FILE = os.path.expanduser("~/.local/state/jamjamjam/state.json")
DEFAULT_CONFIG = {
    "noteNaming": "flats",
    "showChordBox": False,
    "showKeyCard": True,
    "showBpmCard": True,
    "showChordCard": True,
    "autoAnalyze": True,
    "aecEnabled": False,
    "metronomeVolume": 0.7,
    "clickCustom": False,
    "customDown": "",
    "customUp": "",
}

TEMPO_SIGNATURE_RE = re.compile(r"(?<!\d)(\d{1,2})\s*/\s*(\d{1,2})(?!\d)")
TEMPO_BPM_RE = re.compile(
    r"(?<!\d)(\d{1,3}(?:[.,]\d+)?)\s*(?:bpm|b\.?p\.?m\.?)(?!\w)", re.IGNORECASE)
TEMPO_NUMBER_RE = re.compile(r"(?<!\d)(\d{1,3}(?:[.,]\d+)?)(?!\d)")


def parse_tempo_entry(value: object) -> tuple[float | None, str | None]:
    """Parse a free-form tempo/time-signature entry.

    Accepted examples: "120", "6/8", "120 4/4", "140bpm 4/4",
    "7/8 134 BPm". A bare signature changes only the meter; a bare
    number changes only the tempo.
    """
    text = str(value or "").strip()
    if not text:
        return None, None
    text = (text.replace("\u00a0", " ").replace("\uff0f", "/")
            .replace("，", ",").replace("·", " ").replace("|", " ")
            .replace(";", " "))
    text = re.sub(r"(?<=\d),(?=\d)", ".", text).replace(",", " ")
    if not text.strip():
        return None, None

    signature = None
    match = TEMPO_SIGNATURE_RE.search(text)
    if match:
        numerator = int(match.group(1))
        denominator = int(match.group(2))
        if not (1 <= numerator <= 16 and denominator in (1, 2, 4, 8, 16)):
            raise ValueError("Beat count must be 1-16 and the note value 1, 2, 4, 8 or 16")
        signature = f"{numerator}/{denominator}"

    bpm = None
    match = TEMPO_BPM_RE.search(text)
    if match:
        bpm = float(match.group(1).replace(",", "."))
    else:
        remainder = TEMPO_SIGNATURE_RE.sub(" ", text)
        remainder = re.sub(r"b\.?p\.?m\.?", " ", remainder, flags=re.IGNORECASE)
        match = TEMPO_NUMBER_RE.search(remainder)
        if match:
            bpm = float(match.group(1).replace(",", "."))

    if bpm is not None and not (40.0 <= bpm <= 240.0):
        raise ValueError("BPM must be between 40 and 240")
    if bpm is None and signature is None:
        raise ValueError("Enter a BPM (120), a meter (6/8), or both (120 4/4)")
    return bpm, signature


def load_config() -> dict:
    data = {}
    try:
        with open(CONFIG_FILE, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError):
        data = {}
    config = dict(DEFAULT_CONFIG)
    if isinstance(data, dict):
        for key in DEFAULT_CONFIG:
            if key in data:
                config[key] = data[key]
    return config


def save_config(config: dict) -> None:
    try:
        os.makedirs(CONFIG_DIR, exist_ok=True)
        tmp = CONFIG_FILE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as handle:
            json.dump(config, handle, ensure_ascii=False, indent=2)
        os.replace(tmp, CONFIG_FILE)
    except OSError:
        pass


def mic_status() -> tuple[bool, bool]:
    """Return (available, muted) for the default PipeWire source.

    `wpctl get-volume @DEFAULT_SOURCE@` prints e.g. "Volume: 0.80 [MUTED]".
    No output at all means there is no default source (mic unavailable/cut).
    """
    text = shell_output(["wpctl", "get-volume", "@DEFAULT_SOURCE@"], timeout=1.0)
    if not text.strip():
        return (False, False)
    return (True, "[MUTED]" in text)


def shell_output(command: list[str], timeout: float = 2.0) -> str:
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=timeout, check=False)
        return result.stdout or ""
    except (OSError, subprocess.TimeoutExpired):
        return ""


NODE_LINE_RE = re.compile(r"^\s*[* ]?\s*(\d+)\.\s+(\S+)")
SECTION_RE = re.compile(r"^\s*[├└]─\s*([A-Za-z]+):")
DEFAULT_NODE_RE = re.compile(r"^\s*│?\s*\*\s*(\d+)\.\s+(\S+)")
ANY_NODE_RE = re.compile(r"^\s*│?\s*(\d+)\.\s+(\S+)")



def friendly_node_name(name: str) -> str:
    """Turn a PipeWire node name into something a person recognises.

    `alsa_input.pci-0000_64_00.6.HiFi__Mic1__source` is what the backend has to
    match against, and no human would call it that. The PCI part and the trailing
    `_source` are dropped and the ALSA `HiFi__` prefix becomes a space. The
    UNCHANGED name is still what gets stored and sent -- this only affects the
    label, because matching on a prettified string would break the moment a
    device renames itself.
    """
    label = str(name or "")
    if label.endswith("_source"):
        label = label[: -len("_source")]
    label = re.sub(r"^alsa_(input|output)\.", "", label)
    # Only a LEADING `pci-<addr>.` is an address. Matching it anywhere would eat
    # the device's own "pci-0000_64_00.4-usb-..." style token mid-name and leave
    # the label saying "6. Mic1_".
    label = re.sub(r"^(alsa|v4l2)_(input|output)\.", "", label)
    label = re.sub(r"^pci-[0-9a-f]{4}_[0-9a-f]{2}_[0-9a-f]{2}\.\d+[.-]", "", label)
    label = label.replace("__", " ").replace("HiFi", "")
    label = re.sub(r"\.(analog|capture|output)-surround-\d+", "", label)
    label = re.sub(r"-usb-0_\d+_\d+\.\d+", "", label)
    return " ".join(label.split()).strip("_ -") or str(name or "")


def default_audio_nodes() -> tuple[str, str]:
    """Return (monitor_target, input_target) node names for the system defaults.

    The monitor target is the PipeWire monitor of the default *sink*, so the
    analyzer hears exactly what the system is playing (system audio, not the
    microphone). The input target is the default *source* (main system input),
    used by the built-in tuner.
    """
    monitor = ""
    input_target = ""
    first_sink = ""
    first_source = ""
    section = ""
    text = shell_output(["wpctl", "status", "-n"])
    for raw in text.splitlines():
        line = raw.rstrip()
        section_match = SECTION_RE.match(line)
        if section_match:
            section = section_match.group(1)
            continue
        default_match = DEFAULT_NODE_RE.match(line)
        if default_match:
            _node_id, name = default_match.groups()
            if section == "Sinks" and not monitor:
                monitor = name + ".monitor"
            elif section == "Sources" and not input_target:
                input_target = name
            continue
        any_match = ANY_NODE_RE.match(line)
        if any_match:
            _node_id, name = any_match.groups()
            if section == "Sinks" and not first_sink:
                first_sink = name
            elif section == "Sources" and not first_source:
                first_source = name
    if not monitor and first_sink:
        monitor = first_sink + ".monitor"
    if not input_target and first_source:
        input_target = first_source
    # Last resort: scan pw-dump for the default sink's monitor / an audio input.
    nodes = pw_dump_nodes()
    if not monitor:
        for node in nodes:
            name = node.get("node.name", "") or ""
            media = node.get("media.class", "") or ""
            if name.endswith(".monitor") and "Audio" in media \
                    and not any(k in name for k in ("virtual", "null", "loopback", "v4l2")):
                monitor = name
                break
    if not input_target:
        for node in nodes:
            name = node.get("node.name", "") or ""
            media = node.get("media.class", "") or ""
            if "Audio" in media and "v4l2" not in name and "monitor" not in name:
                if name.startswith("alsa_input") or ".source" in name or "input" in name:
                    input_target = name
                    break
    return monitor, input_target


def pw_dump_nodes() -> list[dict]:
    try:
        data = json.loads(shell_output(["pw-dump"], timeout=3.0))
    except json.JSONDecodeError:
        return []
    nodes = []
    for obj in data if isinstance(data, list) else []:
        if not isinstance(obj, dict):
            continue
        if str(obj.get("type", "")).endswith("Interface:Node"):
            props = obj.get("info", {}).get("props", {}) if isinstance(obj.get("info"), dict) else {}
            if isinstance(props, dict):
                nodes.append(dict(props))
    return nodes


class AecSource:
    """Discord-style mic↔PC-audio subtraction for the jamjamjam tuner.

    The tuner listens to the MIC. When the PC plays something audible (music,
    metronome, backing track…), the loudspeakers bleed into the mic and the
    pitch estimate follows the PC audio instead of the guitar. With the AEC:

      1. a second capture runs on the SINK MONITOR of the default output,
      2. the loopback is cross-correlated against the mic to estimate the
         real delay (0..50 ms of round-trip + room latency),
      3. a numpy NLMS adaptive FIR (≈ 6.7 ms tail) maps the loopback onto
         what the mic actually hears of it,
      4. the estimate is SUBTRACTED from the mic before it reaches the tuner.

    SUBTRACTION ONLY WHEN THE PC AUDIO IS ACTUALLY HEARD BY THE MIC: under
    the correlation gate (headphones, speakers far away) the mic passes
    through UNTOUCHED and the weights decay slowly toward the next loud
    moment. Without numpy the filter short-circuits (mic untouched) so the
    tuner never becomes slower because of it.
    """

    TAPS = 320               # FIR tail ≈ 6.7 ms at 48 kHz
    MU = 0.08                # NLMS step
    CORR_GATE = 0.18         # below this agreement: bypass the subtraction
    SEARCH = 0.05            # delay estimation spans ±50 ms
    EPS = 1e-6

    def __init__(self, inner, sample_rate: int):
        self.inner = inner
        self.rate = int(sample_rate)
        self.enabled = False
        self.delay = 0
        self.delay_checked = 0.0
        self.keep = int(0.6 * self.rate)
        self.mic: list[float] = []
        self.loop: list[float] = []
        self.w = np.zeros(self.TAPS, dtype=np.float32)
        self.last_corr = 0.0
        self.subtracting = False

    def enable(self, on: bool) -> None:
        self.enabled = bool(on) and HAVE_NUMPY
        if not self.enabled:
            self.w[:] = 0.0
        self.delay_checked = 0.0

    # ── inlets ────────────────────────────────────────────────────
    def feed_loop(self, data: bytes) -> None:
        """Playback side: the loopback recorder feeds this."""
        if not data or not self.enabled:
            return
        try:
            samples = np.frombuffer(data, dtype="<i2").astype(np.float32) / 32768.0
        except (ValueError, OverflowError):
            return
        self.loop.extend(samples.tolist())
        if len(self.loop) > self.keep:
            del self.loop[:-self.keep]

    def feed(self, data: bytes) -> None:
        """Mic side: the tuner recorder calls this instead of the raw tuner."""
        if not data:
            return
        if not self.enabled or not HAVE_NUMPY:
            self.inner.feed(data)
            return
        try:
            mic = np.frombuffer(data, dtype="<i2").astype(np.float32) / 32768.0
        except (ValueError, OverflowError):
            self.inner.feed(data)
            return
        self.mic.extend(mic.tolist())
        if len(self.mic) > self.keep:
            del self.mic[:-self.keep]
        clean = self._subtracted()
        if clean is None:
            self.inner.feed(data)
            return
        out = np.clip(clean, -1.0, 1.0)
        self.inner.feed((out * 32768.0).astype("<i2").tobytes())

    # ── core ──────────────────────────────────────────────────────
    def _delay_refresh_due(self) -> bool:
        return (time.time() - self.delay_checked) >= 0.25

    def _delay_estimate(self, mic, span):
        """Cross-correlate the mic chunk against the loopback buffer."""
        loop = np.array(self.loop, dtype=np.float32)
        t0 = len(loop) - len(mic)
        best_c, best_lag = -1.0, self.delay
        mic_std = float(np.std(mic))
        for lag in range(-span, span + 1):
            s = t0 - lag
            if s - self.TAPS * 0 < 0 or s + len(mic) > len(loop):
                continue
            seg = loop[s:s + len(mic)]
            seg_std = float(np.std(seg))
            if seg_std < 1e-5:
                continue
            corr = float(np.dot(mic, seg) / (len(mic) * mic_std * seg_std + self.EPS))
            if abs(corr) > best_c:
                best_c, best_lag = abs(corr), lag
        self.last_corr = best_c
        if best_c < self.CORR_GATE:
            return False
        self.delay = int(best_lag)
        return True

    def _subtracted(self):
        """One processing step: realign if needed, then NLMS-subtract."""
        span = int(self.SEARCH * self.rate)
        multi = self.TAPS * 2
        if len(self.mic) < self.TAPS or len(self.loop) < self.TAPS + span * 2 + 64:
            return None
        mic = np.array(self.mic[-multi:], dtype=np.float32)
        mic_std = float(np.std(mic))
        if mic_std < 1e-5:
            return None
        if self._delay_refresh_due() or self.delay == 0:
            if not self._delay_estimate(mic, span):
                # Not correlated enough — the mic does not hear the PC.
                self.w *= 0.97
                return None
        # Pull the aligned loopback (already prefixed with the TAPS tail so
        # the last len(mic) dots line up with the mic).
        start = len(self.loop) - len(mic) - self.delay
        if start - (self.TAPS - 1) < 0:
            return None
        hist = np.array(self.loop[start - self.TAPS + 1:start + len(mic)],
                        dtype=np.float32)
        if len(hist) < self.TAPS:
            return None
        # Sliding windows: row i = loop[i..i+TAPS-1]; the inner FIR dot fits
        # y[i] for the aligned mic[i].
        X = np.lib.stride_tricks.sliding_window_view(hist, self.TAPS)
        X = X[:len(mic)]
        if len(X) != len(mic):
            return None
        y = X @ self.w
        res = mic - y
        seg = X[:, -1]  # the aligned loopback sample that pairs with mic[i]
        seg_std = float(np.std(seg))
        if seg_std < 1e-5:
            return None
        corr = float(np.dot(mic, seg) / (len(mic) * mic_std * seg_std + self.EPS))
        self.last_corr = corr
        if abs(corr) < self.CORR_GATE:
            # Not the PC's fault — the mic is hearing SOMETHING ELSE (the
            # guitar); do NOT subtract anything from it.
            self.w *= 0.97
            self.subtracting = False
            return None
        # Block-NLMS update, VECTORIZED: weight gradient = Σ_n res[n]·X[n]
        # with the per-sample normalisation (X@X / TAPS) folded in.
        denom = (X * X).sum(axis=1) / self.TAPS + self.EPS
        self.w += self.MU * (X.T @ (res / denom))
        norm = float(np.dot(self.w, self.w))
        if norm > 3.0:
            self.w *= math.sqrt(3.0 / norm)
        self.subtracting = True
        return mic - y


# ── Pitch detection ──────────────────────────────────────────────────────────
#
# These constants and this detector are Pitchfork's, taken verbatim from
# plugins/io.github.kemezz.pitchfork/scripts/pitch-detect.py
#   MIT License, Copyright (c) 2026 Hyeongjin
#
# Not "based on" — the same two-stage YIN, the same thresholds, the same window.
# It is copied rather than rewritten because a tuner is judged on what it hears,
# and two implementations of YIN are two different tuners: the previous numpy
# version measured 6 ms per frame against this one's 7 ms, but the difference
# that mattered was never the speed, it was that the two disagreed on real
# material.
#
# RATE is the native one. At 48 kHz this feed decimates by 3 to reach 16 kHz,
# which is why the capture stays at 48 kHz: the recorder, the AEC reference and
# the chord analysis all need it, and resampling the tuner separately would add
# a stage for no gain.
TUNER_RATE = 16000
TUNER_WINDOW = 2048
TUNER_DECIM = 3
TUNER_FMIN = 24.0
TUNER_FMAX = 500.0
TUNER_YIN_THRESHOLD = 0.12
TUNER_REJECT_ABOVE = 0.20
TUNER_GATE = 0.004


class PitchDetector:
    """Pitchfork's detector: coarse YIN on a decimated window, refined at the
    full rate."""

    def __init__(self, rate: int = TUNER_RATE, window: int = TUNER_WINDOW,
                 decim: int = TUNER_DECIM, gate: float = TUNER_GATE) -> None:
        self.rate = rate
        self.window = window
        self.decim = decim
        self.gate = gate
        self.coarse_len = window // decim
        coarse_rate = rate / decim
        self.coarse_min = max(2, int(coarse_rate / TUNER_FMAX))
        self.coarse_max = min(self.coarse_len - 2, int(math.ceil(coarse_rate / TUNER_FMIN)))

    @staticmethod
    def _prefix_energy(x: array.array) -> list:
        prefix = [0.0] * (len(x) + 1)
        total = 0.0
        for i, value in enumerate(x):
            total += value * value
            prefix[i + 1] = total
        return prefix

    @staticmethod
    def _difference(x: array.array, prefix: list, lag: int) -> float:
        n = len(x)
        head = memoryview(x)[0:n - lag]
        tail = memoryview(x)[lag:n]
        return prefix[n - lag] + (prefix[n] - prefix[lag]) - 2.0 * math.sumprod(head, tail)

    def _coarse_lag(self, x: array.array):
        step = self.decim
        decimated = array.array("d", [
            math.fsum(memoryview(x)[i * step:(i + 1) * step]) for i in range(self.coarse_len)
        ])
        prefix = self._prefix_energy(decimated)
        normalized = [math.inf] * (self.coarse_max + 2)
        running = 0.0
        for lag in range(1, self.coarse_max + 1):
            value = self._difference(decimated, prefix, lag)
            running += value
            normalized[lag] = value * lag / running if running > 0 else 1.0
        best = self.coarse_min
        for lag in range(self.coarse_min, self.coarse_max + 1):
            if normalized[lag] < TUNER_YIN_THRESHOLD:
                while lag + 1 <= self.coarse_max and normalized[lag + 1] < normalized[lag]:
                    lag += 1
                return lag, normalized[lag]
            if normalized[lag] < normalized[best]:
                best = lag
        return best, normalized[best]

    def _refine_lag(self, x: array.array, coarse_lag: int) -> float:
        prefix = self._prefix_energy(x)
        centre = coarse_lag * self.decim
        low = max(1, centre - self.decim)
        high = min(len(x) - 2, centre + self.decim)
        if low >= high:
            return float(centre)
        values = {lag: self._difference(x, prefix, lag) for lag in range(low, high + 1)}
        best = min(values, key=values.get)
        if best <= low or best >= high:
            return float(best)
        before, here, after = values[best - 1], values[best], values[best + 1]
        denominator = before - 2.0 * here + after
        if denominator <= 0:
            return float(best)
        shift = 0.5 * (before - after) / denominator
        return float(best) + max(-1.0, min(1.0, shift))

    def analyze(self, frame: array.array) -> dict:
        n = len(frame)
        if n < self.window:
            return {"hz": 0.0, "aperiodicity": 0.0}
        frame = frame[: self.window]
        mean = math.fsum(frame) / n
        centred = array.array("d", [value - mean for value in frame])
        level = math.sqrt(math.sumprod(centred, centred) / n) / 32768.0
        if level < self.gate:
            return {"hz": 0.0, "aperiodicity": 0.0}
        coarse_lag, aperiodicity = self._coarse_lag(centred)
        if aperiodicity > TUNER_REJECT_ABOVE:
            return {"hz": 0.0, "aperiodicity": aperiodicity}
        lag = self._refine_lag(centred, coarse_lag)
        if lag <= 0:
            return {"hz": 0.0, "aperiodicity": aperiodicity}
        return {"hz": self.rate / lag, "aperiodicity": aperiodicity}


class Tuner:
    """Pitch detector on the system input, refreshed from a rolling ring."""

    def __init__(self, ring_seconds: float = 0.5, naming: str = "flats"):
        self.ring_seconds = ring_seconds
        # The note NAME follows the same flats/sharps setting as chord naming.
        # It did not: the note was read out of NOTE_NAMES_FLAT directly, so
        # choosing SHARPS in the settings changed every chord and the fretboard
        # and left the tuner still reading D-flat for what the rest of the
        # plugin was calling D-sharp.
        self.naming = naming
        self._detector = PitchDetector()
        self._frames: list[float] = []
        self.current: dict = {"active": False, "freq": 0.0, "note": "", "octave": 0, "cents": 0.0}

    def feed(self, data: bytes) -> None:
        if not data:
            return
        try:
            samples = array.array("h")
            samples.frombytes(data)
        except (ValueError, OverflowError):
            samples = array.array("h", [0] * (len(data) // 2))
        if sys.byteorder != "little":
            samples.byteswap()
        self._frames.extend(float(sample) / 32768.0 for sample in samples)
        max_frames = int(SAMPLE_RATE * max(0.6, self.ring_seconds + 0.2))
        if len(self._frames) > max_frames:
            del self._frames[:-max_frames]

    def analyze(self) -> dict:
        frames = self._frames
        if len(frames) < SAMPLE_RATE // 20:
            self.current = {"active": False, "freq": 0.0, "note": "", "octave": 0, "cents": 0.0}
            return self.current
        # Pitchfork's own window, at its own rate. The capture stays at
        # SAMPLE_RATE; the newest TUNER_WINDOW * step samples of it are what the
        # detector sees, taken every `step`th sample. The two rates differ by
        # exactly TUNER_DECIM, so every third sample IS the 16 kHz signal and no
        # resampler is needed to obtain it.
        step = SAMPLE_RATE // TUNER_RATE
        frame = frames[-(TUNER_WINDOW * step):]
        if len(frame) < TUNER_WINDOW * step:
            self.current = {"active": False, "freq": 0.0, "note": "", "octave": 0, "cents": 0.0}
            return self.current
        pcm = array.array("h", (int(value * 32767.0) for value in frame[::step]))
        freq = self._detector.analyze(pcm)["hz"]
        if freq <= 0:
            self.current = {"active": False, "freq": 0.0, "note": "", "octave": 0, "cents": 0.0}
            return self.current
        midi_float = 69.0 + 12.0 * math.log2(freq / 440.0)
        midi = int(round(midi_float))
        cents = round((midi_float - midi) * 100.0)
        pc = midi % 12
        self.current = {
            "active": True,
            "freq": round(freq, 2),
            "note": note_name(pc, self.naming),
            "octave": midi // 12 - 1,
            "cents": cents,
        }
        return self.current


class AudioBuffer:
    """Rolling mono int16 buffer with hop-based frame alignment."""

    def __init__(self, hop: int = HOP_SIZE):
        self.hop = hop
        self._data = bytearray()
        self._frames: list[float] = []

    def feed(self, data: bytes) -> None:
        samples = array.array("h")
        try:
            samples.frombytes(data)
        except (ValueError, OverflowError):
            samples = array.array("h", [0] * (len(data) // 2))
        if sys.byteorder != "little":
            samples.byteswap()
        self._frames.extend(float(sample) / 32768.0 for sample in samples)
        max_frames = SAMPLE_RATE * 8
        if len(self._frames) > max_frames:
            del self._frames[:-max_frames]

    def take(self, min_frames: int) -> list[float] | None:
        if len(self._frames) < min_frames:
            return None
        # Analyze the MOST RECENT window. The previous version returned the
        # OLDEST min_frames and only advanced by one hop per call, so the
        # analyzer kept re-hearing ~2 s-stale audio (and never caught up).
        # feed() already caps the buffer at 8 s, so no trimming is needed here.
        return list(self._frames[-min_frames:])

    def last(self, seconds: float) -> list[float]:
        count = int(seconds * SAMPLE_RATE)
        if count <= 0:
            return []
        return self._frames[-count:]

    def clear(self) -> None:
        """Drop every buffered sample (used by a full analysis reset so the
        cleared key/BPM/chord do not immediately re-appear from stale audio)."""
        self._data = bytearray()
        self._frames = []


class ChordSeq:
    """Small sliding window of detected chords, used to build progressions.

    Also tracks when the detected chord sequence starts repeating and turns it
    into a looping cycle (A B C A B C → loop with chords [A, B, C]).
    """

    def __init__(self, capacity: int = 8):
        self.capacity = capacity
        self.items: list[dict] = []
        self.current: str = ""
        self.current_started: float = 0.0
        self.cycle: list[str] = []
        self.cycle_pos = 0
        self.loop_active = False
        self.loop_matches = 0

    def update(self, chord: str, now: float) -> None:
        if not chord:
            return
        if chord == self.current:
            return
        if self.current:
            self.items.append({
                "chord": self.current,
                "started": round(self.current_started, 3),
                "ended": round(now, 3),
                "duration": round(now - self.current_started, 3),
            })
            if len(self.items) > self.capacity:
                self.items = self.items[-self.capacity:]
        self._update_cycle(chord)
        self.current = chord
        self.current_started = now

    def _update_cycle(self, chord: str) -> None:
        if self.loop_active:
            expected = self.cycle[self.cycle_pos % len(self.cycle)]
            if chord == expected:
                self.cycle_pos = (self.cycle_pos + 1) % len(self.cycle)
                # The loop is only *confirmed* once a second chord of the
                # cycle has matched after activation: a bare repeat-back to
                # the first chord is not a loop yet, and a sequence that
                # stops changing right after must not keep its badge.
                self.loop_matches += 1
                return
            self.loop_active = False
            self.cycle_pos = 0
            self.loop_matches = 0
            self.cycle = [chord]
            return
        if not self.cycle:
            self.cycle = [chord]
            return
        if chord == self.cycle[0] and len(self.cycle) >= 2 and len(self.cycle) <= 8:
            self.loop_active = True
            self.cycle_pos = 1
            self.loop_matches = 1
            return
        self.cycle.append(chord)
        if len(self.cycle) >= self.capacity:
            # No loop emerged from this window; restart cycle tracking.
            self.cycle = [chord]

    def loop_snapshot(self) -> dict:
        if not self.loop_active or self.loop_matches < 2:
            return {"active": False, "chords": [], "pos": 0}
        return {
            "active": True,
            "length": len(self.cycle),
            "chords": list(self.cycle),
            "pos": self.cycle_pos,
        }

    def reset(self) -> None:
        self.items = []
        self.current = ""
        self.current_started = 0.0
        self.cycle = []
        self.cycle_pos = 0
        self.loop_active = False
        self.loop_matches = 0

    def snapshot(self, now: float) -> list[dict]:
        result = list(self.items)
        if self.current:
            result.append({
                "chord": self.current,
                "started": round(self.current_started, 3),
                "ended": round(now, 3),
                "duration": round(now - self.current_started, 3),
            })
        return result


class AudioAnalyzer:
    """Key / BPM / chord detection from mono float frames using numpy."""

    def __init__(self, naming: str = "flats"):
        self.naming = naming
        self.buffer = AudioBuffer()
        self.sequence = ChordSeq(8)
        self.key = ""
        self.key_confidence = 0.0
        self.bpm = 0.0
        # Manual overrides freeze the matching detector: setting a BPM or key
        # by hand stops that analysis until a reset clears the lock.
        self.bpm_locked = False
        self.key_locked = False
        # BPM stabilization: the readout only starts publishing a non-zero bpm
        # after 10 seconds of consistent analysis (median history not noisy).
        self._bpm_started_at: float = 0.0
        self.current_chord = ""
        self.current_chord_notes: list[str] = []
        self._chord_time = 0.0
        self.last_chroma: np.ndarray | None = None
        self.last_bass_chroma: np.ndarray | None = None
        self._hop_count = 0
        self._onset_values: list[float] = []
        self._bpm_history: list[float] = []
        self.smoothed_chroma: np.ndarray | None = None
        self._chroma_map: np.ndarray | None = None
        self._bass_map: np.ndarray | None = None
        self._map_len = 0
        self.beats_per_bar = 4
        # Song-change detection: a sustained key/chroma shift means the source
        # moved to a different song, so the UIs offer to reset the analysis.
        self.song_changed = False
        self._session_chroma: np.ndarray | None = None
        self._session_key = ""
        self._change_votes = 0
        self._pending_key = ""
        self._key_hold = 0
        self._key_low_streak = 0
        # True once a key has held for three confident analyses (≥ 0.2): the
        # plugin only draws the fretboard when a key is confidently in mind.
        self.key_stable = False
        # Silence tracking: while the capture hears only noise the backend
        # reports noSignal so the UIs can show "can't find the chord".
        self.no_signal = True
        self._quiet_chunks = 0
        self._rms = 0.0

    def feed(self, data: bytes) -> None:
        if not HAVE_NUMPY or not data:
            return
        self.buffer.feed(data)

    def analyze(self, record_progression: bool = True) -> dict | None:
        if not HAVE_NUMPY:
            return None
        chunk = self.buffer.take(ANALYSIS_CHUNK)
        if chunk is None:
            return None
        frames = np.array(chunk, dtype=np.float32)
        rms = float(np.sqrt(np.mean(np.square(frames))))
        self._rms = rms
        quiet_now = rms < SILENCE_RMS
        if quiet_now:
            self._quiet_chunks += 1
        else:
            self._quiet_chunks = 0
        # UI flag is debounced: a single quiet chunk during a phrase should not
        # flash "no signal". Detection itself is gated on the current chunk, so
        # a quiet chunk never produces a chord.
        self.no_signal = self._quiet_chunks >= QUIET_CHUNKS_TO_MUTE
        if quiet_now:
            self.current_chord = ""
            self.current_chord_notes = []
        else:
            self._hop_count += 1
            # Key, BPM and chord all come from the SAME 2 s chunk.
            self._update_chroma_from_fft(frames)
            self._update_key(frames)
            self._update_bpm(frames)
            chord = self._detect_chord()
            now = time.time()
            if chord:
                self.current_chord = chord
                self._chord_time = now
            elif now - self._chord_time > 1.5:
                # Hold the last chord briefly so a gap doesn't flicker to none.
                self.current_chord = ""
            if self.last_chroma is not None:
                self._track_song_change(self.last_chroma)
        if record_progression and PROGRESSION_ENABLED and not quiet_now:
            self.sequence.update(self.current_chord, time.time())

        return {
            "key": self.key,
            "keyConfidence": round(self.key_confidence, 3),
            "bpm": round(self.bpm, 1) if self.bpm else 0,
            "beatsPerBar": self.beats_per_bar,
            "chord": self.current_chord,
            "progression": self.sequence.snapshot(time.time()),
        }

    def _chroma_maps(self, n_freqs: int) -> None:
        """Precompute the harmonic pitch-class filters (once per FFT size)."""
        if self._chroma_map is not None and self._map_len == n_freqs:
            return
        freqs = np.fft.rfftfreq((n_freqs - 1) * 2, 1.0 / SAMPLE_RATE)
        mid = np.zeros((12, n_freqs), dtype=np.float64)
        bass = np.zeros((12, n_freqs), dtype=np.float64)
        for pc in range(12):
            for octave in range(0, 9):
                f0 = 440.0 * 2.0 ** ((pc + 12 * octave - 69) / 12.0)
                if f0 < 27 or f0 > 8000:
                    continue
                for harmonic in range(1, CHROMA_HARMONICS + 1):
                    f = f0 * harmonic
                    if f > 16000:
                        break
                    weight = CHROMA_HARMONIC_DECAY ** (harmonic - 1)
                    mask = np.exp(-0.5 * ((freqs - f) / (f * CHROMA_WIDTH)) ** 2) * weight
                    mid[pc] += mask
                    if f0 < 260:
                        bass[pc] += mask
        self._chroma_map = mid
        self._bass_map = bass
        self._map_len = n_freqs

    def _spectrum_chroma(self, frames: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
        """Pitch-class chroma (mid) plus a low-octave bass chroma.

        The raw spectrum has a huge dynamic range (peaks ≫ the noise floor), so
        the harmonic-projection filter isolates the notes cleanly. Broadband
        whitening was tried and discarded: it lifts the noise floor to ~1 and
        the projection then flattens the chroma.
        """
        windowed = frames * np.hanning(len(frames))
        spectrum = np.abs(np.fft.rfft(windowed))
        self._chroma_maps(len(spectrum))
        mid = self._chroma_map @ spectrum
        bass = self._bass_map @ spectrum
        for vector in (mid, bass):
            total = float(np.sum(vector))
            if total > 1e-9:
                vector /= total
        return mid, bass

    def _fft_chroma(self, frames: np.ndarray) -> np.ndarray:
        return self._spectrum_chroma(frames)[0]

    def _update_key(self, frames: np.ndarray) -> None:
        if self.key_locked:
            return
        chroma = self.smoothed_chroma
        if chroma is None or float(np.max(chroma)) < KEY_PEAK_MIN:
            return

        shaped = np.power(chroma, CHROMA_POWER)
        norm = float(np.linalg.norm(shaped)) or 1.0
        shaped = shaped / norm
        candidates = []
        for root in range(12):
            for profile, mode in ((KS_MAJOR, ""), (KS_MINOR, "m")):
                rolled = np.roll(profile, root)
                rolled = rolled / (float(np.linalg.norm(rolled)) or 1.0)
                candidates.append((float(np.dot(shaped, rolled)), root, mode))
        candidates.sort(key=lambda item: item[0], reverse=True)
        score, root, mode = candidates[0]
        gap = score - candidates[1][0]
        confidence = max(0.0, min(1.0, gap * 4.0))
        name = f"{note_name(root, self.naming)}{mode}"
        KEY_CONF_THRESHOLD = 0.2  # below this, the Krumhansl score is too noisy
        if name == self._pending_key:
            self._key_hold += 1
        else:
            self._pending_key = name
            self._key_hold = 1
        if confidence >= KEY_CONF_THRESHOLD:
            if self._key_hold >= 3 or (not self.key and confidence >= KEY_CONF_THRESHOLD):
                self.key = name
                self.key_confidence = confidence
                self.key_stable = self._key_hold >= 3
                self._key_low_streak = 0
        else:
            # The candidate is weak: do not overwrite a confident key.
            # If the existing key has been "low confidence" for several
            # analyses in a row, drop it (the song drifted, the mic got
            # noisy, …). The plugin tells the UI to offer a reset.
            if self.key and gap < 0.05:
                self._key_low_streak += 1
                if self._key_low_streak >= 3:
                    self.key = ""
                    self.key_confidence = 0.0
                    self.key_stable = False
                    self.song_changed = True
            else:
                self._key_low_streak = 0

    @property
    def _key_established(self) -> bool:
        return bool(self.key)

    def _update_bpm(self, frames: np.ndarray) -> None:
        """Onset-envelope autocorrelation over the same 2 s chunk as the key.

        Unlike a per-chunk single onset value, this builds ~90 onset frames per
        analysis, so the tempo locks in within a couple of chunks instead of ~20.
        """
        if self.bpm_locked:
            return
        hop = HOP_SIZE
        frame_total = len(frames) // hop
        if frame_total < 12:
            return
        magnitudes = []
        for index in range(frame_total):
            segment = frames[index * hop:(index + 1) * hop]
            magnitudes.append(np.abs(np.fft.rfft(segment * np.hanning(hop))))
        envelope = []
        for index in range(1, len(magnitudes)):
            flux = float(np.sum(np.maximum(0.0, magnitudes[index] - magnitudes[index - 1])))
            envelope.append(flux)
        if len(envelope) < 12:
            return
        env = np.array(envelope, dtype=np.float64)
        env = env - float(env.mean())
        frame_rate = SAMPLE_RATE / hop
        min_lag = max(2, int(math.floor(frame_rate * 60.0 / BPM_MAX)))
        max_lag = min(len(env) - 2, int(math.ceil(frame_rate * 60.0 / BPM_MIN)))
        if max_lag <= min_lag:
            return
        best_lag = 0
        best_corr = 0.12  # require a real periodic peak
        correlations: dict[int, float] = {}
        for lag in range(min_lag, max_lag + 1):
            left = env[:-lag]
            right = env[lag:]
            denom = math.sqrt(float(np.dot(left, left)) * float(np.dot(right, right)))
            if denom <= 1e-9:
                continue
            corr = float(np.dot(left, right)) / denom
            correlations[lag] = corr
            if corr > best_corr:
                best_corr = corr
                best_lag = lag
        if best_lag == 0:
            return
        # Refine the integer lag: at ~47 fps one lag is ~5 BPM around 120, so
        # the raw peak gives a quantized tempo. Fit a parabola through the
        # neighbouring correlations to estimate the true peak position.
        lag = float(best_lag)
        left = correlations.get(best_lag - 1)
        right = correlations.get(best_lag + 1)
        if left is not None and right is not None:
            curvature = left - 2.0 * best_corr + right
            if abs(curvature) > 1e-9:
                lag += 0.5 * (left - right) / curvature
        lag = max(1.0, lag)
        bpm = 60.0 * frame_rate / lag
        while bpm < 65.0:
            bpm *= 2.0
        while bpm > 175.0:
            bpm /= 2.0
        self._bpm_history.append(bpm)
        # Keep a longer history than the median window so the "first valid
        # bpm" age can be tracked across the BPM_MAX of ~12 entries (≈6 s of
        # analysis). We mirror the time series in `_bpm_started_at`.
        self._bpm_history = self._bpm_history[-32:]
        if self._bpm_started_at == 0.0:
            self._bpm_started_at = time.monotonic()
        # BPM must hold for 10 seconds of continuous analysis before being
        # published — before that the readout stays at 0 (the frontend shows
        # a "finding tempo…" hint).
        stable_for = time.monotonic() - self._bpm_started_at
        if stable_for < 10.0:
            self.bpm = 0.0
        else:
            self.bpm = float(np.median(self._bpm_history))
        # Time signature: does the bar repeat every 4 beats or every 3?
        three = correlations.get(best_lag * 3)
        four = correlations.get(best_lag * 4)
        if three is not None and four is not None and abs(three - four) > 0.015:
            self.beats_per_bar = 4 if four >= three else 3
        else:
            self.beats_per_bar = 4

    def _update_chroma_from_fft(self, frames: np.ndarray) -> None:
        mid, bass = self._spectrum_chroma(frames)
        self.last_chroma = mid
        self.last_bass_chroma = bass
        if self.smoothed_chroma is None:
            self.smoothed_chroma = mid.copy()
        else:
            self.smoothed_chroma = self.smoothed_chroma * 0.6 + mid * 0.4

    def _track_song_change(self, chroma: np.ndarray) -> None:
        """Flag when a sustained key + chroma shift means a different song."""
        if self._session_chroma is None:
            self._session_chroma = chroma.copy()
            self._session_key = self.key
            return
        distance = 0.5 * float(np.sum(np.abs(chroma - self._session_chroma)))
        key_moved = bool(self.key and self._session_key and self.key != self._session_key)
        if key_moved and distance > 0.3:
            self._change_votes += 1
        else:
            self._change_votes = max(0, self._change_votes - 1)
        if self._change_votes >= 3:
            self.song_changed = True
        # Drift the reference slowly so a gradual modulation is not a false hit.
        self._session_chroma = self._session_chroma * 0.98 + chroma * 0.02

    def _detect_chord(self) -> str:
        if self.last_chroma is None:
            self.current_chord_notes = []
            return ""
        chroma = np.array(self.last_chroma, dtype=np.float64)
        total = float(np.sum(chroma))
        if total <= 1e-9:
            self.current_chord_notes = []
            return ""
        chroma = chroma / total
        # Tonal gate: a real chord concentrates energy on a few pitch classes;
        # broadband noise spreads it almost evenly, so reject a flat chroma.
        if float(np.max(chroma)) < CHORD_PEAK_MIN:
            self.current_chord_notes = []
            return ""
        shaped = np.power(chroma, CHROMA_POWER)
        shaped = shaped / (float(np.sum(shaped)) or 1.0)
        # Bass note (low octaves only) resolves slash chords / inversions and
        # the C6-vs-Am7 ambiguity.
        bass_pc = -1
        if self.last_bass_chroma is not None:
            bass_total = float(np.sum(self.last_bass_chroma))
            if bass_total > 1e-9:
                bass = self.last_bass_chroma / bass_total
                if float(np.max(bass)) >= 0.16:
                    bass_pc = int(np.argmax(bass))
        scored = []
        maxc = float(np.max(shaped))
        for root in range(12):
            for intervals, suffix in CHORD_TEMPLATES:
                tones = [(root + interval) % 12 for interval in intervals]
                inside = float(sum(shaped[t] for t in tones))
                outside = 1.0 - inside
                # Prefer the smallest chord that actually explains the notes:
                # every extra template tone costs, and a "missing" tone (one
                # far weaker than the strongest pitch) costs more -- this is
                # what stops a plain triad from being read as a maj7/6.
                missing = sum(1 for t in tones if shaped[t] < 0.35 * maxc)
                score = (inside - 0.55 * outside
                         - 0.20 * maxc * len(tones)
                         - 0.45 * maxc * missing
                         + 0.15 * float(shaped[root]))
                if bass_pc >= 0:
                    score += 0.12 if bass_pc == root else -0.04
                scored.append((score, root, suffix, intervals))
        scored.sort(key=lambda item: item[0], reverse=True)
        best_score, root, suffix, intervals = scored[0]
        second_score = scored[1][0] if len(scored) > 1 else 0.0
        if best_score <= 0.0:
            self.current_chord_notes = []
            return ""
        # Reject ambiguous matches: if the runner-up template is nearly as good,
        # there is no real chord (a single note or a noisy spectrum).
        if second_score > 0.0 and best_score < second_score * CHORD_MARGIN:
            self.current_chord_notes = []
            return ""
        self.current_chord_notes = [
            note_name((root + interval) % 12, self.naming) for interval in intervals
        ]
        name = f"{note_name(root, self.naming)}{suffix}"
        if bass_pc >= 0 and bass_pc != root:
            name += "/" + note_name(bass_pc, self.naming)
        return name

    def reset(self) -> None:
        self.key = ""
        self.key_confidence = 0.0
        self.bpm = 0.0
        self.beats_per_bar = 4
        self.song_changed = False
        self.current_chord = ""
        self.current_chord_notes = []
        self.sequence = ChordSeq(8)
        self.smoothed_chroma = None
        self.last_chroma = None
        self.last_bass_chroma = None
        self._session_chroma = None
        self._session_key = ""
        self._change_votes = 0
        self._pending_key = ""
        self._key_hold = 0
        self.key_stable = False
        self._chord_time = 0.0
        self._onset_values = []
        self._bpm_history = []
        self._quiet_chunks = 0
        # Empty the audio window too: without this the very next analysis pass
        # re-detects the still-playing audio within ~0.15 s and the cleared
        # cards look like the reset did nothing.
        self.buffer.clear()


CLICK_SECONDS = 0.032
CLICK_CHUNK_FRAMES = 256


class ClickTrack:
    """Metronome click streaming to PipeWire through pw-play.

    Modelled on dlpwaters.metronome's engine: one continuous raw s16 stream
    written in 256-frame chunks, with the click synthesised per sample (32 ms,
    exponential envelope, 1320 Hz downbeat / 880 Hz other beats) and a 20 ms
    PipeWire latency. The player paces the writes; there is no sleep loop.
    """

    def __init__(self):
        self.metronome_gain = 0.7
        self.click_custom = False
        self.custom_down: list[float] | None = None
        self.custom_up: list[float] | None = None
        self.metronome_enabled = False
        self.metronome_bpm = 120.0
        self.metronome_beats = 4
        self.metronome_phase = 0.0
        self.metronome_beat = 0
        self.running = False
        self.error = ""
        self._process: subprocess.Popen[bytes] | None = None
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._wake = threading.Event()
        self._thread: threading.Thread | None = None
        self._thread = threading.Thread(target=self._run, name="jamjamjam-click", daemon=True)
        self._thread.start()

    def set_metronome_gain(self, gain: float) -> None:
        with self._lock:
            self.metronome_gain = max(0.0, min(1.0, float(gain)))

    def set_click_custom(self, enabled: bool, down: str = "", up: str = "") -> None:
        """Enable/refresh custom click samples. Paths are reloaded when given;
        missing/unreadable files fall back to the built-in tone."""
        loaded_down = self._load_click_wav(down)
        loaded_up = self._load_click_wav(up)
        with self._lock:
            if down and loaded_down is not None:
                self.custom_down = loaded_down
            if up and loaded_up is not None:
                self.custom_up = loaded_up
            if enabled:
                self.click_custom = bool(self.custom_down or self.custom_up)
            else:
                self.click_custom = False

    @staticmethod
    def _load_click_wav(path: str) -> list[float] | None:
        """Load a short mono-converted, resample-accepted .wav click sample."""
        try:
            import wave
            with wave.open(path, "rb") as fh:
                channels = fh.getnchannels()
                width = fh.getsampwidth()
                rate = fh.getframerate()
                raw = fh.readframes(min(fh.getnframes(), rate * 2))
            if width == 2:
                samples = np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0
            elif width == 4:
                samples = np.frombuffer(raw, dtype="<i4").astype(np.float32) / 2147483648.0
            else:
                samples = np.frombuffer(raw, dtype=np.uint8).astype(np.float32)
                samples = (samples - 128.0) / 128.0
            if channels > 1:
                samples = samples.reshape(-1, channels).mean(axis=1)
            if rate != SAMPLE_RATE and rate > 0:
                idx = np.linspace(0, len(samples) - 1, num=int(len(samples) * SAMPLE_RATE / rate))
                samples = np.interp(idx, np.arange(len(samples)), samples)
            peak = float(np.max(np.abs(samples))) if len(samples) else 0.0
            if peak > 0.0:
                samples = samples / peak
            return samples[: SAMPLE_RATE].tolist()
        except (OSError, ValueError, ImportError):
            return None

    def set_metronome(self, enabled: bool, bpm: float = 120.0, beats: int = 4) -> None:
        with self._lock:
            was_enabled = self.metronome_enabled
            self.metronome_enabled = bool(enabled) and bpm > 0.0
            self.metronome_bpm = max(40.0, min(240.0, float(bpm)))
            self.metronome_beats = max(1, int(beats))
            if self.metronome_enabled and not was_enabled:
                # Start on a downbeat; tempo updates while running keep the
                # current phase so the pulse does not jump.
                self.metronome_phase = 0.0
                self.metronome_beat = 0
        self._wake.set()

    def stop(self) -> None:
        self._stop.set()
        self._wake.set()
        if self._thread and self._thread.is_alive():
            self._thread.join(timeout=1.0)
        self._close_process()

    def _render_block(self, frame_count: int) -> array.array:
        with self._lock:
            met_on = self.metronome_enabled
            bpm = self.metronome_bpm
            met_beats = self.metronome_beats
            click_gain = self.metronome_gain
            custom_down = self.custom_down if self.click_custom else None
            custom_up = self.custom_up if self.click_custom else None

        output = array.array("h")
        if not met_on or bpm <= 0.0:
            output.extend([0] * frame_count)
            return output

        frames_per_beat = SAMPLE_RATE * 60.0 / bpm
        click_frames = max(1, int(SAMPLE_RATE * CLICK_SECONDS))
        for _ in range(frame_count):
            accented = self.metronome_beat % met_beats == 0
            value = 0.0
            wave = (custom_down if accented else custom_up)
            if wave is not None:
                index = int(self.metronome_phase)
                if index < len(wave):
                    value = float(wave[index]) * click_gain
            elif self.metronome_phase < click_frames:
                frequency = 1320.0 if accented else 880.0
                gain = click_gain * (0.80 if accented else 0.56)
                phase = self.metronome_phase
                envelope = math.exp(-7.0 * phase / click_frames)
                transient = math.exp(-35.0 * phase / click_frames)
                sine = math.sin(2.0 * math.pi * frequency * phase / SAMPLE_RATE)
                value = gain * envelope * sine + gain * 0.12 * transient
            output.append(max(-32767, min(32767, int(32767 * value))))

            self.metronome_phase += 1.0
            if self.metronome_phase >= frames_per_beat:
                self.metronome_phase -= frames_per_beat
                self.metronome_beat = (self.metronome_beat + 1) % met_beats
        return output

    def _run(self) -> None:
        """Keep the player fed with small continuous chunks, like dlpwaters."""
        while not self._stop.is_set():
            with self._lock:
                should_stream = self.metronome_enabled
            if not should_stream:
                self._close_process()
                self._wake.wait(0.2)
                self._wake.clear()
                continue
            if not self._process and not self._start_process():
                self._stop.wait(1.0)
                continue
            block = self._render_block(CLICK_CHUNK_FRAMES).tobytes()
            try:
                assert self._process and self._process.stdin
                self._process.stdin.write(block)
            except (BrokenPipeError, OSError) as error:
                self.error = f"PipeWire audio stopped: {error}"
                self._close_process()
                self._stop.wait(0.5)

    def _start_process(self) -> bool:
        if shutil.which("pw-play"):
            command = [
                "pw-play", "--raw", "--format", "s16", "--rate", str(SAMPLE_RATE),
                "--channels", "1", "--latency", "20ms", "--media-role", "Music",
                "-P", 'media.name=jamjamjam, application.name="jamjamjam (click)", node.name="jamjamjam-click"',
                "-",
            ]
        elif shutil.which("aplay"):
            command = ["aplay", "-q", "-r", str(SAMPLE_RATE), "-f", "S16_LE", "-c", "1"]
        else:
            self.running = False
            self.error = "Metronome needs pw-play or aplay, but neither was found."
            return False
        try:
            self._process = subprocess.Popen(
                command,
                stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, bufsize=0,
            )
            self.running = True
            self.error = ""
            return True
        except OSError as error:
            self.running = False
            self.error = f"Could not start PipeWire audio: {error}"
            self._process = None
            return False

    def _close_process(self) -> None:
        process = self._process
        self._process = None
        self.running = False
        if not process:
            return
        try:
            if process.stdin:
                process.stdin.close()
            process.terminate()
            process.wait(timeout=0.5)
        except (OSError, subprocess.TimeoutExpired):
            try:
                process.kill()
            except OSError:
                pass


class AudioRecorder:
    """Captures raw s16 PCM and feeds the analyzer.

    `kind="monitor"` targets a sink monitor (system audio, sampled *before*
    the output volume/mute, so detection keeps working even when the speakers
    are muted); `kind="source"` targets a real input (microphone/line).
    """

    def __init__(self, analyzer, target: str = "", kind: str = "monitor"):
        self.analyzer = analyzer
        self.target = target
        self.kind = kind
        self.process: subprocess.Popen[bytes] | None = None
        self.running = False
        self.error = ""
        self.backend = ""
        self._stop = threading.Event()

    def _build_command(self) -> list[str] | None:
        monitor = self.kind == "monitor"
        if self.target:
            if monitor and HAVE_PAREC:
                # parec reaches sink monitors (pw-record cannot on PipeWire 1.6).
                return ["parec", "-d", self.target, "--format=s16le",
                        "--rate", str(SAMPLE_RATE), "--channels=1"]
            if HAVE_PWRECORD:
                return ["pw-record", "--raw", "--format", "s16", "--rate", str(SAMPLE_RATE),
                        "--channels", "1", "--latency", "96ms", "--target", self.target, "-"]
            if HAVE_PAREC:
                return ["parec", "-d", self.target, "--format=s16le",
                        "--rate", str(SAMPLE_RATE), "--channels=1"]
            return None
        # No explicit target: the default source (microphone).
        if HAVE_PWRECORD:
            return ["pw-record", "--raw", "--format", "s16", "--rate", str(SAMPLE_RATE),
                    "--channels", "1", "--latency", "96ms", "-"]
        if HAVE_PAREC:
            return ["parec", "--format=s16le", "--rate", str(SAMPLE_RATE), "--channels=1"]
        return None

    def start(self) -> bool:
        self._stop.clear()
        command = self._build_command()
        if not command:
            self.error = "No audio capture tool found (install parec/pw-record)"
            self.running = False
            return False
        self.backend = command[0]
        try:
            self.process = subprocess.Popen(
                command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL, bufsize=0,
            )
        except OSError as error:
            self.error = f"Could not start audio capture: {error}"
            self.running = False
            return False
        self.running = True
        self.error = ""
        threading.Thread(target=self._read_loop, name="jamjamjam-capture", daemon=True).start()
        return True

    def _read_loop(self) -> None:
        assert self.process and self.process.stdout
        while not self._stop.is_set():
            try:
                chunk = self.process.stdout.read(4096)
            except OSError as error:
                self.error = f"Audio capture read error: {error}"
                self.running = False
                return
            if not chunk:
                # The capture process ended (device vanished, tool error);
                # mark it stopped so the supervisor can restart it.
                self.running = False
                return
            self.analyzer.feed(chunk)

    def stop(self) -> None:
        self._stop.set()
        if self.process:
            try:
                self.process.terminate()
                self.process.wait(timeout=0.5)
            except (OSError, subprocess.TimeoutExpired):
                try:
                    self.process.kill()
                except OSError:
                    pass
        self.process = None
        self.running = False


class GuitarModes:
    """Scale degree positions on a guitar neck."""

    STRINGS = ("E", "B", "G", "D", "A", "E")

    @staticmethod
    def tone_map() -> dict[str, int]:
        return {"C": 0, "C♯": 1, "Db": 1, "D": 2, "D♯": 3, "Eb": 3, "E": 4, "F": 5,
                "F♯": 6, "Gb": 6, "G": 7, "G♯": 8, "Ab": 8, "A": 9, "A♯": 10, "Bb": 10, "B": 11}

    @classmethod
    def scales_for(cls, key: str, naming: str = "flats") -> dict:
        names = NOTE_NAMES_FLAT if naming == "flats" else NOTE_NAMES_SHARP
        if not key:
            return {"root": -1, "scaleType": "", "strings": [], "dots": []}
        mode = "major"
        root_name = key
        if key.endswith("m"):
            mode = "minor"
            root_name = key[:-1]
        elif key.endswith("maj"):
            mode = "major"
            root_name = key[:-3]
        tones = cls.tone_map()
        root_key = root_name.replace("♭", "b").replace("♯", "#")
        if root_key not in tones:
            return {"root": -1, "scaleType": "", "strings": [], "dots": []}
        root = tones[root_key]
        scale = major_scale_degrees(root) if mode == "major" else natural_minor_scale_degrees(root)
        degree_of = {pc: index + 1 for index, pc in enumerate(scale)}

        strings_out = []
        dots = []
        string_pcs = [cls.tone_map()[name] for name in cls.STRINGS]
        for string_index, string_tone in enumerate(string_pcs):
            fret_list = []
            for fret in range(0, 13):
                pc = (string_tone + fret) % 12
                degree = degree_of.get(pc, 0)
                fret_list.append({"fret": fret, "degree": degree, "pc": pc})
                if degree:
                    dots.append({"string": string_index, "fret": fret, "degree": degree})
            strings_out.append({
                "name": cls.STRINGS[string_index],
                "tone": string_tone,
                "frets": fret_list,
            })
        return {
            "root": root,
            "scaleType": mode,
            "strings": strings_out,
            "dots": dots,
            "degreeOf": degree_of,
            "label": f"{names[root]} {mode}",
        }


class AudioAnalyzerBackend:
    def __init__(self, state_file: str = "", command_file: str = "", tuner: bool = True):
        self.config = load_config()
        self.naming = self.config.get("noteNaming", "flats")
        self.state_file = state_file or os.path.expanduser("~/.local/state/jamjamjam/state.json")
        self.command_file = command_file or os.path.expanduser("~/.local/state/jamjamjam/commands.json")
        self.analyzer = AudioAnalyzer(self.naming)
        self.recorder = AudioRecorder(self.analyzer)
        self.click = ClickTrack()
        # self.naming, not a `naming` parameter: this is read straight from the
        # saved config so the tuner starts on the naming the user chose, rather
        # than the flats default and silently disagreeing with every chord.
        self.tuner = Tuner(naming=self.naming) if tuner else None
        self.tuner_recorder: AudioRecorder | None = None
        # AEC (mic↔PC-audio echo subtraction for the tuner): created only
        # when the settings toggle is ON (aecEnabled), and REBUILT when the
        # default sink monitor changes (the loopback must follow the output).
        self.aec_source: AecSource | None = None
        self.aec_recorder: AudioRecorder | None = None
        self.running = True
        self.dirty = True
        self.last_chord_throttle = 0.0
        self.analysis_timer = 0.0
        self.capture_target = ""
        # Last mtime must START at the CURRENT file (a leftover commands.json
        # from a previous session — e.g. a stale {"op":"setMetronome"} — must
        # NOT re-trigger on backend start. The mtime of the fresh file only).
        try:
            self.last_command_file_mtime = Path(self.command_file).stat().st_mtime
        except OSError:
            self.last_command_file_mtime = 0.0
        # System audio (monitor of the default sink) is the analysis source;
        # the default source (microphone) always feeds the tuner.
        self.monitor_target, self.input_target = default_audio_nodes()
        self.recorder.target = self.monitor_target
        self.capture_target = self.monitor_target or "@DEFAULT_SOURCE@"
        self.panel_visible = False
        self.hold = False
        self.paused = False
        self.analysis_locked = False
        # When False, opening the panel only enables the tuner; the analyzer
        # waits for an explicit start (resetAnalysis/startAnalysis or hold).
        self.auto_analyze = bool(self.config.get("autoAnalyze", True))
        self.analysis_suspended = not self.auto_analyze
        # MANUAL overrides (right-click a KEY/BPM card): pinned values that
        # SURVIVE until a reset ('r'/resetAnalysis) clears them back to the
        # detector's live state.
        self.manual_key = ""
        self.manual_bpm = 0.0
        self.manual_time_signature = ""
        # UI-configurable settings from config.json (chord box, AEC hint,
        # metronome click). Applied onto the click track / published in snapshot.
        self.show_chord_box = bool(self.config.get("showChordBox", False))
        self.aec_enabled = bool(self.config.get("aecEnabled", False))
        # An empty value means "follow the system default", which is also what a
        # config without the key means -- so a machine whose default source moves
        # keeps working, and an unplugged interface can be escaped from.
        self.tuner_input = str(self.config.get("tunerInput", ""))
        self._apply_click_config()
        self.input_source = "pc"
        self.metronome_enabled = False
        # 90-second persistence: when the Panel is closed and reopened quickly
        # (restart of the backend), the last written state snapshot is
        # re-read if it is fresh enough so the analysis data is not lost.
        self._restore_recent_state(max_age=90.0)
        # Accumulated-progression bookkeeping: a second analysis appends to the
        # existing sequence; if the key moved, the UIs advise a reset.
        self.needs_reset = False
        self._progression_key = ""
        self.mic_available = True
        self.mic_muted = False
        self.last_mic_check = 0.0
        self.last_tuner_analysis = 0.0
        self.tuner_result: dict = {"active": False, "freq": 0.0, "note": "", "octave": 0, "cents": 0.0}
        self._apply_target()
        self._auto_start()

    def _auto_start(self):
        # PRIVACY GUARD: the tuner's mic capture must NEVER run while the
        # panel is closed — set up the tuner WITHOUT starting its capture.
        # _sync_capture() starts/stops it against the panel-visible/hold gate.
        self._restart_tuner()

    def _restart_tuner(self):
        """(Re)point the tuner's capture at the default microphone.

        With AEC enabled, an AecSource sits BETWEEN the mic recorder and the
        inner Tuner (it subtracts the aligned PC-audio estimate), and a second
        capture runs on the sink monitor as the subtraction reference. The
        loopback recorder share the same privacy gate in _sync_capture().
        """
        if self.tuner is None:
            return
        was_running = bool(self.tuner_recorder and self.tuner_recorder.running)
        target = self.input_target or ""
        analyzer = self.tuner
        self.aec_source = None
        if self.aec_enabled:
            self.aec_source = AecSource(self.tuner, SAMPLE_RATE)
            self.aec_source.enable(True)
            analyzer = self.aec_source
        if self.tuner_recorder is None or self.tuner_recorder.analyzer is not analyzer:
            if self.tuner_recorder is not None and self.tuner_recorder.running:
                self.tuner_recorder.stop()
            self.tuner_recorder = AudioRecorder(analyzer, target=target, kind="source")
        else:
            self.tuner_recorder.target = target
            self.tuner_recorder.kind = "source"
        # The loopback recorder mirrors the microphone one (same gate in
        # _sync_capture, so it is never living while the plugin is closed).
        if self.aec_source is not None:
            if self.aec_recorder is None:
                self.aec_recorder = AudioRecorder(
                    self.aec_source, target=self.monitor_target or "",
                    kind="monitor")
            else:
                self.aec_recorder.stop()
                self.aec_recorder.target = self.monitor_target or ""
                self.aec_recorder.kind = "monitor"
        elif self.aec_recorder is not None:
            self.aec_recorder.stop()
            self.aec_recorder = None
        if was_running:
            self._sync_capture()

    # A source the user picked explicitly, overriding the default source. Empty
    # means "follow the system default", which is what makes the plugin behave
    # the same on a machine where PipeWire moves the default around.
    tuner_input: str = ""

    def _apply_target(self) -> None:
        # An explicitly chosen tuner input outranks the source mode.
        #
        # TUNER INPUT is a direct statement of what the tuner should hear, so it
        # cannot be overruled by whether the analyzer happens to be on PC audio
        # or on the mic: picking an interface in the dropdown and still getting
        # the speakers is the setting looking broken. "" (System default) hands
        # the decision back to the source mode below, which is also what makes
        # the default entry a way out rather than a dead end.
        if self.tuner_input:
            self.recorder.target = self.tuner_input
            self.recorder.kind = "source"
            self.capture_target = self.tuner_input
        elif self.input_source == "pc":
            # Pre-volume monitor of the DEFAULT sink: follows whatever output
            # device is active (internal/HDMI/Bluetooth/jack) and stays audible
            # to the analyzer even when the output is muted or at 0 volume.
            self.recorder.target = self.monitor_target or ""
            self.recorder.kind = "monitor"
            self.capture_target = self.monitor_target or "@DEFAULT_SOURCE@"
        else:
            # Mic mode, no explicit tuner input: the system default source.
            # Same selection model Pitchfork uses — the default entry is always
            # present and always first, so there is a way back from a device
            # that has since been unplugged.
            target = self.input_target or ""
            self.recorder.target = target
            self.recorder.kind = "source"
            self.capture_target = target or "@DEFAULT_SOURCE@"

    def _refresh_audio_nodes(self) -> None:
        """Re-resolve the default sink/source and follow output-device changes.

        PipeWire moves the default sink when the user switches output (internal
        ↔ HDMI ↔ Bluetooth ↔ jack); the monitor target must follow or the
        analyzer would keep listening to the old, now-silent device.
        """
        monitor, input_target = default_audio_nodes()
        if monitor == self.monitor_target and input_target == self.input_target:
            return
        self.monitor_target, self.input_target = monitor, input_target
        self._restart_tuner()
        was_running = self.recorder.running
        if was_running:
            self.recorder.stop()
        self._apply_target()
        if was_running:
            self.recorder.start()
        self.dirty = True

    def _sync_capture(self) -> None:
        # Analysis runs while the panel is open or a hold is active, unless the
        # user turned auto-analysis off and has not started it explicitly.
        desired = (not self.paused) and (not self.analysis_locked) and (
            not self.analysis_suspended
        ) and (self.panel_visible or self.hold)
        self._apply_target()
        if desired and not self.recorder.running:
            self.recorder.start()
            self.dirty = True
        elif not desired and self.recorder.running:
            self.recorder.stop()
            self.dirty = True

        # PRIVACY GUARD: the microphone (tuner) is captured ONLY while the
        # plugin is actually in use (panel open or analysis hold active). The
        # mic must NEVER run while nothing is open. The tuner keeps working
        # even when the chord/analysis path is paused or suspended.
        tuner_desired = (not self.analysis_locked) and (
            self.panel_visible or self.hold
        ) and (self.tuner is not None)
        if tuner_desired and self.tuner_recorder is not None and not self.tuner_recorder.running:
            self.tuner_recorder.start()
            self.dirty = True
        elif not tuner_desired and self.tuner_recorder is not None and self.tuner_recorder.running:
            self.tuner_recorder.stop()
            self.dirty = True
        # The AEC loopback (sink monitor) lives with the mic: same privacy
        # rule (never capturing while the plugin is closed).
        if tuner_desired and self.aec_recorder is not None and not self.aec_recorder.running:
            self.aec_recorder.start()
            self.dirty = True
        elif (not tuner_desired) and self.aec_recorder is not None and self.aec_recorder.running:
            self.aec_recorder.stop()
            self.dirty = True

    def active_time_signature(self) -> str:
        if self.manual_time_signature:
            return self.manual_time_signature
        return f"{max(1, int(self.analyzer.beats_per_bar))}/4"

    def active_beats_per_bar(self) -> int:
        try:
            return max(1, int(self.active_time_signature().split("/", 1)[0]))
        except (TypeError, ValueError):
            return max(1, int(self.analyzer.beats_per_bar))

    def snapshot(self) -> dict:
        now = time.time()
        tuner_result = self.tuner_result
        return {
            "type": "snapshot",
            "recording": self.recorder.running,
            "recorderError": self.recorder.error,
            "captureTarget": self.capture_target,
            "captureBackend": self.recorder.backend,
            "inputSource": self.input_source,
            "visible": self.panel_visible,
            "hold": self.hold,
            "paused": self.paused,
            "locked": self.analysis_locked,
            "autoAnalyze": self.auto_analyze,
            "analysisSuspended": self.analysis_suspended,
            "needsReset": self.needs_reset,
            "mic": {"available": self.mic_available, "muted": self.mic_muted},
            "config": {
                "noteNaming": self.naming,
                "showChordBox": self.show_chord_box,
                "showKeyCard": bool(self.config.get("showKeyCard", True)),
                "showBpmCard": bool(self.config.get("showBpmCard", True)),
                "showChordCard": bool(self.config.get("showChordCard", True)),
                "autoAnalyze": self.auto_analyze,
                "aecEnabled": self.aec_enabled,
            },
            "metronome": {
                "enabled": self.metronome_enabled,
                "bpm": round(self.click.metronome_bpm, 1),
                "beats": self.click.metronome_beats,
                "volume": self.click.metronome_gain,
                "custom": self.click.click_custom,
                "customDown": self.config.get("customDown", ""),
                "customUp": self.config.get("customUp", ""),
            },
            "analyzer": {
                "key": self.manual_key or self.analyzer.key,
                "keyConfidence": (1.0 if self.manual_key else round(self.analyzer.key_confidence, 3)),
                "keyStable": bool(self.manual_key) or self.analyzer.key_stable,
                # Show the tempo the metronome is actually playing even before
                # any analysis exists; live analysis takes over once it has a value.
                "bpm": (round(self.manual_bpm, 1) if self.manual_bpm
                        else (round(self.analyzer.bpm, 1) if self.analyzer.bpm
                              else (round(self.click.metronome_bpm, 1)
                                    if self.metronome_enabled else 0))),
                "beatsPerBar": self.active_beats_per_bar(),
                "timeSignature": self.active_time_signature(),
                "currentChord": self.analyzer.current_chord,
                "chordNotes": list(self.analyzer.current_chord_notes),
                "noSignal": self.analyzer.no_signal,
                "songChanged": self.analyzer.song_changed,
                "progression": self.analyzer.sequence.snapshot(now) if PROGRESSION_ENABLED else [],
            },
            "loop": self.analyzer.sequence.loop_snapshot() if PROGRESSION_ENABLED
                    else {"active": False, "length": 0, "chords": [], "pos": 0},
            "click": {
                "running": self.click.running,
                "error": self.click.error,
            },
            "tuner": tuner_result,
            "guitar": GuitarModes.scales_for(self.analyzer.key, self.naming),
            "noteNaming": self.naming,
        }

    def handle_command(self, request: dict) -> dict:
        op = str(request.get("op", ""))
        if op == "startRecording":
            self.analysis_suspended = False
            self.analysis_locked = False
            changed = self.recorder.start()
            if changed:
                self.analyzer.reset()
            return {"started": changed}
        if op == "stopRecording":
            self.recorder.stop()
            return {}
        if op == "toggleRecording":
            if self.recorder.running:
                self.recorder.stop()
            else:
                self.analysis_suspended = False
                self.analysis_locked = False
                self.recorder.start()
                self.analyzer.reset()
            return {}
        if op == "resetAnalysis":
            # A reset wipes the MANUAL overrides too: the cards go back to the
            # detector's live state (the only way to leave a manual entry).
            self.manual_key = ""
            self.manual_bpm = 0.0
            self.manual_time_signature = ""
            self.analyzer.key_locked = False
            self.analyzer.bpm_locked = False
            self.analyzer.reset()
            self.needs_reset = False
            self._progression_key = ""
            self.analysis_locked = False
            self.analysis_suspended = False
            self._sync_capture()
            self.dirty = True
            return {}
        if op == "setManualKey":
            # Right-click on the KEY card: pin a key manually (e.g. "F#m").
            # Persists until reset. Empty string clears the override.
            self.manual_key = str(request.get("key", "")).strip()
            self.analyzer.key_locked = bool(self.manual_key)
            self.dirty = True
            return {"key": self.manual_key}
        if op == "setManualBpm":
            # Right-click on the BPM card: pin a tempo and/or meter manually
            # ("120", "6/8", "140bpm 4/4"...). Persists until reset. Empty
            # input clears both overrides.
            raw = request.get("bpm", "")
            if raw in (None, "", 0, 0.0):
                self.manual_bpm = 0.0
                self.manual_time_signature = ""
            else:
                bpm, signature = parse_tempo_entry(raw)
                if bpm is not None:
                    self.manual_bpm = bpm
                if signature is not None:
                    self.manual_time_signature = signature
            self.analyzer.bpm_locked = self.manual_bpm > 0
            bpm_now = (self.manual_bpm or self.analyzer.bpm
                       or self.click.metronome_bpm)
            if self.metronome_enabled and bpm_now > 0:
                self.click.set_metronome(
                    True, bpm_now, self.active_beats_per_bar())
            self.dirty = True
            return {
                "bpm": self.manual_bpm,
                "timeSignature": self.active_time_signature(),
                "beatsPerBar": self.active_beats_per_bar(),
            }
        if op == "setVisible":
            visible = bool(request.get("visible", True))
            if visible and not self.panel_visible:
                self.analyzer.reset()
                self.analysis_locked = False
                if self.auto_analyze:
                    self.analysis_suspended = False
            elif not visible and self.panel_visible and not self.auto_analyze:
                self.analysis_suspended = True
            self.panel_visible = visible
            self._sync_capture()
            self.dirty = True
            return {}
        if op == "startAnalysis":
            self.analysis_locked = False
            self.analysis_suspended = False
            self.analyzer.reset()
            self._sync_capture()
            self.dirty = True
            return {"suspended": False}
        if op == "toggleAnalysis":
            if self.analysis_suspended or self.analysis_locked:
                self.analysis_locked = False
                self.analysis_suspended = False
                self.analyzer.reset()
            else:
                self.analysis_suspended = True
            self._sync_capture()
            self.dirty = True
            return {"suspended": self.analysis_suspended}
        if op == "setHold":
            active = bool(request.get("active", True))
            if active:
                self.analysis_locked = False
                self.analysis_suspended = False
            if active and not self.hold:
                # Accumulate across holds (no reset). If a progression already
                # exists under a different key, advise a reset instead of
                # silently mixing two tonalities.
                has_data = bool(self.analyzer.sequence.items or self.analyzer.sequence.current)
                if has_data and self._progression_key and self.analyzer.key \
                        and self.analyzer.key != self._progression_key:
                    self.needs_reset = True
                elif not self._progression_key and self.analyzer.key:
                    self._progression_key = self.analyzer.key
            self.hold = active
            self._sync_capture()
            self.dirty = True
            return {}
        if op == "listInputs":
            # Capture sources, NOT the sinks. A `.monitor` source records what a
            # sink is playing rather than what an instrument sends, so listing
            # everything would offer "System default (whatever the speakers are
            # playing)" as a microphone.
            entries = []
            for node in pw_dump_nodes():
                # pw_dump_nodes yields the raw node PROPS, so the keys are
                # node.name / media.class -- not name / type. Filtering on the
                # wrong keys silently returns nothing, which looks exactly like
                # "no inputs available".
                name = str(node.get("node.name") or "")
                media = str(node.get("media.class") or "")
                if not name or name == "quickshell":
                    continue
                if "Stream" in media or "Sink" in media:
                    continue
                if "Source" not in media:
                    continue
                if name.endswith(".monitor"):
                    continue
                entries.append({"name": name})
            _monitor, _default_input = default_audio_nodes()
            options = [{"name": "", "label": "System default" if not _default_input
                        else "System default (%s)" % friendly_node_name(_default_input)}]
            for e in entries:
                options.append({"name": e["name"], "label": friendly_node_name(e["name"])})
            return {"inputs": options, "current": self.tuner_input}
        if op == "setTunerInput":
            chosen = str(request.get("name", ""))
            if chosen != self.tuner_input:
                self.tuner_input = chosen
                # Persisted, so the choice survives a restart. The STORED value
                # is the raw node name; the label shown in the panel is only ever
                # a prettified view of it.
                self.config["tunerInput"] = chosen
                save_config(self.config)
                self._restart_tuner()
                was_running = self.recorder.running
                if was_running:
                    self.recorder.stop()
                self._apply_target()
                if was_running:
                    self.recorder.start()
                self.dirty = True
            return {}
        if op == "setSource":
            source = str(request.get("source", "pc"))
            if source not in ("pc", "mic"):
                raise ValueError("source must be pc or mic")
            if source != self.input_source:
                self.input_source = source
                self._apply_target()
                if self.recorder.running:
                    self.recorder.stop()
                    self.analyzer.reset()
                    self.recorder.start()
                self.dirty = True
            return {}
        if op == "setPaused":
            self.paused = bool(request.get("active", True))
            self._sync_capture()
            self.dirty = True
            return {"paused": self.paused}
        if op == "togglePaused":
            self.paused = not self.paused
            self._sync_capture()
            self.dirty = True
            return {"paused": self.paused}
        if op == "setConfig":
            changed = False
            naming = request.get("noteNaming")
            if naming in ("flats", "sharps"):
                self.config["noteNaming"] = naming
                self.naming = naming
                self.analyzer.naming = naming
                # The tuner carries its own copy of the setting. It was not
                # updated here, so switching to sharps renamed the chords and
                # the fretboard and left the tuner alone.
                if self.tuner is not None:
                    self.tuner.naming = naming
                changed = True
            if "showChordBox" in request:
                self.config["showChordBox"] = bool(request.get("showChordBox", False))
                self.show_chord_box = bool(self.config["showChordBox"])
                changed = True
            for key in ("showKeyCard", "showBpmCard", "showChordCard"):
                if key in request:
                    self.config[key] = bool(request.get(key, True))
                    changed = True
            if "autoAnalyze" in request:
                self.auto_analyze = bool(request.get("autoAnalyze", True))
                self.config["autoAnalyze"] = self.auto_analyze
                self.analysis_suspended = not self.auto_analyze
                self._sync_capture()
                changed = True
            if "aecEnabled" in request:
                self.config["aecEnabled"] = bool(request.get("aecEnabled", False))
                self.aec_enabled = bool(self.config["aecEnabled"])
                self._restart_tuner()
                changed = True
            if "metronomeVolume" in request:
                self.config["metronomeVolume"] = max(
                    0.0, min(1.0, float(request.get("metronomeVolume", 0.7))))
                self.click.set_metronome_gain(float(self.config["metronomeVolume"]))
                changed = True
            if "clickCustom" in request or "customDown" in request or "customUp" in request:
                if "clickCustom" in request:
                    self.config["clickCustom"] = bool(request.get("clickCustom", False))
                if "customDown" in request:
                    self.config["customDown"] = str(request.get("customDown", ""))
                if "customUp" in request:
                    self.config["customUp"] = str(request.get("customUp", ""))
                self._apply_click_config()
                changed = True
            if changed:
                save_config(self.config)
                self.dirty = True
            return {"config": dict(self.config)}
        if op == "importClick":
            # Open a native file dialog (zenity/portal) and use the chosen
            # .wav as the down (which=down) or up (which=up) click sample.
            which = str(request.get("which", "down"))
            if which not in ("down", "up"):
                raise ValueError("which must be down or up")
            cmd = [
                "zenity", "--file-selection",
                "--title", "Choose a .wav for the %s beat" % ("DOWN" if which == "down" else "UP"),
                "--file-filter", "WAV audio | *.wav",
            ]
            try:
                out = subprocess.check_output(cmd, timeout=60, text=True).strip()
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError):
                out = ""
            if out and out.lower().endswith(".wav"):
                key = "customDown" if which == "down" else "customUp"
                self.config[key] = out
                self._apply_click_config()
                save_config(self.config)
                self.dirty = True
                return {"config": dict(self.config)}
            return {}
        if op == "setMetronome":
            self.metronome_enabled = bool(request.get("enabled", True))
            bpm = float(request.get("bpm", 0) or 0)
            if bpm <= 0:
                bpm = (self.manual_bpm or self.analyzer.bpm or 120.0)
            self.click.set_metronome(
                self.metronome_enabled, bpm, self.active_beats_per_bar())
            self.dirty = True
            return {}
        if op == "setNoteNaming":
            naming = str(request.get("naming", "flats"))
            if naming not in ("flats", "sharps"):
                raise ValueError("Note naming must be flats or sharps")
            self.naming = naming
            self.analyzer.naming = naming
            return {}
        raise ValueError(f"Unknown operation: {op}")

    def run_analysis_pass(self) -> None:
        results = self.analyzer.analyze(record_progression=self.hold)
        if results:
            self.dirty = True
            bpm_now = self.manual_bpm or self.analyzer.bpm
            if self.metronome_enabled and bpm_now > 0:
                self.click.set_metronome(
                    True, bpm_now, self.active_beats_per_bar())
            # Stop hunting once the key is confidently established; a manual
            # start (or a global hold) resumes/restarts it.
            if not self.analysis_locked and not self.hold and self.panel_visible \
                    and self.analyzer.key_stable and self.analyzer.key_confidence >= 0.2:
                self.analysis_locked = True
                self._sync_capture()

    def run_tuner_pass(self) -> None:
        """Refresh the microphone tuner independently of the analyzer recorder."""
        if self.tuner is None or self.tuner_recorder is None or not self.tuner_recorder.running:
            return
        # The pitch detector spins on muted (silence) input and would show a
        # moving needle with no audible note: surface a muted/absent mic as
        # "no note" instead of a stale active reading.
        if not self.mic_available or self.mic_muted:
            if self.tuner_result.get("active"):
                self.tuner_result = {"active": False, "freq": 0.0, "note": "", "octave": 0, "cents": 0.0}
                self.dirty = True
            return
        self.tuner_result = self.tuner.analyze()
        self.dirty = True

    def refresh_mic_status(self) -> None:
        available, muted = mic_status()
        if available != self.mic_available or muted != self.mic_muted:
            self.dirty = True
        self.mic_available = available
        self.mic_muted = muted

    def write_state_file(self) -> None:
        if not self.state_file:
            return
        try:
            data = json.dumps(self.snapshot(), ensure_ascii=False, separators=(",", ":"))
            state_path = Path(self.state_file)
            state_path.parent.mkdir(parents=True, exist_ok=True)
            tmp_path = state_path.with_suffix(".json.tmp")
            tmp_path.write_text(data, encoding="utf-8")
            os.replace(tmp_path, state_path)
        except OSError:
            pass

    def _restore_recent_state(self, max_age: float = 90.0) -> bool:
        """90-second persistence: on backend restart, if a previous state
        snapshot is fresh (< max_age seconds old), restore the lightweight UI
        session flags from it (source, paused/hold/lock, metronome). The
        audio analysis itself keeps building from the fresh chunks."""
        try:
            st = os.stat(self.state_file)
        except OSError:
            return False
        if (time.time() - st.st_mtime) > max_age:
            return False
        try:
            data = json.loads(Path(self.state_file).read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError, ValueError):
            return False
        if not isinstance(data, dict):
            return False
        src = data.get("inputSource")
        if src in ("pc", "mic"):
            self.input_source = src
            self._apply_target()
        self.paused = bool(data.get("paused", False))
        self.hold = bool(data.get("hold", False))
        # The METRONOME state is deliberately NOT restored on reload: a
        # simple toolbar/shell restart must never re-enable the click on its
        # own (the user flips it in the plugin directly). It stays off until
        # the user toggles it again in a fresh session.
        self._sync_capture()
        self.dirty = True
        return True

    def _apply_click_config(self) -> None:
        """Push the config.json metronome settings into the click track."""
        self.click.set_metronome_gain(float(self.config.get("metronomeVolume", 0.7)))
        if self.config.get("clickCustom"):
            self.click.set_click_custom(
                True,
                str(self.config.get("customDown", "") or ""),
                str(self.config.get("customUp", "") or ""),
            )
        else:
            self.click.set_click_custom(False)

    def poll_command_file(self) -> None:
        if not self.command_file:
            return
        path = Path(self.command_file)
        try:
            mtime = path.stat().st_mtime
        except OSError:
            return
        if mtime <= self.last_command_file_mtime:
            return
        self.last_command_file_mtime = mtime
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            # Stale / unreadable file:.consume it (truncate) so a LOCKED
            # command file cannot be replayed again and again.
            try:
                path.write_text("")
                self.last_command_file_mtime = path.stat().st_mtime
            except OSError:
                pass
            return
        op = str(payload.get("op", ""))
        known = {
            "resetAnalysis", "toggleRecording", "startRecording", "stopRecording",
            "setVisible", "setHold", "setSource", "setMetronome",
            "setPaused", "togglePaused", "setConfig", "startAnalysis", "toggleAnalysis", "importClick",
            "setManualKey", "setManualBpm",
        }
        # CONSUMED = CLEARED: the command file is a one-shot TRANSPORT. Once a
        # command is read, the file must be emptied, otherwise a session's
        # leftover "setMetronome=true" re-applies every reload (the exact
        # 'BPM active at shell launch' bug the user hit).
        try:
            path.write_text("")
            self.last_command_file_mtime = path.stat().st_mtime
        except OSError:
            pass
        if op not in known:
            return
        try:
            self.handle_command(payload)
        except (ValueError, TypeError):
            return
        self.dirty = True

    def close(self) -> None:
        self.running = False
        self.recorder.stop()
        if self.tuner_recorder:
            self.tuner_recorder.stop()
        self.click.stop()


def emit(message: dict) -> None:
    sys.stdout.write(json.dumps(message, ensure_ascii=False, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def run() -> int:
    parser = argparse.ArgumentParser(description="jamjamjam audio analysis backend")
    parser.add_argument("--state-file", default="", help="Write a JSON snapshot to this file every update")
    parser.add_argument("--command-file", default="", help="Poll this JSON file for remote commands (reset, recording toggles)")
    parser.add_argument("--standalone", action="store_true", help="Run without stdin IPC (no plugin writer needed)")
    parser.add_argument("--no-tuner", action="store_true", help="Disable the system-input tuner")
    args = parser.parse_args()

    backend = AudioAnalyzerBackend(state_file=args.state_file, command_file=args.command_file, tuner=not args.no_tuner)
    selector = selectors.PollSelector()
    selector.register(sys.stdin, selectors.EVENT_READ, "stdin")
    state = "waiting"
    try:
        emit(backend.snapshot())
        last_tick = time.monotonic()
        last_analysis = time.monotonic()
        last_tuner = time.monotonic()
        last_mic = 0.0
        last_nodes = 0.0
        while backend.running:
            now = time.monotonic()
            # Follow default-device changes (internal ↔ HDMI ↔ Bluetooth ↔
            # jack) and restart a capture that died, so analysis survives
            # output switches and never silently listens to a stale device.
            if now - last_nodes >= 3.0:
                backend._refresh_audio_nodes()
                backend._sync_capture()
                last_nodes = now
            if backend.recorder.running and now - last_analysis >= 1.0:
                backend.run_analysis_pass()
                last_analysis = now
            # The microphone tuner updates on its own clock, regardless of the
            # analyzer recorder (so it works while the panel/TUI is idle).
            #
            # Fast while someone is actually reading it. At the old fixed 0.5 s
            # the note could sit unchanged for half a second between two hops of
            # the needle, which is what "the note stays fixed too long" looks
            # like: the reading lags the string by up to two hops.
            #
            # Measured at ~10 ms per pass over a 128 ms window (bench), so 0.15 s
            # is 6.7 passes a second — about 6.6% of one core WHILE VISIBLE, and
            # only then. Idle returns to 0.5 s (2%), where nobody is watching a
            # needle. Anything faster was measured and is not worth the CPU:
            # 0.12 s already costs 8.3%.
            want_fast = backend.panel_visible or backend.hold
            if now - last_tuner >= (0.15 if want_fast else 0.5):
                backend.run_tuner_pass()
                last_tuner = now
            if now - last_mic >= 2.0:
                backend.refresh_mic_status()
                last_mic = now
            if now - last_tick >= 0.25:
                backend.dirty = True
                last_tick = now
            if backend.dirty:
                backend.dirty = False
                snap = backend.snapshot()
                emit(snap)
                backend.write_state_file()
            backend.poll_command_file()

            if args.standalone:
                time.sleep(0.1)
                backend.dirty = True
                continue

            try:
                events = selector.select(timeout=0.1)
            except OSError:
                events = []
            for key, _mask in events:
                if key.data == "stdin":
                    line = sys.stdin.readline()
                    if line == "":
                        backend.running = False
                        break
                    try:
                        request = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    try:
                        result = backend.handle_command(request)
                        request_id = request.get("id", "")
                        if request_id:
                            emit({"type": "result", "id": request_id, "ok": True, "data": result})
                    except (ValueError, KeyError, TypeError) as error:
                        request_id = request.get("id", "")
                        if request_id:
                            emit({"type": "result", "id": request_id, "ok": False, "error": str(error)})
    finally:
        backend.close()
    return 0


if __name__ == "__main__":
    sys.exit(run())