# jamjamjam

An Omarchy bar widget that listens to what you are playing and reports the **key**, the
**BPM** and the **chord**, with a guitar-neck view, an input tuner and optional MIDI output.

> **Alpha.** Developed on one machine only. Expect missing or rough edges.

## Privacy

Two guarantees, and they are the reason the capture is gated rather than always-on:

- **The microphone is never used while the plugin is closed.** The tuner's mic capture is
  hard-gated in the backend: it runs only while the panel is open, an analysis hold is
  active, or the neck TUI session is open. Nothing is captured in the background.
- **No audio is ever written to disk.** What is captured lives in small in-memory ring
  buffers. What survives a session is analysis metadata only — key, BPM, chord, tuner
  results, config, MIDI choice — under `~/.local/state/jamjamjam/` and
  `~/.config/jamjamjam/`.

## Detection

- **Source.** By default it analyses the PipeWire **monitor of the default sink**, so it
  hears what the system plays rather than what the room hears. A header button switches the
  analysis source between that monitor and the default microphone; it does not affect the
  tuner, whose own input is picked in the panel settings.
- **Tuner input.** The panel settings carry a dropdown of every capture source on the machine,
  and the choice outranks the analysis source: picking an interface there is a direct statement
  of what the tuner should hear, so the tuner plays it even while the analyzer is on PC audio.
  `System default` hands the decision back to the source toggle. This is the same selection
  model Pitchfork uses — the default entry is always present and always first, so there is a
  way back from a device that has since been unplugged.
- **Key** — Krumhansl-Schmuckler profile over harmonic chroma, with a confidence percentage.
  Adopted only after holding across two analyses, and the confidence gates the fretboard.
- **BPM** — onset-envelope autocorrelation over the same window, so tempo locks within a
  couple of seconds, plus an estimated 4/4 vs 3/4.
- **Chord** — an extended dictionary (maj, m, 7, maj7, m7, m7♭5, dim, dim7, 6, m6, sus2, sus4,
  add9) with a separate bass chroma for slash chords and inversions, preferring the smallest
  chord that explains the notes so a triad is not read as a maj7.
- **It does not guess.** Chunks below the silence floor are skipped, a chord must be tonally
  peaked and must beat the runner-up, and the key needs a tonal peak too. One note or a noisy
  spectrum reports *no chord* rather than a wrong answer, and a sustained shift announces
  *"new song detected — press r to reset"* instead of silently changing the key.

Chord-progression and loop detection are **disabled for now** (`PROGRESSION_ENABLED = False`
in the backend; the code is kept to re-enable). The panel and the TUI show a live estimate of
the chord currently playing instead. This is deliberately not presented as a feature — the
detection was not reliable enough.

## The panel

A ♪ icon in the bar: a pulsing red dot while recording, a pulsing ring while an analysis hold
is active, so the hold is visible from the bar even when the TUI is not focused. Left-click
opens the panel, right-click toggles recording. Clicking the icon pins the panel — it stays
open with its input region shrunk to the cards, so clicks fall through and you can keep working.

`g` opens the TUI · `r` resets · `space` resumes the auto-stopped analysis · `p` pauses without
losing results · `m` toggles MIDI · `n` toggles flats/sharps · `s` opens settings. Clicking the
**BPM card** toggles the metronome at the detected tempo, and the card flashes white per beat.

Analysis stops on its own once the key is confidently in mind; `space` restarts it at any time.

## The neck TUI

`jamjamjam-tui` (also the **GUITAR** button) opens a single floating, centered window — a
second launch refocuses the running one. The key/BPM header and the tuner are pinned at the
top, the `jamjamjam` wordmark floats centred below it in a red box while a hold is active, and
the scale line, the fretboard and the live chord line are centred under it. High strings on
top; fret numbers below the neck only.

`hold Right Ctrl` analyses · `m` metronome · `r` reset · `s` settings · `?` help · `q` quit.

**Right Ctrl** is the global analysis hold, and it only acts while the TUI is open. A modifier
key gives no usable keydown for a Hyprland bind, so the setup installs it as two halves: press
on the physical keycode, release on `CTRL + Control_R` — the form Hyprland actually matches on
keyup — plus the push-to-talk helper behind it.

## MIDI

Detects connected devices with `aseqdump`, shows the chord in real time, and drives a
five-waveform synth (sine, triangle, sawtooth, square, organ) streamed to PipeWire. The enable
control is a compact switch on the MIDI MODE row, with SOUND/MUTED beside RESCAN.

## How it works

