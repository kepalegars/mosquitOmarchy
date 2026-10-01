# mosquito Move Manager

Turns an **Ableton Move → Ableton Live → Bitwig Studio** session into one workflow: pull a set
off the Move, convert it, and get a project open in Bitwig.

> **Omarchy only.** Built for and tested on Omarchy (Arch + Hyprland). It uses `hyprctl`, the
> Omarchy menu and its prompt widgets, so it is not portable as-is.

## The binaries

| Binary | Role |
|---|---|
| `mosquito-move-manager` | the name everything launches. No arguments opens the TUI; a one-shot flag runs a single step |
| `mosquito-move-manager-tui` | the compiled Go/Bubble Tea interface — the only interface |
| `mosquito-move-manager-actions` | the non-interactive backend the TUI calls once a decision is made |
| `move-bundle-to-midi` / `move-bundle-to-als` | the converters, also usable standalone |
| `move-manager-webapp` | the Move Manager in a dedicated Chromium profile, downloading straight into `ablbundle` |
| `move-udev-refresh` | the udev helper |

All the workflow logic lives in `lib-move-manager-core.sh` and is shared, so the TUI and the
one-shot flags cannot disagree about what a conversion does.

Run the TUI from a terminal and it execs in place; launched from a menu it opens its own
window (foot, else xterm).

## Working directory

Everything the module manages lives under one folder, `~/Music/Ableton Move Projects/` by
default, created on first launch. **Settings → Change working directory location** moves it
elsewhere, and offers to merge if a folder is already there.

| Folder | Content |
|---|---|
| `ablbundle` | `.abletonbundle` sets — the webapp's downloads land here, silently, even when it is opened outside this script |
| `als` | Live projects saved while converting. The `.als` (beta) route also writes here |
| `bwproject` | Bitwig projects from a conversion |
| `bwproject/midi` | MIDI exports |

A `README.md` describing this layout is written into the folder when it is first created.

## The workflow

`mosquito-move-manager` shows a menu, titled with the active address and a connection dot
(🟢/🔴). In the TUI:

1. **Set the Move address** — remembered, then offered to open the Move Manager.
2. **Open the Move Manager and convert** — opens the webapp. Downloaded sets are converted
   straight away, scoped to that session's downloads. If nothing was downloaded, it offers to
   pick a file instead.
3. **Convert a Move set** — you pick the **set first**, always, then the route:

   | Route | Result |
   |---|---|
   | **MIDI** | `move-bundle-to-midi` → `bwproject/midi` |
   | **.als (beta)** | `move-bundle-to-als` → a native `.als` without opening Ableton at all, then opened in Bitwig |
   | **Bitwig** | opens the bundle in Live, waits for you to save and quit, then opens the result in Bitwig |

4. **Refresh connection status** — re-checks the Move without leaving the menu.
5. **Settings** — see below.
6. **Close**.

The `ablbundle` list is newest first. A completed conversion renames the set with a
`-converted-<type>` marker and shows a green ✓ in the pickers, the same convention the Omarchy
menu uses for its own checked items. MIDI-converted sets always stay visible; "Hide sets
converted to Bitwig" only affects the Bitwig ones.

`--midi` skips the route question, `--pick-file` goes straight to the manual picker.

## Saving in Ableton — the manager waits, it never automates

This is the module's core promise, so it is worth being exact: **there is no automation
whatsoever.** No `Ctrl+Q`, no `Return`, no `xdotool`, no auto-save, no timer, no OSC. You are
always the one who saves and quits; Live is never asked to close by any synthetic mechanism.

What the manager does after opening a set in Live:

- tells you where to save, as a notification and in the runner log. Save wherever you like —
  the detected file is opened **exactly where it is, with no copy and no backup**;
- watches every folder an `.als` can land in (kernel `inotifywait` plus an mtime scan) and
  advances as soon as a file created or modified this session appears, without waiting for Live
  to exit;
- detects the close from the real, version-specific Live executable — never hardcoded to a
  version — matched case-insensitively across the chosen prefix's process tree, and requires
  both that those PIDs are gone and that no Live window has existed for several consecutive
  checks, so a wrapper or helper process is never mistaken for Live;
- picks the saved file **by name first** (a basename matching the converted set wins even if it
  is older), then by newest. The same rule is applied to Live's other save folders only when the
  working folder has nothing.

Every step prints a progress line into the runner log, so the `Working…` screen shows what is
happening instead of sitting silent. **Esc** cancels.

If the configured Ableton is already open when the Bitwig route starts, it offers to close it
and waits until it has — you close it — because a new conversion cannot safely start while one
runs. A *different*, unconfigured Ableton edition is left alone: two instances are expected to
coexist. **Bitwig being open is never a blocker**; its existing window is simply focused rather
than a second instance launched.

When the Bitwig route reaches its own step, the `.als` is opened in Bitwig immediately, with no
copy, no confirmation and no "are you sure". A single notification then asks you to save the
project to finalise the conversion; the script waits at most 5 minutes for that, and exits
quietly rather than reopening its menu over Bitwig. If Bitwig is closed before you save, it
gives up immediately. The final save is detected and copied into `bwproject` the same way. If
no `.als` is ever found, a notification says so instead of silently doing nothing.

### The `.als` (beta) route

It writes a file matching what Live 12 produces when it imports a Move set, but it does **not**
embed the Move's factory instrument — that preset path lives inside Ableton's own
`packs/abl-core-library`. Opened anywhere, the track plays as plain MIDI notes; load a drum rack
or instrument of your own. A Bitwig save after opening it still marks the set converted.

