# `code/modules/Fixes`

Small, idempotent machine-level repairs. Re-running one re-applies it, which is the point:
an Omarchy update that overwrites `hyprland.lua` or `bindings.lua` is repaired by running the
fix again, not by diffing by hand.

## Fixes

These are the entries of the orchestrator's `FIXES` array — offered at setup and under
**Setup → Fixes** in the TUI, and runnable directly with `bash code/modules/Fixes/<script>.sh`.
They are **system workarounds**: each restores a broken or regressed state (a recovery, or a
workaround for a bug in some component), so run them when something does not work the way it
should. Preferences live next door, in `code/modules/Tweaks/` (see its README).

| id | Script | What it fixes |
|---|---|---|
| `omarchy-menu` | `fix-omarchy-menu.sh` | A broken menu — blank rows, empty Apps list — caused by a user-space clone of `omarchy.menu`. Removes the clones, re-enables the stock menu, restarts the shell. |
| `hyprland-crash` | `fix-hyprland-crash.sh` | The "desktop came up broken" case: a truncated or fragmented `hyprland.lua` is restored from the newest valid backup, fatal Lua escapes are normalized, the keyboard layout and shell are re-armed. Installs a post-boot hook so it also self-heals at every boot. |
| `quickshell-bar` | `fix-quickshell-bar.sh` | The Omarchy bar is empty or gone: `shell.json` (bar layout + widget settings) is restored from the newest valid backup — a local `shell.json.*.bak` or a mosquitomarchy backup archive — with widgets this machine does not have dropped, then the shell is restarted. Does nothing while the bar is up; `--force` restores anyway. |
| `1px-seam` | `fix-1px-seam.sh` | A hair-thin transparent line flashing between the bar and a window in borderless or no-gaps tiling: the blur is switched to its legacy path. Only useful with blur on. `--remove` reverts. |
| `ableton-fullscreen` | `fix-ableton-fullscreen.sh` | Ableton's Full Screen mode is shifted, so the content sits off where you click. Launches Live with `WINE_WIN32_FULLSCREEN_CLASS=off`. `--remove` reverts. |
| `bluetooth` | `fix-bluetooth.sh` | Bluetooth stutter/instability: MX Master micro-freezes (BLE `Latency=44` → `0`, interval 6–7; USB autosuspend off on the controller **and** its parent hub) and A2DP reconnect spam (`ReconnectUUIDs=` + `ReconnectAttempts=0`). Writes ConnectionParameters **before** restarting bluetoothd so the daemon actually loads them. Also auto-invoked by the `mx-master` module when the mouse is on Bluetooth. `--remove` reverts. |
| `hyprland-autofocus` | `fix-hyprland-autofocus.sh` | Smart focus: a background app no longer steals focus (neither on map nor on activation request), while a dialog opened by the app you are already using still takes it (same PID, or same non-empty class). Pointer-follow stays at Omarchy's default (hovering still focuses), and focusing never warps the pointer to the window centre. `--remove` restores the previous behaviour. |
| `chromium-google-api-key` | `fix-chromium-google-api-key.sh` | Omarchy's unbranded Chromium shows a permanent "Google API keys are missing" infobar in the browser and in every `--app` webapp. Sets a dummy `GOOGLE_API_KEY` in `~/.config/environment.d/` so Chromium considers a key configured; no Google service is actually enabled. Logout/login is required for GUI apps to inherit it. `--remove` restores the previous state. |

## Modules

These are real orchestrator modules, not quick fixes: they have their own `run_*` and appear
in `--status` and under **Setup → Plugins**.

| Module | Script | Doc |
|---|---|---|
| `brightness` | `code/modules/Plugins/brightness/optimized-brightness.sh` | Omarchy default brightness plus 0% screen-off and a 1% hold ramp. Deploys a `brightness-0` helper. [notes](../Plugins/brightness/display-fixes.md) |
| `mx-master` | `code/modules/Plugins/mx-master/mx-master.sh` | Thumb button → `SUPER` via logiops, plus a mouse-only pointer block. [notes](../Plugins/mx-master/mx-master.md) |
| `touchpad` | `code/modules/Plugins/touchpad/touchpad.sh` | Touchpad-only `hl.device` tuning. [notes](../Plugins/touchpad/touchpad.md) |

`touchpad` and `mx-master` compose: each ships its own `hl.device` block in its own file, each
handles only its own device, and they can be applied in either order or alone. Every value the
MX Master fix writes can be overridden with `MX_MASTER_SENSITIVITY`, `MX_MASTER_DPI` and
`MX_MASTER_SCROLL_FACTOR` before running it.

## Invoked by a module, not offered on its own

The DAW Wine-runtime installer lives in `code/lib/daw-wine-runtime-install.sh`; it installs
the `wine-d2d1-nspa` runtime wrappers that let REAPER and Bitwig share Ableton's Wine build. It
is pointed at by the audio and REAPER setups when the runtime is missing, rather than being
listed here to pick from.

## Notes

- The brightness source is now `code/modules/Plugins/brightness/optimized-brightness.sh`;
  it deploys `~/.local/bin/brightness-0`, not `~/.local/bin/backlight`.
- A fix absent from the `FIXES` array is opt-in by design, and stays out of the automatic pass.
