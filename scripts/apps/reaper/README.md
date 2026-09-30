# REAPER — Omarchy module

Launches REAPER directly on Hyprland's native Xwayland, disables auto DPI (giant/blurry UI, relies on Omarchy's global `xwayland.force_zero_scaling` + `ui_scale_auto=0`). Main window tiled ; every other REAPER window (prefs, save confirmation, media explorer, any dialog) floating, centered on the monitor, fully opaque, no blur, exempt from the global Omarchy opacity -- except REAPER's own popup menus (File/Edit/right-click) and tooltips, which are left wherever REAPER puts them instead of being forced to the center (rules in `~/.config/hypr/hyprland.lua`). Installs `reaper`, creates the `~/.local/bin/reaper-launch` wrapper and the menu shortcut.

Previously used `xwayland-satellite` for isolation, but it has no XDND (drag & drop) bridge and relays the X11 window class late, which caused float/opacity glitches -- dropped in favor of native Xwayland. Drag & drop from external apps into REAPER is still unreliable regardless (REAPER's own Linux/SWELL port, not a compositor issue) -- use REAPER's Media Explorer / Insert Media File instead.

## Usage

```bash
./apps/reaper/setup-reaper.sh        # then launch REAPER from the launcher
```