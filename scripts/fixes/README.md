# `scripts/fixes`

Small, idempotent machine-level repairs. Re-running one re-applies it, which is the point:
an Omarchy update that overwrites `hyprland.lua` or `bindings.lua` is repaired by running the
fix again, not by diffing by hand.

## Fixes

These are the entries of the orchestrator's `FIXES` array — offered at setup and under
**Setup → Fixes** in the TUI, and runnable directly with `bash scripts/fixes/<script>.sh`.
They are **system workarounds**: each restores a broken or regressed state (a recovery, or a
workaround for a bug in some component), so run them when something does not work the way it
should. Preferences live next door, in `scripts/tweaks/` (see its README).

| id | Script | What it fixes |
|---|---|---|
| `omarchy-menu` | `fix-omarchy-menu.sh` | A broken menu — blank rows, empty Apps list — caused by a user-space clone of `omarchy.menu`. Removes the clones, re-enables the stock menu, restarts the shell. |
| `hyprland-crash` | `fix-hyprland-crash.sh` | The "desktop came up broken" case: a truncated or fragmented `hyprland.lua` is restored from the newest valid backup, fatal Lua escapes are normalized, the keyboard layout and shell are re-armed. Installs a post-boot hook so it also self-heals at every boot. |
| `ableton-wine-scroll` | `fix-wine-scroll.sh` | While Ableton is open under Wine, the patched build's optional pointer features create an XInput2 implicit grab that **freezes the trackpad in other apps**. Disables those features in the prefix's registry — the persistent form of upstream's `WINE_X11_POINTER_FEATURES=disabled`. `--remove` reverts. |
| `1px-seam` | `fix-1px-seam.sh` | A hair-thin transparent line flashing between the bar and a window in borderless or no-gaps tiling: the blur is switched to its legacy path. Only useful with blur on. `--remove` reverts. |
| `ableton-fullscreen` | `fix-ableton-fullscreen.sh` | Ableton's Full Screen mode is shifted, so the content sits off where you click. Launches Live with `WINE_WIN32_FULLSCREEN_CLASS=off`. `--remove` reverts. |
| `omarchy-bar` | `fix-omarchy-bar.sh` | The Omarchy toolbar disappeared — toggled off or slid off-screen. Clears the bar-off toggle and re-syncs the shell; if the bar stays parked past the monitor edge, restarts the shell as a last resort. Also re-applies the clock centring (`../tweaks/tweak-bar-clock-centring.sh`) so revealed indicators stop shoving the clock sideways. |

## Modules

These are real orchestrator modules, not quick fixes: they have their own `run_*` and appear
in `--status` and under **Setup → Plugins**.

| Module | Script | Doc |
|---|---|---|
| `brightness` | `scripts/plugins/brightness/optimized-brightness.sh` | Omarchy default brightness plus 0% screen-off and a 1% hold ramp. Deploys a `brightness-0` helper. [notes](display-fixes.md) |
| `mx-master` | `fix-mx-master.sh` | Thumb button → `SUPER` via logiops, plus a mouse-only pointer block. [notes](fix-mx-master.md) |
| `touchpad` | `scripts/plugins/touchpad/touchpad.sh` | Touchpad-only `hl.device` tuning. [notes](fix-touchpad.md) |

`touchpad` and `mx-master` compose: each ships its own `hl.device` block in its own file, each
handles only its own device, and they can be applied in either order or alone. Every value the
MX Master fix writes can be overridden with `MX_MASTER_SENSITIVITY`, `MX_MASTER_DPI` and
`MX_MASTER_SCROLL_FACTOR` before running it.

## Invoked by a module, not offered on its own

`fix-daw-wine-runtime.sh` installs the `wine-d2d1-nspa` runtime wrappers that let REAPER and
Bitwig share Ableton's Wine build. It is pointed at by the audio and REAPER setups when the
runtime is missing, rather than being listed here to pick from.

## Notes

- The brightness source is now `scripts/plugins/brightness/optimized-brightness.sh`;
  it deploys `~/.local/bin/brightness-0`, not `~/.local/bin/backlight`.
- A fix absent from the `FIXES` array is opt-in by design, and stays out of the automatic pass.
