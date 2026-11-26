# `custom/` — the REAPER config this repo ships

Mirrors REAPER's resource path (`~/.config/REAPER`). Setup ▸ REAPER ▸ **P**
copies this tree over it, after backing up every file it replaces to
`code/modules/Apps/reaper/backups/<date>-install/`.

Uninstall ▸ **P** restores the REAPER config (the install-time backup) and
removes the theme assets, but leaves every file copied from here in place:
scripts, JSFX, plugins, ReaPacks and SWS files are never removed. The backup
folder is there if you want to restore one of them by hand.

```
Scripts/                  ReaScripts (.lua/.eel)          -> ~/.config/REAPER/Scripts/
Effects/                  JSFX (.jsfx)                    -> ~/.config/REAPER/Effects/
UserPlugins/              native extensions (reaper_*.so) -> ~/.config/REAPER/UserPlugins/
FXChains/                 FX chain files                  -> ~/.config/REAPER/FXChains/
TrackTemplates/           track templates                 -> ~/.config/REAPER/TrackTemplates/
reaper.ini                global settings + layouts        -> ~/.config/REAPER/reaper.ini
reaper-themeconfig.ini    Theme Adjuster colours/layout    -> ~/.config/REAPER/reaper-themeconfig.ini
reaper-extstate.ini       Theme Adjuster v6/v7 UI state    -> ~/.config/REAPER/reaper-extstate.ini
reaper-kb.ini             custom actions (SCR/KEY)         -> ~/.config/REAPER/reaper-kb.ini
reapack.ini               ReaPack repositories             -> ~/.config/REAPER/reapack.ini
Scripts/                  Lua scripts + __startup.lua      -> ~/.config/REAPER/Scripts/
Effects/                  JSFX + .jsfx-inc deps            -> ~/.config/REAPER/Effects/
FXChains/, TrackTemplates/ exported chains/templates       -> ~/.config/REAPER/...
```

The three `.ini` files are a snapshot of a tuned REAPER install: `reaper.ini`
holds the global settings, `reaper-themeconfig.ini` the Reapertips / Default
Theme Adjuster values, and `reaper-extstate.ini` the Theme Adjuster windows for
Default 6.0 and Default 7.0. `lastthemefn5` and `splashimage` are left out: the
installer writes them with this machine's real paths.

Extra folders are copied exactly where they sit (`custom/<path>` →
`~/.config/REAPER/<path>`), so anything REAPER uses can be added. `.gitkeep`
and `README.md` files are repo bookkeeping and are not installed.

**Theme archive:** for the complete config, put the latest
`Reapertips Theme v*.zip` in `~/Downloads`. The config action copies it into
`../` (`code/modules/Apps/reaper/configs/`) itself — no bootstrap needed. You
can also copy the zip there yourself. It is not shipped with the repo.

This folder is committed: if you build a personal config here, ship it with the
rest of the repo — files left only on your machine never reach the user. `../update-custom-config.sh` refreshes the `.ini` files (settings, layouts,
custom actions, ReaPack repositories) and the `Scripts/` / `Effects` trees from
the current REAPER resource path in a shippable form. Binary extensions
(`UserPlugins/`), ReaPack's package cache and licence data stay out.

Recommended add-ons (download links, not shipped — see `../README.md`):
SWS extension, ReaPack, ReaTeam scripts, ReaImGui. Put the native `.so` files in
`UserPlugins/` and the scripts in `Scripts/` so they are delivered with the repo.
