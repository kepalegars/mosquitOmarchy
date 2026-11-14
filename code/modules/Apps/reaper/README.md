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
code/modules/Apps/reaper/setup-reaper.sh
```

Then launch REAPER from the launcher.

## Reapertips theme + custom config (C in Setup)

With the cursor on the REAPER row in **Setup**, press **C** (`C custom config` appears
in the shortcut bar). It offers two fonts and, by default, uses Omarchy's current
system font:

- installs LSP plugins (VST2/VST3/CLAP/LV2) when they are missing;
- installs the **Reapertips** theme (dark or light, following Omarchy),
  recoloured to Omarchy's accent;
- installs the purple toolbar icons (100/150/200%) and the REAPER 7 splash;
- installs `libSwell-user.colortheme` so the native Linux menus follow the accent too;
- applies `code/modules/Apps/reaper/configs/custom/` over the REAPER resource path.

In **Uninstall**, the same key shows `C restore config` and undoes the visual
part: the REAPER config (including the theme selection) comes back as it was
when C was run in Setup, and the generated theme, purple toolbar icons, splash
and window colours are removed. Scripts, plugins, JSFX, ReaPacks, SWS and LSP
plugins are **never** removed by this.

Before restoring, the config REAPER has at that moment is copied to
`backups/<date>-before-restore/`; install-time backups are in
`backups/<date>-install/` (both inside this module, git-ignored).

The LSP step needs the network but is non-fatal: if `pacman` cannot reach the
repos, the theme is still installed.

### Theme source

Download the free theme from
<https://www.reapertips.com/products/reapertips-theme>, drop
`Reapertips Theme v*.zip` in `~/Downloads`, and run `./bootstrap.sh` once: it
moves the newest archive into `code/modules/Apps/reaper/configs/` (never
overwriting). The installer picks the newest archive there, reads the Purple and
Light variations, and works only from what it extracts — no hardcoded
external-disk path.

As with every other archive this repo does not ship (Ableton, DaVinci,
Spektrafilm, Guitar Pro, Bitwig…), download it **before** the bootstrap so it is
filed away in the same pass and the REAPER config works immediately. Downloading
it later is fine, just re-run the bootstrap. The archive is git-ignored.

### Custom config

`configs/custom/` mirrors the REAPER resource path (`~/.config/REAPER`), so:

```
configs/custom/Scripts/...        -> ~/.config/REAPER/Scripts/...
configs/custom/Effects/...        -> ~/.config/REAPER/Effects/...
configs/custom/UserPlugins/...    -> ~/.config/REAPER/UserPlugins/...
configs/custom/reaper.ini         -> ~/.config/REAPER/reaper.ini
```

`Scripts/`, `Effects/` and `UserPlugins/` are there for ReaScripts, JSFX and
native extensions (SWS, ReaPack). `configs/README.md` lists the recommended SWS /
ReaPack add-ons with their download links.

Anything else — plugins, scripts, templates, settings — goes in the same tree at
the path REAPER uses. It replaces the current files, and **every file it
overwrites is backed up first** to `backups/<date>-install/` (inside this
module, git-ignored). The Setup prompt says this before anything runs.

The custom config is copied, never tracked for undo: `C` in Uninstall leaves
every script, JSFX, plugin, ReaPack and SWS file in place. The backup folder is
there if you want to restore one by hand.

**This folder is shipped with the repo.** If the config prepared here is a
personal one, it must still be committed and delivered with the rest of the repo
on GitHub — files left only on one machine never reach the user. Anything
private (licences, tokens) does not belong in it.

### Accent colour, dark/light and fonts

REAPER has no launch flag or global accent setting: theme colours are baked into
the `.ReaperThemeZip`, and there is no upstream "follow the desktop theme" hook
(the community tools — Theme Replacer, theme-tweak windows — are editors, not
dynamic sync). The workable path is to regenerate the theme from an untouched
base before REAPER starts, which is exactly what `reaper-theme-sync` does:

- `omarchy-theme-color accent` → replaces the theme's own accents (`#ff92af`
  purple, `#feb946` light) and the libSwell accent (`#d1a660`);
- `omarchy-theme-color mode` → picks the Reapertips **Light** or **Purple** base,
  so switching Omarchy between dark and light switches REAPER on next launch;
- `omarchy-font-current` → rewrites the theme's font blobs and
  `default_font_face` when "System fonts" was chosen.

It always starts from the archive copy kept in `~/.config/REAPER/.mosquitomarchy/`
and is called by `reaper-launch` before every start, so Omarchy theme changes are
picked up without re-running Setup. While REAPER is already running, reload the
theme in REAPER (or restart) to see the new colours.
