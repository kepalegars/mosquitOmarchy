# `scripts/` — mosquitOmarchy modules and helpers

This folder holds everything except the two root orchestrators (`setup-customarchy.sh`, `archive-customarchy.sh`) and the repo meta files.

Unlike the other modules, the apps are grouped under `apps/` (one folder per app + shared helpers), with one `apps/README.md` for the whole group; the modules each bring their own `README.md`.

## Folder layout

| Entry | What it is |
|---|---|
| `apps/` | "apps" module : `setup-apps.sh` dispatcher, the per-type installers (`gui/`, `tui-tools/`, `webapps/`) and one folder per bundled app (`ableton`, `bitwig`, `reaper`, `audio-plugin-manager`, `guitarpro`, `davinci`, `handbrake`, `zen`) + `download-assets.sh` |
| `apps/mosquitomarchy/` | the **mosquitOmarchy launcher TUI** (Go/Bubble Tea) : `mosquitomarchy` dispatcher + `tui-go/` + `mosquitomarchy-actions` backend — the recommended interface, see its [README](apps/mosquitomarchy/README.md) |
| `plugins/` | Omarchy shell plugins : `power-management/` (`battery` module), `jamjamjam/` (JamJamJam bar plugin), `live-mode/` |
| `lib/` | shared helpers : `tui-kit/` (Go/Bubble Tea component library) + `common.bash` + `crash.bash` (crash log + clickable AI diagnosis) + `elevate.bash` (`mq_sudo`: pkexec-first elevation, with a `/etc/shells`-safe `$SHELL`) |
| `LLM/` | `ollama` module — local AI (models, REAPER helpers, OpenCode commands) |
| `windows-vm/` | `windows-vm` module — VM launcher + winvm + OEM debloat |
| `omarchy-vm/` | `omarchy-vm` module — Omarchy ISO VM in QEMU/KVM + TUI + passthrough |
| `theme/` | `achraff` theme / `create-theme.sh` |
| `mosquitomarchy-update/` | update watchdog : scripts repo check first, then pending Omarchy updates |
| `fixes/` | idempotent fixes — keyring, Papers/Evince, brightness, keyboard backlight, touchpad, MX Master, menu, theme (`fix-*.sh`); proposed at `setup-customarchy.sh` startup |
| `bootstrap.sh` | one-command start (clone + setup + optional assets) — see the [root README](../README.md#one-command-start) |
| `lib/keybindings.bash` | `keybindings` module primitives — managed SUPER bindings (used by the mosquitOmarchy TUI + `mosquitomarchy-actions`) |
| `gui-run.bash` | shared helper : reopens a `setup-*.sh` launched from a file manager inside a terminal |

## Usage

Do **not** run these scripts individually for a fresh machine : use the orchestrator, which offers each module one by one and handles backup/restore + uninstall + repo update :

```bash
./setup-customarchy.sh                # at the repo root
```

The recommended interface is the **mosquitOmarchy TUI** (`scripts/apps/mosquitomarchy/`), which drives all of the above — status, update, setup, backup/restore — from one menu. Use `Setup → Menu entry` once to register it in the Omarchy launcher.

When a module is invoked directly (e.g. its tinker command), use its own `scripts/<module>/README.md`. Each script resolves its resources via its own directory, so the paths shown in the module READMEs work from inside the folder.

The module READMEs (in `mosquitomarchy-update/`, `plugins/power-management/`, `plugins/jamjamjam/`, `plugins/live-mode/`, `fixes/`, `windows-vm/`, `macos-vm/`, `omarchy-vm/`, `theme/`, `LLM/`, `apps/` and each `apps/<app>/`) are the reference for install commands, options and caveats — they are not duplicated here.

## Elevation (sudo) — one prompt per run

`lib/elevate.bash` is the single elevation helper (`mq_sudo`). mosquitOmarchy asks for the password **once per install/run**, never once per step:

1. `mq_sudo_prime` runs at the start of a module batch (`exec_modules`), a fix batch (`run_fixes`) and each uninstall. If `sudo -n -v` already works (NOPASSWD or a valid timestamp) it does nothing. Otherwise it starts a **persistent root helper** with a **single `pkexec`** — the native Omarchy polkit prompt (the nice one). `lib/mq-root-helper.sh` then executes every later root command of the run through a small FIFO protocol (the exact same commands `mq_sudo` would have run), so the whole run keeps **one** clean prompt.
2. Fallback when pkexec/polkit is unavailable: prime sudo's timestamp once through a GUI askpass (`zenity --password`, else `systemd-ask-password`), which works **without a tty**; the cache then serves the run and a background keep-alive refreshes it.
3. Last resort (no askpass, no agent): the historical **per-call `pkexec`** via a `sudo`→`pkexec` shim (with a `/etc/shells`-safe `$SHELL`).

**Install selection** primes once for the whole selection. Read-only queries (`status`, `setup`, `patches`, `missing-assets`, …) never elevate.

## Crash reporting (Omarchy-compatible)

Non-install scripts source `lib/crash.bash` and call `mq_crash_guard "<tool>"`. On failure they write **one dated log** into the repo-local `.local/crash-logs/` (never committed, never archived) and raise a **critical, clickable Omarchy notification** (`omarchy-notification-send --exec …`). Clicking it runs `scripts/apps/mosquitomarchy/mosquitomarchy-agent-crash`, which opens the default coding agent on the `mosquitomarchy-crash` skill with that exact log — the agent diagnoses and **proposes** fixes, applying nothing until confirmed. Install scripts (`setup-*.sh`) are exempt. The skill is symlinked into `~/.agents/skills/`, so any AI that reads skills discovers it.