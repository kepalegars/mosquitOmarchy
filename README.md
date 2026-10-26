# mosquitOmarchy

Idempotent setup scripts for [Omarchy](https://omarchy.org) (Arch + Hyprland), oriented
toward audio production: REAPER, Bitwig, Ableton Live on Linux, shared Windows VSTs, and
the local tooling around them.

Re-running any script on a configured machine is safe.

> **Scope.** Every module is built exclusively for Omarchy and is only tested on the
> author's own machine. The scripts assume Omarchy's `omarchy-*` commands and its
> config layout (`~/.config/hypr/hyprland.lua`, `foot`, `omarchy-notification-send`).
> Porting them to another distribution or desktop means adapting them first.

> **Picking this project back up?** Read [`JOURNAL.md`](JOURNAL.md) — it holds the
> current status, the active roadmap, and why things are the way they are.

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
  AES-256 encrypted.
- **Fixes** — the small idempotent repairs in `scripts/fixes/`, as a multi-select.
- **Tweaks** — optional preference changes in `scripts/tweaks/` (same multi-select; never
  auto-applied by `-y`).
- **Close** — leave.

`mosquitomarchy-setup.sh` is the engine underneath: every TUI action shells out to it, so
there is rarely a reason to call it by hand.

A failed run writes one dated crash log per session to the repo-local `.local/` and sends a
clickable notification that opens the default AI on the `mosquitomarchy-crash` skill,
pointed at that log, to **propose** a fix. See
[`scripts/lib/crash.bash`](scripts/lib/crash.bash).

## Modules

Details, options and caveats live in each module's own `README.md`. This table is the map.

### Apps

| Module | Installs | Doc |
|---|---|---|
| `reaper` | REAPER + its Hyprland/Wayland integration | [README](scripts/apps/reaper/README.md) |
| `bitwig` | Bitwig Studio from the local `.deb`, with its own module and optional patched `bitwig.jar` | [README](scripts/apps/bitwig/README.md) |
| `ableton` | Ableton Live 12 native on Linux, sharing the same VST root | [README](scripts/apps/ableton/README.md) |
| `guitarpro` | Guitar Pro 8 in its own Wine prefix | [README](scripts/apps/guitarpro/README.md) |
| `davinci-resolve` | DaVinci Resolve (free or Studio) + silent DRwrap integration | [README](scripts/apps/davinci/README.md) |
| `extracto` | Extracto | [README](scripts/apps/extracto/README.md) |
| `handbrake` | HandBrake GUI + CLI, preset sync, Hyprland rules | [README](scripts/apps/handbrake/README.md) |
| `signal` | Signal Desktop, tray behavior, menu entry, and login autostart | [setup](scripts/apps/signal/setup-signal.sh) |
| `betterbird` | Betterbird (Thunderbird fork): install, system-tray close/minimise, login autostart, tiled main window + popups at the pointer | [setup](scripts/apps/betterbird/setup-betterbird.sh) |
| `whatsapp-native` | WhatsApp desktop client (self-contained Electron wrapper): silent visual notifications, tray + close-to-tray, no menu bar, login autostart | [README](scripts/apps/whatsapp-native/README.md) |
| `superfile` | SuperFile terminal file manager; the system default file manager is left unchanged | [README](scripts/apps/superfile/README.md) |
| `zen` | Zen Browser, seeded extensions and theme | [README](scripts/apps/zen/README.md) |
| `keepassxc` | KeePassXC password manager + browser integration (Leaves Omarchy's keyring intact) | [README](scripts/apps/keepassxc/README.md) |
| `hyprmod` | Hyprmod profile configuration in `~/.config/hypr/hyprmod.d/profiles.conf` | — |
| `apps` | The app / TUI / webapp catalogs, reinstallable from a backup selection | [README](scripts/apps/README.md) |

The tables below follow the TUI's Setup folders: each heading is one of them.

### mosquito

| Module | Installs | Doc |
|---|---|---|
| `ableton-move-manager` | Ableton Move → Live → Bitwig conversion (MIDI export, native Omarchy prompts) | [README](scripts/apps/ableton-move-manager/README.md) |
| `audio-stack` (folder) | APM/yabridge, Mixbay, Levels Guard, live mode, PipeWire — Enter installs/removes all five | [stack](scripts/mosquito/audio-stack/README.md) |
| `audio-plugin-manager` | Audio Plugin Manager (Wine/yabridge plugins) | [README](scripts/mosquito/audio-stack/apm/README.md) |
| `mixbay` | USB audio bay (EVO 8/4 + ALSA interfaces) | [README](scripts/mosquito/audio-stack/mixbay/README.md) |
| `levels-guard` | Native audio panel + media-key guard | [stack](scripts/mosquito/audio-stack/README.md) |
| `mosquito.jamjamjam` | Real-time key/BPM/chord detection with a fretboard and tuner | [README](scripts/mosquito/jamjamjam/README.md) |
| `live-mode` | A thermal/perf session mode: app closing, gaps, routing, package fence | [README](scripts/mosquito/audio-stack/live-mode/README.md) |
| `mega-caffeine` | Coffee mode: laptop closed without sleeping, red tint, natural-language durations (installs battery management first if missing) | [README](scripts/mosquito/mega-caffeine/README.md) |
| `keybindings` | The `SUPER` bindings of this package, inside one reversible block in `bindings.lua` | [README](scripts/apps/mosquitomarchy/README.md#keybindings) |

### Plugins

The project's own layer: the manager itself, and the desktop-hardware modules.

| Module | Installs | Doc |
|---|---|---|
| `battery-management` | Ultra-save low-power mode, `power-helper`, watchdog, and the `mosquito.power` bar plugin | [README](scripts/plugins/battery-management/README.md) |
| `mosquitomarchy` | This TUI (built from the Go sources in the repo), its dispatcher, menu entry, float rule, post-boot hook and the `SUPER+ALT+M` shortcut | [README](scripts/apps/mosquitomarchy/README.md) |
| `mosquitomarchy-update` | The update watchdog (scripts repo first, then Omarchy) | [README](scripts/mosquitomarchy-update/README.md) |
| `brightness` | Omarchy default brightness plus 0% screen-off and a 1% hold ramp | [notes](scripts/plugins/brightness/display-fixes.md) |
| `touchpad` | Touchpad acceleration, sensitivity, scroll factor, and optional kinetic scrolling | [notes](scripts/plugins/touchpad/touchpad.md) |
| `mx-master` | MX Master thumb button → `SUPER`, smartshift off, scroll direction | [notes](scripts/plugins/mx-master/mx-master.md) |

### Themes

| Module | Installs | Doc |
|---|---|---|
| `achraff` | An Omarchy theme built from an image in `theme/Wallpapers/` | [README](scripts/theme/README.md) |

`touchpad` and `mx-master` compose: each ships its own `hl.device` block, handles only its
own device, and never touches the other.

### Language models

| Module | Installs | Doc |
|---|---|---|
| `ollama` | Ollama + REAPER-oriented models (~14 GB) | [README](scripts/LLM/README.md) |
| `remove-ai` | Re-enables (Setup) or removes (Uninstall) Omarchy's own agentic parts | — |

### VMs

| Module | Installs | Doc |
|---|---|---|
| `windows-vm` | Windows 11 in Docker over RDP; installs the VM itself if absent | [README](scripts/windows-vm/README.md) |
| `macos-vm` | macOS VM | [README](scripts/macos-vm/README.md) |
| `omarchy-vm` | Omarchy in QEMU/KVM from the official ISO | [README](scripts/omarchy-vm/README.md) |

### Catalogs

`apps`, `tuis`, `webapps` and `fixes` are catalog-backed: each entry in
`scripts/apps/*/` is its own selectable item rather than a single module. See
[scripts/apps/README.md](scripts/apps/README.md) and [scripts/fixes/README.md](scripts/fixes/README.md).

**audio-stack** is a folder row under *mosquito*, not a module of its own: Enter installs or
removes all five components, while Left/Right folds the folder and each child stays selectable.

**Creating a theme from an image** is not in the tables either, and not in Setup either: it is a
row on the [TUI's main menu](scripts/apps/mosquitomarchy/README.md), right after Keybindings,
because it creates a theme rather than installing a module. See
[scripts/theme/README.md](scripts/theme/README.md).

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
and the passphrase is asked through a hidden prompt. Any `deps` file under `scripts/` is
read on restore and its packages reinstalled.

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

Builds an archive of the repo into the directory next to it, in one of two
types chosen from a menu (or `--type=`): `complete` (the whole working tree
including the backups folder, logs asked about) or `source` (tracked code
only: no logs, no install files, no backups). The source list comes from
`git ls-files`, and every build re-reads its own output and refuses to keep
it if a log, `Passwords.kdbx` or backup slipped in where it should not be.

```bash
./archive-mosquitomarchy.sh              # menu: choose a type, then build
./archive-mosquitomarchy.sh --list       # what would go in, writes nothing
./archive-mosquitomarchy.sh --type=source
./archive-mosquitomarchy.sh --out=DIR
```

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
└── scripts/
    ├── apps/                 # one folder per app, plus the app/TUI/webapp catalogs
    │   └── mosquitomarchy/   # the manager TUI + backend + archive-mosquitomarchy.sh
    ├── mosquito/             # mosquito tools: live-mode, jamjamjam, pipewire-settings, mega-caffeine
    ├── plugins/              # shell plugins: battery-management, brightness, touchpad, ...
    ├── fixes/                # small idempotent repairs
    ├── tweaks/               # optional preference changes (never auto-applied)
    ├── lib/                  # shared helpers, tui-kit/ (the Go component library)
    ├── theme/  LLM/  deps/
    ├── windows-vm/  macos-vm/  omarchy-vm/
    └── mosquitomarchy-update/
```

Each script resolves its resources from its own directory, so moving a whole directory does
not break its paths.

## Versions

Every version shown in a TUI is the version of the **script**, never of the application it
installs. So `hyprmod - v1.0.0` does not mean hyprmod 1.0.0 — hyprmod ships its own versioning
and this says nothing about it. It means *the mosquitOmarchy script that sets hyprmod up* is
at 1.0.0, which is what "check for updates" acts on. Nothing in the list is the application's
own version, so there is nothing there to compare against a vendor release.

There is one source: the root [`VERSION`](VERSION) file, currently **1.0.0**, which
`module_version()` reads and the installers inject into `mosquitomarchy-tui` and
`mosquito-mixbay-tui` at build time (`-X main.appVersion`). There is deliberately no
second list — a list next to `VERSION` is how the two drift.

The rule is what makes the update zone meaningful. A row saying 1.0.0 next to a row saying
0.9.0 would look like one module was newer than another; in fact both would be describing
their installers, and the only real comparison is against the version on GitHub.

## After the install

1. **Windows VM** — inside the guest, open `\\host.lan\Data` and run `install.bat` once.
   The module does the host side itself.
2. **Windows plugins** — install them into the shared VST root so every DAW sees them, or
   into a Wine prefix. One install in the shared root is visible everywhere.
3. `./scripts/mosquito/audio-stack/apm/setup-yabridge.sh --tweaks` after each new plugin.
4. iLok licenses are activated per Wine prefix; reconnect if you just joined `realtime`.
5. Ableton Live: first-time ASIO / PipeASIO configuration under *Settings → Audio*.

## License

See [`LICENSE`](LICENSE).
