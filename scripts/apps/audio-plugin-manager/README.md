# Audio Plugin Manager + wine/yabridge stack

> **Omarchy only.** Built for and tested on Omarchy (Arch + Hyprland). It uses `hyprctl`,
> Omarchy menu widgets and the Omarchy launcher; not portable as-is.

Two things live here:

1. the **mosquito Audio Plugin Manager** — Windows VSTs *and* native Linux plugins, install /
   uninstall / fixes / standalone launch;
2. the **wine/yabridge stack** it sits on — packages, shared plugin folders, per-vendor
   precautions.

**Bitwig and REAPER are not installed here.** They have their own folders and installers
(`../bitwig/`, `../reaper/`) and are driven from the `audio` orchestrator module.

## Before reporting a failed install

Read [`PLUGIN-TESTS.md`](PLUGIN-TESTS.md) — a ProtonDB-style registry, one block per plugin:
version, ✅/⚠️/❌, and any special treatment it needs. Several plugins are known to need
something before they will work, and that is recorded there.

## The stack — `setup-audio-stack.sh`

Every step is detected and idempotent.

1. **Packages** — `[multilib]`, wine-staging, yabridge, yabridgectl, realtime-privileges,
   winetricks, the `realtime` group
2. **Plugin folders** — the shared root (default `~/Music/Audio Plugins`, legacy `~/VST`
   reused if it holds real plugins), yabridgectl registration, `yabridge-autosync` units, the
   native search paths (`VST_PATH`, `VST3_PATH`, `CLAP_PATH`, `LV2_PATH` in
   `~/.config/environment.d`), and wine-prefix → shared-folder linking
3. **Per-vendor precautions** — applies only what concerns installed plugins
4. **Audio Plugin Manager** — installs the manager itself
5. **Wine menu cleanup** — drops the `Uninstall` / `Manual` launcher entries Windows plugin
   installers publish

```bash
scripts/apps/audio-plugin-manager/setup-audio-stack.sh              # interactive
scripts/apps/audio-plugin-manager/setup-audio-stack.sh -y           # defaults
scripts/apps/audio-plugin-manager/setup-audio-stack.sh --tweaks     # step 3 only — after each new plugin
scripts/apps/audio-plugin-manager/setup-audio-stack.sh --dry-run
scripts/apps/audio-plugin-manager/setup-audio-stack.sh --vst-sync
scripts/apps/audio-plugin-manager/setup-audio-stack.sh --vst-status
scripts/apps/audio-plugin-manager/setup-audio-stack.sh --wine-menu   # step 5 only
```

### Per-vendor precautions (step 3)

| Vendor | Precaution |
|---|---|
| Xfer Serum | winetricks `gdiplus`, override `d2d1`, tooltips off |
| FabFilter | group `"fabfilter"` — inter-plugin communication, VST2 |
| Arturia / Kick 2 / The Drop | `HideWineExports`; Bitwig sandbox recommended |
| MeldaProduction | disable GPU rendering in each plugin |
| ujam / Gorilla Engine / Loopcloud | `disable_pipes = true` |
| KiloHearts | fd leak esync → `WINEESYNC=0` or fsync |
| Spitfire Audio | reinstall in a clean prefix on sample errors |
| iZotope / D16 | activation is impossible under wine |
| Waves | stay on V12; V13+ is unstable under the bridge |
| sforzando | known graphical refresh problem |
| Tokyo Dawn / Voxengo | linear / radial knobs mode |
| Applied Acoustics | `hide_daw = true` — crashes Bitwig otherwise |
| Sonible (JUCE8) | black GUI; winetricks `vcrun6sp6 w_workaround_wine_bug-50894` |
| Scaler | software rendering if the GUI stays black |
| Softube / Plugin Alliance | black GUI is standard; install via `wine msiexec /i` |

Re-run `--tweaks` after every new plugin.

## Shared folders — `link-vst-shared.sh`

Links wine prefixes (`~/.wine` for yabridge, `~/.wine-ableton` for Ableton) to shared
directories: the real files stay in the shared root and the Windows folders become symlinks,
so **one install is visible in every DAW**. Called by the stack, the Ableton setup and the
manager's install/uninstall.

```bash
scripts/apps/audio-plugin-manager/link-vst-shared.sh                    # all detected prefixes
scripts/apps/audio-plugin-manager/link-vst-shared.sh --prefix ~/.wine   # one prefix
scripts/apps/audio-plugin-manager/link-vst-shared.sh -y
```

## The manager

