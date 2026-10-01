# `scripts/fixes`

Small, idempotent machine-level repairs. Re-running one re-applies it, which is the point:
an Omarchy update that overwrites `hyprland.lua` or `bindings.lua` is repaired by running the
fix again, not by diffing by hand.

## Quick fixes

These are the entries of the orchestrator's `FIXES` array — offered at setup and under
**Setup → Quick fixes** in the TUI, and runnable directly with `bash scripts/fixes/<script>.sh`.

| id | Script | What it fixes |
|---|---|---|
| `keepassxc-window` | `fix-keepassxc-window.sh` | The KeePassXC window floats and centers in Hyprland instead of misbehaving when tiled. Idempotent marked block in `hyprland.lua`, matching both the native app-id and the XWayland class. |
| `tui-theme` | `fix-tui-theme.sh` | Regenerates the Omarchy palette and rebuilds every Go TUI so their colours follow the **active** theme. The dynamic palette re-read already ships in `tui-kit`; this forces it. |
| `omarchy-menu` | `fix-omarchy-menu.sh` | A broken menu — blank rows, empty Apps list — caused by a user-space clone of `omarchy.menu`. Removes the clones, re-enables the stock menu, restarts the shell. |
| `hyprland-crash` | `fix-hyprland-crash.sh` | The "desktop came up broken" case: a truncated or fragmented `hyprland.lua` is restored from the newest valid backup, fatal Lua escapes are normalized, the keyboard layout and shell are re-armed. Installs a post-boot hook so it also self-heals at every boot. |
| `ableton-wine-scroll` | `fix-wine-scroll.sh` | While Ableton is open under Wine, the patched build's optional pointer features create an XInput2 implicit grab that **freezes the trackpad in other apps**. Disables those features in the prefix's registry — the persistent form of upstream's `WINE_X11_POINTER_FEATURES=disabled`. `--remove` reverts. |
| `1px-seam` | `fix-1px-seam.sh` | A hair-thin transparent line flashing between the bar and a window in borderless or no-gaps tiling: the blur is switched to its legacy path. Only useful with blur on. `--remove` reverts. |
| `ableton-fullscreen` | `fix-ableton-fullscreen.sh` | Ableton's Full Screen mode is shifted, so the content sits off where you click. Launches Live with `WINE_WIN32_FULLSCREEN_CLASS=off`. `--remove` reverts. |
| `omarchy-bar` | `fix-omarchy-bar.sh` | The Omarchy toolbar disappeared — toggled off or slid off-screen. Clears the bar-off toggle and re-syncs the shell. |
| `wine-menu` | `fix-wine-menu.sh` | `Uninstall` / `Manual` entries cluttering the launcher: a Windows installer wrote Start-Menu shortcuts into its prefix and Wine republished each as an app entry. Removes the ones belonging to prefixes mosquitOmarchy manages, plus the empty publisher folders, and refreshes the desktop database. `--all-prefixes` widens it; the `NoDisplay` file associations are never touched. Also applied at the end of the audio plugin manager, the audio stack and the Guitar Pro setup. |
| `terminal-padding` | `fix-terminal-padding.sh` | Omarchy pads every terminal by 14px and paints that padding with the theme background, so on a dark theme the text block reads as a dark slab inside a light window. Keeps the padding but makes it take the terminal's own background. `--remove` reverts. |

## Modules

These are real orchestrator modules, not quick fixes: they have their own `run_*` and appear
in `--status` and under **Setup → Plugins**.

| Module | Script | Doc |
|---|---|---|
| `brightness` | `fix-optimized-brightness.sh` | Perceptual brightness, where 0% really means off via DPMS. Deploys a `backlight` helper. [notes](display-fixes.md) |
| `mx-master` | `fix-mx-master.sh` | Thumb button → `SUPER` via logiops, plus a mouse-only pointer block. [notes](fix-mx-master.md) |
| `touchpad` | `fix-touchpad.sh` | Touchpad-only `hl.device` tuning. [notes](fix-touchpad.md) |

`touchpad` and `mx-master` compose: each ships its own `hl.device` block in its own file, each
handles only its own device, and they can be applied in either order or alone. Every value the
MX Master fix writes can be overridden with `MX_MASTER_SENSITIVITY`, `MX_MASTER_DPI` and
`MX_MASTER_SCROLL_FACTOR` before running it.

## Invoked by a module, not offered on its own

`fix-daw-wine-runtime.sh` installs the `wine-d2d1-nspa` runtime wrappers that let REAPER and
Bitwig share Ableton's Wine build. It is pointed at by the audio and REAPER setups when the
runtime is missing, rather than being listed here to pick from.

## Opt-in only

`fix-replace-evince-with-papers.sh` swaps the system document viewer for Papers. It is
deliberately **not** a quick fix and never offered automatically: changing the default PDF
handler is a system-wide decision. `--status` and `--uninstall` are supported, and Evince
stays installed as an invisible backend so previews keep working.

## Notes

- `backlight` in this folder is the **source** of the deployed `~/.local/bin/backlight`
  helper, not a directory.
- A fix absent from the `FIXES` array is opt-in by design, and stays out of the automatic pass.
