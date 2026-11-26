# REAPER configs

## Theme archive

Download the latest **Reapertips Theme** from
<https://www.reapertips.com/products/reapertips-theme> and drop
`Reapertips Theme v*.zip` in `~/Downloads`. Setup ▸ REAPER ▸ **P** copies the
newest one here automatically — no bootstrap step. That zip is required for the
complete config (theme + splash + toolbar icons).

Like the other archives this repo does not ship, downloading it before the
bootstrap is the smoothest path, but P finds it in Downloads whenever you add
it. The zip stays local and is git-ignored; it is not redistributed.

## `custom/` — the config this repo ships

`custom/` mirrors REAPER's resource path (`~/.config/REAPER`) and is applied
over it by Setup ▸ REAPER ▸ **P**:

```
custom/Scripts/...             -> ~/.config/REAPER/Scripts/...
custom/Effects/...             -> ~/.config/REAPER/Effects/...
custom/UserPlugins/...         -> ~/.config/REAPER/UserPlugins/...
custom/reaper.ini              -> ~/.config/REAPER/reaper.ini
custom/reaper-themeconfig.ini  -> ~/.config/REAPER/reaper-themeconfig.ini
custom/reaper-extstate.ini     -> ~/.config/REAPER/reaper-extstate.ini
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

`configs/update-custom-config.sh` resnapshots the three `.ini` files from the
current REAPER resource path. It drops the licence/nag state and the
machine-bound theme and splash pointers so the copy stays shippable, and is
the supported way to publish a new tuning.

Files the install overwrites are backed up first to
`code/modules/Apps/reaper/backups/<date>-install/`. Setup ▸ Uninstall ▸ **P**
restores the REAPER config and removes the theme, splash, window colours and
toolbar icons. It never removes scripts, plugins, JSFX, ReaPacks, SWS or LSP
plugins.

## SWS / ReaPack add-ons

On Arch, the config action installs the **distro packages** `reapack` and
`sws` — important: the upstream ReaPack binary needs `libxml2.so.2`, which
current Arch no longer ships, so it silently fails to load. The packaged build
links against `libxml2.so.16`. On other systems it falls back to GitHub
Releases. To use a specific version instead, drop a compatible file in
`~/Downloads`: a bare
`reaper_*-$arch.so`, a `sws-*-Linux-$arch*.tar.xz`, or a `.reaperpkg`/`.zip`.
Only the `.so` matching this system is extracted and copied to
`UserPlugins/`; every candidate is checked with `ldd` and a binary with
missing libraries is refused. Other useful add-ons are separate:

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

The theme is recoloured once when the config is applied and then stays fixed;
there is no launcher-time sync.