Renamed from "VST Manager" when it started handling both plugin universes. `Installed
plugins`, `Install a plugin from file`, `Uninstall a plugin`, `Plugin fixes`, `Cleanup
inconsistencies` and `Launch a standalone plugin` are common to both and sit on the first
menu. `Windows VST Plugins (Wine)` is a submenu for the Wine-only leftovers — prefix
management, executable visibility, the Hide VST2 / Hide 32-bit filters.

| Binary | Role |
|---|---|
| `mosquito-audio-plugin-manager` | dispatcher. No arguments = the TUI; `status`, `install`, `launch` run one step |
| `mosquito-audio-plugin-manager-tui` | the compiled Go/Bubble Tea interface — the only interface |
| `mosquito-audio-plugin-manager-actions` | the non-interactive backend the TUI calls |

```bash
mosquito-audio-plugin-manager                  # interactive
mosquito-audio-plugin-manager status           # one-shot report, no UI
mosquito-audio-plugin-manager install foo.exe
mosquito-audio-plugin-manager launch foo.exe
```

All the logic lives in `lib-audio-plugin-manager-core.sh`, shared by the TUI and the backend so
they cannot disagree. The TUI execs in place from a terminal, or opens its own window
(foot, else xterm) when launched from a menu.

A **machine-scoped state log**, `audio-plugin-manager-state.json`, records what was installed,
its prefix and its move history. Copied to another machine it is ignored and reinitialised; it
is git-ignored.

Native Windows apps (`iexplore`, `wmplayer`, `wordpad`, `edge`, `webview2`…) and uninstallers are
never offered as plugins.

## The two universes

**Windows VST, via Wine/yabridge** — installed by running its installer in a prefix. The
dedicated `~/.wine-vst` is created automatically when nothing is installed yet, or you can
choose a new `~/.wine-<name>`. Uninstalls **quarantine** rather than delete, into
`~/.cache/vst-quarantine/`.

**Native Linux (LV2 / CLAP / native VST3)** — no Wine, no prefix, no bridge. Any host scans a
fixed set of folders at startup, so install/uninstall/enable-disable only ever means putting a
bundle where hosts look, or renaming it out of the way. Never a package operation, and no sudo
anywhere in the flow.

Scan and install roots are the standard **user** paths `~/.lv2`, `~/.clap`, `~/.vst3` — this
tool never installs into `/usr`. System paths are shown read-only in the list, pointing you at
`pacman` rather than acting on them.

`~/.vst3` is *also* yabridge's own target for bridged Windows VST3s, so every entry there is
`readlink`'d first: anything resolving into a `.wine*` prefix is a bridge stub and is excluded —
it already appears in the Windows list.

An LV2 folder only counts as a plugin if its `manifest.ttl` actually declares an `lv2:Plugin`
or a subclass, which is what excludes the spec bundles that ship with the `lv2` package itself
(`atom.lv2`, `core.lv2`…) and also end in `.lv2`.

## Where DAWs must look

The first-launch wizard configures what it can; this is the complete picture.

| DAW | What to add |
|---|---|
| **REAPER** | `vstpath=~/.vst`, a `vst3path` covering `~/.vst3`, `clappath=~/.clap` in `~/.config/REAPER/reaper.ini`. The wizard adds these. |
| **Ableton Live (Linux)** | nothing per-DAW — it reads the shared wine `Common Files` symlinks that `link-vst-shared.sh` provides |
| **Bitwig Studio** | Preferences ▸ Plug-ins ▸ *Folders for VST Plug-ins*: `~/.vst`, `~/.vst3`, `~/.clap`, plus the CLAP folder for `~/.clap`. **Cannot be automated** — do this once. |

The `~/.vst`, `~/.vst3` and `~/.clap` paths are the **yabridge chainloader stubs** that
`yabridgectl` writes, not the raw `.dll` bundles in the shared root. A native Linux host must
scan the stubs.

## First launch

On a machine with no preferences yet, a short wizard runs first:

1. **Plugins folder** — the default shared root is used right away; choosing *No* opens the file
   manager so you can pick an existing one. Stored in Settings, changeable later.
2. **DAW paths** — updates the config of every already-installed DAW, per the table above.
   Whatever cannot be done externally is named on screen rather than failing quietly.

## The plugin list

One unified list, `[origin/format]  name` — `[vst/vst2]`, `[native/lv2]`. Plugins installed by a
Windows installer are grouped under their wine-program folder, with the same nesting as the
Uninstall screen.

