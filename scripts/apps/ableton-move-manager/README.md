# mosquito Move Manager — Omarchy module (ableton-move-manager)

> **Scope / disclaimer**: this module is designed for and tested **only on
> [Omarchy](https://omarchy.org)** (Arch Linux + Hyprland + the Omarchy shell).
> It assumes Omarchy's tools and paths and is **not tested on any other
> distribution, desktop or window manager** — adapt it before reusing it
> elsewhere.

Turns an **Ableton Move → Ableton Live → Bitwig Studio** session into a single
workflow.

## One interface, one core

Every menu, prompt, and piece of workflow logic lives in `lib-move-manager-core.sh`,
shared by the single interface and the non-interactive actions backend:

- **TUI** (`mosquito-move-manager-tui`) — a real terminal UI, a compiled Go/Bubble
  Tea program (see `tui-go/`). It is **the only interface**: there is no bash/gum
  "native" overlay and no interface switching anymore. Launched with no arguments it
  opens its own terminal window (foot, falling back to xterm) when started from
  somewhere that doesn't already provide one (the Omarchy Trigger menu), and runs
  directly in your terminal otherwise.
- `mosquito-move-manager-actions` — a thin non-interactive backend the TUI calls once
  every decision is made in Go (see that file's own header).

`mosquito-move-manager` — the name the Omarchy menu entry and everything else
launches — is a small, stable **dispatcher**: no arguments = the TUI (exec'd
straight, opening a terminal if needed); with one-shot flags (`status`, `--demo`,
`--address`, `--midi`, `--skip-manager`, `--no-bitwig`, `--pick-file`) it runs the
relevant core function directly, using the core's own real prompts (the Omarchy
overlay / zenity / plain-tty chain). Nothing heavier runs on every launch, and
nothing needs to change (the menu entry, a keybinding, `mosquito-move-manager` typed
by hand) across any of them.

## The working directory

Everything this module manages — downloaded sets, saved Ableton projects, converted Bitwig
projects, MIDI exports — lives under one folder, the **working directory**. By default
that's `~/Music/Ableton Move Projects/` (created on first launch if missing); its own
`README.md`, dropped inside it, lists exactly what each subfolder holds. Its location can be
changed any time from **Settings → Change working directory location**.

## Saving in Ableton — the manager waits, it never automates

After a set opens in Ableton, the manager does **only** this: it tells you
where to save it, waits for you to save **and quit** Ableton, then detects the
saved `.als` and opens it in Bitwig. There is **no automation at all** — no
`Ctrl+Q`, no `Return`, no `xdotool` key-sending, no "assisted save/close", no
auto-save, no timer and no OSC. You are always the one who saves and quits;
Ableton Live is never asked to close by any synthetic mechanism.

On launch it shows a wrapped desktop notification (and the same three lines in
the runner log), so the folder stays readable:

```
Save your project in:
<working dir>/als
Then QUIT Ableton to continue.
```

The path shown is the manager's configurable working directory (see
**Settings → Change working directory location**; default
`~/Music/Ableton Move Projects/als`). Save wherever you like — the manager
opens the detected `.als` exactly where it is, with **no copy and no backup**.

The close is detected from the real, **version-specific** Live executable:
`ableton_pids()` derives the image name from the install picked in Settings
(`LEARNED_ABLETON_EXE`, e.g. `Ableton Live 12 Suite.exe` — never hardcoded to
12), matches it **case-insensitively** across the chosen Wine prefix's process
tree (`/proc/<pid>/environ` carries `WINEPREFIX=<prefix>`, the same test the
`ableton-live` wrapper's own lifecycle library uses), and enumerates **every**
matching PID. It then watches every folder an `.als` can land in (kernel-level
`inotifywait` plus an mtime scan) and trusts the close only once those PIDs are
**gone** *and* zero Ableton windows (`xdotool`, without `--onlyvisible`) have
existed for several consecutive checks. The saved `.als` is then chosen from
the working `als` folder by **name first** — a file whose basename matches the
converted set (`<set name>.als`) wins even if it is older — then by the
**newest** `.als` created or modified since the session started; the same
name-then-newest rule is applied to Ableton's other save folders only when the
working folder has nothing. The chosen file is opened in
Bitwig **immediately** — no copy step, no "open in Bitwig?" confirmation. The only Bitwig-open decision left is **Settings → "Open the
converted .als directly with Bitwig using ydotool"**: when On, the `.als` is
handed straight to Bitwig's own **File > Open** dialog; when Off (or when the
ydotool path is unavailable) Bitwig is launched/focused normally and a
notification tells you to open the file yourself.

