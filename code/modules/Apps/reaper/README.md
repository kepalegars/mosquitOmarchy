# REAPER

REAPER can run with the native Wayland `libSwell` from
[GoranKovac/Wayland-Swell](https://github.com/GoranKovac/Wayland-Swell): its
dialogs are real child toplevels and follow the main window's monitor, so no
Hyprland window rules are needed.

If the Wayland build misbehaves, run `setup-reaper.sh --x11`: it restores the
X11 fallback behaviour by keeping the system `libSwell` (the old binary was
saved manually under `backups/`). `setup-reaper.sh --wayland` re-enables it.

There is no `reaper-ui-scale`, no launcher-time theme sync and no Hyprland rule
managed by this module. The theme is generated once when the custom config is
applied and then stays as it is. LSP plugins are an optional yes/no question at
the end of an interactive install (`--lsp` / `--no-lsp` for automation), and a
mosquitOmarchy backup records whether they were present so a restore installs
them directly without asking.

## Plugin folders

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

## Reapertips theme + custom config (P in Setup)

With the cursor on the REAPER row in **Setup**, press **P** (`P custom config` appears
in the shortcut bar). It offers two fonts and, by default, uses Omarchy's current
system font:

- installs LSP plugins (VST2/VST3/CLAP/LV2) when they are missing;
- installs ReaPack + SWS from the Arch packages `reapack`/`sws` (the upstream
  ReaPack build requires the obsolete `libxml2.so.2` and will not load on
  current Arch), with a GitHub/Downloads fallback on other systems and an
  `ldd` check so a broken `.so` is never installed;
- installs the **Reapertips** theme (dark or light, following Omarchy),
  recoloured to Omarchy's accent;
- installs the purple toolbar icons (100/150/200%) and the REAPER 7 splash;
- installs `libSwell-user.colortheme` so the native Linux menus follow the accent too;
- applies `code/modules/Apps/reaper/configs/custom/` over the REAPER resource path.

Both actions require REAPER to be closed: the TUI asks you to close it and
retry, and the config script refuses to write while a REAPER process is alive.

In **Uninstall**, the same key shows `P restore config` and undoes the visual
part: the REAPER config (including the theme selection) comes back as it was
when P was run in Setup, and the generated theme, purple toolbar icons, splash
and window colours are removed. Scripts, plugins, JSFX, ReaPacks, SWS and LSP
plugins are **never** removed by this.

Before restoring, the config REAPER has at that moment is copied to
`backups/<date>-before-restore/`; install-time backups are in
`backups/<date>-install/` (both inside this module, git-ignored).

The LSP step needs the network but is non-fatal: if `pacman` cannot reach the
repos, the theme is still installed.

### Theme source

Download the latest free theme from
<https://www.reapertips.com/products/reapertips-theme> and drop
`Reapertips Theme v*.zip` in `~/Downloads`. The config action copies the newest
archive into `code/modules/Apps/reaper/configs/` itself — no bootstrap step, no
prompt. It can also be placed in that folder directly. The zip is git-ignored.

As with the other archives this repo does not ship (Ableton, DaVinci,
Spektrafilm, Guitar Pro, Bitwig…), downloading it before the first bootstrap is
still the smoothest path; downloading it later works too, P finds it in
Downloads. The installer reads the Purple and Light variations from the archive
and works only from what it extracts — no hardcoded external-disk path.

### Custom config

`configs/custom/` mirrors the REAPER resource path (`~/.config/REAPER`), so:

```
configs/custom/Scripts/...             -> ~/.config/REAPER/Scripts/...
configs/custom/Effects/...             -> ~/.config/REAPER/Effects/...
configs/custom/UserPlugins/...         -> ~/.config/REAPER/UserPlugins/...
configs/custom/reaper.ini              -> ~/.config/REAPER/reaper.ini
configs/custom/reaper-themeconfig.ini  -> ~/.config/REAPER/reaper-themeconfig.ini
configs/custom/reaper-extstate.ini     -> ~/.config/REAPER/reaper-extstate.ini
```

The three `.ini` files carry the global settings, the Reapertips Theme Adjuster
colours/layout and the Default 6.0 / 7.0 Theme Adjuster window state. The
installer writes `lastthemefn5`, `splash` and `splashimage` itself, into the
`[reaper]` section of `reaper.ini` — that is what makes the REAPER 7 splash
actually show instead of REAPER's stock one.

`Scripts/`, `Effects/` and `UserPlugins/` are there for ReaScripts, JSFX and
native extensions (SWS, ReaPack). `configs/README.md` lists the recommended SWS /
ReaPack add-ons with their download links.

Anything else — plugins, scripts, templates, settings — goes in the same tree at
the path REAPER uses. It replaces the current files, and **every file it
overwrites is backed up first** to `backups/<date>-install/` (inside this
module, git-ignored). The Setup prompt says this before anything runs.

The custom config is copied, never tracked for undo: `P` in Uninstall leaves
every script, JSFX, plugin, ReaPack and SWS file in place. The backup folder is
there if you want to restore one by hand.

**This folder is shipped with the repo.** If the config prepared here is a
personal one, it must still be committed and delivered with the rest of the repo
on GitHub — files left only on one machine never reach the user. Anything
private (licences, tokens) does not belong in it.

### Accent colour and fonts

`reaper-theme-apply` generates the Reapertips theme **once**, choosing the
Light/Purple base for Omarchy's mode and replacing its accents and the
libSwell accent with Omarchy's accent. It is not called at launch: the theme
and `lastthemefn5` stay as applied until you re-apply the config with P or
change the theme inside REAPER.
