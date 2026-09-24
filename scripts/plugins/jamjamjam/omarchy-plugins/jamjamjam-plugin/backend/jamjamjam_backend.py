#!/usr/bin/python3
"""jamjamjam backend: key/BPM/chord detection, MIDI input, and simple synth."""

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

try:
    import shazamio  # type: ignore  # noqa: E402
    HAVE_SHAZAMIO = True
except ImportError:
    HAVE_SHAZAMIO = False

PLUGIN_ID = "jamjamjam-plugin"

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
    "showChordBox": True,
    "aecEnabled": False,
    "metronomeVolume": 0.7,
    "clickStyle": "classic",
    "clickCustom": False,
    "customDown": "",
    "customUp": "",
}

CLICK_STYLES = ("classic", "wood", "kick", "beep")


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


class Tuner:
    """Pitch detector on the system input, refreshed from a rolling ring."""

    def __init__(self, ring_seconds: float = 0.5):
        self.ring_seconds = ring_seconds
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
        rms = math.sqrt(sum(sample * sample for sample in frames) / len(frames))
        if rms < 0.004:
            self.current = {"active": False, "freq": 0.0, "note": "", "octave": 0, "cents": 0.0}
            return self.current
        frames = frames[-int(SAMPLE_RATE * 0.4):]
        freq = self._autocorrelation_freq(frames, SAMPLE_RATE)
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
            "note": NOTE_NAMES_FLAT[pc],
            "octave": midi // 12 - 1,
            "cents": cents,
        }
        return self.current

    @staticmethod
    def _autocorrelation_freq(frames: list[float], rate: int) -> float:
        # Vectorised YIN pitch detection (FFT autocorrelation + cumulative
        # mean normalised difference). The old pure-Python O(N·lags) loop was
        # far too slow to run continuously, and its global-minimum search
        # picked subharmonics (329 Hz -> 66 Hz); the first-dip rule fixes that.
        if not HAVE_NUMPY or len(frames) < rate // 20:
            return 0.0
        x = np.asarray(frames, dtype=np.float64)
        n = x.size
        min_lag = max(2, int(rate / 1000.0))
        max_lag = int(rate / 55.0)
        if max_lag <= min_lag or n <= max_lag + 1:
            return 0.0
        size = 1 << (2 * n - 1).bit_length()
        spectrum = np.fft.rfft(x, size)
        ac = np.fft.irfft(spectrum * np.conj(spectrum), size)[:n]
        cumsq = np.cumsum(x * x)
        total = float(cumsq[-1])
        lags = np.arange(1, max_lag + 1)
        head = cumsq[n - lags - 1]
        tail = total - cumsq[lags - 1]
        diff = (head + tail - 2.0 * ac[lags]) / (n - lags)
        cumulative = np.cumsum(diff)
        dprime = diff * lags / np.maximum(cumulative, 1e-12)
        window = dprime[min_lag - 1:max_lag]
        below = np.nonzero(window < 0.2)[0]
        if below.size == 0:
            return 0.0
        idx = int(below[0])
        while idx + 1 < window.size and window[idx + 1] < window[idx]:
            idx += 1
        tau = float(min_lag + idx)
        # Parabolic interpolation around the dip for sub-cent accuracy.
        if min_lag <= tau - 1 and tau + 1 <= max_lag:
            y0 = float(dprime[int(tau) - 2])
            y1 = float(dprime[int(tau) - 1])
            y2 = float(dprime[int(tau)])
            denom = y0 - 2.0 * y1 + y2
            if abs(denom) > 1e-12:
                shift = 0.5 * (y0 - y2) / denom
                if -1.0 < shift < 1.0:
                    tau += shift
        if tau <= 0:
            return 0.0
        return rate / tau


