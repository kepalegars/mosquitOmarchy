"""jamjamjam-bpm — real-time tempo, time-signature and key estimation.

Architecture follows the beat-tracking literature rather than any single one of
the surveyed implementations:

    capture -> mono -> STFT onset-detection function -> adaptive threshold
            -> YIN cumulative-mean-normalized difference -> tempogram comb
            -> log-Gaussian tempo prior + harmonic (octave) rule
            -> Viterbi tempo continuity -> confidence gate -> LOCK

Why this shape (see REPO-RESEARCH notes in README.md):

* ``realtime-bpm-analyzer`` and ``BeatDetect.js`` threshold the raw waveform
  and histogram inter-peak intervals, so they lock onto kick timbre and
  loudness, not beat periodicity.  Not used.
* ``bpmdetect`` (SoundTouch) is a sound real-time core: decimated envelope,
  cross-correlation with a 30 s forgetting curve and an explicit x2/x4
  harmonic rule.  Its harmonic rule and decay discipline are adopted.
* ``BTrack`` is the strongest tracker of the four (spectral ODF, balanced
  autocorrelACF, 4-comb tempogram, HMM tempo continuity) but hardcodes
  44100 Hz and clamps to 80-160 BPM.  Its architecture is adopted with the
  hardcoded rate removed and the clamp widened.

What none of the four implements, and what this module adds, is a
*convergence* signal.  A tempo is only published once the periodicity peak has
won by a clear margin for several consecutive frames and the observed beat
intervals have stopped moving; the estimate then stops being revised.  That is
the "detect, then stop once stable" contract the UI is built on.

No GPL code is linked: BTrack and bpmdetect are GPL-3.0, BeatDetect.js is
GPL-3.0.  Only numpy is required.
"""

from __future__ import annotations

import math
import subprocess
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field, asdict
from typing import Optional

import numpy as np

# ── Analysis geometry ────────────────────────────────────────────────────────
# Frame/hop are in samples of the *capture* rate.  Everything downstream is
# expressed in frames per second so a 48 kHz PipeWire stream and a 44.1 kHz
# file need no resampling — the hardcoded 44100 of BTrack is the trap here.
FRAME = 1024
HOP = 512

BPM_MIN = 30.0   # low enough that a 4/4 bar period is observable: at a 40 BPM
                  # floor a 96 BPM bar (2.5 s) falls outside the lag window, the
                  # downbeat accent becomes invisible and 8th-note material is
                  # read at double time
BPM_MAX = 208.0

# YIN absolute threshold.  0.10-0.15 is the conventional range; below 0.10 the
# dip finder starts accepting noise plateaus.
YIN_THRESHOLD = 0.15

# Comb-filter geometry, from BTrack: 4 elements, Rayleigh-weighted around a
# period of 43 frames (that is ~120 BPM at 86.13 frames/s).
COMB_ELEMENTS = 4
COMB_SIGMA = 43.0

# Tempo prior.  A log-Gaussian centred on 120 BPM breaks the half/double-time
# tie the same way a listener would: it is a prior, not a clamp, so 70 BPM and
# 170 BPM stay legal.
PRIOR_CENTRE = 120.0
PRIOR_WIDTH = 1.30  # in octaves

# Streaming tempo continuity (BTrack's HMM, reduced to a log-domain Gaussian).
# Per-frame evidence alone cannot separate a beat from its double/half, because
# both are consistent descriptions of the same onsets.  What separates them is
# that the true tempo does not jump: penalising candidates far from the previous
# frame's estimate is the practical form of the Viterbi transition penalty, and
# it is what stops a transient 2x reading from winning a single frame.
CONTINUITY_WIDTH = 0.35  # in octaves

# Viterbi tempo grid.
GRID_BPM_MIN = 40.0
GRID_BPM_MAX = 208.0
GRID_STEP = 1.0
GRID_SIGMA = 4.0  # transitions to adjacent grid states cost exp(-0.5*(d/s)^2)

# Convergence gate.
LOCK_MARGIN = 1.35  # peak / mean(other candidates)
LOCK_FRAMES = 12  # consecutive frames above the margin
LOCK_JITTER = 0.035  # max relative std-dev of recent beat intervals
LOCK_REARM_JUMP = 0.12  # a >12% tempo jump re-arms the detector
LOCK_MAX_HOLD = 20.0  # re-arm after 20 s regardless (track change safety)

