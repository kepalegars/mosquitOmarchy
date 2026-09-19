# `scripts/` — mosquitOmarchy modules and helpers

This folder holds everything except the two root orchestrators (`setup-customarchy.sh`, `archive-customarchy.sh`) and the repo meta files.

Unlike the other modules, the apps are grouped under `apps/` (one folder per app + shared helpers), with one `apps/README.md` for the whole group; the modules each bring their own `README.md`.

## Folder layout

| Entry | What it is |
|---|---|
| `apps/` | "apps" module : `setup-apps.sh` dispatcher, the per-type installers (`gui/`, `tui-tools/`, `webapps/`) and one folder per bundled app (`ableton`, `bitwig`, `reaper`, `audio-plugin-manager`, `guitarpro`, `davinci`, `handbrake`, `zen`) + `download-assets.sh` |
| `apps/mosquitomarchy/` | the **mosquitOmarchy launcher TUI** (Go/Bubble Tea) : `mosquitomarchy` dispatcher + `tui-go/` + `mosquitomarchy-actions` backend — the recommended interface, see its [README](apps/mosquitomarchy/README.md) |
| `plugins/` | Omarchy shell plugins : `power-management/` (`battery` module), `jamjamjam/` (JamJamJam bar plugin), `live-mode/` |
| `lib/` | shared helpers : `tui-kit/` (Go/Bubble Tea component library) + `common.bash` |
| `LLM/` | `ollama` module — local AI (models, REAPER helpers, OpenCode commands) |
| `windows-vm/` | `windows-vm` module — VM launcher + winvm + OEM debloat |
| `omarchy-vm/` | `omarchy-vm` module — Omarchy ISO VM in QEMU/KVM + TUI + passthrough |
| `theme/` | `achraff` theme / `create-theme.sh` |
| `mosquitomarchy-update/` | update watchdog : scripts repo check first, then pending Omarchy updates |
| `fixes/` | idempotent fixes — keyring, Papers/Evince, brightness, keyboard backlight, touchpad, MX Master, menu, theme (`fix-*.sh`); proposed at `setup-customarchy.sh` startup |
| `bootstrap.sh` | one-command start (clone + setup + optional assets) — see the [root README](../README.md#one-command-start) |
| `setup-keybindings.sh` | `keybindings` module — SUPER keybindings manager |
| `gui-run.bash` | shared helper : reopens a `setup-*.sh` launched from a file manager inside a terminal |

## Usage

Do **not** run these scripts individually for a fresh machine : use the orchestrator, which offers each module one by one and handles backup/restore + uninstall + repo update :

```bash
./setup-customarchy.sh                # at the repo root
```

The recommended interface is the **mosquitOmarchy TUI** (`scripts/apps/mosquitomarchy/`), which drives all of the above — status, update, setup, backup/restore — from one menu. Use `Setup → Menu entry` once to register it in the Omarchy launcher.

When a module is invoked directly (e.g. its tinker command), use its own `scripts/<module>/README.md`. Each script resolves its resources via its own directory, so the paths shown in the module READMEs work from inside the folder.

The module READMEs (in `mosquitomarchy-update/`, `plugins/power-management/`, `plugins/jamjamjam/`, `plugins/live-mode/`, `fixes/`, `windows-vm/`, `macos-vm/`, `omarchy-vm/`, `theme/`, `LLM/`, `apps/` and each `apps/<app>/`) are the reference for install commands, options and caveats — they are not duplicated here.