Every step prints a `…` progress line into the TUI's runner log, so the
`Working…` screen shows what is happening live instead of sitting silent.

**Session log.** Every conversion launch (an Ableton project, a `.adg`/`.bwpreset`
preset, a MIDI export) writes its own log — the runner's progress/message lines
plus the session's stdout/stderr — to a fresh
`~/.local/state/move-session/conversion-logs/conversion-<timestamp>.log`.
The path is printed as the first line of the runner (and logged). Only the
follow-up Bitwig-open step of the *same* conversion appends to that file (the
active log records both its path and its tag, so a preset or MIDI log is never
carried into a later project conversion); one conversion is one file. Old logs
are pruned and the active one is capped (rotated aside after 2 MiB), so they
can't grow without bound. If a conversion ever appears to hang, that file is
the place to look.

**Automatic `.als` detection.** The manager detects the saved `.als` on its own
— via a kernel-level `inotifywait close_write` watch on `als/` and the broad
Ableton save roots, plus an mtime poll — and advances as soon as a file created
or modified in this session appears, without waiting for the Ableton process to
exit. **Esc** cancels/aborts the conversion. While the conversion runs, Ableton
is floated (untiled) and raised in front of the manager window on Hyprland (see
**Ableton window handling** below).

### Ableton window handling

When a conversion launches Ableton, the manager asks Hyprland to make Live's
main window **floating (untiled)** and to raise it **in front of the
script/manager window** — the save-and-close wait is easier to follow with Live
visible. It finds the window by class (the same `ableton_win_class` used for
detection, e.g. `ableton live 12 suite.exe`, or the generic `ableton live`) via
`hyprctl clients -j`, then runs the Lua dispatchers
`hl.dsp.window.float`, `hl.dsp.focus` and `hl.dsp.window.bring_to_top` (falling
back to the classic `togglefloating`/`focuswindow`/`alterzorder` syntax on older
Hyprland builds). It runs once right after the launch and again once the Live
process appears, then periodically while waiting. With no `hyprctl` (or on a
non-Hyprland compositor) the whole thing is a silent no-op.

## Opening the converted .als in Bitwig automatically (ydotool)

Bitwig has no command-line support for opening a project file (see the
Bitwig step in **Workflow** below), so the manager can hand the converted
`.als` to Bitwig's own **File > Open** dialog for you. When the setting
**Settings → "Open the converted .als directly with Bitwig using ydotool"**
is **On** (the default), the end of a conversion launches/focuses Bitwig and
drives it with `ydotool`: it temporarily disables every real keyboard and
mouse through Hyprland (so only its own synthetic events reach Bitwig),
presses Ctrl+O, waits for the **"Select Project to Open"** dialog, presses
Ctrl+L, puts the path on the clipboard with `wl-copy`, pastes with Ctrl+V,
presses Enter, waits for the dialog to close, then restores the input
devices. Bitwig is only ever launched or focused — it is never asked to
close.

Requirements and caveats:

- **Hyprland only.** The input device toggling and window targeting use
  `hyprctl`; this does nothing on another session/compositor. When not in a
  Hyprland session the manager falls back to the normal launch (below).
- Needs `hyprctl`, `jq`, `ydotool` and `wl-copy` installed, plus
  **passwordless sudo** (the routine starts `ydotoold` itself; with no
  passwordless sudo it skips the direct open and falls back).
- A 15-second watchdog re-enables the keyboard/mouse on its own if anything
  hangs, so a stuck dialog can never leave you without input.
- While it runs, your physical keyboard and mouse are briefly disabled by
  design. Nothing else on screen is clicked for you.

When the setting is **Off**, or whenever the ydotool path is unavailable or
fails, the manager launches Bitwig the normal way (or switches to its
already-open window) and sends a secondary desktop notification telling you to
open the `.als` in Bitwig yourself. The setting is remembered in
`~/.config/move-session/prefs` like every other preference.

## Move as a Bitwig controller (Ableton → Move)

The dedicated submenu **Move as Bitwig controller** installs two halves:

