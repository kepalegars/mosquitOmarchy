# mosquitOmarchy

Idempotent setup scripts for [Omarchy](https://omarchy.org) (Arch + Hyprland), oriented
toward audio production: REAPER, Bitwig, Ableton Live on Linux, shared Windows VSTs, and
the local tooling around them.

Re-running any script on a configured machine is safe.

> **Scope.** Every module is built exclusively for Omarchy and is only tested on the
> author's own machine. The scripts assume Omarchy's `omarchy-*` commands and its
> config layout (`~/.config/hypr/hyprland.lua`, `foot`, `omarchy-notification-send`).
> Porting them to another distribution or desktop means adapting them first.

> **Picking this project back up?** Read [`TODO.md`](TODO.md) for open work,
> [`TESTING.md`](TESTING.md) for the remaining checks, and [`JOURNAL.md`](JOURNAL.md)
> for the history and why things are the way they are.

> **Written with AI.** This repository was coded with [OpenCode](https://opencode.ai)
> driving **BigPickle DeepSeek 4.1 Flash** and **Space Bunny Free**. Everything was
> then read, run and corrected on the author's machine — the AI wrote the code, it
> did not decide what the code should be.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/kepalegars/mosquitOmarchy/master/bootstrap.sh | bash -s -- -y
```

That clones the repo, reports which large installers this machine is still missing,
installs the missing modules, builds the TUI, and registers a menu entry. From an
existing clone, `./bootstrap.sh -y` does the same without the pipe.

Every bootstrap run rebuilds the Go TUI from the current sources, even when a
binary is already deployed — there is no "already built" shortcut, so the
running manager can never go stale behind the repo.

Large application installers (Ableton, Bitwig, DaVinci, Guitar Pro) are **not** in the
repo — see [Large installers](#large-installers).

| Flag | Effect |
|---|---|
| `-y` | no questions, apply defaults |
| `--zips` | accepted and ignored — nothing has been downloaded for a while |
| `--status` | report what is installed, change nothing |
| `--init-git` | attach `origin` to an extracted release copy, so self-update works |
| `--repo=URL` `--dir=PATH` | use a fork / a different clone location |

## The TUI

Once installed, `mosquitOmarchy` is the interface for everything here — run it, or open
**Omarchy menu → Install → mosquitOmarchy**. The menus are:

- **Status** — every module and its state.
- **Update** — pull the scripts repo, then re-apply the changed installed modules.
- **Setup** — the module tree. `tab` selects, `←/→` expand a folder, `i` explains the
  highlighted entry, `enter` installs the selection.
- **Backup / Restore** — a dated archive in `mosquitomarchy-backups/` (next to the repo), optionally
  AES-256 encrypted. The filename carries the mosquitOmarchy version and channel
  (`-v1.0.0-stable`, `-rc`, …) so an archive says exactly what made it.
  **Keybindings** are backed up as `custom only` by default: only the
  `mosquitOmarchy_Keybindings` block is archived, never the rest of
  `~/.config/hypr/bindings.lua`. Choosing `all` archives the whole file; `no`
  archives none. On restore, `all` is offered again when the archive has it
  (default), and `custom only` merges just the managed block back.
  **Hyprland configs** are a separate yes/no choice: the whole `~/.config/hypr`
  tree is archived (bindings excluded) and restored last. Third-party Omarchy
  shell plugins installed by the user appear under the *Plugins* folder.
- **Fixes** — the small idempotent repairs in `code/modules/Fixes/`, as a multi-select.
- **Tweaks** — optional preference changes in `code/modules/Tweaks/` (same multi-select; never
  auto-applied by `-y`).
- **Close** — leave.

`mosquitomarchy-setup.sh` is the engine underneath: every TUI action shells out to it, so
there is rarely a reason to call it by hand.

A failed run writes one dated crash log per session to the repo-local `.local/` and, when the
crash-toast switch is on (off by default; Extras toggles it), sends a clickable notification
that opens the default AI on the `mosquitomarchy-crash` skill, pointed at that log, to
**propose** a fix. See [`code/lib/crash.bash`](code/lib/crash.bash).

## Modules

Details, options and caveats live in each module's own `README.md`. This table is the map.

### Apps

| Module | Installs | Doc |
|---|---|---|
| `reaper` | REAPER + its Hyprland/Wayland integration | [README](code/modules/Apps/reaper/README.md) |
| `bitwig` | Bitwig Studio from the local `.deb`, with its own module and optional patched `bitwig.jar` | [README](code/modules/Apps/bitwig/README.md) |
| `ableton` | Ableton Live 12 native on Linux, sharing the same VST root | [README](code/modules/Apps/ableton/README.md) |
| `guitarpro` | Guitar Pro 8 in its own Wine prefix | [README](code/modules/Apps/guitarpro/README.md) |
| `davinci-resolve` | DaVinci Resolve (free or Studio) + silent DRwrap integration | [README](code/modules/Apps/davinci/README.md) |
| `extracto` | Extracto | [README](code/modules/Apps/extracto/README.md) |
| `douze` | SSL 12 control (douze daemon, udev, PipeWire split) + Omarchy360 mixer | [README](code/modules/Apps/douze/README.md) · [study](code/modules/Apps/douze/STUDY.md) |
| `tidal` | TIDAL Hi-Fi (TidaLuna): package, hidden menu bar, `SUPER+SHIFT+M` binding | [setup](code/modules/Apps/tidal/setup-tidal.sh) |
| `handbrake` | HandBrake GUI + CLI, preset sync, Hyprland rules | [README](code/modules/Apps/handbrake/README.md) |
| `signal` | Signal Desktop, tray behavior, menu entry, and login autostart | [setup](code/modules/Apps/signal/setup-signal.sh) |
| `betterbird` | Betterbird (Thunderbird fork): install, system-tray close/minimise, login autostart, tiled main window + popups at the pointer | [setup](code/modules/Apps/betterbird/setup-betterbird.sh) |
| `whatsapp-native` | WhatsApp Web as a Chromium web app: tray supervisor (login starts hidden in the tray, menu opens directly), silent notifications, close-to-tray, no menu bar, no shortcut, login autostart | [README](code/modules/Apps/whatsapp-native/README.md) |
| `superfile` | SuperFile terminal file manager; the system default file manager is left unchanged | [README](code/modules/Apps/superfile/README.md) |
| `zen` | Zen Browser, seeded extensions and theme | [README](code/modules/Apps/zen/README.md) |
| `keepassxc` | KeePassXC password manager + browser integration (Leaves Omarchy's keyring intact) | [README](code/modules/Apps/keepassxc/README.md) |
| `apps` | The TUIs of `code/modules/TUIs/`, reinstallable from a backup selection | [README](code/modules/Apps/README.md) · [TUIs](code/modules/TUIs/README.md) |

The tables below follow the TUI's Setup folders: each heading is one of them.

### mosquito

| Module | Installs | Doc |
|---|---|---|
| `ableton-move-manager` | Ableton Move → Live → Bitwig conversion (MIDI export, native Omarchy prompts) | [README](code/modules/mosquito/move-manager/README.md) |
| `audio-stack` (folder) | APM/yabridge, Mixbay, Levels Guard, live mode, PipeWire — Enter installs/removes all five | [stack](code/modules/mosquito/audio-stack/README.md) |
| `audio-plugin-manager` | Audio Plugin Manager (Wine/yabridge plugins) | [README](code/modules/mosquito/audio-stack/apm/README.md) |
| `mixbay` | USB audio bay (EVO 8/4, SSL 12 via douze, RME/ESI ALSA, beta interfaces) + default audio foundation (PipeWire/udev/rate) | [README](code/modules/mosquito/audio-stack/mixbay/README.md) |
| `levels-guard` | Native audio panel + media-key guard | [stack](code/modules/mosquito/audio-stack/README.md) |
| `mosquito.jamjamjam` | Real-time key/BPM/chord detection with a fretboard and tuner | [README](code/modules/mosquito/jamjamjam/README.md) |
| `live-mode` | A thermal/perf session mode: app closing, gaps, routing, package fence | [README](code/modules/mosquito/audio-stack/live-mode/README.md) |
| `mega-caffeine` | Coffee mode: laptop closed without sleeping, red tint, natural-language durations | [README](code/modules/mosquito/mega-caffeine/README.md) |
| `keybindings` | mosquitOmarchy-managed `SUPER` bindings in a reversible `bindings.lua` block | [README](code/main%20tui/README.md#keybindings) |

### Plugins

The project's own layer: the manager itself, and the desktop-hardware modules.

| Module | Installs | Doc |
|---|---|---|
| `battery-management` | Profile-colored battery icon/panel; the retired ultra-save CPU/power cap is removed | [README](code/modules/Plugins/battery-management/README.md) |
| `omaskpinpass` | SSH askpass + GnuPG pinentry plugins and binaries, built per-user; configures SSH askpass and GPG agent | [installer](code/modules/Plugins/omaskpinpass/setup-omaskpinpass.sh) |
| `downloads` | Omarchy Downloads popup + `SUPER+ALT+D` binding | [installer](code/modules/Plugins/omarchy-downloads/setup-omarchy-downloads.sh) |
| `taskq` | TaskQ deadline widget | [GitHub](https://github.com/sendaljpt/taskq) |
| `process-killer` | Omarchy process-killer widget | [GitHub](https://github.com/BeresN/omarchy-process-killer) |
| `mosquitomarchy` | This TUI (built from the Go sources in the repo), its dispatcher, menu entry, float rule, post-boot hook and the `SUPER+ALT+M` shortcut | [README](code/main%20tui/README.md) |
| `mosquitomarchy-update` | The update watchdog (scripts repo first, then Omarchy) | [README](code/main%20tui/update/README.md) |
| `brightness` | Omarchy default brightness plus 0% screen-off and a 1% hold ramp | [notes](code/modules/Plugins/brightness/display-fixes.md) |
| `touchpad` | Touchpad acceleration, sensitivity, scroll factor, and optional kinetic scrolling | [notes](code/modules/Plugins/touchpad/touchpad.md) |
| `mx-master` | MX Master thumb button → `SUPER`, smartshift off, scroll direction | [notes](code/modules/Plugins/mx-master/mx-master.md) |
| `reboot-into-windows` | System menu entry: find the UEFI Windows Boot Manager, 15 s yes/no countdown, arm BootNext for the next boot only, reboot | [README](code/modules/Plugins/reboot-into-windows/README.md) |

### Themes

| Module | Installs | Doc |
|---|---|---|
| `achraf67` | An Omarchy theme built from an image in `Themes/Wallpapers/` | [README](code/modules/Themes/README.md) |

`touchpad` and `mx-master` compose: each ships its own `hl.device` block, handles only its
own device, and never touches the other.

### Language models

| Module | Installs | Doc |
|---|---|---|
| `ollama` | Ollama + REAPER-oriented models (~14 GB) | [README](code/modules/lame/README.md) |
| `remove-ai` | Re-enables (Setup) or removes (Uninstall) Omarchy's own agentic parts | — |

### VMs

| Module | Installs | Doc |
|---|---|---|
| `windows-vm` | Windows 11 in Docker over RDP; installs the VM itself if absent | [README](code/modules/VMs/windows-vm/README.md) |
| `macos-vm` | macOS VM | [README](code/modules/VMs/macos-vm/README.md) |
| `omarchy-vm` | Omarchy in QEMU/KVM from the official ISO | [README](code/modules/VMs/omarchy-vm/README.md) |

### Entries

`TUIs` and `Fixes` are entry-backed: each file or folder is its own selectable
item rather than a single module. See [code/modules/TUIs/README.md](code/modules/TUIs/README.md)
and [code/modules/Fixes/README.md](code/modules/Fixes/README.md).

**audio-stack** is a folder row under *mosquito*, not a module of its own: Enter installs or
removes all five components, while Left/Right folds the folder and each child stays selectable.

**Creating a theme from an image** is not in the tables either, and not in Setup either: it is a
row on the [TUI's main menu](code/main%20tui/README.md), right after Keybindings,
because it creates a theme rather than installing a module. See
[code/modules/Themes/README.md](code/modules/Themes/README.md).

## Commands

### `mosquitomarchy-setup.sh`

The orchestrator. It offers backup/restore, then installs modules, then reports.

```bash
./mosquitomarchy-setup.sh                    # interactive
./mosquitomarchy-setup.sh -y                 # defaults
./mosquitomarchy-setup.sh --status           # report only
./mosquitomarchy-setup.sh --update -y        # also re-run the already-OK modules
./mosquitomarchy-setup.sh --backup           # dated backup, then exit
./mosquitomarchy-setup.sh --list             # list existing backups
./mosquitomarchy-setup.sh --restore[=FILE]   # restore one
./mosquitomarchy-setup.sh --uninstall [-y] [--purge]   # per-module removal
./mosquitomarchy-setup.sh --include=MODULE   # re-offer a module you removed
./mosquitomarchy-setup.sh --update-repo      # git pull the scripts
```

**Backup.** Each is `mosquitomarchy-backups/omarchy-backup-<timestamp>.tar.gz` (next to the repo): Hyprland and
app configs, the Zen profile (extensions, theme and the browser's own settings — browsing
data is deliberately excluded), package lists, the app selection, and a `RESTORE.md`. With
`--backup` the archive is then encrypted in place with AES-256 (gpg, file level, no sudo)
and the passphrase is asked through a hidden prompt. Module scripts install their own
missing runtime packages when they run; there is no global dependency manifest.

Plugin folders are **offered, never automatic**: the audio plugin manager owns that path, so
the backup asks the manager where the folder is, shows the folder, file count and size, and
archives it only if you agree. `-y` records the cheap inventory instead of several GB of
files; use `--vst-backup=full` to include them. On restore, a folder that moved since the
backup is deployed into the location the manager points at now, after asking.

**Uninstall** removes wrappers, menu entries, `omarchy-menu.jsonc` blocks, user units, custom
plugins, Hyprland bindings and the theme. Personal data (`~/VST`, `~/.config/windows`,
`~/.ollama`) is **kept** unless you add `--purge`. Uninstalled modules are remembered so they
are not re-proposed; `--include=MODULE` brings one back. System parts (packages, udev,
sudoers) need `sudo bash ./mosquitomarchy-setup.sh --uninstall -y`.

**Updates** are strictly `git pull --ff-only`, never `reset --hard`, `clean` or `rebase`, so
untracked files next to the scripts are never touched. The check runs on every launch and
once per boot, and always *before* pending Omarchy updates. An update re-applies every
module whose files changed — including `mosquitomarchy` itself, so the TUI is rebuilt
from the new sources (a `pull` alone never rebuilds anything).

**Removing the manager completely** (for a clean retest, from a terminal):

```bash
# 1. close the TUI if it is open, then remove the manager itself:
~/.local/bin/mosquitomarchy-actions uninstall mosquitomarchy
# 2. clear its memory (first-run marker, tree cache, uninstalled-modules list):
rm -rf ~/.local/state/mosquitomarchy ~/.cache/mosquitomarchy
rm -f ~/.local/state/omarchy-custom-scripts/excluded
```

The backend call removes the binaries, the dispatcher, the menu entry, the hook and
the float rule (plugins and apps stay — they have their own uninstall rows). The
`rm` lines clear the first-run marker, the tree cache and the uninstalled-modules
memory, so the next `./bootstrap.sh` starts from zero.

### `archive-mosquitomarchy.sh`

Builds an archive in `code/main tui/`, in one of two types chosen from a menu
(or `--type=`): `complete` (tracked, untracked and ignored files, with logs
optional) or `source` (tracked source only). Both exclude `.local`, `PATCH`,
password databases, generated machine lists and nested archives. The script
shows a progress bar, verifies the finished archive and refuses to start when
the destination lacks a 128 MB free-space margin beyond the input size.

```bash
./archive-mosquitomarchy.sh              # menu: choose a type, then build
./archive-mosquitomarchy.sh --list       # what would go in, writes nothing
./archive-mosquitomarchy.sh --type=source
./archive-mosquitomarchy.sh --out=DIR
```

The output name includes the time, so another archive made the same day will
not overwrite it. `complete` includes large ignored installers; check its size
and available disk space with `--type=complete --list` first.

A release replaces the bootstrap pipe — extract it, `./bootstrap.sh --init-git` to make
self-update work, then `./bootstrap.sh`.

## Large installers

**You bring these yourself.** None of them can be fetched automatically: Bitwig
and Ableton are behind account logins, and a multi-GB zip has no business in a
git clone. The clean technique: download every installer you want, drop them
all in `~/Downloads`, then run `./bootstrap.sh` — it moves each recognised
file into its module folder (never overwriting an existing file) and tells you
which Setup rows stay greyed out for the files still missing. You can also drop
a file straight into its module folder; each module looks for its installer
**where its own script lives** and says which file it expects when it is
missing.

A missing file is a fact about the machine, not a failed install: the module
that needs it stays visible in Setup but **greyed out**, and pressing Enter on
it says which file to put where instead of starting something that cannot
finish. Drop the file in (or re-run bootstrap with it in `~/Downloads`), and
the row comes back on its own.

Also not in the repo:

| App | File | Get it |
|---|---|---|
| Ableton Live | `install-ableton-latest.run` (installs Ableton) | [releases](https://github.com/shibco/ableton-linux/releases/latest) |
| Ableton Live | `ableton_live_suite_*.zip` or `_intro_*.zip` | [ableton.com](https://www.ableton.com/en/download/) (account needed) |
| Bitwig Studio | `bitwig-studio-*.deb`, version pinned by the module | [bitwig.com](https://www.bitwig.com/download/) |
| DaVinci Resolve | `DaVinci_Resolve_*_Linux.zip` (~7 GB) | [Blackmagic](https://www.blackmagicdesign.com/support/family/davinci-resolve-and-fusion) |
| Guitar Pro 8 | `guitar-pro-8-setup.exe` | [downloads](https://downloads.guitar-pro.com/gp8/stable/guitar-pro-8-setup.exe) |

## Layout

```
mosquitOmarchy/
├── bootstrap.sh              # clone + setup entry point
├── mosquitomarchy-setup.sh   # the orchestrator
├── VERSION                   # the single source of the version below
└── code/
    ├── modules/
    │   ├── Apps/             # one folder per desktop app
    │   ├── TUIs/             # one setup-<name>.sh per terminal tool
    │   ├── Plugins/          # shell plugins: battery-management, brightness, touchpad, ...
    │   ├── Fixes/            # small idempotent repairs
    │   ├── Tweaks/           # optional preference changes (never auto-applied)
    │   ├── Themes/           # theme generator + wallpapers
    │   ├── VMs/              # windows-vm/, macos-vm/, omarchy-vm/
    │   ├── lame/             # local language models (ollama)
    │   └── mosquito/         # mosquito tools: audio-stack, jamjamjam, move-manager, ...
    ├── main tui/             # the manager TUI + backend + update/ + go/ + addons/ (emoticon is the tracked example)
    ├── lib/                  # shared helpers, tui-kit/ (the Go component library)
    ├── tests/                # standalone regression tests (Wine window matcher, ...)
    └── dev/                  # development helpers (module size manifest)
```

Each script resolves its resources from its own directory, so moving a whole directory does
not break its paths.

## Addons

Addons live in `code/main tui/addons/` (user-owned; `emoticon` is the tracked example, all others are gitignored) and are managed from
**Extras → Addons** in the TUI: category groups, tick/untick, then a Yes/No confirmation
listing the additions and removals. An addon is a folder with `addon.conf`
(`NAME`, `CATEGORY`, `DESCRIPTION`, `ENABLED`), `install.sh` and an optional
`remove.sh`. Every mosquitOmarchy update re-applies the addons installed before it.
`emoticon` is the tracked example (`Themes`): see
[`code/main tui/README.md`](code/main%20tui/README.md#addons).

## Versions

Every version shown in a TUI is the version of the **script**, never of the application it
installs. For example, a module version identifies the mosquitOmarchy installer, not the
application it installs; it is what "check for updates" acts on.

There is one source: the root [`VERSION`](VERSION) file, currently **1.0.0**, which
`module_version()` reads and the installers inject into `mosquitomarchy-tui` and
`mosquito-mixbay-tui` at build time (`-X main.appVersion`). There is deliberately no
second list — a list next to `VERSION` is how the two drift.

The rule is what makes the update zone meaningful. A row saying 1.0.0 next to a row saying
0.9.0 would look like one module was newer than another; in fact both would be describing
their installers, and the only real comparison is against the version on GitHub.

## After the install

1. **Omarchy VM** — create it from **Omarchy menu → Setup → Omarchy VM** (new
   VMs enable VirGL 3D by default). Each
   VM gets its own host folder, **`~/VMs/<name>/shared`**, mounted in the guest
   at **`/mnt/host`**. Finish the guest side once, inside the VM:

   ```bash
   mkdir -p ~/VMs
   curl -sf --retry 3 http://10.0.2.2:7789/share -o ~/VMs/omarchy-vm-share
   sudo bash ~/VMs/omarchy-vm-share --install
   ```

   This mounts the shared folder, installs its boot unit and the clipboard
   agent. The downloaded helper is copied to `/usr/local/bin` and can be
   deleted. Until it has run, the launcher shows a notification and a link to
   <https://github.com/kepalegars/mosquitOmarchy>; the exact commands are in
   [`code/modules/VMs/omarchy-vm/README.md`](code/modules/VMs/omarchy-vm/README.md).

2. **Windows VM** — inside the guest, open `\\host.lan\Data` and run `install.bat` once.
   The module does the host side itself.
3. **Windows plugins** — install them into the shared VST root so every DAW sees them, or
   into a Wine prefix. One install in the shared root is visible everywhere.
4. `./code/modules/mosquito/audio-stack/apm/setup-yabridge.sh --tweaks` after each new plugin.
5. iLok licenses are activated per Wine prefix; reconnect if you just joined `realtime`.
6. Ableton Live: first-time ASIO / PipeASIO configuration under *Settings → Audio*.

## License

See [`LICENSE`](LICENSE).

> **Admin only** — [mosquitOmarchy archive cloud](https://kdrive.infomaniak.com/app/share/1099475/377fc533-3661-4242-88ef-be2343e88a0a) (direct access from the GitHub repo).
