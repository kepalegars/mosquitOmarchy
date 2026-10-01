# REAPER

Installs REAPER, adds a `reaper-launch` wrapper, and adds a menu shortcut. Its real work is the
Hyprland window rules: the main window tiles, and **every other REAPER window floats** — the
preferences dialog, save confirmations, the Media Explorer, anything — centered on the monitor,
fully opaque, no blur, and exempt from Omarchy's global opacity.

The exceptions are deliberate: REAPER's own popup menus (File, Edit, right-click) and its
tooltips are left wherever REAPER puts them rather than being yanked to the center, because
forcing those to center makes them unusable.

All rules live in `~/.config/hypr/hyprland.lua`.

## Running it

Launches on Hyprland's **native XWayland**, with auto-DPI disabled — it relies on Omarchy's
global `xwayland.force_zero_scaling` plus `ui_scale_auto=0`, otherwise the UI comes out giant
and blurry.

`xwayland-satellite` was used previously for isolation and then dropped: it has no XDND bridge,
so drag & drop did not work, and it relays the X11 window class late, which caused float and
opacity glitches.

> Drag & drop from another app into REAPER is still unreliable, and that is REAPER's own
> Linux/SWELL port rather than a compositor issue. Use the Media Explorer or
> **Insert ▸ Media File** instead.

## Plugin folders

For REAPER to see what the audio plugin manager manages, `~/.config/REAPER/reaper.ini` needs the
yabridge chainloaders:

```
vstpath=~/.vst
vst3path=…~/.vst3…
clappath=~/.clap
```

Those are the `.so` stubs `yabridgectl` writes, not the raw `.dll` bundles. The audio plugin
manager's first-launch wizard adds these automatically, and the audio stack's step 2 sets the
matching environment variables.

## Install

```bash
scripts/apps/reaper/setup-reaper.sh
```

Then launch REAPER from the launcher.