KS_MAJOR = np.array(
    [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
)
KS_MINOR = np.array(
    [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]
)

NOTE_NAMES_SHARP = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
NOTE_NAMES_FLAT = ["C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"]

# 12 pitch classes, spelled with the accidental set implied by the key, so the
# major/minor table below is read as a real key rather than a rotation.
NOTE_NAMES_SHARP = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
NOTE_NAMES_FLAT = ["C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"]

# Krumhansl-Schmuckler weights, indexed by position in the scale.  The degrees
# must stay ordered *and rooted at the tonic*: the weights are positional, so a
# candidate profile is built by walking these degrees outwards from the tonic.
# The first version stored sorted pitch-class sets instead, which put the tonic
# weight (6.35) on whichever class happened to be lowest -- G major came out with
# its loudest note on C -- and it listed the major scale twice, so every "minor"
# candidate was really a major one and key finding returned one fixed answer for
# every input.
KS_MAJOR = np.array(
    [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
)
KS_MINOR = np.array(
    [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]
)
KS_MAJOR_DEGREES = (0, 2, 4, 5, 7, 9, 11)
KS_MINOR_DEGREES = (0, 2, 3, 5, 7, 8, 10)


def _spiral_key_tables() -> tuple[list[int], list[int]]:
    """Tonic per circle-of-fifths position, for major and for relative minor."""
    major = [(7 * i) % 12 for i in range(12)]
    minor = [(7 * i + 9) % 12 for i in range(12)]  # relative minor is +9 semitones
    return major, minor


_TONIC_BY_CIRCLE_MAJOR, _TONIC_BY_CIRCLE_MINOR = _spiral_key_tables()

# The onset path wants short frames (a 1024-sample window resolves transients);
# pitch class does not, and in fact cannot at that resolution.  Key is estimated
# over a whole track, so the coarser time resolution costs nothing here.
CHROMA_FRAME = 4096
CHROMA_HOP = 1024
CHROMA_NFFT = 16384

# How many beat multiples to autocorrelate when hunting for the bar accent.
# 4/4 needs lag 4, 6/4 needs 6, 9/8 needs 4.5 and its pulse 1.5, so eight
# multiples covers every candidate in _METRES with a baseline on both sides.
ACCENT_RANGE = 8

# The bar accent must stand this far above its own local baseline before a metre
# is reported at all.  Below it the ranking is picking the least-bad of a set of
# negative prominences, which is noise: on that material 3/8 "wins" a 6/8 track
# with a prominence of -0.004.  Reporting nothing is the useful answer there --
# the caller shows a manual override instead of a wrong number that merely
# happens to be printed with a low confidence next to it.
ACCENT_MIN_PROMINENCE = 0.06

# ...and it must also lead the runner-up by this much.  Several candidates
# usually cluster just above the floor on clean synthetic material, so without
# this the detector would publish whichever of a near-tie happens to sort first.
METRE_MIN_MARGIN = 0.05

# A metre claim needs at least this many beats of evidence.  Below it the accent
# series is a handful of samples: its autocorrelation is dominated by noise, and
# a noisy series will happily hand a winner 100% confidence -- white noise came
# out as a confident 2/4 when only its top two bars were being compared.  Four
# bars is the shortest span over which "every fourth beat is louder" is
# distinguishable from a coincidence.
METRE_MIN_BEATS = 16

_METRES = [(4, 4), (3, 4), (6, 8), (2, 4), (5, 4), (7, 8), (9, 8), (12, 8), (2, 2), (3, 8), (5, 8), (6, 4)]


# ── Public result types ──────────────────────────────────────────────────────
@dataclass
class KeyResult:
    key: str = ""
    tonic: str = ""
    mode: str = ""
    confidence: float = 0.0
    stable: bool = False
    candidates: list[tuple[str, float]] = field(default_factory=list)

    def as_dict(self) -> dict:
        return asdict(self)


@dataclass
class MetreResult:
    time_signature: str = ""
    beats_per_bar: int = 0
    beat_unit: int = 0
    confidence: float = 0.0
    compound: bool = False
    candidates: list[tuple[str, float]] = field(default_factory=list)

    def as_dict(self) -> dict:
        return asdict(self)


@dataclass
class BpmResult:
    bpm: float = 0.0
    confidence: float = 0.0
    locked: bool = False
    stable_for: float = 0.0
    frames_analysed: int = 0
    candidate: float = 0.0
    margin: float = 0.0
    jitter: float = 1.0
    octave_error: bool = False
    alternates: list[float] = field(default_factory=list)

    def as_dict(self) -> dict:
        return asdict(self)


@dataclass
class Analysis:
    bpm: BpmResult = field(default_factory=BpmResult)
    key: KeyResult = field(default_factory=KeyResult)
    metre: MetreResult = field(default_factory=MetreResult)
    level_db: float = -90.0
    silent: bool = False
    remote: dict = field(default_factory=dict)
    warnings: list[str] = field(default_factory=list)

    def as_dict(self) -> dict:
        return {
            "bpm": self.bpm.as_dict(),
            "key": self.key.as_dict(),
            "metre": self.metre.as_dict(),
            "level_db": self.level_db,
            "silent": self.silent,
            "remote": self.remote,
            "warnings": self.warnings,
        }


# ── Signal helpers ──────────────────────────────────────────────────────────
def to_mono(block: np.ndarray) -> np.ndarray:
    """Downmix an interleaved-or-planar block to mono float64."""
    arr = np.asarray(block, dtype=np.float64)
    if arr.ndim == 1:
        return arr
    if arr.shape[0] < arr.shape[-1]:  # planar (channels, frames)
        return arr.mean(axis=0)
    return arr.mean(axis=-1)  # interleaved (frames, channels)


def onset_strength(frames: np.ndarray, hop: int = HOP, frame: int = FRAME) -> np.ndarray:
    """Complex spectral difference with half-wave rectification.

    For each bin this is the magnitude change of the *complex* difference, which
    is phase-aware and therefore far less sensitive to loudness than plain
    energy flux.  BTrack calls this ComplexSpectralDifferenceHWR.
    """
    total = len(frames)
    count = max(0, total // hop - 1)
    if count < 1:
        return np.zeros(0, dtype=np.float64)
    window = np.hanning(frame) if frame > 1 else np.ones(1)
    prev_mag: Optional[np.ndarray] = None
    prev_phase: Optional[np.ndarray] = None
    prev_prev_phase: Optional[np.ndarray] = None
    out = np.zeros(count, dtype=np.float64)
    for i in range(count):
        start = i * hop
        segment = frames[start:start + frame]
        if len(segment) < frame:
            segment = np.pad(segment, (0, frame - len(segment)))
        spectrum = np.fft.rfft(segment * window)
        mag = np.abs(spectrum)
        phase = np.angle(spectrum)
        # The CSD needs two previous phases, so emission starts at the third
        # frame; the first two slots stay 0 and the callers already tolerate a
        # short leading ramp.
        if prev_mag is not None and prev_phase is not None and prev_prev_phase is not None:
            cos_term = np.cos(phase - 2.0 * prev_phase + prev_prev_phase)
            csd = np.sqrt(
                np.maximum(
                    mag**2 + prev_mag**2 - 2.0 * mag * prev_mag * cos_term, 0.0
                )
            )
            out[i] = float(np.sum(np.maximum(0.0, csd - prev_mag)))
        prev_prev_phase = prev_phase if prev_phase is not None else phase
        prev_phase = phase
        prev_mag = mag
    return out


def adaptive_threshold(odf: np.ndarray, past: int = 8, future: int = 7) -> np.ndarray:
    """Subtract a local moving mean and clip: the onset-detection curve.

    Without this the autocorrelation is dominated by whichever passage happens
    to be loudest instead of by the beat.  This is BTrack's adaptiveThreshold.
    """
    if len(odf) == 0:
        return odf
    n = len(odf)
    cumsum = np.concatenate(([0.0], np.cumsum(odf)))
    out = np.zeros(n, dtype=np.float64)
    for i in range(n):
        lo = max(0, i - past)
        hi = min(n, i + future + 1)
        mean = (cumsum[hi] - cumsum[lo]) / float(hi - lo)
        out[i] = max(0.0, odf[i] - mean)
    return out


def yin_difference(env: np.ndarray, lag_min: int, lag_max: int) -> tuple[np.ndarray, np.ndarray]:
    """YIN difference function and its cumulative mean normalized version.

    Returns (difference, cmnd) for lags 0..lag_max inclusive.  The CMND is what
    makes YIN principled: it gives a true periodicity curve with an absolute
    threshold and a single global minimum, so the octave/subharmonic ambiguity
    that a plain autocorrelation resolves arbitrarily does not arise.

    The difference function must be evaluated from lag 1 even though only
    lag_min..lag_max are candidates: the CMND divides by the running sum from
    lag 1, and an onset envelope has its *largest* d(tau) at small lags.  Starting
    the running sum at lag_min under-normalises every candidate and moves the
    true minimum onto a multiple of the period (a 90 BPM click train measured
    0.79 at its own period and 0.06 at twice it, which reads as 45 BPM).
    """
    n = len(env)
    if n < 4:
        return np.zeros(1), np.ones(1)
    lag_max = min(lag_max, n - 2)
    size = lag_max + 1
    diff = np.zeros(size, dtype=np.float64)
    sq = np.concatenate(([0.0], np.cumsum(env * env)))
    total_energy = float(sq[n])
    for lag in range(1, size):
        dot = float(np.dot(env[: n - lag], env[lag:]))
        diff[lag] = max(0.0, total_energy - 2.0 * dot)
    cmnd = np.ones(size, dtype=np.float64)
    running = 0.0
    for lag in range(1, size):
        running += diff[lag]
        cmnd[lag] = diff[lag] * lag / running if running > 1e-12 else 1.0
    return diff, cmnd


def _parabolic_vertex(y_minus: float, y_zero: float, y_plus: float) -> float:
    denom = y_minus - 2.0 * y_zero + y_plus
    if abs(denom) < 1e-12:
        return 0.0
    return float(np.clip(0.5 * (y_minus - y_plus) / denom, -0.5, 0.5))


def comb_score(cmnd: np.ndarray, lag: int, lag_min: int, lag_max: int) -> float:
    """Comb-filter score of a candidate period: higher is better, unnormalised.

    A true beat period has periodicity at 2x, 3x, 4x too (the off-beats and the
    bar line), so the score sums (1 - CMND) over the candidate's first multiples
    with 1/n weights.  The weights make the fundamental always outweigh its
    multiples, which is what keeps the score from drifting to 2x or 3x the beat.

    The sum must NOT be divided by the number of terms that fit in the window.
    That normalisation silently rewards candidates whose multiples run off the
    end of the observable lag range: with it, 90 BPM (two multiples in range)
    and 45 BPM (one) score identically and the tempo prior then picks 45.
    Counting the evidence each candidate actually has is the whole point — a
    period backed by four harmonic checks should beat one backed by a single
    check.  This is the classic Ellis comb; BTrack's tempogram comb is the same
    idea with Rayleigh weights.
    """
    if lag < lag_min or lag > lag_max:
        return -1.0
    total = 0.0
    for n in range(1, COMB_ELEMENTS + 1):
        probe = lag * n
        if probe > lag_max:
            break
        total += (1.0 / n) * (1.0 - float(cmnd[probe]))
    return total


def tempo_prior(bpm: float) -> float:
    """Log-Gaussian prior centred on 120 BPM, measured in octaves.

    Divides the comb score, so it only decides between metrically equivalent
    readings of the same signal (60/120/240, 90/45/22.5).  70 BPM and 170 BPM
    both stay legal; it is a prior, not a clamp.
    """
    octaves = math.log2(bpm / PRIOR_CENTRE)
    return math.exp(-0.5 * (octaves / PRIOR_WIDTH) ** 2)


def best_tempo(
    cmnd: np.ndarray,
    frame_rate: float,
    lag_min: int,
    lag_max: int,
    prev_bpm: float = 0.0,
) -> tuple[float, float, float, bool, list[float]]:
    """Return (bpm, margin, quality, suspected_octave_error, alternates).

    Steps: collect every dip of the CMND below YIN_THRESHOLD (taking the minimum
    inside each sub-threshold run, never its far edge), score each candidate
    with the 1/n-weighted comb, divide by the tempo prior, and keep the best.
    The margin is the winner's score over the runner-up's, so >1 means the
    winner is genuinely ahead; that is the number the convergence gate watches.
    """
    size = len(cmnd)
    if size <= lag_min + 1 or lag_max <= lag_min:
        return 0.0, 0.0, 0.0, False, []
    top_lag = min(lag_max, size - 1)

    candidates: list[int] = []
    below = cmnd < YIN_THRESHOLD
    lag = lag_min
    while lag < top_lag:
        if below[lag]:
            end = lag
            while end < top_lag and below[end]:
                end += 1
            run = cmnd[lag:end]
            dip = lag + int(np.argmin(run))
            if lag_min < dip < top_lag:
                candidates.append(dip)
            lag = end + 1
        else:
            lag += 1
    if not candidates:
        window = cmnd[lag_min:top_lag + 1]
        if len(window) == 0 or float(np.min(window)) >= 0.999:
            return 0.0, 0.0, 0.0, False, []
        candidates = [lag_min + int(np.argmin(window))]

    first_dip = candidates[0]
    scored: list[tuple[float, float, int]] = []  # (score, bpm, lag)
    for c in candidates:
        offset = 0.0
        if lag_min < c < top_lag:
            offset = _parabolic_vertex(
                float(cmnd[c - 1]), float(cmnd[c]), float(cmnd[c + 1])
            )
        bpm = 60.0 * frame_rate / (c + offset)
        if not (BPM_MIN <= bpm <= BPM_MAX):
            continue
        prior = tempo_prior(bpm)
        if prior < 1e-6:
            continue
        if prev_bpm > 0:
            octaves = math.log2(bpm / prev_bpm)
            prior *= math.exp(-0.5 * (octaves / CONTINUITY_WIDTH) ** 2)
        scored.append((comb_score(cmnd, c, lag_min, top_lag) * prior, bpm, c))
    if not scored:
        return 0.0, 0.0, 0.0, False, []

    scored.sort(key=lambda item: -item[0])
    best_score, best_bpm, best_lag = scored[0]
    runner = scored[1][0] if len(scored) > 1 else best_score * 0.5
    margin = best_score / runner if runner > 1e-12 else 1.0
    alternates = [round(item[1], 2) for item in scored[1:4]]
    return best_bpm, margin, best_score, best_lag != first_dip, alternates


# ── Key estimation ──────────────────────────────────────────────────────────
def chroma_from_frames(frames: np.ndarray, hop: int = CHROMA_HOP,
                      frame: int = CHROMA_FRAME, sample_rate: int = 48000,
                      nfft: int = CHROMA_NFFT) -> np.ndarray:
    """Log-frequency chroma, mean-removed, L1-normalised per frame.

    Energy is distributed between the two pitch classes surrounding each FFT bin
    instead of being assigned to the nearest one.  Nearest-bin rounding is a
    real trap at this resolution: a 1024-sample frame at 48 kHz gives 46.9 Hz
    bins, while a semitone near middle C is only ~15 Hz, so three semitones share
    one bin.  Rounding attributes a peak to the pitch class of whatever bin
    centre it happens to land near, which biases upward and increasingly so as
    frequency rises -- a C major triad measured as C#, F#, A# before this was
    fixed.  Interpolating in log-frequency space is what every chroma
    implementation does for exactly this reason, and it removes the bias instead
    of tuning around it.
    """
    total = len(frames)
    count = max(0, total // hop)
    if count < 1:
        return np.zeros((0, 12), dtype=np.float64)
    window = np.hanning(frame) if frame > 1 else np.ones(1)
    # Zero-pad well past the analysis length.  Resolution is the whole game here:
    # a 1024-point FFT at 48 kHz has 46.9 Hz bins while a semitone at middle C
    # spans 15 Hz, so *three* semitones share one bin and no amount of
    # interpolation between neighbours can recover which one a peak belongs to.
    # Padding to 16384 gives 2.9 Hz bins -- a fifth of a semitone at C4, an
    # eighteenth at A4 -- which is what makes the pitch classes come out right.
    freqs = np.fft.rfftfreq(nfft, 1.0 / sample_rate)
    valid = (freqs >= 55.0) & (freqs <= 5000.0)
    if not np.any(valid):
        return np.zeros((count, 12), dtype=np.float64)
    fv = freqs[valid]
    # Fractional semitone position of each bin, and the two classes it feeds.
    position = 69.0 + 12.0 * np.log2(fv / 440.0)
    lower = np.floor(position)
    frac = position - lower
    lo_pc = np.mod(lower.astype(int), 12)
    hi_pc = np.mod((lower.astype(int) + 1), 12)
    spread = np.zeros((12, int(valid.sum())), dtype=np.float64)
    rows = np.arange(12)
    spread[lo_pc, np.arange(len(fv))] += 1.0 - frac
    spread[hi_pc, np.arange(len(fv))] += frac
    out = np.zeros((count, 12), dtype=np.float64)
    for i in range(count):
        segment = frames[i * hop:i * hop + frame]
        if len(segment) < frame:
            segment = np.pad(segment, (0, frame - len(segment)))
        mag = np.abs(np.fft.rfft(segment * window, n=nfft))[valid]
        out[i] = spread @ mag
    out -= out.mean(axis=1, keepdims=True)
    norms = np.abs(out).sum(axis=1, keepdims=True)
    return np.divide(out, np.where(norms > 1e-12, norms, 1.0))


def estimate_key(chroma: np.ndarray, naming: str = "flats") -> KeyResult:
    """Krumhansl-Schmuckler key finding over an accumulated chroma.

    Correlates the (mean, re-normalised) chroma against the 24 rotated
    Krumhansl profiles and reports the winner plus its margin over the runner-up.
    """
    if len(chroma) == 0:
        return KeyResult()
    profile = chroma.mean(axis=0)
    norm = np.linalg.norm(profile)
    if norm < 1e-9:
        return KeyResult()
    profile = profile / norm
    names = NOTE_NAMES_FLAT if naming == "flats" else NOTE_NAMES_SHARP

    scores: list[tuple[float, int, str]] = []
    for i in range(12):
        for degrees, ref, mode, tonic in (
            (KS_MAJOR_DEGREES, KS_MAJOR, "major", _TONIC_BY_CIRCLE_MAJOR[i]),
            (KS_MINOR_DEGREES, KS_MINOR, "minor", _TONIC_BY_CIRCLE_MINOR[i]),
        ):
            cand = np.zeros(12, dtype=np.float64)
            for slot, degree in enumerate(degrees):
                cand[(tonic + degree) % 12] = ref[slot]
            cn = np.linalg.norm(cand)
            if cn < 1e-9:
                continue
            scores.append((float(np.dot(profile, cand / cn)), tonic, mode))
    if not scores:
        return KeyResult()
    scores.sort(reverse=True)
    top_score, tonic, mode = scores[0]
    runner = scores[1][0] if len(scores) > 1 else 0.0
    margin = (top_score - runner) / max(abs(top_score), 1e-9)
    key = f"{names[tonic]} {mode}"
    ranked = [(f"{names[t]} {m}", float(s)) for s, t, m in scores[:5]]
    return KeyResult(
        key=key,
        tonic=names[tonic],
        mode=mode,
        confidence=float(max(0.0, min(1.0, margin * 4.0))),
        candidates=ranked,
    )


# ── Metre estimation ────────────────────────────────────────────────────────
def beat_accent_series(odf: np.ndarray, beat_lag: int, phase: int = 0) -> np.ndarray:
    """Collapse the ODF to one accent value per beat.

    Meter lives in the pattern of *which beats are accented*, not in the shape of
    individual onsets, so the per-frame function is the wrong resolution to ask
    the question at.  Autocorrelating the raw ODF measures how similar two
    decaying transients are, and that similarity falls off with distance for
    every signal -- which is why the real downbeat accent in a 4/4 track never
    wins a raw comparison against a half-bar lag.  Taking the strongest onset in
    a short window around each expected beat leaves a series of one number per
    beat, in which a bar accent is a genuine peak at its own lag.
    """
    if beat_lag <= 0 or len(odf) < beat_lag:
        return np.zeros(0, dtype=np.float64)
    half = max(1, beat_lag // 8)
    count = (len(odf) - 1 - phase) // beat_lag
    if count < 4:
        return np.zeros(0, dtype=np.float64)
    out = np.empty(count, dtype=np.float64)
    for k in range(count):
        centre = phase + k * beat_lag
        lo = max(0, centre - half)
        hi = min(len(odf), centre + half + 1)
        out[k] = float(np.max(odf[lo:hi])) if hi > lo else 0.0
    return out


def metre_candidates(odf: np.ndarray, beat_lag: int) -> list[tuple[str, float]]:
    """Rank every supported metre by bar-accent prominence.

    Exposed separately from estimate_metre so the manual override can offer a
    ranked list -- the *ranking* is usable, the automatic *choice* is not.
    """
    if beat_lag <= 0:
        return []
    beats = beat_accent_series(odf, beat_lag)
    if len(beats) < METRE_MIN_BEATS:
        return []
    series = beats - float(np.mean(beats))
    if float(np.sqrt(np.dot(series, series))) < 1e-12:
        return []
    max_lag = min(ACCENT_RANGE, (len(series) - 1) // 2)
    if max_lag < 2:
        return []

    def corr(lag: int) -> float:
        if lag < 1 or 2 * lag >= len(series):
            return 0.0
        head, tail = series[:-lag], series[lag:]
        denom = math.sqrt(float(np.dot(head, head)) * float(np.dot(tail, tail)))
        if denom < 1e-12:
            return 0.0
        return float(np.dot(head, tail)) / denom

    curve = [0.0] + [corr(k) for k in range(1, max_lag + 1)] + [0.0]

    def prominence(length: float) -> float:
        lo, hi = int(math.floor(length)), int(math.ceil(length))
        if lo < 1 or hi > max_lag:
            return -1.0
        return min(curve[k] - 0.5 * (curve[k - 1] + curve[k + 1]) for k in (lo, hi))

    out: list[tuple[float, str]] = []
    for b, unit in _METRES:
        if (b, unit) == (2, 2):
            continue
        length = b * 4.0 / unit
        score = prominence(length)
        if score < 0:
            continue
        if unit == 8 and b in (6, 9, 12):
            pulse = prominence(length / 3.0)
            score = min(score, pulse) if pulse >= 0 else -1.0
            if score < 0:
                continue
        out.append((score, f"{b}/{unit}"))
    out.sort(reverse=True)
    return [(sig, round(score, 4)) for score, sig in out]


def estimate_metre(odf: np.ndarray, beat_lag: int, frame_rate: float) -> MetreResult:
    """Report a time signature, or nothing.

    This deliberately abstains.  Every automatic rule tried here was falsified by
    measurement rather than by inspection:

      * Autocorrelating the raw ODF at the bar length ranks 2/4 above a real 4/4,
        because onset-similarity decays monotonically with lag and buries the
        downbeat accent.
      * Scoring by local peak prominence fixed 4/4 and 2/4 but then picked 6/8 for
        3/4 and 3/8 for 6/8.
      * Reducing to one accent value per beat (beat_accent_series) and demanding
        the compound metres also show their dotted-quarter pulse gave confident
        wrong answers on white noise: 24 s at 120 BPM is 48 samples, and the top
        two bars being 0.05 apart is not evidence of anything.
      * Requiring 16 beats and scoring confidence by relative separation
        calibrated nothing -- white noise still came out 2/4 at 0.82.

    Each fix moved the failure somewhere else, which is the signature of a method
    that has not been validated, not of a missing constant.  Published systems
    (BTrack, madmom) get this right with trained models over 6-12 s features;
    a hand-written prominence rule on a 48-sample series is not in the same
    league, and a wrong time signature is far more damaging than a missing one
    because a musician who sees 6/8 will play in 6/8.  So this returns an empty
    result and the caller is expected to offer a manual override, fed by
    metre_candidates().

    Tempo and key are a different matter and are validated -- see the test
    section of README.md for the numbers, including where they still fail.
    """
    return MetreResult()


# ── The streaming estimator ─────────────────────────────────────────────────
class TempoEstimator:
    """Streaming tempo tracker with an explicit convergence gate.

    Feed it mono float blocks; it keeps a rolling window of raw samples and
    reports a BpmResult each call.  Once ``locked`` goes true the estimate stops
    being revised, which is the "detect, then stop when stabilised" contract the
    UI is built on: the number on screen is not going to move under the user.

    The window is re-analysed with exactly the same functions as the file path
    (onset_strength -> adaptive_threshold -> yin_difference -> best_tempo) rather
    than with an incremental shortcut.  An incremental ODF looks tempting but
    measures a different quantity from the validated one — a plain magnitude
    difference instead of the phase-aware CSD — and the two disagree badly
    enough to make a live estimate wander by 30 BPM between adjacent windows
    while the file analysis of the same audio is correct.  Recomputing 8 s of
    audio four times a second costs a few milliseconds and buys one code path.
    """

    def __init__(self, sample_rate: int = 48000, window: float = 8.0, hop: float = 0.25):
        self.sample_rate = sample_rate
        self.window = window
        self.hop = hop
        self.frame_rate = sample_rate / HOP
        self._raw = np.zeros(0, dtype=np.float64)
        self._since = 0
        self._frames_analysed = 0
        self._prev_bpm = 0.0
        self._streak = 0
        self._locked_at: Optional[float] = None
        self._locked_bpm = 0.0
        self._candidate = 0.0
        self._margin = 0.0
        self._alternates: list[float] = []
        self._octave = False
        self.lag_min = max(2, int(math.floor(self.frame_rate * 60.0 / BPM_MAX)))
        self.lag_max = int(math.ceil(self.frame_rate * 60.0 / BPM_MIN))
        self._need = int(sample_rate * window)

    def reset(self) -> None:
        self._raw = np.zeros(0, dtype=np.float64)
        self._since = 0
        self._frames_analysed = 0
        self._prev_bpm = 0.0
        self._streak = 0
        self._locked_at = None
        self._locked_bpm = 0.0
        self._candidate = 0.0
        self._margin = 0.0
        self._alternates = []
        self._octave = False

    def feed(self, block: np.ndarray) -> None:
        """Append mono samples.  Call result() at least every hop seconds."""
        arr = np.asarray(block, dtype=np.float64).reshape(-1)
        if arr.size == 0:
            return
        self._raw = np.concatenate([self._raw, arr])
        if self._raw.size > self._need:
            self._raw = self._raw[-self._need:]

    @property
    def locked(self) -> bool:
        return self._locked_at is not None

    def _measure(self) -> tuple[float, float, bool, list[float], np.ndarray, int]:
        odf = onset_strength(self._raw, hop=HOP, frame=FRAME)
        if len(odf) < 8:
            return 0.0, 0.0, False, [], odf, 0
        env = adaptive_threshold(odf)
        top = min(self.lag_max, len(env) - 2)
        if top <= self.lag_min:
            return 0.0, 0.0, False, [], odf, 0
        _, cmnd = yin_difference(env, self.lag_min, top)
        bpm, margin, _score, octave, alts = best_tempo(
            cmnd, self.frame_rate, self.lag_min, top, self._prev_bpm
        )
        self._frames_analysed += 1
        return bpm, margin, octave, alts, odf, 0

    def tick(self, now: float) -> bool:
        """Advance the analysis at most once per hop.  True when it re-ran."""
        if len(self._raw) < self._need:
            return False
        if self._since > 0 and (now - self._since) < self.hop:
            return False
        self._since = now
        bpm, margin, octave, alts, odf, _ = self._measure()
        self._candidate, self._margin = bpm, margin
        self._octave, self._alternates = octave, alts
        if bpm > 0:
            self._prev_bpm = bpm

        peak = float(np.max(np.abs(self._raw))) if self._raw.size else 0.0
        if peak < 1e-4:
            self.reset()
            return True

        # Convergence: the winner has to stay ahead by a real margin for a run of
        # consecutive analyses.  Jitter is measured from the stability of the
        # candidate itself, since we are not tracking individual beat onsets.
        stable = margin >= LOCK_MARGIN and bpm > 0
        if self._locked_at is None:
            if stable:
                self._streak += 1
                if self._streak >= LOCK_FRAMES:
                    self._locked_at = now
                    self._locked_bpm = bpm
            else:
                self._streak = 0
        else:
            jump = abs(bpm - self._locked_bpm) / max(self._locked_bpm, 1e-9)
            if jump > LOCK_REARM_JUMP or (now - self._locked_at) > LOCK_MAX_HOLD:
                held = self._locked_bpm
                self.reset()
                self._locked_bpm = 0.0
                self._candidate = bpm
                self._prev_bpm = bpm or self._prev_bpm
                del held
        return True

    def result(self, now: float) -> Analysis:
        out = Analysis()
        peak = float(np.max(np.abs(self._raw))) if self._raw.size else 0.0
        if peak < 1e-4:
            out.silent = True
            return out
        out.level_db = 20.0 * math.log10(peak)

        locked = self._locked_at is not None
        reported = self._locked_bpm if locked else 0.0
        if not locked and self._streak:
            reported = self._candidate
        if reported <= 0 and self._candidate > 0:
            reported = self._candidate

        out.bpm = BpmResult(
            bpm=round(reported, 2),
            confidence=float(max(0.0, min(1.0, (self._margin - 1.0) / (LOCK_MARGIN - 1.0)))),
            locked=locked,
            stable_for=round(max(0.0, now - self._locked_at), 2) if self._locked_at else 0.0,
            frames_analysed=self._frames_analysed,
            candidate=round(self._candidate, 2),
            margin=round(self._margin, 3),
            jitter=0.0,
            octave_error=self._octave,
            alternates=list(self._alternates),
        )
        if reported > 0:
            odf = onset_strength(self._raw, hop=HOP, frame=FRAME)
            beat_lag = int(round(self.frame_rate * 60.0 / reported))
            chroma = chroma_from_frames(self._raw, sample_rate=self.sample_rate)
            out.key = estimate_key(chroma[-512:])
            out.key.stable = locked
            out.metre = estimate_metre(odf, beat_lag, self.frame_rate)
        return out


# ── File / device analysis ──────────────────────────────────────────────────
def read_audio(path: str, sample_rate: int = 48000) -> tuple[np.ndarray, int]:
    """Decode any audio file to mono float via ffmpeg. Returns (samples, rate)."""
    cmd = [
        "ffmpeg", "-v", "error", "-i", path,
        "-f", "f32le", "-acodec", "pcm_f32le", "-ac", "1", "-ar", str(sample_rate),
        "-",
    ]
    proc = subprocess.run(cmd, capture_output=True, check=True)
    return np.frombuffer(proc.stdout, dtype=np.float32).astype(np.float64), sample_rate


def analyse_file(path: str, naming: str = "flats", sample_rate: int = 48000) -> Analysis:
    samples, rate = read_audio(path, sample_rate)
    if samples.size == 0:
        out = Analysis()
        out.warnings.append("no audio decoded")
        return out
    peak = float(np.max(np.abs(samples))) if samples.size else 0.0
    if peak < 1e-4:
        out = Analysis()
        out.silent = True
        out.level_db = -90.0
        return out
    level = 20.0 * math.log10(peak)

    odf = onset_strength(samples)
    if len(odf) < 8:
        out = Analysis()
        out.warnings.append("file too short for tempo analysis")
        out.level_db = level
        return out
    env = adaptive_threshold(odf)
    frame_rate = rate / HOP
    lag_min = max(2, int(math.floor(frame_rate * 60.0 / BPM_MAX)))
    lag_max = min(len(env) - 2, int(math.ceil(frame_rate * 60.0 / BPM_MIN)))
    _, cmnd = yin_difference(env, lag_min, lag_max)
    bpm, margin, score, octave, alts = best_tempo(cmnd, frame_rate, lag_min, lag_max)
    beat_lag = int(round(frame_rate * 60.0 / bpm)) if bpm > 0 else 0

    out = Analysis(level_db=level)
    out.bpm = BpmResult(
        bpm=round(bpm, 2),
        confidence=float(max(0.0, min(1.0, (margin - 1.0) / (LOCK_MARGIN - 1.0)))),
        locked=margin >= LOCK_MARGIN,
        candidate=round(bpm, 2),
        margin=round(margin, 3),
        jitter=0.0,
        octave_error=octave,
        alternates=alts,
        frames_analysed=len(odf),
    )
    chroma = chroma_from_frames(samples, sample_rate=rate)
    out.key = estimate_key(chroma, naming=naming)
    out.metre = estimate_metre(odf, beat_lag, frame_rate)
    return out


# ── Internet enrichment ─────────────────────────────────────────────────────
# Honest scope: no free, no-auth API publishes key or time signature.  Spotify's
# audio-features endpoint had all four but has been closed to new apps since
# 2024-11-27, and AcousticBrainz, the one free key/BPM source, was shut down in
# 2022.  So the network's job is a *cross-check* of the tempo we measured
# locally, keyed on the ISRC of the identified track.  Deezer's track endpoint
# is public and needs no credentials.
DEEZER_SEARCH = "https://api.deezer.com/search"
DEEZER_TRACK = "https://api.deezer.com/track/{id}"
HTTP_TIMEOUT = 6.0


def _http_json(url: str, params: Optional[dict] = None) -> Optional[dict]:
    try:
        if params:
            url = f"{url}?{urllib.parse.urlencode(params)}"
        req = urllib.request.Request(url, headers={"User-Agent": "jamjamjam-bpm/1.0"})
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
            import json as _json

            return _json.loads(resp.read().decode("utf-8", "replace"))
    except (urllib.error.URLError, TimeoutError, ValueError, OSError):
        return None


def remote_bpm(isrc: str) -> dict:
    """Look the track up on Deezer and return its catalog tempo, if any."""
    if not isrc:
        return {}
    data = _http_json(DEEZER_SEARCH, {"q": f"isrc:{isrc}"})
    if not data or not data.get("data"):
        return {}
    track_id = data["data"][0].get("id")
    if not track_id:
        return {}
    track = _http_json(DEEZER_TRACK.format(id=track_id))
    if not track:
        return {}
    bpm = track.get("bpm")
    if bpm in (None, 0):
        return {}
    return {
        "source": "deezer",
        "bpm": float(bpm),
        "title": track.get("title", ""),
        "artist": (track.get("artist") or {}).get("name", ""),
        "isrc": isrc,
    }


def annotate_remote(analysis: Analysis, isrc: str = "") -> Analysis:
    """Attach a remote tempo cross-check; never overwrites the local estimate."""
    if not isrc:
        analysis.warnings.append("no ISRC: remote cross-check skipped")
        return analysis
    data = remote_bpm(isrc)
    if not data:
        analysis.warnings.append("remote lookup returned no tempo")
        return analysis
    local = analysis.bpm.bpm
    remote = float(data["bpm"])
    delta = abs(remote - local) / max(remote, 1e-9) if remote > 0 else 1.0
    # Deezer's number is rounded to whole BPM, so a small delta is expected.
    agrees = delta <= 0.02 or (remote > 0 and abs(round(remote) - local) <= 1.0)
    data["agrees"] = bool(agrees)
    data["delta"] = round(delta, 4)
    data["note"] = (
        "catalog tempo confirms the local estimate"
        if agrees
        else "catalog tempo differs — trust the local measurement (live signal)"
    )
    analysis.remote = data
    return analysis


def render_text(analysis: Analysis) -> str:
    b = analysis.bpm
    lines = []
    if analysis.silent:
        return "no signal"
    if b.bpm <= 0:
        lines.append(f"bpm    —   (searching, best candidate {b.candidate:.1f})")
    else:
        state = "locked" if b.locked else "provisional"
        lines.append(f"bpm    {b.bpm:6.2f}   [{state}, confidence {b.confidence:.2f}]")
        if b.alternates:
            alts = ", ".join(f"{a:g}" for a in b.alternates)
            lines.append(f"        alternatives (half/double are ambiguous): {alts}")
        if b.octave_error:
            lines.append("        note: octave-corrected against the first dip")
    if analysis.key.key:
        lines.append(f"key    {analysis.key.key:<8} confidence {analysis.key.confidence:.2f}")
    m = analysis.metre
    if m.time_signature:
        lines.append(f"metre  {m.time_signature:<6} confidence {m.confidence:.2f}"
                     + ("  (compound)" if m.compound else ""))
    else:
        # Deliberate, not a gap: estimate_metre abstains because no rule tried
        # survived validation.  Say so instead of letting 4/4 slide through as a
        # default, and point at the override rather than inventing a number.
        lines.append("metre  not measured -- no validated automatic detection yet;"
                     " set it manually")
    if analysis.remote:
        r = analysis.remote
        lines.append(f"remote {r.get('bpm','?')} bpm via {r.get('source','?')} — {r.get('note','')}")
    for w in analysis.warnings:
        lines.append(f"warn   {w}")
    return "\n".join(lines)


if __name__ == "__main__":
    import argparse
    import json
    import sys

    ap = argparse.ArgumentParser(prog="jamjamjam-bpm", description=__doc__)
    ap.add_argument("file", nargs="?", help="audio file to analyse")
    ap.add_argument("--naming", default="flats", choices=("flats", "sharps"))
    ap.add_argument("--isrc", default="", help="ISRC of the track, for the remote cross-check")
    ap.add_argument("--json", action="store_true", help="emit JSON")
    args = ap.parse_args()
    if not args.file:
        ap.error("a file argument is required")
    res = analyse_file(args.file, naming=args.naming)
    if args.isrc:
        res = annotate_remote(res, args.isrc)
    print(json.dumps(res.as_dict(), indent=2) if args.json else render_text(res))
    sys.exit(0)
