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

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/kepalegars/mosquitOmarchy/master/bootstrap.sh | bash -s -- --zips -y
```

That clones the repo, installs the missing modules, builds the TUI, and registers a menu
entry. From an existing clone, `./bootstrap.sh --zips -y` does the same without the pipe.

Large application installers (Ableton, Bitwig, DaVinci, Guitar Pro) are **not** in the
repo — see [Large installers](#large-installers).

| Flag | Effect |
|---|---|
| `-y` | no questions, apply defaults |
| `--zips` | also download the large installers |
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
- **Backup / Restore** — a dated archive in `~/omarchy-backups/`, optionally
  AES-256 encrypted.
- **Quick fixes** — the small idempotent fixes in `scripts/fixes/`, as a multi-select.
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
| `audio` | yabridge/wine-staging, Bitwig Studio, the shared VST root, the mosquito Audio Plugin Manager | [bitwig](scripts/apps/bitwig/README.md) · [manager](scripts/apps/audio-plugin-manager/README.md) |
| `ableton` | Ableton Live 12 native on Linux, sharing the same VST root | [README](scripts/apps/ableton/README.md) |
| `guitarpro` | Guitar Pro 8 in its own Wine prefix | [README](scripts/apps/guitarpro/README.md) |
| `davinci-resolve` | DaVinci Resolve (free or Studio) | [README](scripts/apps/davinci/README.md) |
| `extracto` | Extracto | [README](scripts/apps/extracto/README.md) |
| `handbrake` | HandBrake GUI + CLI, preset sync, Hyprland rules | [README](scripts/apps/handbrake/README.md) |
| `superfile` | SuperFile as the default file manager | [README](scripts/apps/superfile/README.md) |
| `zen` | Zen Browser, seeded extensions and theme | [README](scripts/apps/zen/README.md) |
| `keepassxc` | KeePassXC as the system Secret Service | [README](scripts/apps/keepassxc/README.md) |
| `apps` | The app / TUI / webapp catalogs, reinstallable from a backup selection | [README](scripts/apps/README.md) |

### mosquito

| Module | Installs | Doc |
|---|---|---|
| `mosquitomarchy` | This TUI, its menu entry and the `SUPER+ALT+M` shortcut | [README](scripts/apps/mosquitomarchy/README.md) |
| `ableton-move-manager` | Ableton Move → Live → Bitwig conversion (MIDI export, native Omarchy prompts) | [README](scripts/apps/ableton-move-manager/README.md) |
| `jamjamjam-plugin` | Real-time key/BPM/chord detection with a fretboard and MIDI output | [README](scripts/plugins/jamjamjam/README.md) |
| `live-mode` | A thermal/perf session profile: app closing, gaps, routing, package fence | [README](scripts/plugins/live-mode/README.md) |
| `keybindings` | The `SUPER` bindings of this package, inside one reversible block in `bindings.lua` | [README](scripts/apps/mosquitomarchy/README.md#keybindings) |
| `mosquitomarchy-update` | The update watchdog (scripts repo first, then Omarchy) | [README](scripts/mosquitomarchy-update/README.md) |

### Plugins and fixes

| Module | Installs | Doc |
|---|---|---|
| `battery` | Ultra-save, a custom battery plugin, mega caffeine | [README](scripts/plugins/power-management/README.md) |
| `brightness` | Perceptual brightness | [notes](scripts/fixes/display-fixes.md) |
| `keyboard-backlight` | Backlight toggle + a Trigger entry | [notes](scripts/fixes/display-fixes.md) |
| `touchpad` | Touchpad acceleration and sensitivity | [notes](scripts/fixes/fix-touchpad.md) |
| `mx-master` | MX Master thumb button → `SUPER`, smartshift off, scroll direction | [notes](scripts/fixes/fix-mx-master.md) |
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

Two rows in the TUI are not in the tables above, because they are not orchestrator modules: the
**mosquito Audio Plugin Manager** is selected as its own row but is installed by `audio`, and
**building a theme from a wallpaper** is selected under *Themes* but is done by `achraff`.

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

**Backup.** Each is `~/omarchy-backups/omarchy-backup-<timestamp>.tar.gz`: Hyprland and
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
once per boot, and always *before* pending Omarchy updates.

### `scripts/archive-mosquitomarchy.sh`

Builds a release tarball from `git ls-files` only, so no personal or ignored file can leak
in, then re-reads its own output and refuses to keep it if a `PATCH/`, log, `Passwords.kdbx`
or backup slipped in. The two install files GitHub cannot hold are asked about once and the
answer is recorded in the filename (`-installers` suffix or not).

```bash
./scripts/archive-mosquitomarchy.sh              # build, asks about the installers
./scripts/archive-mosquitomarchy.sh --list       # both sizes, writes nothing
./scripts/archive-mosquitomarchy.sh --no-installers
./scripts/archive-mosquitomarchy.sh --out=DIR
```

A release replaces the bootstrap pipe — extract it, `./bootstrap.sh --init-git` to make
self-update work, then `./bootstrap.sh`.

## Large installers

Not in the repo; the `windows-vm` and `audio` modules expect the first two.

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
    ├── plugins/              # shell plugins: live-mode, jamjamjam, power-management
    ├── fixes/                # small idempotent fixes
    ├── lib/                  # shared helpers, tui-kit/ (the Go component library)
    ├── theme/  LLM/  deps/
    ├── windows-vm/  macos-vm/  omarchy-vm/
    ├── mosquitomarchy-update/
    └── archive-mosquitomarchy.sh
```

Each script resolves its resources from its own directory, so moving a whole directory does
not break its paths.

## Versions

Every displayed version is the version of the **script**, never of the application it
installs. There is one source: the root [`VERSION`](VERSION) file, currently **1.0.0**, which
`module_version()` reads and the Go TUIs mirror in `appVersion`. There is deliberately no
second list — a list next to `VERSION` is how the two drift.

## After the install

1. **Windows VM** — inside the guest, open `\\host.lan\Data` and run `install.bat` once.
   The module does the host side itself.
2. **Windows plugins** — install them into the shared VST root so every DAW sees them, or
   into a Wine prefix. One install in the shared root is visible everywhere.
3. `./scripts/apps/audio-plugin-manager/setup-audio-stack.sh --tweaks` after each new plugin.
4. iLok licenses are activated per Wine prefix; reconnect if you just joined `realtime`.
5. Ableton Live: first-time ASIO / PipeASIO configuration under *Settings → Audio*.

## License

See [`LICENSE`](LICENSE).
