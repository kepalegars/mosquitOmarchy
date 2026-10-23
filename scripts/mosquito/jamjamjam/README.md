# jamjamjam

An Omarchy bar widget that listens to what you are playing and reports the **key**, the
**BPM** and the **chord**, with a guitar-neck view, an input tuner and a metronome.

> **Alpha.** Developed on one machine only. Expect missing or rough edges.

## Privacy

Two guarantees, and they are the reason the capture is gated rather than always-on:

- **The microphone is never used while the plugin is closed.** The tuner's mic capture is
  hard-gated in the backend: it runs only while the panel is open or an analysis hold is
  active. Nothing is captured in the background.
- **No audio is ever written to disk.** What is captured lives in small in-memory ring
  buffers. What survives a session is analysis metadata only — key, BPM, chord, tuner
  results and config — under `~/.local/state/jamjamjam/` and
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
in the backend; the code is kept to re-enable). The panel shows a live estimate of the chord
currently playing instead. This is deliberately not presented as a feature — the detection was
not reliable enough.

## The panel

A ♪ icon in the bar: a pulsing red dot while recording and a blinking fork while capture is
live. Left-click opens the panel, right-click toggles recording. Clicking the icon pins the
panel — it stays open with its input region shrunk to the cards, so clicks fall through and you
can keep working.

`r` resets (and starts analysis when auto-analysis is off) · `p` pins/unpins · `m` toggles the
metronome · `+`/`-` changes the tempo by 5 BPM (AZERTY: `=` also works as `+`) · `,` pauses
without losing results · `n` toggles flats/sharps · `s` opens settings.
Clicking the **BPM card** toggles the metronome at the detected tempo (or 120 BPM before
any analysis, and that value is displayed), and the card flashes white per beat. Live
detection then moves the tempo. Right-click it to enter a tempo, a meter, or both: `120`, `6/8`, `120 4/4`,
`140bpm 4/4` and `7/8 134 BPm` all work.

The metronome uses the dlpwaters.metronome click (1320 Hz downbeat, 880 Hz other beats) by
default. Settings can import a down/up `.wav` and switch to it with **Use imported**; **Use
default** switches back to the built-in click.

The KEY, BPM and CHORD cards can each be hidden independently in settings, and the remaining
cards share the full width. The **NOTE CARD** toggle (under the tuner) is off by default and
shows the chord box only when enabled. **Auto analyze** (on by default) starts analysis when the panel
opens. Turn it off to keep the tuner available while the analyzer waits: press `r` to start
it manually.

Analysis also stops on its own once the key is confidently found; `r` restarts it. Pressing `r`
clears the chosen key/BPM and the detected progression.

The former guitar-neck TUI is **abandoned**. Its Go sources and dispatcher remain in
`tui-go/` and `jamjamjam-tui` for reference, but setup no longer builds or installs them, and
the old RIGHT CTRL helper, Hyprland window rule and binding are removed.

## How it works

```
QuickShell QML (Service / Panel / BarWidget / GuitarFretboard)
              │  JSON over stdin/stdout
              ▼
Python backend (backend/jamjamjam_backend.py)
   ├─ pw-record (sink monitor)  → s16 mono → FFT key / BPM / chords
   ├─ pw-record (tuner input)   → tuner pitch (YIN, 16 kHz window)
   └─ pw-play   ← rendered metronome samples (256-frame stream, 20 ms latency)

Backend → snapshot JSON every ~250 ms
   ~/.local/state/jamjamjam/state.json
   ~/.config/jamjamjam/config.json
```

The backend runs while the plugin service is loaded and answers commands on stdin
(`setVisible`, `setHold`, `setSource`, `setMetronome`, `setPaused`, `setConfig`,
`resetAnalysis`, `startAnalysis`, `toggleAnalysis`). The QML service is the only client; the
former TUI is no longer part of the session model.

The system-audio capture uses the sink monitor via `parec` rather than `pw-record
--target <sink>.monitor`, which records silence on PipeWire 1.6 — monitors are ports, not
nodes. It samples before the output volume and mute, so detection survives a muted or
zero-volume output, and the default sink is re-resolved every 3 s so a device change is
followed instead of leaving a stale silent capture.

## Requirements

`python3` + `numpy`, and `pipewire-utils` (`pw-play`, `pw-record`).

## Install

```bash
scripts/mosquito/jamjamjam/setup-jamjamjam-plugin.sh            # plugin + bar entry
scripts/mosquito/jamjamjam/setup-jamjamjam-plugin.sh --remove
omarchy restart shell
```

Opening setup also retires any old TUI binary, RIGHT CTRL helper and Hyprland rule from a
previous install.

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
is active) and every 0.5 s otherwise. At a fixed 0.5 s the note sat unchanged
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
