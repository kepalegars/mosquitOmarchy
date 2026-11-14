# `custom/` — the REAPER config this repo ships

Mirrors REAPER's resource path (`~/.config/REAPER`). Setup ▸ REAPER ▸ **C**
copies this tree over it, after backing up every file it replaces to
`code/modules/Apps/reaper/backups/<date>-install/`.

Uninstall ▸ **C** restores the REAPER config (the install-time backup) and
removes the theme assets, but leaves every file copied from here in place:
scripts, JSFX, plugins, ReaPacks and SWS files are never removed. The backup
folder is there if you want to restore one of them by hand.

This folder is committed: if you build a personal config here, ship it with the
rest of the repo — files left only on your machine never reach the user.

```
Scripts/       ReaScripts (.lua/.eel)          -> ~/.config/REAPER/Scripts/
Effects/       JSFX (.jsfx)                    -> ~/.config/REAPER/Effects/
UserPlugins/   native extensions (reaper_*.so) -> ~/.config/REAPER/UserPlugins/
FXChains/      FX chain files                  -> ~/.config/REAPER/FXChains/
TrackTemplates/ track templates                -> ~/.config/REAPER/TrackTemplates/
reaper.ini     settings                        -> ~/.config/REAPER/reaper.ini
```

Extra folders are copied exactly where they sit (`custom/<path>` →
`~/.config/REAPER/<path>`), so anything REAPER uses can be added. `.gitkeep`
and `README.md` files are repo bookkeeping and are not installed.

Recommended add-ons (download links, not shipped — see `../README.md`):
SWS extension, ReaPack, ReaTeam scripts, ReaImGui. Put the native `.so` files in
`UserPlugins/` and the scripts in `Scripts/` so they are delivered with the repo.