## Opening the converted `.als` in Bitwig

Bitwig has no command-line way to open a project — no `%f`/`%U` in its desktop entry, no
matching `MimeType`, no such flag in the binary — unlike REAPER, which has both. So with
**Settings → Open the converted `.als` directly with Bitwig using ydotool** **On** (the default),
the end of a conversion drives Bitwig's own File ▸ Open dialog: the real keyboard and mouse are
disabled through Hyprland so only synthetic events reach Bitwig, then Ctrl+O, wait for *Select
Project to Open*, Ctrl+L, paste the path with `wl-copy`, Enter, wait for the dialog to close, and
the devices are restored.

**Bitwig is only ever launched or focused — never asked to close.**

Requirements and caveats, all of them load-bearing:

- **Hyprland only.** The device toggling and window targeting use `hyprctl`; off Hyprland it
  falls back to the normal launch.
- Needs `hyprctl`, `jq`, `ydotool`, `wl-copy` and **passwordless sudo** (it starts `ydotoold`
  itself). Without any of these it skips the direct open and falls back.
- A 15-second watchdog re-enables the keyboard and mouse by itself, so a stuck dialog can never
  leave you without input.
- Your physical input is briefly disabled **by design**. Nothing else on screen is clicked.

When the setting is Off, or the path is unavailable or fails, Bitwig is launched normally and a
notification tells you to open the file yourself. The setting lives in
`~/.config/move-session/prefs` like every other preference.

## Move as a Bitwig controller

A dedicated submenu installs two halves: the **host controller scripts**, copied into
`~/Documents/Bitwig Studio/Controller Scripts/Ableton/Move/` so Bitwig lists the vendor as
**Ableton** and the controller as **Move** (restart Bitwig, or Settings ▸ Controllers ▸ rescan,
then Add Controller and pick the `midiin4`/`midiou4` USB ports); and the **on-device Move
module**, built and pushed to the Move over ssh.

Both can be removed from the same submenu. Removing the host scripts only deletes that folder
(and the `Ableton/` vendor folder if it ends up empty) — nothing else in the Controller Scripts
tree is touched.

On-device detection needs ssh to `move.local`. When ssh is unreachable the status reads
**unknown**, not "not installed", and both install and uninstall stay offered, so a broken ssh
can never make the module look absent.

The controller itself is documented separately — see
[`move-bitwig/README.md`](move-bitwig/README.md) for using it, `SPEC.md` for how it works and
`TODO.md` for what is still open.

## Settings

| Setting | Effect |
|---|---|
| Ableton version | which Live executable counts as "the app" for detection |
| Working directory location | move or merge the projects folder |
| Open the converted `.als` in Bitwig with ydotool | the direct-open path above |
| Hide sets converted to Bitwig | filter the pickers |
| Clear the `als` working folder | empties it after a confirmation; never touches `ablbundle`/`bwproject` |

## Logs and records

- **Session log.** Each conversion launch — a project, a preset, a MIDI export — writes its own
  `~/.local/state/move-session/conversion-logs/conversion-<timestamp>.log` holding the runner's
  progress lines and the session's stdout/stderr. The path is printed as the runner's first line.
  Only the follow-up Bitwig step of the *same* conversion appends to it, so a preset log is
  never carried into a later project. Old logs are pruned and the active one is rotated aside
  past 2 MiB. If a conversion ever appears to hang, this is the file to read.
- **Conversion record.** Every conversion is appended to `~/.local/state/move-session/converted.log`
  with its timestamp, type and before/after filename, independently of the filename marker.
  `mosquito-move-manager status` reads it.

## Connection status

The connection dot and the availability of "Open the Move Manager" are checked **once, right
before the main menu is drawn** — at launch, and again on returning to it. Nothing else checks
it, so plugging the Move in while the menu sits untouched will not be reflected until you
interact; use **Refresh connection status**. Checking is a USB check plus a bounded ping, so it
can never stall the menu.

A udev rule (`99-ableton-move.rules`) fires `move-udev-refresh` on **disconnect** only, and only
warns when the Move Manager's Chromium profile is running — the one case where losing the
connection actually blocks what you are doing.

## Install

```bash
scripts/apps/ableton-move-manager/setup-ableton-move-manager.sh             # interactive
scripts/apps/ableton-move-manager/setup-ableton-move-manager.sh -y          # unattended
scripts/apps/ableton-move-manager/setup-ableton-move-manager.sh --uninstall
scripts/apps/ableton-move-manager/setup-ableton-move-manager.sh --status
sudo bash scripts/apps/ableton-move-manager/setup-ableton-move-manager.sh  # adds the root steps
```

Uninstall removes the udev rule, the Chromium policy and the menu entry; the binaries stay
unless you remove them. `--purge` also drops `~/.config/move-session` and
`~/.local/state/move-session` — prefs, log and state are kept by default.

Deploys the binaries, the four project folders, **one** menu entry under
**Trigger ▸ Music ▸ mosquito Move Manager**, a custom Move Manager icon (rather than the
device's unreliable favicon), a Tracker exclusion for the projects folder, and — as root — the
udev rule and a Chromium policy exempting `move.local` downloads from the safe-browsing
"Keep?" dialog, which is unreliable to click under Hyprland.

## In the orchestrator

Registered as module `ableton-move-manager` in `mosquitomarchy-setup.sh`, so
`mosquitomarchy-setup.sh` installs and removes it like any other module. It reports `ok` when
its binaries are present, and `--purge` also drops the config and state directories.
