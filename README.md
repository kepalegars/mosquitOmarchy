# mosquitOmarchy

Personal scripts for configuring Omarchy (Arch/Hyprland) oriented toward **audio production** (REAPER, Bitwig, Windows VST, local AI). All scripts are **idempotent**: safe to re-run on an already-configured machine.

This README is the **complete reference** for the orchestrator (`mosquitomarchy-setup.sh` — install + backup/restore + per-module uninstall + repo update, all in one script) and the release archiver (`archive-mosquitomarchy.sh`), and it lists **every module** the repo ships, including modules bundled inside another one (e.g. Bitwig inside `audio`) and modules not selected in a given run. Each module's own install commands, options and caveats live in its folder's `README.md` — linked from the **Documentation** column of the module tables in [Modules](#modules).

> **Resuming work on this repo (human or AI)?** Check [`JOURNAL.md`](JOURNAL.md) first — it tracks current status, the active roadmap, and the history of decisions, and is meant to be read before this README when picking the project back up.

> **How this repo is built**: almost entirely vibe-coded with [Claude Code](https://claude.com/claude-code) and [OpenCode](https://opencode.ai/) — the owner directs and reviews, the AI writes the vast majority of the code.

> **Scope / disclaimer**: every module here is built **exclusively for [Omarchy](https://omarchy.org)** (Arch Linux + Hyprland + the Omarchy shell and tooling) and is **only tested on the author's own Omarchy machine** — never on other distributions, desktops, or window managers. Scripts assume Omarchy-specific tools and paths (`omarchy-*` commands, the Lua `~/.config/hypr/hyprland.lua`, `foot`, `omarchy-notification-send`, …). Reusing them elsewhere requires adapting them; do not expect them to work unmodified.

## Installation files

The large installers are not in the repo; they are provided by the release archive (`archive-mosquitomarchy.sh`) or must be downloaded separately:

| App | File | In repo? | In release archive? | Download |
|---|---|---|---|---|
| Ableton Live | `install-ableton-latest.run` (required to install Ableton) | no | yes | https://github.com/shibco/ableton-linux/releases/latest |
| Ableton Live | `ableton_live_suite_12.4.5_64.zip` or `ableton_live_intro_12.4.5_64.zip` | no | no | https://www.ableton.com/en/download/ (Ableton account required) |
| Bitwig Studio | `bitwig-studio-6.0-beta-6.deb` (version pinned by the module) | no | yes (only app provided) | [direct 6.1.1](https://www.bitwig.com/dl/Bitwig%20Studio/6.1.1/installer_linux/) · [download page](https://www.bitwig.com/download/) |
| DaVinci Resolve | `DaVinci_Resolve_*_Linux.zip` (~7 GB) | no | no | [All versions](https://www.blackmagicdesign.com/support/family/davinci-resolve-and-fusion) · [free direct](https://www.blackmagicdesign.com/support/download/59dd4eef1f4941c29fb8dc48b33f5c87/Linux) · [Studio direct](https://www.blackmagicdesign.com/support/download/baf7c071c0524fbf8ccc961925c9f443/Linux) |
| Guitar Pro 8 | `guitar-pro-8-setup.exe` | no | no | https://downloads.guitar-pro.com/gp8/stable/guitar-pro-8-setup.exe |

## One-command start

**Repo already cloned:**

```bash
./scripts/bootstrap.sh                        # interactive: full setup
./scripts/bootstrap.sh --zips -y              # auto setup + downloads missing large installer files
./scripts/bootstrap.sh --status               # module status, no changes made
./scripts/bootstrap.sh --repo=https://github.com/kepalegars/mosquitOmarchy.git --dir=PATH  # override repo URL / clone destination
```

**Repo not yet present** (large installer files are **not** in the repo):

```bash
curl -fsSL https://raw.githubusercontent.com/kepalegars/mosquitOmarchy/master/scripts/bootstrap.sh | bash -s -- --zips -y
```

> The repo is at <https://github.com/kepalegars/mosquitOmarchy>. `bootstrap.sh` clones it by
> default; if you keep a fork, override `REPO_URL` / `RAW_BOOTSTRAP_URL` / `BRANCH` at the
> top of `scripts/bootstrap.sh` or pass `--repo=URL`.

## Manage everything from mosquitOmarchy (the TUI)

Once installed, **everything in this repo can be driven from one TUI**: `mosquitOmarchy`. Run `mosquitomarchy` (or open the Omarchy launcher → **Install → mosquitOmarchy**) and use its menu:

- **Status** — every module and its state (installed / partial / missing / uninstalled by you).
- **Update** — pull the scripts repo and re-apply the changed installed modules.
- **Setup** — lists the categories as options (alphabetically, plus **Menu entry**, **Add shortcut for mosquitOmarchy** and **Install selection**); picking a category opens its item tree (also alphabetical): `tab` selects, `←/→` expand/collapse a folder, `i` shows the highlighted entry's description, `enter` installs the selection. **Menu entry** registers the launcher in the Omarchy menu; **Add shortcut for mosquitOmarchy** binds `SUPER + ALT + M` (press `i` on either for details).
- **Backup / Restore** — dated archives, with the same content choices as before (apps / TUIs / webapps selection, VST plugins, KeePassXC passwords), plain **or** AES-256 encrypted with a passphrase asked twice.
- **Close** — leave the TUI.

Any failed run also writes **one dated crash log per session** into the repo-local `.local/` folder (never committed, never archived) and sends a **clickable Omarchy notification**: it opens the default AI on the `mosquitomarchy-crash` skill, pointed at that log, to **propose** a fix without applying it. See [`scripts/lib/crash.bash`](scripts/lib/crash.bash) and the [mosquitOmarchy README](scripts/apps/mosquitomarchy/README.md#crash-reporting--ai-diagnosis).

The TUI is the single interface; `mosquitomarchy-setup.sh` remains the engine (every TUI action shells out to it), so you should not need to call it by hand.

**Recommended once, so mosquitOmarchy is always one click away:** in the TUI go to **Setup → Menu entry → Yes**. This registers the entry in **Omarchy menu → Install → mosquitOmarchy** (`~/.config/omarchy/extensions/omarchy-menu.jsonc`); from then on you can reopen the TUI at any time from the launcher.

The **one-line install** above (`curl … bootstrap.sh | bash -s -- --zips -y`) sets all of this up: it clones the repo, runs `mosquitomarchy-setup.sh -y`, builds the mosquitOmarchy TUI and registers the menu entry.

## Versions

Every displayed version is the version of the **script** (the installer/module) — **not** of the application it installs. Versions are shown:

- in the mosquitOmarchy **Setup** tree, next to each module (`reaper - v1.0.0`);
- in **Status**, next to each module;
- in the **top-left corner of the first page** of every mosquito TUI (grey, same style as the shortcut hints), e.g. `v1.0.0`.

All scripts are **v1.0.0**, except three still at **v0.1.0**: the DaVinci Resolve setup, HandBrake, and `bootstrap.sh`. The main script — the whole repository — is **v0.1.0** (see the root [`VERSION`](VERSION) file).

## Structure

```
mosquitOmarchy/
├── README.md · LICENSE · assets.links · .gitignore · .mise.toml
├── archive-mosquitomarchy.sh       # "latest release" tar.gz (root)
├── mosquitomarchy-setup.sh         # single orchestrator: backup/restore → modules → uninstall → repo update
└── scripts/
    ├── gui-run.bash             # file-manager launch support (reopens installers in a terminal)
    ├── bootstrap.sh             # one-command start
    ├── deps                     # deps with no module folder of their own (currently: omagrab)
    ├── lib/                     # shared helpers: tui-kit/ (Go component library) + common.bash + crash.bash + keybindings.bash
    ├── fixes/                   # small idempotent fixes (Papers, brightness, touchpad, MX Master, menu…)
    ├── plugins/                 # Omarchy shell plugins: power-management/ · jamjamjam/ · live-mode/
    ├── apps/                    # "apps" module: dispatchers + one folder per type
    │   ├── gui/  tui-tools/  webapps/  #   catalogs + install/uninstall per type
    │   ├── mosquitomarchy/      #   the mosquitOmarchy launcher TUI (dispatcher + Go TUI + backend)
    │   └── ableton/  bitwig/  reaper/  audio-plugin-manager/  guitarpro/  davinci/  handbrake/
    │       ableton-move-converter/  superfile/  zen/  #   Move Manager · file manager · browser seed
    ├── LLM/                     # setup-ollama-audio-expert.sh
    ├── windows-vm/  macos-vm/  omarchy-vm/  theme/
    └── mosquitomarchy-update/      # update watchdog (scripts repo first, then Omarchy)
```

Each module folder has a `README.md` with the module's own details — linked in the **Documentation** column of the [Modules](#modules) tables. Each script resolves its resources via its own directory: moving an entire directory has no effect on paths.

**Quick system fixes** live in `scripts/fixes/` (small idempotent fixes — Papers/Evince swap, perceptual brightness, keyboard backlight, touchpad, MX Master, theme). At startup, interactive mode proposes to apply them and opens a **multi-select** (Space = choose, Tab = navigate), each fix with its micro-explanation; `-y` applies them all automatically.

**File-manager launch**: right-click any `setup-*.sh` / `uninstall-*.sh` → **Run as a Program**.

## Orchestrators

| Script | Role |
|---|---|
| [bootstrap.sh](#one-command-start) | One-command start: clone (if needed) + setup + optional asset download |
| [mosquitOmarchy](scripts/apps/mosquitomarchy/README.md) | The launcher TUI (Go/Bubble Tea): status / update / setup tree / backup-restore — the recommended interface |
| [mosquitomarchy-setup.sh](#mosquitomarchy-setupsh) | Master: backup/restore → modules one by one → uninstall → repo update → report |
| [archive-mosquitomarchy.sh](#archive-mosquitomarchysh) | Complete tar.gz archive of the repo (the "latest release") |

---

## mosquitomarchy-setup.sh

Single entry point, no standalone helper anymore: it integrates the **backup/restore**, the **per-module uninstall**, the **repo update** and the module installs. Flow: backup/restore offered → optional removal of Omarchy preinstalls (keeping your personal apps/tuis) → modules one by one (`-y` = install all missing + update the OK ones with `--update`) → theme at the end (skipped with `-y`) → optional per-module uninstall → final report (yes/no per module) + status.

```bash
./mosquitomarchy-setup.sh                     # interactive
./mosquitomarchy-setup.sh -y                  # defaults (auto backup, missing modules)
./mosquitomarchy-setup.sh --update -y         # also re-runs the already-OK modules (idempotent)
./mosquitomarchy-setup.sh --status            # module status only, no modification
./mosquitomarchy-setup.sh --backup            # dated backup, then exit (passphrase prompt via gum TUI if available)
./mosquitomarchy-setup.sh --backup --vst-backup=full   # idem + full VST archive (~/VST)
./mosquitomarchy-setup.sh --list              # chronological list of the backups ([encrypted] = .tar.gz.gpg)
./mosquitomarchy-setup.sh --restore[=FILE]    # restore a backup (chronological choice; encrypted → passphrase asked)
./mosquitomarchy-setup.sh --uninstall [-y] [--purge]  # per-module uninstall (interactive; -y = all)
./mosquitomarchy-setup.sh --update-repo       # git pull the scripts from GitHub (see "Repo updates")
./mosquitomarchy-setup.sh --include=<mod>     # re-offer a module you previously uninstalled
```

### Modules

Grouped by priority (creative apps first, then desktop/power tuning, then maintenance), alphabetical within each group.

**Creative apps**

| Module | What it does | Script called | Documentation |
|---|---|---|---|
| `ableton` | Ableton Live 12 native Linux + shared Windows VST plugins | `scripts/apps/ableton/setup-ableton.sh` | [README](scripts/apps/ableton/README.md) |
| `apps` | Apps / TUIs / webapps — catalog per type, reinstallable from a backup selection | `scripts/apps/setup-apps.sh` | [README](scripts/apps/README.md) · [gui/KeePassXC](scripts/apps/gui/README.md) |
| `audio` | yabridge/wine-staging stack, real-time group, Bitwig Studio 6.0 Beta 6 (local `.deb`), REAPER, shared VST folders, autosync + the **mosquito Audio Plugin Manager** | `setup-bitwig.sh` + `setup-reaper.sh` + `setup-audio-stack.sh` | [bitwig](scripts/apps/bitwig/README.md) · [reaper](scripts/apps/reaper/README.md) · [audio-plugin-manager](scripts/apps/audio-plugin-manager/README.md) |
| `davinci` | DaVinci Resolve Studio or free + H.264/H.265 + optional OFX SpectraFilm | `scripts/apps/davinci/setup-davinci.sh` | [README](scripts/apps/davinci/README.md) |
| `guitarpro` | Guitar Pro 8 via Wine (dedicated prefix) | `scripts/apps/guitarpro/setup-guitarpro.sh` | [README](scripts/apps/guitarpro/README.md) |
| `ableton-move-converter` | mosquito Move Manager — Ableton Move → Ableton Live → Bitwig (menu: address / Move Manager / convert — native Omarchy prompts, MIDI export) | `scripts/apps/ableton-move-manager/setup-ableton-move-manager.sh` | [README](scripts/apps/ableton-move-manager/README.md) |
| `jamjamjam-plugin` | JamJamJam bar plugin — real-time key/BPM/chord detection, chord progression grid, guitar fretboard (numbered degrees), MIDI chord mode + synth. **Privacy:** the microphone is never captured while the plugin is closed, and no audio is ever written to disk (analysis data only, in the cache/state dir) | `scripts/plugins/jamjamjam/setup-jamjamjam-plugin.sh` | [README](scripts/plugins/jamjamjam/README.md) |
| `handbrake` | HandBrake GUI + CLI, H.264/H.265 encoders, preset sync, Hyprland rules | `scripts/apps/handbrake/setup-handbrake.sh` | [README](scripts/apps/handbrake/README.md) |
| `ollama` | Ollama + REAPER-oriented models (~14 GB) + OpenCode integration | `scripts/LLM/setup-ollama-audio-expert.sh` | [README](scripts/LLM/README.md) |
| `reaper` | REAPER + Hyprland/Wayland integration | `scripts/apps/reaper/setup-reaper.sh` | [README](scripts/apps/reaper/README.md) |
| `windows-vm` | "Windows" launcher (USB + DPI) + winvm (RAM/CPU/disk) + OEM debloat | `scripts/windows-vm/setup-windows-vm.sh` | [README](scripts/windows-vm/README.md) |
| `omarchy-vm` | Omarchy in QEMU/KVM from the official ISO — launcher + TUI manager + shared folder + USB/GPU passthrough | `scripts/omarchy-vm/setup-omarchy-vm.sh` | [README](scripts/omarchy-vm/README.md) |

**Desktop & power**

| Module | What it does | Script called | Documentation |
|---|---|---|---|
| `achraff` | "Achraff 67" visual theme + unlock/Plymouth logo | `create-theme.sh` (forced `achraf67.png` image) | [README](scripts/theme/README.md) |
| `battery` | ultra save + custom battery plugin + mega caffeine ([details](scripts/plugins/power-management/README.md)) | `scripts/plugins/power-management/setup-battery-management.sh` | [README](scripts/plugins/power-management/README.md) |
| `brightness` | Perceptual brightness | `scripts/fixes/fix-optimized-brightness.sh` | [README](scripts/fixes/display-fixes.md) |
| `keyboard-backlight` | Keyboard backlight toggle + Trigger entry | `scripts/fixes/fix-keyboard-backlight-menu.sh` | [README](scripts/fixes/display-fixes.md) |
| `keybindings` | `SUPER` keybindings (app launches + quick functions) in `bindings.lua` — managed from the TUI (Setup ▸ keybindings) | the mosquitOmarchy TUI (+ `scripts/lib/keybindings.bash`) | [section](#keybindings-managed-by-the-mosquitomarchy-tui) |
| `mx-master` | MX Master (any model): thumb gesture button → `SUPER`, momentary (logiops system service) | `scripts/fixes/fix-mx-master.sh` | [README](scripts/fixes/fix-mx-master.md) |

**MX Master pointer/scroll specifics** (written by the fix, per-DEVICE, never touches the touchpad): `dpi 1000` · `smartshift → off` (the auto free-wheel mode was the erratic, continuous scroll bug on Hyprland) · `hiresscroll → off` (logiops+libinput WHEEL-state double-scroll on Hyprland, PixlOne #523 / #442) · `sensitivity 0.0, accel flat` (the old 1.0 = max-libinput-speed crawl) · `scroll_method "notch", scroll_factor 1.0` (the default factor was INVERTED: -1.00). Override any value with env vars `MX_MASTER_SENSITIVITY`, `MX_MASTER_DPI`, `MX_MASTER_SCROLL_FACTOR` before running the fix.
| `superfile` | SuperFile as the default file manager (+ optional FileChooser portal override) | `scripts/apps/superfile/setup-superfile.sh` | [README](scripts/apps/superfile/README.md) |
| `keepassxc` | KeePassXC as the system Secret Service — **replaces gnome-keyring completely** (keyring secrets must be migrated manually; package removal optional & asked) | `scripts/apps/keepassxc/setup-keepassxc-integration.sh` | [README](scripts/apps/keepassxc/README.md) |
| `touchpad` | Acceleration + touchpad sensitivity (mouse untouched) | `scripts/fixes/fix-touchpad.sh` | [README](scripts/fixes/fix-touchpad.md) |

**Touchpad + MX Master together** — they compose, they don't collide: each fix ships its own `hl.device` block in its own file, with independent `require`s, and both take care of ONLY their own device (the pad and its sensitivity, the mouse with its own sensitivity). Apply them in any order (or only one); any other mouse can reuse the same pattern — copy a fix script, adjust the name/values. See [scripts/fixes/fix-touchpad.md](scripts/fixes/fix-touchpad.md#together-touchpad--mx-master-or-any-mouse).
| `zen` | Zen Browser config — seed plugins (XPI), extension settings + chrome theme deployed into the active profile | `scripts/apps/zen/setup-zen.sh` | [README](scripts/apps/zen/README.md) |

**Maintenance**

| Module | What it does | Script called | Documentation |
|---|---|---|---|
| `mosquitomarchy-update` | Update watchdog: scripts repo check first, then pending Omarchy updates + opencode conflict review | `scripts/mosquitomarchy-update/setup-mosquitomarchy-update.sh` | [README](scripts/mosquitomarchy-update/README.md) |

A module marked `—` in `--status` is not applicable on this machine (e.g. VM without a VM installed).

### Backup / restore (integrated)

Each backup is a dated file `~/omarchy-backups/omarchy-backup-<timestamp>.tar.gz`. Contents: config (`~/.config/hypr`, `REAPER`, `windows`, `opencode`, Omarchy bar/plugins, `yabridgectl`, Zen active-profile plugins/settings/chrome, omagrab binary+config, and — when KeePassXC is installed — its settings + the `Passwords.kdbx` database), package lists (`pkglist.txt`/`aurlist.txt`), `apps.selected` (reinstalled by `setup-apps.sh`), `RESTORE.md`, and optional VST plugins:

On `--backup` the archive is then **encrypted in place** with an AES-256
passphrase (gpg — same cipher as LUKS, file level, no sudo): the plain
`.tar.gz` is replaced by `omarchy-backup-<timestamp>.tar.gz.gpg`. The
passphrase is asked via the **gum TUI** (`ask_passphrase`, hidden input, twice)
or the raw terminal if gum is missing; non-interactive runs use
`OMARCHY_BACKUP_PASSPHRASE`. `--list` flags encrypted backups, and `--restore`
asks for the same passphrase before applying (never reuses the shell history
or argv — gpg reads it via stdin).

| Mode | Content |
|---|---|
| `full` | `plugins/plugins-vst.tar.gz` complete (several GB) |
| `list` (default) | `plugins/manifest.txt`: inventory + yabridgectl config |
| `none` | nothing |

On restore, the battery plugins (`custom.power`, `mosquito.indicators`, `mosquito.confirm`) are **excluded** from the config and recreated by the `battery` module (no old frozen copies).

On restore, the **module dependencies are checked automatically**: any `deps` file under `scripts/` (one official package per line, `#` = comment) is read and the orchestrator installs whatever is missing (`sudo pacman -S --needed`) — module-specific ones live inside their own module folder (e.g. `scripts/apps/zen/deps`: `zen-browser-bin`), while `scripts/deps` groups deps for things with no module folder of their own (currently just omagrab: `yt-dlp`, `ffmpeg`, `wl-clipboard` — the user's own external tool, only backed up/restored here, never installed by a module script).

### Uninstall (integrated)

`--uninstall` goes through each module individually (interactive chooser, or `-y` for all). It removes `~/.local/bin` wrappers, menu entries, `omarchy-menu.jsonc` blocks, user systemd units, custom Omarchy plugins, Hyprland bindings, the Achraff theme. **Personal data** (`~/VST`, `~/.config/windows`, `~/.ollama`) is **preserved** by default — add `--purge` to delete it too.

Each uninstalled module is **remembered** (`~/.local/state/omarchy-custom-scripts/excluded`): the master will no longer re-propose it — re-offer with `./mosquitomarchy-setup.sh --include=<mod>`.

> System parts (packages, sudoers, udev, `bitwig.jar`, helpers in `/usr/local/bin`) require sudo: re-run `sudo bash ./mosquitomarchy-setup.sh --uninstall -y` to remove them too.

### Repo updates

**How it works** — `mosquitomarchy-setup.sh` embeds an "update zone": every time it is launched (whatever the command) and once per boot (via the `mosquitomarchy-update` hook, checked *before* pending Omarchy updates), it compares the local git `HEAD` to the GitHub `HEAD` (`git ls-remote`). If GitHub is ahead, it offers a fast-forward `git pull` — and, once pulled, `--update` re-applies every module in its latest form.

**The update is strictly a `git pull --ff-only`** — it never runs `git clean`, `reset --hard` or `rebase`, so anything that lives next to the scripts and is **not tracked by the repository** is never touched or deleted by an update.

**How the owner makes updates available** — nobody edits the scripts locally; the **owner**'s GitHub repo is the single source of truth:

1. The owner commits and pushes as soon as a module changes.
2. Every machine picks up the change on its own, via the update-zone check above — at the next boot or the next manual run, no announcement needed.
3. In an emergency, a user can self-update immediately with `./mosquitomarchy-setup.sh --update-repo` (fast-forward only), but the **recommended** path is to wait for the owner's push rather than pulling ahead of it.

---

## archive-mosquitomarchy.sh

On launch you choose among two archive types (or `--type=`):

| Type | Content |
|---|---|
| `print` | **Full personal archive**: repo + the dated config backups (`~/omarchy-backups/`) |
| `release` | Everything except logs and backup files — the "clean" archive |

Always excluded (whatever the type): logs, `.venv`, Git history, previous archives. **Large installers** (Ableton zips/`.run`, Guitar Pro `.exe`, DaVinci zips) are embedded **automatically** in `print` archives (they are the personal backup of the installers), and **offered** (never forced) for the `release` archives. The file name embeds the type: `omarchy-scripts-print-<date>.tar.gz`, `omarchy-scripts-release-<date>.tar.gz`.

```bash
./archive-mosquitomarchy.sh                 # interactive: type → heavy installers → tar.gz
./archive-mosquitomarchy.sh -y              # defaults: type 'print', all heavy installers embedded
./archive-mosquitomarchy.sh --type=release  # non-interactive: "clean" release (no backups)
./archive-mosquitomarchy.sh --with-ableton --with-davinci
./archive-mosquitomarchy.sh --list-heavy    # list the detected heavy files
./archive-mosquitomarchy.sh --no-backups    # print only: skip the config backups
```

---

## Keybindings (managed by the mosquitOmarchy TUI)

There is no external keybindings script anymore: the manager is PART of the mosquitOmarchy TUI (Setup ▸ keybindings). It manages the `SUPER` bindings of this package (app launches + quick functions) directly in `~/.config/hypr/bindings.lua`, inside a single reversible marker block (`-- >>> Omarchy_Custom_Scripts_Keys` … `-- <<< …`). The screen shows the managed bindings as tab-selectable rows, category options to add one (package app / quick function / Ableton Move / custom command — Enter binds and proposes a Hyprland reload to validate the config), and removal of the ticked bindings with Enter (confirm). The Uninstall ▸ keybindings flavor opens the list directly, adds a Reset row (wipes EVERY binding managed by mosquitOmarchy — precise confirmation), and its tab selection persists: a global uninstall run removes the ticked bindings too. The primitives live in `scripts/lib/keybindings.bash` (`kb-list`, `kb-add`, `kb-remove`, `kb-reset`, `kb-reload`, `kb-free` subcommands of `mosquitomarchy-actions`).

All the keybindings created by this package live in ONE block of `~/.config/hypr/bindings.lua`; removing the whole block (the Reset row) restores Omarchy's defaults. When a chosen key is an Omarchy **default** binding it is unbound first (with a comment explaining what it replaced) — the same `hl.unbind` + `o.bind` pattern used by `setup-optimized-brightness.sh`.

Quick functions catalog includes the package helpers already installed on the system: `backlight` (max / min), `ultra-save toggle`, `mega-caffeine`. Apps get a `{ launch = "…" }` binding; functions a `{ locked = true, repeating = true }` command binding.

---

## Recommended execution order (new machine)

```bash
git clone https://github.com/kepalegars/mosquitOmarchy ~/mosquitOmarchy && cd ~/mosquitOmarchy
./scripts/bootstrap.sh --zips -y          # downloads large files + auto setup
```

Then, manually (also shown in the final report):

1. `omarchy-windows-vm install` if the VM did not exist, then inside the VM: `\\host.lan\Data\install.bat`
2. Install Windows plugins — either for Linux DAWs (Bitwig/REAPER via yabridge, the shared VST root — `~/Music/Audio Plugins`, legacy `~/VST`) or in wine prefixes. With Ableton Linux, plugins in the shared root are **shared**: one install = visible everywhere
3. `./scripts/apps/audio-plugin-manager/setup-audio-stack.sh --tweaks` after each new plugin
4. Reconnect if the `realtime` group was just joined; iLok licenses to activate per wine prefix
5. Ableton Linux: first ASIO/PipeASIO config (Settings > Audio)