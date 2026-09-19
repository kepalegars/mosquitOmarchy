# jamjamjam

Omarchy bar-widget plugin that analyzes audio in real time: detects the musical
key, the BPM and the chord being played right now. Includes a guitar-neck scale
visualizer, an input tuner, an optional Shazam song hook, and a full
guitar-neck TUI with a hold-to-detect analysis button.

## Features

* **Icon-only bar button** (♪) — a pulsing red dot appears while recording, and
  a pulsing ring frames the icon while an **analysis hold** is active (the
  TUI's key or the global RIGHT CTRL), so the hold is visible from the bar even
  when the neck TUI is not focused.
  Left-click opens the panel; right-click toggles recording.
* **Capture lifecycle** — the panel's real-time analysis runs while the *panel is
  open*, unless a TUI owns the session (then only the TUI's hold captures) or
  the analysis is paused; the tuner always listens to the microphone.
  Capture auto-stops (and analysis is reset) once nothing needs it.
* **System-audio analysis** — captures the PipeWire monitor of the default sink
  automatically, so it hears exactly what the system plays (not the mic).
* **INPUT PC/MIC** — the header button (a squared icon button: computer-screen =
  PC audio, microphone = mic) switches the *analysis* source between the speaker
  monitor (PC) and the default microphone. It does **not** affect the tuner.
* **Input tuner** — always listens to the **default microphone**, independent of
  the INPUT setting, so it works whatever you are analyzing. YIN pitch detection
  (vectorised FFT autocorrelation) with note + octave and a sharp/flat cent
  indicator in both the panel and the TUI. The **whole tuner is shown all the
  time**: with no note it reads a full **"no note"** (panel: a full-size dash)
  plus the needle gauge drawn empty, rather than a tiny dash, and the TUI header
  always draws the gauge `♭·····│·····♯` (with the needle only when a note is
  detected). When the default source is muted or unavailable both tuners clearly
  say **"mic muted"** instead of staying silent.
* **Reinforced detection** — the analyzer never invents a key/chord/BPM out of
  silence or broadband noise: chunks below the silence floor are skipped
  entirely (RMS gate), a chord must be **tonally peaked** (a few pitch classes,
  not a flat noisy chroma) and must clearly beat the runner-up template, and the
  key needs a tonal peak too. A single note or a noisy spectrum reports **no
  chord** instead of a wrong guess.
* **Pause** — the play/pause icon button next to the reset icon (Material
  Design glyphs shared with the rest of the shell) freezes the analysis (and
  stops capture) without losing the current results. `p` in the panel.
* **Reset** — the reset icon really empties the display: key, BPM, current
  chord, its notes, the progression and the guitar neck all clear at once. It
  also drops the analyzer's audio window so the cleared state is actually
  visible instead of the next analysis pass re-detecting the still-playing
  audio within a fraction of a second.
* **Plugin keys** — `g` opens the TUI, `r` resets the analysis, `space`
  resumes/restarts the (auto-stopped) analysis, `p` pauses, `m` toggles MIDI,
  `n` toggles flats/sharps, `s` opens settings.
* **Metronome from the BPM card** — click the **BPM card** to toggle the
  metronome at the detected BPM (120 while no BPM is known). While it runs, the
  card flashes **white once per beat** at that tempo, and the TUI's `m` key
  drives the same metronome.
* **Robust capture** — PC audio is captured from the **sink monitor via
  `parec`**, which samples the mix **before the output volume and mute**, so
  detection keeps working even when the speakers are muted or at 0. The backend
  re-resolves the default sink every 3 s and follows output-device changes
  (internal / HDMI / Bluetooth / jack) so it never keeps listening to a stale,
  now-silent device. (`pw-record --target <sink>.monitor` was measured to record
  *silence* on PipeWire 1.6 — monitors are ports, not nodes — which was the old
  detection bug.) The analysis window bug is fixed too: `take()` used to return
  the *oldest* 2 s and advance one hop, so the analyzer re-heard ~2 s-stale
  audio; it now analyses the most recent window.
* **Key detection** (Krumhansl-Schmuckler profile on harmonic chroma), shown
  with a confidence percentage; the key is adopted only after holding for two
  analyses, and `keyStable` gates the fretboard.
* **BPM detection** (onset-envelope autocorrelation over the *same* 2 s window
  as the key, so tempo locks in within a couple of seconds) and an estimated
  **time signature** (4/4 vs 3/4) shown in the BPM card and the TUI header.
* **Chord detection with quality** — an extended dictionary (maj, m, 7, maj7,
  m7, m7♭5, dim, dim7, 6, m6, sus2, sus4, add9) matched against a harmonic,
  pitch-class chroma with a separate **bass chroma** for **slash chords /
  inversions** (e.g. `Fmaj7/A`). Prefers the smallest chord that explains the
  notes, so a triad is not read as a maj7. The panel's chord card shows **only
  the chord name** (centred, elided); the line below shows the notes.
* **Silence detection** — when the capture hears no music (RMS silent for a few
  seconds) the backend flags `noSignal` and the panel/TUI say
  *"could not find the chord"* instead of a stale chord.
* **Independent TUI and plugin** — the backend keeps capturing while the panel
  is open **or the neck TUI is open**, so the TUI gets the same live key / BPM /
  chord detection as the panel (previously it only heard audio during a hold).
* **Pin the panel** — clicking the red **♪** icon in the header (hover shows the
  hint) **pins** the panel: it stays open and its popup input region shrinks to
  the card, so clicks fall through and you can keep using other apps while the
  detection keeps running. Click ♪ again (or close the panel) to unpin.
* **Analysis lock** — once the key is confidently in mind the analysis
  **stops on its own** (capture pauses). Press **space** in the panel (or use a
  global RIGHT CTRL hold) to resume/restart it at any time.
* **Song-change detection** — a sustained key + chroma shift means the source
  moved to another song; the panel and TUI then show
  *"new song detected — press r to reset"*.
* **TUI-owned analysis** — the analysis hold is the global **RIGHT CTRL**
  (press-and-hold; release to freeze). Only the detection progress is shown
  while holding — results appear on release.
* **Live chord estimate (progression set aside)** — chord-progression detection
  and loop detection were not reliable enough, so they are **disabled for now**
  (`PROGRESSION_ENABLED = False`; the `ChordSeq` code is kept intact to
  re-enable later). In their place the UIs show a **real-time estimate of the
  chord being played right now** — the chord name plus its notes, refreshed each
  analysis pass (the panel's CHORD card, and the TUI line below the neck).
* **Guitar neck TUI** — the **Open TUI** toolbar button (flush with the right
  edge, aligned with the chord card; MIDI sits on the left) opens a
  **floating-centered prompt**
  (`jamjamjam-tui`, single instance — a second launch refocuses the running
  window). It opens on the same `mosquito jamjamjam` splash as the other
  mosquito TUIs for 1.5 s. Layout: the key/BPM header is **pinned at the very
  top** with the tuner (note + cents + needle gauge — no input-source label);
  the `jamjamjam` wordmark floats **below the header, vertically centred in the
  page and horizontally centred**, framed by a red rounded box while an
  analysis is being held; the scale/chord line, the large fretboard (**high
  strings on top, low at the bottom**, white string lines, grey fret lines) and
  the live chord line are all **horizontally centred**. The fret numbers
  are printed **only below the neck** and the vertical fret lines **stop at the
  strings** (they never run into the numbers). Shortcuts:
  `hold Right Ctrl · m metronome · r reset · s settings · ? help · q quit`.
  `s` opens the settings (note naming); `?` opens the help
  (which explains R = root, the digits, and the orientation).
* **Global analyze shortcut** — the **RIGHT CTRL** key (hold) runs the analysis
  even when the neck TUI is **not focused**, and only while the TUI is open.
  Right Ctrl stops acting as Ctrl and becomes the dedicated analyze hold. The setup
  script installs it into `~/.config/hypr/bindings.lua` as two halves (a
  modifier keysym gives no usable keydown for a bind): press on the physical
  keycode `code:105` (`evdev KEY_RIGHTCTRL 97 + 8`) and release on
  `CTRL + Control_R` — the form Hyprland actually matches on keyup — plus the
  push-to-talk helper behind it.
* **Theme-aware** — the panel, fretboard and tuner read the active Omarchy
  theme (accent, foreground, background, muted, urgent) at runtime, so colors
  keep following the current theme without hard-coded values. The **GUITAR**
  toolbar button is filled with the theme **accent**, and its label switches
  black/white to whichever contrasts most with that fill (BT.601 luminance).
* **MIDI mode** — detects connected MIDI devices (aseqdump), displays the chord
  currently played in real time, and drives a simple 5-waveform synthesizer
  (sine, triangle, sawtooth, square, organ) streamed to PipeWire. The enable
  control is a **compact switch** on the MIDI MODE header row (a full labelled
  toggle row used to overflow the header), SOUND/MUTED sits on its own row next
  to RESCAN, and the detected chord is a single compact line instead of a box.
* **Optional song identification** — the setup script installs `shazamio` when
  it can (`pip install --user shazamio`, retrying with
  `--break-system-packages` on Arch's PEP 668; never fatal). When importable,
  the last seconds of the monitor capture are matched and the title/artist
  shown. Note: on Python 3.14 the pydub→audioop chain isn't usable yet, so
  matching stays cleanly off there (`song.available:false`).

## How it works

```
  QuickShell QML (Service.qml / Panel.qml / BarWidget.qml)
                 │  JSON over stdin/stdout
                 ▼
  Python backend (backend/jamjamjam_backend.py)
     ├─ pw-record (default-sink monitor) → s16 mono → FFT key/BPM/chords
     ├─ pw-record (default source)       → tuner pitch
     ├─ aseqdump   → MIDI note on/off → chord id + synth note_on/off
     └─ pw-cat     ← rendered synth samples (S16 → PipeWire), incl. metronome

  Backend → snapshot JSON every ~250 ms
            ~/.local/state/jamjamjam/state.json   (atomic, for the TUI)
            ~/.local/state/jamjamjam/commands.json (TUI → backend commands)
            ~/.local/state/jamjamjam/tui.pid       (set while the TUI is open)
            ~/.config/jamjamjam/config.json         (note naming)
```

The backend runs while the plugin service is loaded, emits a snapshot JSON line
every ~250 ms, and answers commands on stdin (`setVisible`, `setHold`,
`setSource pc|mic`, `setMetronome`, `setPaused`, `setConfig`, `resetAnalysis`,
`openTui`, …). The TUI is a pure viewer of `state.json` and writes its own
commands (hold/reset/metronome/config) to `commands.json`, which the running
backend polls — the `jamjamjam-tui` dispatcher only starts the backend
standalone when the snapshot is stale, so the neck works even with the panel
closed. While `tui.pid` points at a live process the backend treats the TUI as
the session owner.

The **hold command** is the global RIGHT CTRL and gates the analysis stream:
while a hold (or the open panel) is active the backend reports the real-time key,
BPM and current chord. Chord-progression accumulation is currently disabled
(`PROGRESSION_ENABLED = False`) so the UIs show only that live chord estimate.

## Requirements

* python3 + numpy
* pipewire-utils (`pw-cat`, `pw-record`)
* alsa-utils (`aseqdump`)
* go (only to build the neck TUI during setup)

## Install

```bash
./setup-jamjamjam-plugin.sh            # copy plugin + bar entry + build/install TUI + floating prompt rule
./setup-jamjamjam-plugin.sh --remove   # uninstall
```

The setup script also adds the optional Shazam hook when possible
(`pip install --user shazamio`); the plugin works fine without it.

Then restart the shell:

```bash
omarchy restart shell
```

Open the neck TUI from the panel (GUITAR button), or: `jamjamjam-tui`.