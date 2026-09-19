# Audio Plugin Manager + wine/yabridge stack — Omarchy module

> **Scope / disclaimer**: this module is designed for and tested **only on
> [Omarchy](https://omarchy.org)** (Arch Linux + Hyprland + the Omarchy shell).
> It assumes Omarchy's tools and paths and is **not tested on any other
> distribution, desktop or window manager** — adapt it before reusing it
> elsewhere.

This folder (renamed from `audio-stack`) holds two things:

1. the **mosquito Audio Plugin Manager** — the main tool for Windows **and**
   native Linux plugins (install / uninstall / fixes / standalone),
2. the **wine/yabridge audio stack** it sits on — packages, shared VST
   folders, per-vendor yabridge precautions.

**Bitwig and REAPER are NOT installed here anymore** — they each have their
own folder and installer (`../bitwig/setup-bitwig.sh`, `../reaper/setup-reaper.sh`)
and are driven from the `audio` orchestrator module.

## The wine/yabridge stack — setup-audio-stack.sh

Each step is detected and **idempotent**:

1. **Packages** — `[multilib]`, wine-staging, yabridge, yabridgectl, realtime-privileges, winetricks, `realtime` group
2. **VST folders** — the shared root (default `~/Music/Audio Plugins`, legacy `~/VST` fallback), yabridgectl registration, `yabridge-autosync` systemd units, native plugin-search env vars (`VST_PATH`/`VST3_PATH`/`CLAP_PATH`/`LV2_PATH` via `~/.config/environment.d`), wine-prefix → shared-folder linking
3. **Yabridge precautions by vendor** — applies only what concerns installed plugins
4. **Audio Plugin Manager menu entry** — installs the manager itself

```bash
./apps/audio-plugin-manager/setup-audio-stack.sh             # interactive, each step asked
./apps/audio-plugin-manager/setup-audio-stack.sh -y          # all defaults
./apps/audio-plugin-manager/setup-audio-stack.sh --tweaks    # step 3 only, after each new plugin
./apps/audio-plugin-manager/setup-audio-stack.sh --dry-run   # simulation, nothing modified
./apps/audio-plugin-manager/setup-audio-stack.sh --vst-sync  # yabridgectl sync
./apps/audio-plugin-manager/setup-audio-stack.sh --vst-status
```

Plugins installed via a Windows installer end up in the shared VST root (monitored by autosync). After installing a new plugin, re-run `--tweaks` to apply its possible precautions.

### VST knowledge base (`kb_*` tables, step 3)

| Vendor | Precaution |
|---|---|
| Xfer Serum | winetricks `gdiplus` + override `d2d1` + tooltips off |
| FabFilter | group `"fabfilter"` (inter-plugin communication, VST2) |
| Arturia / Kick 2 / The Drop | `HideWineExports` ; Bitwig sandbox recommended |
| MeldaProduction | disable GPU rendering in each plugin |
| ujam / Gorilla Engine / Loopcloud | `disable_pipes = true` |
| KiloHearts | fd leak esync → `WINEESYNC=0` or fsync |
| Spitfire Audio | reinstall in a clean prefix on sample errors |
| iZotope / D16 | activation impossible under wine (licenses) |
| Waves | stay on V12 (V13+ unstable under bridge) |
| sforzando | known graphical refresh problem |
| Tokyo Dawn / Voxengo | linear / radial knobs mode |
| Applied Acoustics | `hide_daw = true` (crashes Bitwig otherwise) |
| Sonible (JUCE8) | black GUI ; winetricks `vcrun6sp6 w_workaround_wine_bug-50894` |
| Scaler | use software rendering if the GUI stays black |
| Softube / Plugin Alliance | black GUI standard wine / `wine msiexec /i` |

## Share VST folders between prefixes — link-vst-shared.sh

Links wine prefixes (`~/.wine` for yabridge, `~/.wine-ableton` for Ableton) to shared directories (real files stay in the shared root, the Windows folders become symlinks). One plugin install = visible in all DAWs. Called by `setup-audio-stack.sh`, `setup-ableton.sh` and the Audio Plugin Manager's install/uninstall.

```bash
./apps/audio-plugin-manager/link-vst-shared.sh                   # links all detected prefixes
./apps/audio-plugin-manager/link-vst-shared.sh --prefix ~/.wine  # one specific prefix only
./apps/audio-plugin-manager/link-vst-shared.sh -y                # non-interactive
```

## mosquito Audio Plugin Manager — mosquito-audio-plugin-manager

Renamed from "VST Manager" — the tool now handles *both* plugin universes: Windows VST
plugins run through Wine/yabridge, and genuinely native Linux plugins (LV2/CLAP/
native-Linux-VST3, no Wine at all). **Installed plugins** (the unified plugin
list), **Install a plugin from file**,
**Uninstall a plugin**, **Plugin fixes**, **Cleanup inconsistencies** and
**Launch a standalone plugin**
are common to both and sit directly on the first menu. **Windows VST Plugins (Wine)** is a
submenu holding only the Wine-specific leftovers — prefix management, executable
visibility in the Omarchy menu, and the Hide VST2/Hide 32-bit filters — nothing that
makes sense for native plugins lives there. **Settings** is likewise unified at the top
level (file picker, plugins folder, manual rescan).

Manages Windows VST plugins: install via wine (same prefix by default — the dedicated
`~/.wine-vst` is created automatically when nothing is installed yet — or a new
`~/.wine-<name>`), uninstall, standalone launch, prefix moves with a management history,
and which standalone executables appear in the menu. Native Windows apps (iexplore,
wmplayer, wordpad, witch*/edge/webview2/copilot, …) and uninstallers are never offered.
Uninstalls **quarantine** files into `~/.cache/vst-quarantine/` (native plugins:
`~/.cache/audio-plugin-manager-quarantine/`) rather than destroying them.

**One interface, one core** — same architecture as the sibling mosquito Move Manager
module, kept deliberately consistent: all the actual logic lives in
`lib-audio-plugin-manager-core.sh`, shared by `mosquito-audio-plugin-manager-tui` (a real
terminal UI, a compiled Go/Bubble Tea program — see `tui-go/`; it is **the only
interface**, opening its own terminal window when needed) and the thin non-interactive
`mosquito-audio-plugin-manager-actions` backend the TUI calls once every decision is made
in Go. `mosquito-audio-plugin-manager` itself is a small, stable dispatcher — no
arguments = the TUI (exec'd straight, opening a foot/xterm window if needed); flag
actions (`launch`, `install`, `status`) run the relevant core function directly with the
core's own real prompts (native Omarchy overlay / zenity / tty chain). Nothing heavier
runs on every launch.

A **machine-scoped state log** (`audio-plugin-manager-state.json`) records what was
installed, its wine prefix and move history. It is tied to the machine id: if the repo is
copied to another machine the log is ignored and reinitialised (and it is git-ignored).

```bash
~/.local/bin/mosquito-audio-plugin-manager                # interactive menu (the TUI)
~/.local/bin/mosquito-audio-plugin-manager status         # one-shot report, no UI
~/.local/bin/mosquito-audio-plugin-manager install foo.exe
~/.local/bin/mosquito-audio-plugin-manager launch foo.exe
```

### First launch — the setup wizard

On a machine with no preferences yet, the first launch runs a short wizard before the
menu appears:

1. **Plugins folder** — the default shared root is used right away (just press Enter);
   choosing *No* opens the default file manager (superfile when installed) so you can
   pick an existing folder — the final choice is stored in Settings (it can be changed
   later; changing it moves every real plugin file).
2. **DAW plugin paths** — the manager then updates the config of every **already
   installed** DAW (Bitwig, REAPER, Ableton Live for Linux — each version) so it scans
   the right folders. What can be done externally is done automatically:
- **REAPER** — `vstpath`/`vst3path`/`clappath` in `~/.config/REAPER/reaper.ini` gain
      the yabridge chainloaders `~/.vst`, `~/.vst3`, `~/.clap`;
   - **Ableton Linux** — the shared folders are wired through the wine-prefix
     `Common Files` symlinks by `link-vst-shared.sh`;
   - **Bitwig** — no command-line/INI way to add plugin folders: the wizard names it as
     needing one manual step (Preferences → Plug-ins → "Folders for VST Plug-ins").
   Programs that can't be set up externally are named on screen, and this README's
   **Installed plugins** section tells you exactly what to point where.

### Installed plugins

The **Installed plugins** entry is the unified plugin list (`[origin/format]  name`,
e.g. `[vst/vst2]` or `[native/lv2]`). Plugins installed by a Windows installer are grouped
under their wine-program folder (the same folder rows and nesting as the Uninstall screen).
**Tab** hides/shows the highlighted plugin (or an entire folder row) so DAWs no longer see
it; **Left/Right** cycles the sort. For DAWs to find what it manages, point each DAW at
the folders below (the first-launch wizard does this automatically where possible):

- **Windows VST plugins (via Wine/yabridge)** — the **yabridge chainloaders**
  `~/.vst` (VST2), `~/.vst3` (VST3), `~/.clap` (CLAP): these are the `.so` stubs
  `yabridgectl` drops, which is what native Linux hosts must scan — not the raw `.dll`
  bundles in the shared root.
- **Native plugins (LV2/CLAP/native VST3)** — the standard user paths `~/.lv2`,
  `~/.clap`, `~/.vst3` (this tool installs into those, never into `/usr`).

Per DAW:
- **REAPER** — `~/.config/REAPER/reaper.ini` must have `vstpath=~/.vst`,
  `vst3path=` covering `~/.vst3`, and `clappath=~/.clap` (the yabridge chainloader
  stubs). The first-launch wizard adds these automatically.
- **Ableton Live for Linux** — reads its plugin folders through the shared wine
  `Common Files` symlinks provided by `link-vst-shared.sh` (no per-DAW path config).
- **Bitwig Studio** — Preferences → Plug-ins → **"Folders for VST Plug-ins"**: add
  `~/.vst`, `~/.vst3`, `~/.clap` (and the CLAP folder list for `~/.clap`). This one
  cannot be automated; do it once after install.

### Native plugins (LV2/CLAP/native-Linux-VST3)

Merged into the same **Plugin list**/**Install**/**Uninstall** as the Wine/VST side, but a
genuinely separate underlying mechanism: installed without Wine at all, no wine prefix, no
yabridge. Any host just scans a fixed set of folders at startup, so install/uninstall/
enable-disable only ever means putting a bundle where hosts look, or renaming it out of
the way — never a package manager operation.

Scan/install roots are the standard **user** paths: `~/.lv2`, `~/.clap`, `~/.vst3` — no
sudo anywhere in this flow. The system paths (`/usr/lib/{lv2,clap,vst3}`,
`/usr/local/lib/{lv2,clap,vst3}`, where a pacman/AUR-installed plugin lands) are shown in
the **Plugin list** too, read-only — this tool never uninstalls or disables a system
package, only points you at `pacman` for those.

`~/.vst3` is *also* yabridge's own target for bridged Windows VST3 plugins (see above) —
every entry found there is `readlink`'d first, and anything resolving into a `.wine*`
prefix is a bridge stub, not a native plugin, and is excluded (it already shows up in the
VST plugin list instead).

- **Plugin list** — one unified list, `[origin/format]  name` (e.g. `[vst/vst2]` or
  `[native/lv2]`), sortable live with the ←/→ arrow keys (vendor/name/format/install date
  — vendor falls back to name for native rows, which have no wine prefix to group by) and
  Tab-toggleable per row: unchecking a plugin marks it for hiding, checking it back shows
  it again, and leaving the list (Esc) with any changes prompts a Save/Discard confirm —
  a hidden plugin stays in the manager but is excluded from DAW scans (VST: a `.hidden`
  filename suffix + a yabridge resync; native: the same `.disabled` suffix trick
  described below). Enter on a row shows its detail.
- **Install a plugin from file** — one picker (superfile or the native/zenity chain, per
  Settings) for both universes: it auto-detects what was picked — a Windows installer
  (`.exe`/`.msi`) goes through the existing wine-prefix wizard; a raw `.lv2` folder /
  `.clap` file / `.vst3` bundle, or a `.zip`/`.tar`/`.tar.gz`/`.tgz` archive containing one
  (searched up to 2 levels deep, e.g. a vendor's zip that wraps the bundle in one extra
  folder), installs natively — no need to say which kind it is up front.
- **Enable/disable without uninstalling** (the native mechanism the Plugin list's Tab-hide
  uses under the hood) — every host recognizes the exact `.lv2`/`.clap`/`.vst3` suffix
  when scanning, so appending `.disabled` makes a bundle invisible to every host without
  touching its contents; removing the suffix re-enables it.
- **Uninstall** — one multi-select picker (Tab to check several plugins of either origin,
  Enter to remove them together in one batch — or just Enter on a single highlighted row
  with nothing checked, for a quick one-off removal), non-destructive: VST files go to
  `~/.cache/vst-quarantine/`, native bundles to
  `~/.cache/audio-plugin-manager-quarantine/<timestamp>-uninstall/`, neither deleted.
- An LV2 folder only counts as a plugin — not one of the spec/extension bundles that ship
  with the `lv2` package itself (`atom.lv2`, `core.lv2`, …, which also end in `.lv2`) — if
  its `manifest.ttl` actually declares an `lv2:Plugin` (or a subclass, e.g.
  `lv2:InstrumentPlugin`): the same lightweight substring check most simple LV2 scanners
  use, not a full Turtle parser.

### Plugin fixes

Some Wine plugins misbehave under Hyprland/Wayland in ways that are not the plugin's
fault: their editor window can come up unclickable, or their hover tooltips can steal
input from the editor. **Plugin fixes** (a top-level menu item) asks which plugin to fix,
then shows the catalog grouped into expanded category folders (▾ Plugin windows,
▾ CrispyTuner specific, ▾ Cursor): **Tab** or **x** toggles the highlighted fix, and
toggling a category row selects/deselects every fix in it; **Enter** applies the newly
checked fixes and **removes** the unchecked ones that were applied, in one go. Fixes
already applied for the plugin are shown checked on entry (the state is matched no matter
which shape it was recorded in), and the plugin chooser marks plugins that already carry
at least one applied fix with an accent ● next to the name. Fixes designed for one
product are grouped under a `<Plugin> specific` category, which already names the
product, so the row carries no extra tag; they are **never hidden** — a plugin-specific
fix stays visible and selectable for every plugin.
Each fix is written as its own marked, idempotent block in
`~/.config/hypr/hyprland.lua` (`-- >>> mosquito_fix_<id>` … `-- <<< mosquito_fix_<id>`),
and `hyprctl reload` is run afterwards. The applied state lives in
`~/.config/audio-plugin-manager/fixes.json`; the Lua block is always regenerated from it,
so re-applying never stacks duplicate rules and removing the last plugin for a fix removes
its block.

- **Wine plugin GUI input (Hyprland/XWayland)** — forces the selected plugin's editor
  window to float, stay unblurred, and receive XWayland input even when the plugin asks
  not to. Matched on the window *title* (these editors usually report an empty class — the
  class rule is generic and hitless). This is the fix for CrispyTuner's inert GUI, grouped
  under the **CrispyTuner specific** category (the category names the product; no per-row
  tag).
- **Ableton/Wine hover tooltips** — keeps the tooltip windows Ableton plugs (e.g.
  CrispyTuner) create floating, unblurred, animation-free and never focused, so hovering
  them stops stealing input from the editor. Applied once, independently of the plugin;
  grouped under the **CrispyTuner specific** folder.
- **Stop the cursor recentering (global)** — Hyprland 0.56.2 has **no per-window warp
  rule**, so this is a *global* desktop option (`cursor:no_warps` +
  `cursor:persistent_warps`). It affects every app, not just Wine; enable it only after
  confirming the recentering is Hyprland focus-warp and not Wine's own pointer handling.
  It is **not** applied automatically.

Known plugins get their required fixes **applied automatically on first install** (the
dependency map is `known_plugin_fixes()` in the core lib; currently CrispyTuner →
GUI-input + tooltip), so a fresh install works out of the box. After any successful
install the TUI also asks **"Plugin installed. Apply fixes for … now?"** and, if accepted,
opens this screen with the remaining plugin-scope fixes offered.

The Uninstall screen's **x** key opens the highlighted row's containing folder in the
system file manager (the wine-program folder for a folder row, the plugin file's folder
for a plugin row). The interactive launcher warns once when it is not running in a
Hyprland session, because the window rules and GUI fixes are written for Hyprland and
nothing was tested elsewhere.

### Settings

The single top-level **Settings** screen holds everything not specific to the Wine/VST
side:

- **File picker** — superfile vs. the native/zenity chain, shared by both install flows.
- **Plugins folder** — where every plugin is stored (`PLUGINS_ROOT`, default
  `~/Music/Audio Plugins`, containing `vst` (VST2), `vst3`, `clap` subfolders for the
  Windows plugin bundles yabridgectl watches, plus `lv2`, `vst3-native`, `clap-native`
  staging roots for the native-plugin installer; a legacy `~/VST` folder with real
  plugins is reused as-is). A fresh `PLUGINS_ROOT` gets a custom folder icon (this
  app's own icon, via
  `gio set metadata::custom-icon` — a no-op, harmlessly, wherever `gio` or the icon file
  isn't available). Changing this **moves every real plugin file** to the new location and
  re-links wine/yabridge (confirm-gated, via `migrate_plugins_root()`). An existing
  install keeps using wherever its plugins already are (no silent migration) — only a
  genuinely fresh install starts at the new default.
- **Default plugin installation file directory** — where the Install-a-plugin file picker
  starts (`DOWNLOADS_DIR`, default `~/Downloads`). Just a preference, not destructive.
- **Plugin window handler** — `Classic (float + decorations)` vs `Hyprland-managed`.
  Changing it rewrites the **global** Hyprland window rules for wine plugin editors, so it
  is wrapped in a confirmation dialog: it only affects plugin windows opened from now on,
  and a per-plugin fix still overrides it. The same toggle is reachable with **x** on the
  Installed-plugins list, behind the same confirmation.
- **Rescan for untracked plugins** — manually re-runs the same reconcile-missing/
  reconcile-orphans check that also runs once automatically at startup (native plugins
  need no equivalent: a directory scan is always current, there's no separate tracking
  state to fall out of sync).

A deployed `README.md` (`~/.config/audio-plugin-manager/README.md`) reflects the current
settings (default install file directory, plugins folder, file picker) and is regenerated
automatically on every Settings change.

### Cleanup inconsistencies

One-shot, fully **non-destructive** "cleanup!" pass (a confirm-gated top-level menu item,
or `mosquito-audio-plugin-manager-actions cleanup`) that fixes every plugin/log
inconsistency in one go, with the log and the files on disk both treated as ground truth —
never removing a real file or a log entry:

- **Missing plugins** (tracked but the file is gone) are *kept* in the log, with their
  file list emptied — the "file missing" nag stops until the plugin is reinstalled or
  explicitly removed, nothing is uninstalled.
- **Untracked files** found on disk are *registered* into the log (so they show up as
  installed and stop being offered as orphans).
- A file tracked under **several keys** is reduced to its single best owner in the log
  (disk untouched).
- **Dangling menu entries** — a generated `.desktop` whose standalone `.exe` no longer
  exists on disk — are removed (pure debris; the launcher could only fail).

**Windows VST Plugins (Wine)**, the submenu, holds the rest — genuinely Wine/yabridge-specific,
as flat items with no further settings sub-page:

- **Manage prefixes** and **Manage visible executables in Omarchy Menu**.
- **Hide VST2** and **Hide 32-bit** toggles filter the Plugin list (bitness is checked via
  `file -b` on the `.dll` — `PE32 executable` = 32-bit, `PE32+ executable` = 64-bit —
  meaningful only for the vst2/`.dll` case, since a real Windows VST3 bundle is a
  directory `scan_plugins()` never matches as a bitness-checkable file).

Sort mode itself is no longer a settings screen — it's cycled live from inside the Plugin
list with the ←/→ arrow keys, btop-style.

## Installing the module — setup-audio-plugin-manager.sh

Menu entry "**mosquito Audio Plugin Manager**" (Audio category) installed/updated by
`setup-audio-plugin-manager.sh` (search "mosquito" in the launcher to find it), which
deploys the dispatcher + core + the compiled TUI to `~/.local/bin`, installs the icon,
the Hyprland float rule for the TUI window and the `mosquito.confirm` Omarchy overlay, and
migrates the file-picker preference and state log forward while removing every pre-rename
artifact (the "VST Manager"-era binaries/desktop/icon/Hyprland block, the even older
superseded `vst-install` wrapper and its "Install a VST plugin" entry).

```bash
./apps/audio-plugin-manager/setup-audio-plugin-manager.sh           # install the manager (+ menu)
./apps/audio-plugin-manager/setup-audio-plugin-manager.sh -y        # non-interactive
```