- `←` `→` cycles the sort (vendor / name / format / install date) live, btop-style
- `Tab` hides or shows the highlighted plugin, or a whole folder row
- `Enter` shows a row's detail
- leaving with changes prompts Save / Discard

A hidden plugin stays managed but is excluded from DAW scans: a `.hidden` filename suffix plus a
yabridge resync for VST, the `.disabled` suffix for native. Every host recognises the exact
`.lv2` / `.clap` / `.vst3` suffix when scanning, so the rename hides a bundle without touching
its contents, and dropping the suffix brings it back.

**Install a plugin from file** takes one picker and auto-detects: a `.exe`/`.msi` goes through
the wine-prefix wizard, while a raw bundle or a `.zip`/`.tar`/`.tar.gz`/`.tgz` containing one
(searched two levels deep, for a vendor zip that wraps the bundle) installs natively. You do not
say which kind it is up front.

**Uninstall** is a multi-select — `Tab` to check several, `Enter` to remove them in one batch,
or `Enter` on a single row with nothing checked. Native bundles go to
`~/.cache/audio-plugin-manager-quarantine/<timestamp>-uninstall/`. Nothing is deleted.

**Hide VST2** / **Hide 32-bit** filter the list. Bitness is read with `file -b` on the `.dll`
(`PE32` = 32-bit, `PE32+` = 64-bit), so it is only meaningful for VST2 — a real VST3 bundle is a
directory.

## Launch an executable in the default prefix

*Windows VST Plugins → Launch an executable in the default prefix* runs a Windows program
inside the default wine prefix without going through a DAW. Two ways to pick the file:

- **Browse to a file…** — opens the file manager (nautilus/superfile/zenity, whichever the
  picker preference resolves to) so you can navigate the prefix's own filesystem. The file
  manager only *designates the file*: the manager stays on top and does the wine launch
  itself, so the program runs in the right prefix rather than whichever prefix the file
  manager happens to associate with `.exe`.
- **List the executables already in the prefix** — every `.exe` under the prefix's `drive_c`,
  excluding the emulated `windows/` system folder (on a real prefix that folder alone holds
  ~200 system exes), sorted by name with the folder path as the sub-line.

The default prefix is the same one installs target (see *Default wine prefix* in Settings).
The launched program's window is floated by the same Hyprland rule as a plugin editor.

## Plugin fixes

Some Wine plugins misbehave under Hyprland in ways that are not the plugin's fault: the editor
window comes up unclickable, or its hover tooltips steal input. **Plugin fixes** asks which
plugin, then shows the catalog in two sections — generic fixes in their own folders, and
plugin-specific ones below a separator, grouped by **product name alone**. Those stay visible
for every plugin, since the same Wine issue shows up elsewhere.

`Tab` or `x` toggles, `Enter` applies the newly checked and removes the unchecked-but-applied
in one pass. Already-applied fixes are pre-checked, and the plugin chooser marks plugins that
carry at least one with an accent `●`.

A fix is recorded **per product, not per plugin file**, and the rules match the editor window's
*title* — the same window for a product's VST2 and VST3 copies — so one tick covers both formats
and you never apply it twice. Only a genuinely single-format fix (a patch rewriting a `.vst2`
binary) declares it, and its row is tagged `[VST2 only]` / `[VST3 only]` so the restriction is
visible rather than implied. `i` spells it out on the info popup.

Each fix is a marked, idempotent block in `~/.config/hypr/hyprland.lua`
(`-- >>> mosquito_fix_<id>` … `-- <<< mosquito_fix_<id>`), followed by `hyprctl reload`. The
applied state lives in `~/.config/audio-plugin-manager/fixes.json` and the Lua is always
regenerated from it, so re-applying never stacks duplicate rules and removing the last plugin
for a fix removes its block. The product list is deduplicated case-insensitively: a state that
drifted to both `CrispyTuner` and `crispytuner` collapses to one entry and one rule on the next
apply, and re-applying restores the product's own capitalisation.

| Fix | What it does |
|---|---|
| Wine plugin GUI input | Forces the editor window to float, stay unblurred and take XWayland input even when the plugin asks not to. Matched on the window **title** — these editors report an empty class, so a class rule is generic and hitless. |
| Ableton/Wine hover tooltips | Keeps the tooltip windows floating, unblurred, animation-free and unfocused, so hovering stops stealing input. Applied once, independent of the plugin. |
| Stop the cursor recentering | Hyprland 0.56.2 has **no per-window warp rule**, so this is a `cursor:no_warps` + `cursor:persistent_warps` **global** option. It affects every app, so it is never applied automatically — enable it only after confirming the recentering is Hyprland focus-warp and not Wine's own pointer handling. Tagged `[global]`. |

