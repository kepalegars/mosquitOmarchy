# jamjamjam-bpm

Tempo, key and time signature for jamjamjam. Local analysis, numpy only.

    ./setup-jamjamjam-bpm.sh
    jamjamjam-bpm analyse track.wav
    jamjamjam-bpm watch --source alsa_input.usb-ESI_Audiotechnik_UGM192_UGM192_v1.4-4515-937A-136052020-470C-01.analog-stereo
    jamjamjam-bpm doctor

## What is reliable, and what is not

Read this before trusting a number.

| | status | evidence |
|---|---|---|
| **tempo** | works, with a known ambiguity | 13/17 synthetic accented click tracks exact in file mode; the 4 misses are 2 half-time, 1 double-time and 1 off-grid. Streaming: 11/16, all with the estimate stable to within 1 BPM between adjacent windows. |
| **key** | works on real material | 15/17 diatonic scales, the 2 misses being F#/Gb spelling rather than a wrong note |
| **time signature** | **not implemented** | no rule tried survived validation; `estimate_metre` returns nothing on purpose |
| **key from a bare triad** | unreliable | 2/6 — a triad alone is genuinely ambiguous between a key and its relative |

### Time signature abstains, on purpose

`estimate_metre` returns an empty result and says so. Four automatic rules were
written and each was falsified by measurement rather than by reading the code:

1. Autocorrelating the onset-strength function at the bar length ranked 2/4 above
   a real 4/4. Onset similarity decays monotonically with lag (0.73, 0.62, 0.56,
   0.58, 0.34 at one to five beats), so the genuine downbeat accent at four beats
   is higher than its neighbours yet far below every shorter lag.
2. Ranking by local peak prominence instead of raw correlation fixed 4/4 and 2/4,
   then picked 6/8 for 3/4 and 3/8 for 6/8.
3. Collapsing the ODF to one accent value per beat (`beat_accent_series`) and
   requiring compound metres to also show their dotted-quarter pulse produced
   *confident* wrong answers on white noise: 24 s at 120 BPM is 48 samples, and
   the top two bars being 0.05 apart is not evidence of anything.
4. Demanding 16 beats and scoring confidence by relative separation calibrated
   nothing — white noise still came out as 2/4 at 0.82 confidence.

Each fix relocated the failure rather than removing it, which is what an
unvalidated method looks like. Published systems (BTrack, madmom) get this right
with trained models over 6-12 s of features. A wrong time signature is worse than
a missing one — a musician who reads 6/8 will *play* in 6/8 — so the detector
abstains and `metre_candidates()` feeds a manual override instead.

### Two bugs worth remembering

Both were found by testing against synthesised material and both produced
plausible-looking nonsense, which is why they are written down:

- **Chroma resolution.** Rounding each FFT bin to its nearest pitch class
  measured a C major triad as C#, F#, A#. At 1024 points and 48 kHz a bin is
  46.9 Hz wide while a semitone at middle C is 15 Hz, so three semitones share one
  bin and interpolation between neighbours cannot recover the right one. Fixed by
  a 4096-point window zero-padded to 16384 (2.9 Hz bins) with energy split
  linearly between the two surrounding pitch classes.
- **Key profiles.** The scale tables held sorted pitch-class *sets* and listed the
  major scale twice. The Krumhansl weights are positional, so a sorted set put
  the tonic weight (6.35) on whichever class happened to be lowest — G major
  matched a profile whose loudest note was C — and every "minor" candidate was
  really a major one, so key finding returned one fixed answer for everything.

## How the tempo estimate works

`onset_strength` → `adaptive_threshold` → `yin_difference` → `best_tempo`

- **Onset function**: complex spectral difference with half-wave rectification,
  which uses phase as well as magnitude, unlike a plain magnitude difference.
- **Threshold**: adaptive local mean, so quiet passages do not need a second pass.
- **Period**: YIN difference function and its cumulative mean, with the first dip
  below threshold taken as the beat period. Computing the CMND from lag 1 (not 0)
  and taking the argmin inside each sub-threshold run is what keeps the period
  honest.