class ShazamDetector:
    """Optional song fingerprinting. Stays inert unless `shazamio` is installed."""

    def __init__(self):
        self.result: dict | None = None
        self._enabled = HAVE_SHAZAMIO
        self._period_seconds = 8.0
        self._lock = threading.Lock()
        self._last_attempt = 0.0
        self._error = ""
        if not self._enabled:
            return
        self._thread = threading.Thread(target=self._loop, name="jamjamjam-shazam", daemon=True)
        self._thread.start()

    def enabled(self) -> bool:
        return self._enabled

    def feed(self, frames: list[float]) -> None:
        if not self._enabled or not frames:
            return
        now = time.monotonic()
        if now - self._last_attempt < self._period_seconds:
            return
        self._last_attempt = now
        # Downsample to 44100 mono int16, 5 seconds for shazamio.
        step = max(1, int(SAMPLE_RATE / 44100))
        samples_16 = frames[-44100 * 5::step]
        raw = array.array("h")
        for sample in samples_16:
            raw.append(max(-32767, min(32767, int(sample * 32767))))
        if len(raw) < 44100:
            return
        threading.Thread(target=self._recognize, args=(raw.tobytes(),), daemon=True).start()

    def _recognize(self, data: bytes) -> None:
        try:
            import asyncio
            loop = asyncio.new_event_loop()
            asyncio.set_event_loop(loop)
            sh = shazamio.Shazam()
            result = loop.run_until_complete(sh.recognize(data))
            loop.close()
            track = (result or {}).get("track", {}) if isinstance(result, dict) else {}
            title = (track.get("title") or track.get("full_title") or "").strip()
            artist = "; ".join(item.get("name", "") for item in track.get("subtitle") if isinstance(track.get("subtitle"), list)) or ""
            subtitle = (track.get("subtitle") or "").strip()
            if title:
                with self._lock:
                    self.result = {
                        "title": title,
                        "artist": artist or subtitle,
                        "match": True,
                    }
        except Exception:
            with self._lock:
                self._error = "shazam failed"

    def snapshot(self) -> dict:
        with self._lock:
            result = dict(self.result) if self.result else None
            return {
                "available": self._enabled,
                "match": result,
                "error": self._error,
            }


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
        bpm = 60.0 * frame_rate / best_lag
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