- **Host controller scripts** — copied into a Bitwig *vendor subfolder* so
  Bitwig lists the controller as **Ableton → Move**:
  ```
  ~/Documents/Bitwig Studio/Controller Scripts/Ableton/Move/
  ```
  (Earlier versions copied the files flat at the root of `Controller Scripts/`,
  where Bitwig showed no vendor.) After install, **restart Bitwig** — or use
  **Settings → Controllers** and rescan — for the Ableton vendor and Move
  controller to appear. Then, in Bitwig: **Settings → Controllers → Add
  Controller → choose vendor Ableton, then controller Move**, and select the
  `midiin4` / `midiou4` (the Ableton Move) USB MIDI ports.
- **On-device Move module** — built and pushed to
  `/data/UserData/schwung/modules/overtake/move-bitwig` with the vendored
  `move-bitwig` scripts, in a visible terminal.

Both halves can be removed again from the same submenu. Removing the host
scripts only deletes the `Controller Scripts/Ableton/Move/` folder (and the
`Ableton/` vendor folder if it is left empty) — nothing else in the Controller
Scripts tree is ever touched. Removing the on-device module prefers the
vendored `move-bitwig/scripts/uninstall.sh` when present and otherwise runs
`ssh ableton@move.local 'rm -rf /data/UserData/schwung/modules/overtake/move-bitwig'`
in a visible terminal.

On-device detection (installed / not found) requires **ssh to the Move**
(`ableton@move.local`). When ssh is unreachable the status reads **unknown**
rather than "not installed", and the submenu still offers both install and
uninstall so a broken ssh can never make the module look absent.

## Workflow

Launching `mosquito-move-manager` (the Omarchy entry **Trigger > Music >
mosquito Move Manager**) shows a menu. Its title bar shows the
active address followed by a connection dot (🟢/🔴):

```
mosquito Move Manager — move.local 🟢

1. Set the Move address                  → remembered, then offers to open
                                            the Move Manager
2. Open the Move Manager and convert     → opens the webapp (dedicated
                                            Chromium profile, single instance —
                                            opening it again replaces any
                                            window already open; downloads
                                            land straight into
                                            <projects>/ablbundle, silently,
                                            even if the webapp is opened
                                            without this script). Downloaded
                                            sets are converted straight away,
                                            scoped to just this session's
                                            downloads; if nothing was
                                            downloaded, a notification offers
                                            to pick a file instead
3. Convert a Move set                    → pick the set first (always, never
                                            the route first) → route choice:
· MIDI   → move-bundle-to-midi → <projects>/bwproject/midi
      · .als (beta) → move-bundle-to-als, straight to a native Live `.als`
                without Ableton (no factory Move instrument is embedded —
                the pads you put on the grid land as plain MIDI notes; load
                a drum rack/kit of your own in the target). The `.als` is then
                opened in Bitwig immediately, exactly like the Bitwig route,
                and a subsequent Bitwig save still marks the set converted.
      · Bitwig → if Ableton (the version configured in Settings) is already
                open, offers to close it (you close it yourself) and waits
                until it actually has before continuing — the script can't
                safely start a new conversion while it's running. A
                *different*, unconfigured Ableton edition is left alone (two
                separate instances are expected to coexist). Bitwig being open
                is never a blocker and never asked to close — if it's already
                running by the time this route reaches its own step, the
                script just switches to its existing window instead of
                launching a second instance (see below) → a short notification
                fires the moment Ableton is launched, kept up 30 seconds,
                telling you exactly where to save and that you must quit
                Ableton afterwards ("Save your project in the working
                directory's `als` folder, then QUIT Ableton to continue.") →
                opens the original bundle directly in Ableton Live (no
                renaming, the Ableton version is set once in Settings) →
                then it only waits: no keys are sent, no timer, no OSC — save
                the project and QUIT Ableton yourself. While you work it
                watches (kernel-level `inotifywait` on every save folder, plus
                a broad mtime scan) for a `.als` created or modified after this
                session started, and waits for Ableton's real process AND all
                its Wine/DXGI/JUCE windows to be fully gone (only the actual
                Live executable counts — wrapper/helper watchers are ignored),
                then for the file to stop changing on disk → the detected
                `.als` is opened exactly where it is, with NO copy and NO
                backup → the file is opened in Bitwig
                immediately (no confirmation; the ydotool setting above is the
                only Bitwig-open choice) → a single notification
                (kept up 20 seconds, saying simply to open the saved
                project in the working directory to finish the
                conversion) → save there → detected, copied into
                <projects>/bwproject the same way, left open — and the
                script itself exits quietly rather than popping its own
                menu back up over Bitwig (even if Bitwig is closed again
                right away, before saving). If no .als is found at all, a
                notification says so, instead of silently doing nothing.
                Waits at most 5 minutes for the Bitwig save (not the full
                Ableton-session wait, and bails out immediately if Bitwig
                itself is closed before that) — this stage is just
                background bookkeeping, not something that should keep the
                script running for hours; Bitwig itself is never asked to
                close, here or anywhere else in this flow. If it's already
                open when this step is reached, its existing window is
                simply focused (`omarchy-hyprland-focus-app`, switching to
                whatever workspace/monitor it's on) instead of launching a
                second instance. Bitwig's own executable has no command-line
                support for opening a project file at all (confirmed: no
                `%f`/`%U` in its `.desktop` entry, no matching `MimeType`,
                and no such flag in the binary itself — unlike, say,
                REAPER, which supports both), so if it opens on an empty
                project instead of the set, open it by hand from the
                working directory's `als` folder (File > Open / Cmd-O). For
                the same reason, it can't be added to Nautilus's "Open
                With" list either — a `%f`-style entry would just create
                the exact same "opens empty" bug, now triggered from the
                file manager instead of from here. If the *target* set's
                own Ableton is already open when this route is about to
                launch it, asks to close that instance first, waits for you
                to close it, then launches fresh.
4. Refresh connection status             → re-checks the Move's connection
                                            right away, without leaving the
                                            menu (there's no way to bind
                                            this to a keyboard shortcut like
                                            Tab from here — the native
                                            overlay doesn't expose one)
5. Settings                              → hide sets converted to Bitwig
                                             on/off, open the converted .als
                                             directly in Bitwig with ydotool
                                             on/off (Hyprland; see above),
                                             pick the Ableton
                                            version to use, change the
                                            working directory's location
                                            (folder picker; moves the
                                            current one there, or offers
                                            to merge if a folder is
already there), clear the
                                             `als` working folder
                                             (confirmation, then empties
                                             it — never touches
                                             `ablbundle`/`bwproject`)
6. Close
```