```
QuickShell QML (Service / Panel / BarWidget / GuitarFretboard)
              │  JSON over stdin/stdout
              ▼
Python backend (backend/jamjamjam_backend.py)
   ├─ pw-record (sink monitor)  → s16 mono → FFT key / BPM / chords
   ├─ pw-record (tuner input)   → tuner pitch (YIN, 16 kHz window)
   ├─ aseqdump  → MIDI note on/off → chord + synth note_on/off
   └─ pw-cat    ← rendered synth and metronome samples

Backend → snapshot JSON every ~250 ms      TUI → commands
   ~/.local/state/jamjamjam/state.json       commands.json
   ~/.config/jamjamjam/config.json           tui.pid (while the TUI is open)
```

The backend runs while the plugin service is loaded and answers commands on stdin
(`setVisible`, `setHold`, `setSource`, `setMetronome`, `setPaused`, `setConfig`,
`resetAnalysis`, `openTui`). The TUI is a pure viewer of `state.json` and writes its own
commands; the dispatcher only starts a standalone backend when the snapshot is stale, so the
neck works even with the panel closed. While `tui.pid` names a live process, the backend
treats the TUI as the session owner.

The system-audio capture uses the sink monitor via `parec` rather than `pw-record
--target <sink>.monitor`, which records silence on PipeWire 1.6 — monitors are ports, not
nodes. It samples before the output volume and mute, so detection survives a muted or
zero-volume output, and the default sink is re-resolved every 3 s so a device change is
followed instead of leaving a stale silent capture.

## Requirements

`python3` + `numpy`, `pipewire-utils` (`pw-cat`, `pw-record`), `alsa-utils` (`aseqdump`), and
`go` to build the TUI during setup.

## Install

```bash
scripts/plugins/jamjamjam/setup-jamjamjam-plugin.sh            # plugin + bar entry + TUI + float rule
scripts/plugins/jamjamjam/setup-jamjamjam-plugin.sh --remove
omarchy restart shell
```

Then open the neck from the **GUITAR** button, or run `jamjamjam-tui`.

Song identification is optional: the setup installs `shazamio` when it can, never fatally, and
the plugin works without it. On Python 3.14 the `pydub`→`audioop` chain is not usable yet, so
matching stays off and reports `song.available: false`.

## Cost

`backend/bench_cpu_analysis.py` runs 10 s of the real pipeline against a synthesized stream
and prints a README line; it completes in about 0.2 s. One analysis pass is scheduled **once
per second**, so the pass costs on the order of 1% of a core, with peak memory in the tens of
MiB during analysis. Re-run the bench on your own machine rather than trusting a number
measured elsewhere.

The tuner's single pass over 4 s of mic audio is about 127 ms, and only runs while the panel
or a hold is active. Each pass is ~10 ms per frame over a 128 ms window, which is what the numpy
implementation it replaced cost too — the reason for the swap was agreement, not speed: see below.

**Tuner cadence.** The pitch detector runs every **0.15 s while the panel is open** (or a hold
or the neck TUI is active) and every 0.5 s otherwise. At a fixed 0.5 s the note sat unchanged
for half a second between two hops of the needle, which reads as a lag rather than a tuner.
Measured cost of the fast cadence on the backend: **7.2 % of one core with the panel open, 2.8 %
with it closed**. 0.12 s was measured too and costs 8.3 % — not worth it.

**The reading outlives the detection.** A pitch detector drops out constantly: between plucks,
while the peg moves, on any frame straddling two strings. The panel keeps the last reading for
2.5 s, so the note does not vanish before it has been read; the needle holds its position across
the gap instead of snapping to the centre.

### Tuner pitch detection

The tuner runs **Pitchfork's detector, copied verbatim** (`PitchDetector` in the backend, from
`plugins/io.github.kemezz.pitchfork/scripts/pitch-detect.py`, MIT). A tuner is judged on what
it hears, and two implementations of YIN are two different tuners, so this is a copy rather than
a reimplementation.

It is two-stage: a coarse YIN on a decimated window, then a re-search at the full rate around
that estimate, refined by parabolic interpolation. The window is 2048 samples at 16 kHz, and
the range is 24 Hz–500 Hz — the 24 Hz floor is a 5-string bass's B0 (24.5 Hz), which the old
55 Hz floor could not see at all: the search window did not contain the period, so the tuner
simply reported nothing. The capture stays at 48 kHz for the recorder, the AEC reference and the
chord analysis, and the tuner takes every third sample of it, which *is* the 16 kHz signal.

Measured against Pitchfork's own detector on synthesised harmonics (24.50, 41.20, 82.41, 146.83
and 329.63 Hz), the two agree to within 0.01 Hz at every frequency, including on a window that
straddles two notes — both report the same subharmonic and both accept it, which is a property
of the algorithm rather than a defect of the port. Wideband noise is rejected (aperiodicity
above 0.20), as is anything below the 0.004 gate.

## Status

Feature-by-feature history, the bugs behind the current behaviour and what is queued live in
[`JOURNAL.md`](../../../JOURNAL.md). Bench numbers and a few behaviours noted here were
measured on the author's machine only.