class MidiSynth:
    """Very simple additive synth streaming to PipeWire through pw-cat."""

    def __init__(self, enabled: bool = True, volume: float = 0.4):
        self.enabled = enabled
        self.volume = max(0.0, min(1.0, volume))
        self.waveform = "sine"
        self.voices: dict[int, dict[str, float]] = {}
        # Metronome click settings (UI-configurable). `metronome_gain` is the
        # dedicated click volume (independent of the MIDI synth master vol);
        # click_style picks the built-in tone, custom_* optional .wav samples
        # loaded from disk that override the tone for down/up beats.
        self.metronome_gain = 0.7
        self.click_style = "classic"
        self.click_custom = False
        self.custom_down: list[float] | None = None
        self.custom_up: list[float] | None = None
        self.metronome_enabled = False
        self.metronome_bpm = 120.0
        self.metronome_beats = 4
        self.running = False
        self.error = ""
        self._process: subprocess.Popen[bytes] | None = None
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._wake = threading.Event()
        self._thread: threading.Thread | None = None
        self._thread = threading.Thread(target=self._run, name="jamjamjam-synth", daemon=True)
        self._thread.start()

    def set_enabled(self, enabled: bool) -> None:
        with self._lock:
            self.enabled = bool(enabled)
            if not self.enabled:
                self.voices.clear()
        self._wake.set()

    def set_waveform(self, waveform: str) -> None:
        with self._lock:
            self.waveform = waveform

    def set_volume(self, volume: float) -> None:
        with self._lock:
            self.volume = max(0.0, min(1.0, volume))

    def set_metronome_gain(self, gain: float) -> None:
        with self._lock:
            self.metronome_gain = max(0.0, min(1.0, float(gain)))

    def set_click_style(self, style: str) -> None:
        if style not in CLICK_STYLES:
            return
        with self._lock:
            self.click_style = style
            # Restart on the next tick cleanly.
            self.metronome_tick_left = 0.0

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

    def note_on(self, note: int, velocity: int) -> None:
        with self._lock:
            if not self.enabled:
                return
            freq = 440.0 * (2.0 ** ((note - 69) / 12.0))
            self.voices[note] = {
                "freq": freq, "phase": 0.0, "velocity": math.sqrt(max(1, velocity) / 127.0),
                "env": 0.0, "stage": "attack",
            }
        self._wake.set()

    def note_off(self, note: int) -> None:
        with self._lock:
            voice = self.voices.get(note)
            if not voice:
                return
            voice["stage"] = "release"
            voice["release_step"] = max(voice["env"], 0.001) / max(1, int(0.2 * SAMPLE_RATE))

    def panic(self) -> None:
        with self._lock:
            self.voices.clear()
        self._wake.set()

    def set_metronome(self, enabled: bool, bpm: float = 120.0, beats: int = 4) -> None:
        with self._lock:
            self.metronome_enabled = bool(enabled) and bpm > 0.0
            self.metronome_bpm = max(40.0, min(240.0, float(bpm)))
            self.metronome_beats = max(1, int(beats))
            if self.metronome_enabled:
                # Restart metronome at a downbeat: click immediately, then
                # the next click lands exactly one beat later.
                self.metronome_phase = 0.0
                self.metronome_beat = 0
                self.metronome_in_beat = True
                self.metronome_tick_left = 0.04
                self.metronome_tick_phase = 0.0
        self._wake.set()

    def stop(self) -> None:
        self._stop.set()
        self._wake.set()
        if self._thread and self._thread.is_alive():
            self._thread.join(timeout=1.0)
        self._close_process()

    def _render_block(self, frame_count: int) -> array.array:
        output = array.array("h")
        attack_step = 1.0 / (SAMPLE_RATE * 0.005)
        with self._lock:
            voices = dict(self.voices)
            master = self.volume * 0.3
            met_on = self.metronome_enabled
            met_bpm = self.metronome_bpm
            met_beats = self.metronome_beats
        beat_len = 60.0 / met_bpm if met_on else 0.0
        with self._lock:
            click_gain = self.metronome_gain
            style = self.click_style
            custom_down = self.custom_down if self.click_custom else None
            custom_up = self.custom_up if self.click_custom else None
        custom_step = 0
        custom_done = False
        custom_samples = None
        for _ in range(frame_count):
            mixed = 0.0
            finished = []
            for note, voice in voices.items():
                if voice["stage"] == "attack":
                    voice["env"] = min(1.0, voice["env"] + attack_step)
                    if voice["env"] >= 1.0:
                        voice["stage"] = "sustain"
                elif voice["stage"] == "release":
                    voice["env"] -= voice["release_step"]
                    if voice["env"] <= 0.0:
                        finished.append(note)
                        continue
                phase = voice["phase"]
                freq = voice["freq"]
                waveform = self.waveform
                if waveform == "sine":
                    value = math.sin(phase)
                elif waveform == "triangle":
                    value = 2.0 / math.pi * math.asin(math.sin(phase))
                elif waveform == "sawtooth":
                    value = 2.0 * (phase / (2.0 * math.pi) - math.floor(0.5 + phase / (2.0 * math.pi)))
                elif waveform == "square":
                    value = 1.0 if math.sin(phase) >= 0 else -1.0
                elif waveform == "organ":
                    value = 0.5 * math.sin(phase) + 0.3 * math.sin(phase * 2.0) + 0.2 * math.sin(phase * 3.0)
                else:
                    value = math.sin(phase) + 0.5 * math.sin(phase * 2.0)
                mixed += value * voice["env"] * voice["velocity"]
                voice["phase"] = (phase + 2.0 * math.pi * freq / SAMPLE_RATE) % (2.0 * math.pi)
            with self._lock:
                for note in finished:
                    self.voices.pop(note, None)
            if met_on:
                self.metronome_phase += 1.0 / SAMPLE_RATE
                if self.metronome_phase >= beat_len:
                    self.metronome_phase -= beat_len
                    self.metronome_beat = (self.metronome_beat + 1) % met_beats
                    self.metronome_in_beat = self.metronome_beat == 0
                    self.metronome_tick_left = 0.04
                    self.metronome_tick_phase = 0.0
                    # New beat: choose the sample for this beat (down or up)
                    # and reset the custom-sample cursor.
                    if self.metronome_in_beat:
                        custom_samples = custom_down
                    else:
                        custom_samples = custom_up
                    custom_done = custom_samples is None
                    custom_step = 0
                if not custom_done and custom_samples is not None and custom_step < len(custom_samples):
                    # Custom .wav click: plays the FULL sample length (not
                    # capped at the 0.04 s builtin tick), mono-converted and
                    # peak-normalized at load, gained.
                    value = float(custom_samples[custom_step]) * click_gain
                    custom_step += 1
                    if custom_step >= len(custom_samples):
                        custom_done = True
                    mixed += value
                elif self.metronome_tick_left > 0.0:
                    if style == "wood":
                        freq = 900.0 if self.metronome_in_beat else 620.0
                        accent = 0.75 if self.metronome_in_beat else 0.5
                    elif style == "kick":
                        freq = 140.0 if self.metronome_in_beat else 100.0
                        accent = 1.0 if self.metronome_in_beat else 0.65
                    elif style == "beep":
                        freq = 1400.0 if self.metronome_in_beat else 900.0
                        accent = 0.55 if self.metronome_in_beat else 0.35
                    else:  # classic
                        freq = 1760.0 if self.metronome_in_beat else 1100.0
                        accent = 0.55 if self.metronome_in_beat else 0.35
                    env = self.metronome_tick_left / 0.04
                    # Kick: exponential pitch decay to feel like a drum;
                    # the others stay fixed-tone (classic/wood/beep).
                    phase = self.metronome_tick_phase
                    if style == "kick":
                        decay = math.exp(-3.0 * (1.0 - env))
                        value = math.sin(phase) * env * accent * decay * 2.0
                    elif style == "wood":
                        value = math.sin(phase) * env * accent
                        # Add a soft knock overtone
                        value += 0.4 * math.sin(2.2 * phase) * env * accent
                    else:
                        value = math.sin(phase) * env * accent
                    mixed += value * click_gain
                    step = 2.0 * math.pi * freq / SAMPLE_RATE
                    self.metronome_tick_phase = (phase + step) % (2.0 * math.pi)
                    self.metronome_tick_left -= 1.0 / SAMPLE_RATE
            elif custom_step > 0:
                # Loop tail (metronome stopped mid-sample): clear counters.
                custom_step = 0
            sample = math.tanh(mixed * master) * 0.9
            output.append(max(-32767, min(32767, int(sample * 32767))))
        return output

    def _start_process(self) -> bool:
        try:
            self._process = subprocess.Popen(
                [
                    "pw-cat", "--playback", "--raw", "--format", "s16", "--rate", str(SAMPLE_RATE),
                    "--channels", "1", "--latency", "128", "--media-role", "Music", "-",
                ],
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

    def _run(self) -> None:
        block_frames = 384
        block_seconds = block_frames / SAMPLE_RATE
        silence = bytes(block_frames * 2)
        next_write = time.perf_counter()
        while not self._stop.is_set():
            with self._lock:
                should_stream = self.enabled or bool(self.voices) or self.metronome_enabled
            if not should_stream:
                self._close_process()
                self._wake.wait(0.2)
                self._wake.clear()
                next_write = time.perf_counter()
                continue
            if not self._process and not self._start_process():
                self._stop.wait(1.0)
                continue
            now = time.perf_counter()
            wait_seconds = next_write - now
            if wait_seconds > 0:
                self._wake.wait(wait_seconds)
                self._wake.clear()
            with self._lock:
                has_voices = bool(self.voices) or self.metronome_enabled
            block = self._render_block(block_frames).tobytes() if has_voices else silence
            try:
                assert self._process and self._process.stdin
                self._process.stdin.write(block)
                next_write += block_seconds
                if next_write < time.perf_counter() - block_seconds:
                    next_write = time.perf_counter() + block_seconds
            except (BrokenPipeError, OSError) as error:
                self.error = f"PipeWire audio stopped: {error}"
                self._close_process()
                self._stop.wait(0.5)
                next_write = time.perf_counter()


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


PORT_RE = re.compile(r"^\s*(\d+:\d+)\s{2,}(.+?)\s{2,}(.+?)\s*$")
NOTE_RE = re.compile(r"Note\s+(on|off)\s+(\d+),\s+note\s+(\d+),\s+velocity\s+(\d+)", re.IGNORECASE)
CC_RE = re.compile(r"Control\s+change\s+(\d+),\s+controller\s+(\d+),\s+value\s+(\d+)", re.IGNORECASE)


def parse_port_listing(text: str) -> list[dict[str, str]]:
    ports = []
    for line in text.splitlines():
        match = PORT_RE.match(line)
        if not match:
            continue
        port_id, client, name = match.groups()
        if client == "System":
            continue
        ports.append({"id": port_id, "client": client.strip(), "name": name.strip(), "label": f"{client.strip()} · {name.strip()}"})
    return ports


def parse_midi_line(line: str) -> dict | None:
    note_match = NOTE_RE.search(line)
    if note_match:
        kind, channel, note, velocity = note_match.groups()
        event_type = "note_on" if kind.lower() == "on" and int(velocity) > 0 else "note_off"
        return {"type": event_type, "channel": int(channel), "note": int(note), "velocity": int(velocity)}
    cc_match = CC_RE.search(line)
    if cc_match:
        channel, controller, value = cc_match.groups()
        return {"type": "control_change", "channel": int(channel), "controller": int(controller), "value": int(value)}
    return None


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
        self.tui_pid_file = os.path.expanduser("~/.local/state/jamjamjam/tui.pid")
        self.analyzer = AudioAnalyzer(self.naming)
        self.recorder = AudioRecorder(self.analyzer)
        self.synth = MidiSynth(enabled=True, volume=0.4)
        self.tuner = Tuner() if tuner else None
        self.tuner_recorder: AudioRecorder | None = None
        self.shazam = ShazamDetector()
        self.midi_in_process: subprocess.Popen[str] | None = None
        self.ports: list[dict[str, str]] = []
        self.selected_port = ""
        self.selected_name = ""
        self.midi_connected = False
        self.midi_mode = False
        self.held: dict[int, int] = {}
        self.midi_chord = ""
        self.last_port_scan = 0.0
        self.running = True
        self.dirty = True
        self.last_chord_throttle = 0.0
        self.analysis_timer = 0.0
        self.capture_target = ""
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
        # UI-configurable settings from config.json (chord box, AEC hint,
        # metronome click). Applied onto the synth / published in snapshot.
        self.show_chord_box = bool(self.config.get("showChordBox", True))
        self.aec_enabled = bool(self.config.get("aecEnabled", False))
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
        # panel (and any TUI session) is closed — set up the tuner WITHOUT
        # starting its capture. _sync_capture() starts/stops it against the
        # panel-visible/hold/TUI-active gate at every state change.
        self._restart_tuner()

    def _restart_tuner(self):
        """(Re)point the tuner's capture at the default microphone."""
        if self.tuner is None:
            return
        target = self.input_target or ""
        if self.tuner_recorder is None:
            self.tuner_recorder = AudioRecorder(self.tuner, target=target, kind="source")
        else:
            if self.tuner_recorder.running:
                self.tuner_recorder.stop()
            self.tuner_recorder.target = target
            self.tuner_recorder.kind = "source"
        self._sync_capture()

    def _tui_active(self) -> bool:
        """True while a jamjamjam-neck TUI owns the session (its pid is alive)."""
        try:
            pid = int(Path(self.tui_pid_file).read_text(encoding="utf-8").strip())
        except (OSError, ValueError):
            return False
        if pid <= 0:
            return False
        try:
            os.kill(pid, 0)
        except OSError:
            return False
        return True

    def _apply_target(self) -> None:
        if self.input_source == "pc":
            # Pre-volume monitor of the DEFAULT sink: follows whatever output
            # device is active (internal/HDMI/Bluetooth/jack) and stays audible
            # to the analyzer even when the output is muted or at 0 volume.
            self.recorder.target = self.monitor_target or ""
            self.recorder.kind = "monitor"
            self.capture_target = self.monitor_target or "@DEFAULT_SOURCE@"
        else:
            self.recorder.target = self.input_target or ""
            self.recorder.kind = "source"
            self.capture_target = self.input_target or "@DEFAULT_SOURCE@"

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
        # The plugin analyses independently of the neck TUI, and vice versa:
        # capture runs while the panel is open, a global hold is active, OR the
        # neck TUI is open (its pid is alive) -- so the TUI sees live chords too.
        desired = (not self.paused) and (not self.analysis_locked) and (
            self.panel_visible or self.hold or self._tui_active()
        )
        self._apply_target()
        if desired and not self.recorder.running:
            self.recorder.start()
            self.dirty = True
        elif not desired and self.recorder.running:
            self.recorder.stop()
            self.dirty = True

        # PRIVACY GUARD: the microphone (tuner) is captured ONLY while the
        # plugin is actually in use (panel open, analysis hold active, or the
        # neck TUI open). The mic must NEVER run while nothing is open.
        tuner_desired = desired and (self.tuner is not None)
        if tuner_desired and self.tuner_recorder is not None and not self.tuner_recorder.running:
            self.tuner_recorder.start()
            self.dirty = True
        elif not tuner_desired and self.tuner_recorder is not None and self.tuner_recorder.running:
            self.tuner_recorder.stop()
            self.dirty = True

    def snapshot(self) -> dict:
        now = time.time()
        midi_state = "off"
        midi_message = "MIDI mode disabled"
        if self.midi_mode:
            if self.midi_connected:
                midi_state = "connected"
                midi_message = self.selected_name or "MIDI device connected"
            elif self.ports:
                midi_state = "available"
                midi_message = "Choose a MIDI input"
            else:
                midi_state = "waiting"
                midi_message = "Connect a MIDI keyboard"
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
            "tuiActive": self._tui_active(),
            "needsReset": self.needs_reset,
            "mic": {"available": self.mic_available, "muted": self.mic_muted},
            "config": {
                "noteNaming": self.naming,
                "showChordBox": self.show_chord_box,
                "aecEnabled": self.aec_enabled,
            },
            "metronome": {
                "enabled": self.metronome_enabled,
                "bpm": round(self.synth.metronome_bpm, 1),
                "beats": self.synth.metronome_beats,
                "volume": self.synth.metronome_gain,
                "style": self.synth.click_style,
                "custom": self.synth.click_custom,
                "customDown": self.config.get("customDown", ""),
                "customUp": self.config.get("customUp", ""),
                "styles": list(CLICK_STYLES),
            },
            "analyzer": {
                "key": self.analyzer.key,
                "keyConfidence": round(self.analyzer.key_confidence, 3),
                "keyStable": self.analyzer.key_stable,
                "bpm": round(self.analyzer.bpm, 1) if self.analyzer.bpm else 0,
                "beatsPerBar": self.analyzer.beats_per_bar,
                "timeSignature": f"{self.analyzer.beats_per_bar}/4",
                "currentChord": self.analyzer.current_chord,
                "chordNotes": list(self.analyzer.current_chord_notes),
                "noSignal": self.analyzer.no_signal,
                "songChanged": self.analyzer.song_changed,
                "progression": self.analyzer.sequence.snapshot(now) if PROGRESSION_ENABLED else [],
            },
            "loop": self.analyzer.sequence.loop_snapshot() if PROGRESSION_ENABLED
                    else {"active": False, "length": 0, "chords": [], "pos": 0},
            "midi": {
                "mode": self.midi_mode,
                "state": midi_state,
                "message": midi_message,
                "ports": self.ports,
                "selectedPort": self.selected_port,
                "connected": self.midi_connected,
                "currentChord": self.midi_chord,
                "heldNotes": sorted(self.held),
                "deviceCount": len(self.ports),
            },
            "synth": {
                "enabled": self.synth.enabled,
                "waveform": self.synth.waveform,
                "volume": self.synth.volume,
                "running": self.synth.running,
                "error": self.synth.error,
            },
            "tuner": tuner_result,
            "song": self.shazam.snapshot(),
            "guitar": GuitarModes.scales_for(self.analyzer.key, self.naming),
            "noteNaming": self.naming,
        }

    def handle_command(self, request: dict) -> dict:
        op = str(request.get("op", ""))
        if op == "startRecording":
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
                self.recorder.start()
                self.analyzer.reset()
            return {}
        if op == "resetAnalysis":
            self.analyzer.reset()
            self.needs_reset = False
            self._progression_key = ""
            self.analysis_locked = False
            self._sync_capture()
            return {}
        if op == "setVisible":
            visible = bool(request.get("visible", True))
            if visible and not self.panel_visible:
                self.analyzer.reset()
                self.analysis_locked = False
            self.panel_visible = visible
            self._sync_capture()
            self.dirty = True
            return {}
        if op == "resumeAnalysis":
            # Space in the plugin: if the analysis auto-stopped on a confident
            # key, restart it fresh; otherwise stop it.
            if self.analysis_locked:
                self.analyzer.reset()
                self.analysis_locked = False
            else:
                self.analysis_locked = True
            self._sync_capture()
            self.dirty = True
            return {"locked": self.analysis_locked}
        if op == "setHold":
            active = bool(request.get("active", True))
            if active:
                self.analysis_locked = False
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
                changed = True
            if "showChordBox" in request:
                self.config["showChordBox"] = bool(request.get("showChordBox", True))
                self.show_chord_box = bool(self.config["showChordBox"])
                changed = True
            if "aecEnabled" in request:
                self.config["aecEnabled"] = bool(request.get("aecEnabled", False))
                self.aec_enabled = bool(self.config["aecEnabled"])
                changed = True
            if "metronomeVolume" in request:
                self.config["metronomeVolume"] = max(
                    0.0, min(1.0, float(request.get("metronomeVolume", 0.7))))
                self.synth.set_metronome_gain(float(self.config["metronomeVolume"]))
                changed = True
            if "clickStyle" in request:
                style = str(request.get("clickStyle", "classic"))
                if style in CLICK_STYLES:
                    self.config["clickStyle"] = style
                    self.synth.set_click_style(style)
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
            if bpm > 0:
                self.synth.set_metronome(self.metronome_enabled, bpm)
            else:
                self.synth.set_metronome(self.metronome_enabled, self.analyzer.bpm or 120.0)
            self.dirty = True
            return {}
        if op == "openTui":
            self.open_tui()
            return {}
        if op == "refreshPorts":
            self.last_port_scan = 0.0
            self.scan_ports()
            return {}
        if op == "enableMidi":
            self.midi_mode = bool(request.get("enabled", True))
            if self.midi_mode:
                self.scan_ports()
            else:
                self.stop_midi_process()
            return {}
        if op == "toggleMidi":
            self.midi_mode = not self.midi_mode
            if self.midi_mode:
                self.scan_ports()
            else:
                self.stop_midi_process()
            return {}
        if op == "selectPort":
            self.select_port(str(request.get("port", "")))
            return {}
        if op == "setSynthEnabled":
            self.synth.set_enabled(bool(request.get("enabled", False)))
            return {}
        if op == "setWaveform":
            waveform = str(request.get("waveform", "sine"))
            if waveform not in ("sine", "triangle", "sawtooth", "square", "organ"):
                raise ValueError("Unknown waveform")
            self.synth.set_waveform(waveform)
            return {}
        if op == "setVolume":
            self.synth.set_volume(float(request.get("volume", 0.4)))
            return {}
        if op == "panicMidi":
            self.synth.panic()
            return {}
        if op == "setNoteNaming":
            naming = str(request.get("naming", "flats"))
            if naming not in ("flats", "sharps"):
                raise ValueError("Note naming must be flats or sharps")
            self.naming = naming
            self.analyzer.naming = naming
            return {}
        raise ValueError(f"Unknown operation: {op}")

    def scan_ports(self) -> None:
        if not self.midi_mode:
            return
        try:
            result = subprocess.run(["aseqdump", "-l"], capture_output=True, text=True, timeout=2, check=False)
            next_ports = parse_port_listing(result.stdout)
        except (OSError, subprocess.TimeoutExpired):
            next_ports = []
        if next_ports != self.ports:
            self.ports = next_ports
            self.dirty = True
        available_ids = {port["id"] for port in self.ports}
        if self.selected_port and self.selected_port not in available_ids:
            self.stop_midi_process()
            self.selected_port = ""
        if not self.selected_port:
            candidate = next((port for port in self.ports if "korg" in port["label"].lower() or "microkey" in port["label"].lower()), None)
            if candidate:
                self.select_port(candidate["id"], persist=False)
        if self.selected_port and (not self.midi_in_process or self.midi_in_process.poll() is not None):
            self.start_midi_process()

    def select_port(self, port_id: str, persist: bool = True) -> None:
        port = next((item for item in self.ports if item["id"] == port_id), None)
        self.stop_midi_process()
        if not port:
            self.selected_port = ""
            self.selected_name = ""
            self.midi_connected = False
            return
        self.selected_port = port["id"]
        self.selected_name = port["label"]
        self.start_midi_process()
        self.dirty = True

    def start_midi_process(self) -> None:
        if not self.selected_port:
            return
        try:
            self.midi_in_process = subprocess.Popen(
                ["stdbuf", "-oL", "-eL", "aseqdump", "-p", self.selected_port],
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, bufsize=1,
            )
            self.midi_connected = True
            self.dirty = True
        except OSError:
            self.midi_in_process = None
            self.midi_connected = False

    def stop_midi_process(self) -> None:
        process = self.midi_in_process
        self.midi_in_process = None
        self.midi_connected = False
        self.held.clear()
        self.midi_chord = ""
        self.synth.panic()
        if not process:
            return
        try:
            process.terminate()
            process.wait(timeout=0.4)
        except (OSError, subprocess.TimeoutExpired):
            try:
                process.kill()
            except OSError:
                pass

    def process_midi_line(self, line: str) -> None:
        event = parse_midi_line(line)
        if not event:
            return
        if event["type"] == "note_on":
            note = int(event["note"])
            velocity = int(event["velocity"])
            self.held[note] = velocity
            self.synth.note_on(note, velocity)
        elif event["type"] == "note_off":
            note = int(event["note"])
            self.held.pop(note, None)
            self.synth.note_off(note)
        elif event["type"] == "control_change" and event["controller"] == 64:
            pass
        self.midi_chord = identify_chord(list(self.held), self.naming)
        self.dirty = True

    def run_analysis_pass(self) -> None:
        results = self.analyzer.analyze(record_progression=self.hold)
        if results:
            self.dirty = True
            self.shazam.feed(self.analyzer.buffer.last(6.0))
            if self.metronome_enabled and self.analyzer.bpm > 0:
                self.synth.set_metronome(True, self.analyzer.bpm)
            # Stop hunting once the key is confidently established; space (or a
            # global hold) resumes/restarts it. Skipped while the neck TUI owns
            # the session, which wants continuous detection.
            if not self.analysis_locked and not self.hold and self.panel_visible \
                    and not self._tui_active() \
                    and self.analyzer.key_stable and self.analyzer.key_confidence >= 0.2:
                self.analysis_locked = True
                self._sync_capture()

    def run_tuner_pass(self) -> None:
        """Refresh the microphone tuner independently of the analyzer recorder."""
        if self.tuner is None or self.tuner_recorder is None or not self.tuner_recorder.running:
            return
        self.tuner_result = self.tuner.analyze()
        self.dirty = True

    def refresh_mic_status(self) -> None:
        available, muted = mic_status()
        if available != self.mic_available or muted != self.mic_muted:
            self.dirty = True
        self.mic_available = available
        self.mic_muted = muted

    def open_tui(self) -> None:
        # The Go TUI opens a /dev/tty when run with no controlling terminal,
        # so spawning it detached via Popen leaves the user staring at
        # nothing. Mirror the other mosquito managers (live-mode / move /
        # audio plugin) and wrap it in a square terminal when needed.
        launcher = os.path.expanduser("~/.local/bin/jamjamjam-tui")
        if not os.path.isfile(launcher):
            self.dirty = True
            return
        # Already running — bring it to the foreground instead of stacking.
        pid_file = os.path.expanduser("~/.local/state/jamjamjam/tui.pid")
        try:
            with open(pid_file, "r") as fh:
                existing = int((fh.read() or "0").strip() or 0)
        except (OSError, ValueError):
            existing = 0
        if existing and os.path.isdir(f"/proc/{existing}"):
            env = os.environ.copy()
            env["DISPLAY"] = env.get("DISPLAY", ":0")
            env["WAYLAND_DISPLAY"] = env.get("WAYLAND_DISPLAY", "wayland-1")
            subprocess.run(["loginctl", "activate"], env=env, check=False) if False else None
            os.system(f"hyprctl dispatch bringactivetotop pid:{existing} >/dev/null 2>&1 || true")
            return
        cmd = [launcher, "open"]
        if not (sys.stdout and sys.stdout.isatty()):
            if os.path.exists("/usr/bin/foot"):
                cmd = ["foot", "-W", "100x30", "--app-id=org.omarchy.mosquito-jamjamjam-tui", "-e", launcher, "open"]
            elif os.path.exists("/usr/bin/xterm"):
                cmd = ["xterm", "-e", launcher, "open"]
        try:
            proc = subprocess.Popen(
                cmd,
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL, start_new_session=True,
            )
            try:
                os.makedirs(os.path.dirname(pid_file), exist_ok=True)
                with open(pid_file, "w") as fh:
                    fh.write(str(proc.pid))
            except OSError:
                pass
        except OSError:
            pass

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
        met = data.get("metronome")
        if isinstance(met, dict):
            bpm = float(met.get("bpm") or 0.0)
            self.metronome_enabled = bool(met.get("enabled", False)) and bpm > 0.0
            self.synth.set_metronome(self.metronome_enabled, bpm)
        self._sync_capture()
        self.dirty = True
        return True

    def _apply_click_config(self) -> None:
        """Push the config.json metronome settings into the synth."""
        self.synth.set_metronome_gain(float(self.config.get("metronomeVolume", 0.7)))
        style = str(self.config.get("clickStyle", "classic"))
        if style in CLICK_STYLES:
            self.synth.set_click_style(style)
        if self.config.get("clickCustom"):
            self.synth.set_click_custom(
                True,
                str(self.config.get("customDown", "") or ""),
                str(self.config.get("customUp", "") or ""),
            )
        else:
            self.synth.set_click_custom(False)

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
            return
        op = str(payload.get("op", ""))
        known = {
            "resetAnalysis", "toggleRecording", "startRecording", "stopRecording",
            "setVisible", "setHold", "setSource", "setMetronome",
            "setPaused", "togglePaused", "setConfig", "resumeAnalysis", "importClick",
        }
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
        self.stop_midi_process()
        self.synth.stop()


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
    registered_midi = None
    state = "waiting"
    try:
        backend.scan_ports()
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
            if now - last_tuner >= 0.5:
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

            midi_stdout = backend.midi_in_process.stdout if backend.midi_in_process and backend.midi_in_process.poll() is None else None
            if midi_stdout is not None and midi_stdout is not registered_midi:
                if registered_midi is not None:
                    try:
                        selector.unregister(registered_midi)
                    except (KeyError, ValueError):
                        pass
                selector.register(midi_stdout, selectors.EVENT_READ, "midi")
                registered_midi = midi_stdout
            elif midi_stdout is None and registered_midi is not None:
                try:
                    selector.unregister(registered_midi)
                except (KeyError, ValueError):
                    pass
                registered_midi = None

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
                elif key.data == "midi" and key.fileobj is not None:
                    line = key.fileobj.readline()
                    if line:
                        backend.process_midi_line(line)
    finally:
        backend.close()
    return 0


if __name__ == "__main__":
    sys.exit(run())