Known plugins get their required fixes applied automatically on first install (the dependency
map is `known_plugin_fixes()` in the core lib), so a fresh install works out of the box. After a
successful install the TUI also asks *"Plugin installed. Apply fixes for … now?"* and opens the
screen with what remains.

`x` on the Uninstall screen opens the highlighted row's containing folder in the file manager.
The launcher warns once when it is not running under Hyprland, since the window rules and GUI
fixes are written for it.

## Settings

| Setting | Notes |
|---|---|
| **Plugins folder** | `PLUGINS_ROOT`, default `~/Music/Audio Plugins`, with `vst`/`vst3`/`clap` subfolders for the Windows bundles and `lv2`/`vst3-native`/`clap-native` staging roots. Changing it **moves every real plugin file** and re-links wine/yabridge, behind a confirmation. An existing install keeps using wherever its plugins already are — no silent migration. |
| **Default install file directory** | where the install picker starts. A preference only. |
| **Default wine prefix** | the prefix installs target and *Launch an executable* runs in. **Automatic** by default: a prefix that already owns plugins, else `~/.wine-vst`. Choosing a specific one is **confirmation-gated** with a warning — the manager's defaults keep plugin installs out of the prefix your regular Windows apps use, so pointing it at a shared prefix (`~/.wine`) makes plugin installers write there too. Existing plugins are never moved; only new installs follow. Can be set back to *Automatic*. |
| **File picker** | superfile, or the native/zenity chain. Shared by both install flows. |
| **Plugin window handler** | `Classic (float + decorations)` or `Hyprland-managed`. Rewrites the **global** wine-editor window rules, so it is confirmation-gated; affects only windows opened from now on, and a per-plugin fix still overrides it. Also on `x` in the plugin list. |
| **Rewrite applied fixes when installing** | when *On*, a fix **already applied** to that plugin is rewritten silently on each install (so a rule you hand-edited is restored). When *Off*, nothing is applied without being asked. Independent of the row below. |
| **Ask "apply fixes now?" after an install** | the *discovery* step for a newly-installed plugin: shows the fixes page for the freshly installed plugin — or the whole vendor category when the whole suite was installed. *No* only **skips opening the page**; it never undoes a fix that was already written by the row above. |
| **Rescan for untracked plugins** | re-runs the reconcile check that also runs once at startup. Native plugins need no equivalent — a directory scan is always current. |

A deployed `~/.config/audio-plugin-manager/README.md` mirrors the current settings and is
regenerated on every change.

## Cleanup inconsistencies

A confirm-gated, fully non-destructive pass that treats the log and the files as ground truth
without ever removing a real file or a log entry:

- **missing** plugins (tracked, file gone) are kept with an emptied file list, so the nag stops
  until you reinstall or remove them explicitly
- **untracked** files on disk are registered, so they show as installed and stop being offered
  as orphans
- a file tracked under several keys is reduced to its single best owner
- **dangling menu entries** — a generated `.desktop` whose `.exe` is gone — are removed, since
  the launcher could only fail

## Wine menu cleanup

Windows plugin installers write `Uninstall` / `Manual` shortcuts into their prefix's Start Menu,
and Wine republishes each as a launcher entry under `Wine / Programs / <vendor>` — the wrong
entry for something this module installs *and* uninstalls, sitting next to the
`vst-standalone-*.desktop` it publishes itself.

The cleanup runs after each install and uninstall, scoped to the one prefix that just ran, and
at the end of both setup scripts scoped to the prefixes this stack owns (`~/.wine-vst*`). It also
prunes the empty `.directory` publishers. `~/.wine` is never swept in bulk — that is where you run
your own Windows apps — and the `NoDisplay=true` file associations are never touched.

Full detail, and the standalone version: [`scripts/fixes/fix-wine-menu.sh`](../../fixes/README.md).

## Install the manager

```bash
scripts/apps/audio-plugin-manager/setup-audio-plugin-manager.sh           # interactive
scripts/apps/audio-plugin-manager/setup-audio-plugin-manager.sh -y        # unattended
```

Deploys the dispatcher, the core and the compiled TUI to `~/.local/bin`, installs the icon, the
Hyprland float rule and the `mosquito.confirm` overlay, and removes every pre-rename artifact
(the "VST Manager" binaries, desktop entry, icon and Hyprland block, and the older superseded
`vst-install` wrapper).