- **Tempo**: the CMND is scored by a comb filter summing `(1 - CMND)` over each
  candidate's first four multiples with 1/n weights, times a log-domain tempo
  prior. The comb sum is deliberately **not** divided by the number of terms that
  fit in the lag window: normalising rewards candidates whose multiples run off
  the end of the observable range, which scored 90 BPM and 45 BPM identically and
  let the prior pick 45.
- **Streaming**: a log-domain Gaussian continuity term (BTrack's HMM transition
  penalty, reduced) suppresses transient double-time readings. The window is
  re-analysed with the same functions as the file path rather than by an
  incremental shortcut — an incremental ODF measures a different quantity and made
  live estimates wander by 30 BPM between adjacent windows while the file
  analysis of the same audio was correct.
- **Convergence**: the winner must hold a margin for a run of analyses, then the
  estimate stops moving, which is the "detect then stop when stabilised" contract
  the UI is built on.

`alternates` always lists the half/double candidates. A beat and its double are
both consistent descriptions of the same onsets; what separates them is that the
true tempo does not jump, which is the continuity term's job. Where the material
is genuinely ambiguous, the alternates are shown and the user picks.

The four file-mode misses are not all the same mistake, and lumping them together
as "octave errors" would overstate how well this works:

| signal | reads | kind |
|---|---|---|
| 90 BPM | 45.0 | half-time |
| 174 BPM | 86.8 | half-time |
| 96 BPM, 8th-note accents | 192.8 | double-time |
| 100 BPM, 16th-note accents, bar accent outside the window | 133.7 | off-grid |

So the known weakness is real but narrow: it shows on synthetic subdivision
patterns, and the half-time cases are the ones a listener would most notice. On
material with a visible bar accent and a beat-level pulse it is exact.

## Key

Krumhansl-Schmuckler correlation against all 24 keys, mean-removed and
L2-normalised chroma, per-frame log-frequency folding. Flats by default, sharps
with `--naming sharps` — F# major is reported as Gb major under the default and
that is the naming convention, not a wrong note.

## The network, and what it is not for

The only remote call is an optional Deezer tempo cross-check, and it requires an
ISRC. It annotates; it never overwrites the measured value, because Deezer's
number is a catalogue entry rounded to whole BPM and a live signal is not
necessarily the record.

**Key and time signature are never looked up.** There is no free, no-auth API that
publishes them: Spotify's audio-features endpoint is closed to new applications,
AcousticBrainz has shut down, and Deezer exposes tempo only. Reporting a key or a
signature from a catalogue that was never consulted would be a fabrication, so
those two are measured — and where measurement is not yet trustworthy (time
signature) the answer is withheld instead.

## Prior art that was read, not linked

All of these are GPL or incompatible with a from-scratch numpy implementation, so
none of them is vendored; they were read for the algorithms.

- <https://github.com/dlepaux/realtime-bpm-analyzer> — TypeScript, Apache-2.0.
  Raw-waveform threshold plus interval histogram. No FFT, no ODF, no ACF, so not
  competitive for anything but a first result.
- <https://arthurbeaulieu.github.io/BeatDetect.js/> — JS, GPL-3.0. Offline only;
  0.5 s maximum peak bins and an interval histogram, no ACF.
- <https://github.com/Tatsh/bpmdetect> — C++/Qt, SoundTouch. Real-time with a
  decimated envelope and ACF, a ×2/×4 harmonic rule and a 30 s forgetting window.
  The closest match to the design here.
- <https://github.com/adamstark/BTrack> — C++, GPL-3.0. Spectral ODF, balanced ACF,
  a 4-comb and an HMM, with a Rayleigh-weighted tempogram comb. The reference
  architecture, and the reason the stream carries a continuity term.

## Layout

    lib_bpm_core.py            the analysis; importable, and has its own __main__
    bpm_cli.py                 batch driver: many files, one greppable block each
    jamjamjam-bpm              entry point: analyse / watch / doctor
    setup-jamjamjam-bpm.sh     link into ~/.local/bin

Exit status from `analyse` is 1 if any file produced no tempo, so a script can
tell "found nothing" from "found something".
