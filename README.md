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
- **Backup / Restore** — a dated archive in `~/omarchy-backups/`, optionally
  AES-256 encrypted.
- **Fixes** — the small idempotent fixes in `scripts/fixes/`, as a multi-select.
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

The tables below follow the TUI's Setup folders: each heading is one of them.

### mosquito

| Module | Installs | Doc |
|---|---|---|
| `ableton-move-manager` | Ableton Move → Live → Bitwig conversion (MIDI export, native Omarchy prompts) | [README](scripts/apps/ableton-move-manager/README.md) |
| `mosquito.jamjamjam` | Real-time key/BPM/chord detection with a fretboard and MIDI output | [README](scripts/plugins/jamjamjam/README.md) |
| `live-mode` | A thermal/perf session mode: app closing, gaps, routing, package fence | [README](scripts/plugins/live-mode/README.md) |
| `battery` | Ultra-save, a custom battery plugin, mega caffeine | [README](scripts/plugins/power-management/README.md) |
| `keybindings` | The `SUPER` bindings of this package, inside one reversible block in `bindings.lua` | [README](scripts/apps/mosquitomarchy/README.md#keybindings) |

### Plugins

The project's own layer: the manager itself, and the desktop-hardware modules.

| Module | Installs | Doc |
|---|---|---|
| `mosquitomarchy` | This TUI (built from the Go sources in the repo), its dispatcher, menu entry, float rule, post-boot hook and the `SUPER+ALT+M` shortcut | [README](scripts/apps/mosquitomarchy/README.md) |
| `mosquitomarchy-update` | The update watchdog (scripts repo first, then Omarchy) | [README](scripts/mosquitomarchy-update/README.md) |
| `brightness` | Perceptual brightness | [notes](scripts/fixes/display-fixes.md) |
| `touchpad` | Touchpad acceleration and sensitivity | [notes](scripts/fixes/fix-touchpad.md) |
| `mx-master` | MX Master thumb button → `SUPER`, smartshift off, scroll direction | [notes](scripts/fixes/fix-mx-master.md) |

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

One TUI row is not in the tables above, because it is not an orchestrator module: the **mosquito
Audio Plugin Manager** is selected as its own row under *mosquito* but is installed by `audio`.

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

Builds an archive of the repo into the directory next to it, in one of three
types chosen from a menu (or `--type=`): `complete` (the whole working tree,
logs asked about), `release` (tracked code plus the install files you choose,
no logs) or `source` (tracked code only). Release and source lists come from
`git ls-files`, and every build re-reads its own output and refuses to keep
it if a log, `Passwords.kdbx` or backup slipped in. The two install files
GitHub cannot hold are asked about once for a release and the answer is
recorded in the filename (`-installers` suffix or not).

```bash
./scripts/archive-mosquitomarchy.sh              # menu: choose a type, then build
./scripts/archive-mosquitomarchy.sh --list       # what would go in, writes nothing
./scripts/archive-mosquitomarchy.sh --type=source --no-installers
./scripts/archive-mosquitomarchy.sh --out=DIR
```

A release replaces the bootstrap pipe — extract it, `./bootstrap.sh --init-git` to make
self-update work, then `./bootstrap.sh`.

## Large installers

**You bring these yourself.** None of them can be fetched automatically: Bitwig
and Ableton are behind account logins, and a ~4 GB zip has no business in a git
clone. Each module looks for its installer **where its own script lives** —
`scripts/apps/ableton/`, `scripts/apps/guitarpro/`, `scripts/apps/bitwig/` — and
says which file it expects when it is missing. `scripts/apps/bitwig/setup-bitwig.sh`
and `scripts/apps/ableton/setup-ableton.sh` both check up front and abort rather
than half-install.

`assets.links` is the **inventory** of those files: where each one belongs, and
its sha256 where recording one is worth it. Nothing is ever downloaded — there is
no URL to download from. Ableton and Bitwig sit behind account logins, and a 4 GB
zip has no business in a clone, so this is a presence check, not a fetcher:

| Command | Says |
|---|---|
| `download-assets.sh` | one line per file, then where to put whatever is missing |
| `download-assets.sh --status` | the same list, nothing else |
| `download-assets.sh --check` | integrity only — exit 1 on corruption, **0** on absence |
| `download-assets.sh --ready <path>` | silent; exit 0 if usable, 1 if not |

A missing file is a fact about the machine, not a failed install: the module that
needs it stays visible in Setup but **greyed out**, and pressing Enter on it says
which file to put where instead of starting something that cannot finish. Drop the
file in, and the row comes back on its own. DaVinci is inventoried by presence only
— hashing an 11 GB zip on every `--check` costs more than the answer is worth.

Also not in the repo, and not covered by `assets.links`:

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

Every version shown in a TUI is the version of the **script**, never of the application it
installs. So `hyprmod - v1.0.0` does not mean hyprmod 1.0.0 — hyprmod ships its own versioning
and this says nothing about it. It means *the mosquitOmarchy script that sets hyprmod up* is
at 1.0.0, which is what "check for updates" acts on. Nothing in the list is the application's
own version, so there is nothing there to compare against a vendor release.

There is one source: the root [`VERSION`](VERSION) file, currently **1.0.0**, which
`module_version()` reads and the Go TUIs mirror in `appVersion`. There is deliberately no
second list — a list next to `VERSION` is how the two drift.

The rule is what makes the update zone meaningful. A row saying 1.0.0 next to a row saying
0.9.0 would look like one module was newer than another; in fact both would be describing
their installers, and the only real comparison is against the version on GitHub.

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
