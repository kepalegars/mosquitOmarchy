# REAPER configs

## Theme archive

Download the free **Reapertips Theme** from
<https://www.reapertips.com/products/reapertips-theme> and drop
`Reapertips Theme v*.zip` in `~/Downloads`, then run `./bootstrap.sh` once:
it moves the newest archive here and Setup ▸ REAPER ▸ **C** picks it up.

Like every other archive this repo does not ship (Ableton, DaVinci, Spektrafilm,
Guitar Pro, Bitwig…), download it **before** running `bootstrap.sh`: the
bootstrap files it into the repo in one pass, and the matching Setup row is
usable immediately. Downloading it later works too — just re-run the bootstrap.

The zip stays local and is git-ignored; it is not redistributed with the repo.

## `custom/` — the config this repo ships

`custom/` mirrors REAPER's resource path (`~/.config/REAPER`) and is applied
over it by Setup ▸ REAPER ▸ **C**:

```
custom/Scripts/...       -> ~/.config/REAPER/Scripts/...
custom/Effects/...       -> ~/.config/REAPER/Effects/...
custom/UserPlugins/...   -> ~/.config/REAPER/UserPlugins/...
custom/reaper.ini        -> ~/.config/REAPER/reaper.ini
```

The layout is the one REAPER itself uses, so a file can be dropped at the
destination path without conversion. `Scripts/`, `Effects/` and `UserPlugins/`
exist as the usual homes for ReaScripts, JSFX and native extensions
(`reaper_*.so`).

This folder is **committed and shipped**: it is what the repo delivers to
every user. If the config prepared here is a personal one, it still has to be
included with the rest of the repo on GitHub — add the files under
`custom/`, do not leave them on one machine. Anything private (licences,
account tokens, huge samples) does not belong here.

Files the install overwrites are backed up first to
`code/modules/Apps/reaper/backups/<date>-install/`. Setup ▸ Uninstall ▸ **C**
restores the REAPER config and removes the theme, splash, window colours and
toolbar icons. It never removes scripts, plugins, JSFX, ReaPacks, SWS or LSP
plugins.

## SWS / ReaPack add-ons

These are downloaded separately (not shipped, same as the theme archive). Install
them into the tree above so they travel with the repo:

| Add-on | What it adds | Link |
| --- | --- | --- |
| SWS extension | Hundreds of actions, Resources (FX chains, track templates), S&M | <https://www.sws-extension.org/> |
| ReaPack | Package manager for ReaScripts | <https://reapack.com/> |
| ReaTeam scripts | The default ReaPack repository (thousands of scripts) | <https://github.com/ReaTeam/ReaScripts> |
| ReaImGui | Immediate-mode GUI for ReaScripts | <https://github.com/cfillion/reaimgui> |

- The SWS extension is a native `reaper_sws-x86_64.so`: it goes in
  `custom/UserPlugins/`.
- ReaPack is also a `reaper_reapack-x86_64.so` in `custom/UserPlugins/`.
- ReaScripts (`.lua`, `.eel`) go in `custom/Scripts/`, JSFX (`.jsfx`) in
  `custom/Effects/`, and FX chains / track templates can be exported from REAPER
  into `custom/FXChains/` and `custom/TrackTemplates/`.

`reaper-theme-sync` keeps the theme's accent and font in step with Omarchy; the
SWS/ReaPack scripts above are unaffected by theme changes.