Dismissing the main menu (Escape) asks to confirm quitting, same as
"Close" — it never exits silently. Dismissing any *submenu* (Settings, a set/version/route
picker) just returns to the main menu, no confirmation needed there. If the main menu sits
unanswered for **30 minutes**, it exits on its own, silently — no confirmation, since nobody
would be there to answer one either. Killing any other still-running copy first (never
Ableton or Bitwig) is enforced by the interactive flows — a fresh launch always wins, so
repeated launches can't pile up in the background indefinitely.

Once a set's conversion completes it's renamed with a `-converted-<type>`
marker (`midi` or `bwproject`) and shown with a green **✓** in the pickers
(e.g. "Set 12.ablbundle (converted to Bitwig) ✓" — same checkmark
convention as the Omarchy menu's own checked items). MIDI-converted sets
always stay visible; Settings' "Hide sets converted to Bitwig" only affects
the Bitwig-converted ones. A durable record of every conversion (timestamp,
type, before/after filename) is also appended to
`~/.local/state/move-session/converted.log`, independent of the filename
marker — shown in `mosquito-move-manager status`.

If no set is found in `<projects>/ablbundle` when converting, it offers to
point to one specific file instead — a one-off pick, never remembered for
next time. The ablbundle list is shown **newest first**. `--midi` skips the
route question and takes the MIDI route; `--pick-file` goes straight to the
manual picker.

When disconnected (checked over USB, near-instant, and a bounded ping —
never allowed to stall the menu — to the configured address), option 2 is
shown unavailable with a short reason and can't be opened.

## Connection status: checked once per redraw, no live push

There is no "notify me when the Move connects" feature, and no attempt to push a live
update into an already-displayed menu either — the interactive menu is rebuilt on every
screen change and has no channel for background updates to dict what's already on screen.
Trying to force it closed and redrawn from outside turned out not to be worth the
complexity either.

What actually happens: the connection dot and the "Open the Move Manager" option's
availability are checked **exactly once, right before the main menu is (re)drawn** — on
first launch, and again every time you come back to it from Settings, "Convert a Move
set", or after a cancelled quit. Nothing outside the main menu ever checks it — Settings,
the version picker, the route/set pickers don't touch the Move at all, so they never do
either. If you plug or unplug while the menu is sitting there untouched, it won't reflect
that until you interact with it — pick **"Refresh connection status"** (a normal menu
option; there's no way to bind this to the literal Tab key from here, since the native
overlay doesn't expose any keyboard hook beyond Enter/Escape) to force a fresh check
without leaving the menu.

The one exception: a udev rule (`99-ableton-move.rules`) fires `move-udev-refresh` only
on **disconnect**, and only warns if the Move Manager's own Chromium profile is currently
running (whether launched standalone or through this script) — since that's the one
situation where losing the connection actually blocks something you're doing right now.

## Folders (`~/Music/Ableton Move Projects/` — custom path choice at first launch, or when the folder goes missing)

| Folder | Content |
|---|---|
| `ablbundle` | `.abletonbundle` sets — the Move Manager webapp downloads **straight here** (dedicated Chromium profile) |
| `als` | Ableton Live projects saved while converting a set (auto-detected wherever they're saved, copied here if needed) — the `.als` (beta) route also writes here |
| `bwproject` | Bitwig projects from the conversion (same auto-detect/copy) |
| `bwproject/midi` | MIDI exports (`move-bundle-to-midi`) |

A `README.md` explaining this layout is dropped into the folder the first
time it's created.

### .als (beta) known limitations

The `.als` route writes a file that matches the structure Live 12 produces when
it imports a Move set, but it does **not** embed the Move's factory instrument
device chain — the path to the instrument preset lives under Live's own
`packs/abl-core-library/...` and is unavailable outside Ableton. When the file
is opened in Bitwig (or Live), the track plays as plain MIDI notes: load a drum
rack or instrument of your own. A Bitwig save after opening the `.als` still
marks the set converted, just like the normal Ableton→Bitwig route.

## Usage

```bash
mosquito-move-manager             # menu: set address / open Move Manager / convert
mosquito-move-manager status      # state (address, folders, files)
mosquito-move-manager --demo      # simulation without a Move
mosquito-move-manager --address 3 # address without asking
mosquito-move-manager --midi      # convert with the MIDI route (no route question)
mosquito-move-manager --skip-manager  # don't wait for the Move Manager to close
mosquito-move-manager --no-bitwig # stop after Ableton
```

`move-bundle-to-midi` / `move-bundle-to-als` can also be used standalone:

```bash
move-bundle-to-midi -o out /path/to/set.abletonbundle   # -> out/set.mid
move-bundle-to-als  -o out /path/to/set.abletonbundle   # -> out/set.als (beta)
```

## Installation / uninstallation

```bash
./setup-ableton-move-manager.sh        # interactive menu (install / uninstall / status)
./setup-ableton-move-manager.sh -y     # non-interactive install (deploys bins, folders, menu; udev + policy if root)
./setup-ableton-move-manager.sh --uninstall  # removes udev rule + chromium policy + menu entry (binaries stay)
./setup-ableton-move-manager.sh --status     # current state, no modification
sudo bash ./setup-ableton-move-manager.sh   # same + udev rule + chromium policy (root steps)
```

Deploys:
- `~/.local/bin/mosquito-move-manager` (menu workflow), `~/.local/bin/move-bundle-to-midi` (MIDI export),
  `~/.local/bin/move-bundle-to-als` (.als export, beta), `~/.local/bin/move-udev-refresh` (udev live-redraw helper), and `~/.local/bin/move-manager-webapp` (Move Manager
  in a dedicated Chromium profile whose downloads go straight into `<projects>/ablbundle`, silently, single
  instance)
- `<projects>/{ablbundle,als,bwproject,bwproject/midi}`
- ONE menu entry **Trigger > Music > mosquito Move Manager** (Music is a
  dedicated submenu with a Nerd-Font icon; legacy duplicates are purged, the old
  `move-session.desktop` launcher is removed). Written through `sudo`, the menu is
  restored to your user (0644, `chown`), otherwise the launcher silently hides it.
- `~/.local/share/icons/hicolor/256x256/apps/ableton-move-manager.png` — a custom Move
  Manager icon (`move-manager-icon.png`, shipped in this module's own folder), used as the
  webapp/launcher icon (no more fetching the Move's own unreliable device favicon)
- Tracker/localsearch is told to skip the projects folder (`gsettings`,
  `org.freedesktop.Tracker3.Miner.Files ignored-directories`) — its
  libmodplug-based MIDI metadata extractor has a real segfault bug on some
  generated MIDI files (confirmed via `coredumpctl`, a system-library issue,
  not a problem with the exported file itself)
- udev rule `/etc/udev/rules.d/99-ableton-move.rules` (as root)
- Chromium managed policy `/etc/chromium/policies/managed/ableton-move.json` (as root):
  exempts `move.local` downloads from the safe-browsing "This type of file can harm
  your computer. **Keep?**" dialog — that popup is unreliable to click under Hyprland.
  The Move Manager webapp is displayed as **"Move Manager"** in the
  launcher; the internal id stays `ableton-move-manager`.

## Native Omarchy prompts (flag-driven flows only)

The TUI owns every interactive decision; the only prompts left that render with the
native Omarchy widgets are the ones the dispatcher's one-shot flag actions
(`--midi`, `--pick-file`, …) hit, via the core's real `ui_*` primitives:

| Question | Widget |
|---|---|
| Move address | `omarchy-menu-input` (text field, themed square box) |
| Open/cancel, keep the version, convert now, open folder | `mosquito.confirm` overlay (square, Yes/No) |
| Main menu, Settings, route MIDI/Bitwig, pick a set / a .als version | `omarchy-menu-select` |
| Tracking / export / end | `omarchy-notification-send` — see the icon table below |

Falls back to zenity, then a plain terminal prompt (`read`) when a widget is
missing (same logic as `mega-caffeine`).

### Notification icons

A small, coherent vocabulary built on the same circle-dot motif as the
main-menu status indicator:

| Icon | Meaning | Used for |
|---|---|---|
| 🔴 | Move unreachable / action refused | "Not connected"; Move-not-detected. 🟢/🔴 also match the main menu's own connection dot — there's no standalone connect/disconnect notification. |
| ◎ | an app is open, waiting on you to finish something in it | "Download a set and close the Manager…" (persists the whole Manager session); "Save your project in …" (Ableton, auto-expires); "Save the project to finalize…" (Bitwig) |
| 🔳 | click this notification to do something | "No set downloaded — click to pick a file and convert" |
| ✅ | a conversion step completed | "Set exported as MIDI — …" |
| ⚪ | nothing to do, empty state | "No set found in …" |

All five glyphs are plain Unicode (circle-dot emoji/symbols), so they render in
any Nerd-font shell theme — none of them is a private-use-area (PUA) glyph
whose coverage depends on one specific font. Emoji come from the OS color-emoji
font (Noto Color Emoji) and the symbols (◎, ⚪) from the monospace font itself;
switching the Omarchy font (e.g. to another installed Nerd Font such as Meslo,
Iosevka or JetBrains Mono) keeps every notification icon visible — verified
against every installed `fc-match` font below.

Blocking/instruction notifications ("Not connected", "Move not detected", "No
new .als") are sent with the `--persist` flag: they stay on screen until
clicked or dismissed, and like all Omarchy notifications they arrive via the
default `omarchy-action` app name, which Do-Not-Disturb lets through — so they
show even in silent mode.

Font coverage (verified with `fc-list ':charset=…'` for every glyph above plus
the battery/flacon glyphs used elsewhere): each Nerd Font installed on this
machine (CaskaydiaMono, Meslo LGM, Iosevka, JetBrains Mono, BitstromWera)
contains the battery PUA glyphs `󰂁`/`󰂅` and the flacon ``; the color emoji
live in Noto Color Emoji (installed, fontconfig fallback).

## Orchestrator integration

The module is wired into `mosquitomarchy-setup.sh` as module `ableton-move-manager`
(one `sudo bash mosquitomarchy-setup.sh` run installs/uninstalls everything):
- `MODULES` : `"ableton-move-manager:mosquito Move Manager — Ableton Move → Ableton Live → Bitwig (menu: address / Move Manager / convert — Go TUI, MIDI export)"`
- `st_ableton_move_converter` : `~/.local/bin/{mosquito-move-manager,mosquito-move-manager-tui,lib-move-manager-core.sh,move-bundle-to-midi,move-udev-refresh,move-manager-webapp}` present → `ok`
- `run_ableton_move_converter` : `bash scripts/apps/ableton-move-manager/setup-ableton-move-manager.sh -y`
- `un_ableton_move_converter` : the module setup `--uninstall` (menu entry + udev rule
  + chromium policy + webapp icon) then removal of the 4 binaries; `--purge` also drops
  `~/.config/move-session` and `~/.local/state/move-session` (prefs/log/state kept by default).