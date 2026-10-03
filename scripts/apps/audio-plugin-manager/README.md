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

## Contents

- [Before reporting a failed install](#before-reporting-a-failed-install)
- [The stack — setup-audio-stack.sh](#the-stack--setup-audio-stacksh)
- [Shared folders, vendor data, and the registry](#shared-folders-vendor-data-and-the-registry--link-vst-sharedsh)
- [The manager](#the-manager)
- [Prefixes, and which one a DAW must use](#prefixes-and-which-one-a-daw-must-use)
- [The two universes](#the-two-universes)
- [Where DAWs must look](#where-daws-must-look)
- [First launch](#first-launch)
- [The plugin list](#the-plugin-list)
- [Launch an executable in the default prefix](#launch-an-executable-in-the-default-prefix)
- [Plugin fixes](#plugin-fixes)
- [Known traps](#known-traps)
- [Settings](#settings)
- [Parked work](#parked-work)
- [Cleanup inconsistencies](#cleanup-inconsistencies)
- [Wine menu cleanup](#wine-menu-cleanup)
- [Install the manager](#install-the-manager)

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

## Shared folders, vendor data, and the registry — `link-vst-shared.sh`

A Windows plugin is **not self-contained**, and linking its files is only the first of three
things that have to cross a prefix boundary. This is why "install once, use in every DAW" needs
more than symlinks, and why most of the problems reported against this stack were not really
about wine.

### 1. Plugin entry points

The real files stay in the shared root (`~/Music/Audio Plugins/{vst,vst3,clap}`) and each
prefix's Windows plugin folders become symlinks into it:

| In the prefix | Points at |
|---|---|
| `Program Files/Common Files/VST3`, `Program Files (x86)/Common Files/VST3` | the shared `vst3/` |
| `Program Files/Common Files/CLAP`, `Program Files (x86)/Common Files/CLAP` | the shared `clap/` |
| `Program Files/Steinberg/VSTPlugins`, `Program Files (x86)/Steinberg/VSTPlugins` | the shared `vst/` |

### 2. Vendor **data**, which lives inside the prefix

Several vendors ship a thin loader next to the real code, and the real code lives at a path
compiled into the binary. A plugin loaded in a prefix that lacks it fails in a way that reads
like a broken install:

- **Kilohearts** — every `kHs*.vst3` is a ~240 KB stub that imports only four Windows DLLs and
  calls `LoadLibrary` for `HeartCore`, a single 74 MB DLL the installer drops under
  `ProgramData/Kilohearts`.
- **iZotope** — the bundles in the shared store symlink their `Cores/` and `Presets/` back to
  `Program Files/iZotope`. Pro-R and RX read impulse responses from there and report them
  missing when the path is absent or empty.
- **Sonible** — smartEQ, smart:comp and smart:chain run their analysis against per-product
  neural models under `Common Files/sonible`: ~400 MB of `.nn` files. Without them the plugin
  loads and then analyses nothing.

These are linked into every prefix that runs a DAW.

### 3. A plugin's own **dependency DLL**

A plugin folder may hold more than plugins. Sonible ships `sonible_onnxruntime_v1-15-1.dll`
beside its VST3s, and `smartEQ4.vst3` / `smartgate.vst3` carry it in their **PE import table** —
a load-time dependency, not an optional one.

This matters because of *where the plugin ends up*. In the shared store the DLL is a sibling of
the plugin, which is where a Windows loader looks first. yabridge does not run the plugin from
there: it puts the Windows file inside the bundle at `Contents/x86_64-win/` and loads **that**.
The sibling is now two levels up and out of reach, so the dependency stops resolving and the
plugin never initialises. The vendor's own layout shows the answer — the Sonible plugins that
work are proper bundles and carry the DLL in `Contents/x86_64-win/`, next to the plugin.

So every `.dll` in a plugin's install folder that is not itself a plugin is linked next to the
file yabridge actually loads. Plugins with no such dependency are untouched: iZotope and
FabFilter import only Wine builtins, which is exactly why they never showed the symptom.

### 4. Vendor **registry** state

iZotope does not look for its data on the filesystem at all. Its plugins read:

```
HKLM\Software\iZotope\<PRODUCT>\CorePath = "C:\Program Files\iZotope\<product>\Cores\iZ<product>Core.dll"
```

With that value absent the plugin reports an empty core path and says *"One of the files this
plug-in needs cannot be found, please reinstall or contact technical support"* — about a file
it never tried to open. **A symlink cannot fix this**; only the registry entry carries the
answer. The installer writes the key into whichever prefix it is pointed at, which is why these
plugins can work under one DAW and fail under another, and why reinstalling changes nothing.

So vendor registry state is shared too, from the prefix that has it to the prefixes that do
not, and a prefix that already has it keeps its own.

### Deciding whose copy wins

"Has files in it" is the wrong test, and it is wrong in the direction that *keeps* the broken
copy. A partial install leaves a populated folder behind:

- `~/.wine` carried a 33 MB `ProgramData/Kilohearts` with the installer, the cache and the log —
  and no `HeartCore`, because that run was interrupted or aimed at the wrong prefix.
- `~/.wine-ableton` carried `Program Files/iZotope` holding only `VocalSynth 2`, none of the
  `Cores` the bundles point at.

So the requirement is derived from what the plugins actually dereference — the required iZotope
product names are read back out of the shared store's own symlinks — and a copy that does not
satisfy it is set aside rather than kept. **A prefix with a genuinely complete copy keeps it**:
this links the support tree, it does not decide which install of a DAW is authoritative.

Each prefix is serviced with the wine build its DAW already runs under. Handing a prefix to a
different build makes wine rewrite every builtin DLL, which is the churn all of this exists to
avoid.

```bash
scripts/apps/audio-plugin-manager/link-vst-shared.sh                    # all detected prefixes
scripts/apps/audio-plugin-manager/link-vst-shared.sh --prefix ~/.wine   # one prefix
scripts/apps/audio-plugin-manager/link-vst-shared.sh -y
```

Idempotent: a second run performs zero writes. It refuses to touch a prefix whose wineserver is
running, because a registry import into a live prefix is overwritten when wineserver exits.

> **A check that starts what it is checking.** "Is this prefix busy?" must not be
> `wineserver -p` — that flag *starts* a server. Asking it of three prefixes started stock
> wine-staging servers on prefixes belonging to the patched runtime, after which every client
> against them failed with `wine client error: version mismatch`: the server on the socket was a
> different build from the client. The check reads `/proc` and looks at each wineserver's own
> `WINEPREFIX`.

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

## Prefixes, and which one a DAW must use

There are three prefixes on a typical machine, and they are **not** interchangeable:

| Prefix | Belongs to | Wine build |
|---|---|---|
| `~/.wine-vst` | the plugin manager — where Windows plugins are installed | patched `wine-d2d1-nspa` (DComp) |
| `~/.wine-ableton` | Ableton Live | stock `wine-staging` |
| `~/.wine` | **games** — DXVK, winetricks | stock `wine-staging` |

### A plugin is not prefix-independent

This is the single most important thing to know about this stack, and it is not a Wine
limitation. A Windows plugin bundle is not self-contained: its loader hands its vendor's shared
DLL to `LoadLibrary` by name, at a path compiled into the binary. Run the host under a prefix
that lacks those and the plugin reports its own data missing — *"Could not load HeartCore"*,
*"missing impulse response files"* — while the plugin files themselves are perfectly fine in the
shared store. Only the registry entry or the prefix-internal path carries the answer.

### A DAW that runs under the wrong prefix will abort

yabridge's Wine host process can die during start-up, and when it does yabridge does what its
own source says it does: the blocking `accept()` has no cancellation, so it calls
`std::terminate()` and takes the whole DAW with it. A REAPER project can die that way.

The trigger seen in practice: the patched wine first on `PATH` while `WINEPREFIX` was unset, so
REAPER fell through to `~/.wine` — the **gaming** prefix, last initialised by stock
wine-staging. Wine answers a version switch by rewriting every builtin DLL (`wineboot -u`), and
yabridge's host died inside that. 61 of the 63 aborts in that window were REAPER's plugin
scanner, one process per wrapped plugin, every one identical.

So `~/.local/bin/reaper-launch` and `~/.local/bin/bitwig-studio` **pin `WINEPREFIX`** rather than
leaving it to the environment, and both wrappers are generated from
`scripts/lib/wine-runtime-daw.bash`. If you hand-edit one and drop the export, the crash comes
back. `~/.wine` stays the gaming prefix, which is what it was created for.

> **Do not merge the prefixes into one.** Serum 2's DirectComposition editor needs the patched
> build; DXVK and winetricks need stock. One prefix means one Wine build, so you would trade a
> REAPER abort for either a Serum 2 crash or broken games. Sharing the *data* across prefixes
> gives you install-once-use-everywhere without that trade.

### Which runtime a DAW needs

A wine VST3 editor that builds a DirectComposition surface — Serum 2 — **cannot be created under
stock wine-staging**; it dies during editor creation. Only the patched fork has working DComp, so
a DAW launched with the system wine cannot open that editor even though the plugin is installed
and yabridged correctly. This was hand-fixed once in `~/.local/bin/reaper`, a wrapper nothing
launched, while the desktop entry pointed somewhere else — so the fix looked applied and was
not. Both launchers are generated now.

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

| Fix | Default | Scope | What it does |
|---|---|---|---|
| Wine plugin GUI input | **on** | per plugin | Forces the editor window to float, stay unblurred and take XWayland input even when the plugin asks not to. Matched on the window **title** — these editors report an empty class, so a class rule is generic and hitless. |
| Link the plugin data into every wine prefix | **on** | per plugin | Runs the linker above: entry points, vendor data, dependency DLLs and vendor registry state, from the prefix that owns each into the prefixes that lack it. Recorded per plugin like the GUI-input fix — the effect is machine-wide, the record says which plugin was verified. |
| Install the Microsoft C++ runtime in the DAW prefixes | **on** | per plugin | Some plugins need a Microsoft DLL that Wine only stubs — smart:gate's only import that smartEQ4 does not have is `MSVCP140_ATOMIC_WAIT.dll`. Prefixes are detected, never assumed. |
| Ableton/Wine hover tooltips | on | once | Keeps the tooltip windows floating, unblurred, animation-free and unfocused, so hovering stops stealing input. Applied once, independent of the plugin. |
| Stop the cursor recentering | off | **global** | Hyprland 0.56.2 has **no per-window warp rule**, so this is a `cursor:no_warps` + `cursor:persistent_warps` **global** option. It affects every app, so it is never applied automatically — enable it only after confirming the recentering is Hyprland focus-warp and not Wine's own pointer handling. Tagged `[global]`. |

**The wine GUI-input fix is applied by default**, which it originally was not. It was only ever
applied to a fix that was *already* marked applied — so on a first install, nothing — and a
plugin that needs it, which is every wine editor opened under a window manager, never got it.
That is why the fixes page showed it unapplied and why *"does this plugin need fixes?"* kept
answering no for a plugin that did. A Settings row turns it off, and with it off nothing is
written without being asked.

The two filesystem/runtime fixes render **no window rule**, so `hyprland.lua` is left alone
instead of gaining an empty block. They act inside `fix_apply`.

### The offer at the end of an install is only made when there is something to offer

After a successful install the TUI may ask *"Plugin installed. Apply fixes for … now?"* — but
only when a real fix is **pending**. A plugin whose entire catalog is the input fix that applies
to every plugin anyway has, by then, already had it; the page would open to a single row that is
already ticked, and the question would read as *"this plugin needs fixes?"* for a plugin that
has nothing left to need. Already-applied fixes are not pending, and the always-applied input
fix does not count towards it.

Known plugins get their required fixes applied automatically on first install (the dependency
map is `known_plugin_fixes()` in the core lib), so a fresh install works out of the box.

`x` on the Uninstall screen opens the highlighted row's containing folder in the file manager.
The launcher warns once when it is not running under Hyprland, since the window rules and GUI
fixes are written for it.

## Known traps

Each of these was diagnosed on a real machine and cost real time. They are listed because the
symptom never points at the cause.

**"Could not load HeartCore"** — Kilohearts. Not a broken install, not a reinstall problem. The
`kHs*.vst3` are stubs that load a 74 MB DLL from `ProgramData/Kilohearts`, inside the prefix.
Running the DAW under a prefix that lacks it produces this. See *Prefixes*.

**"missing impulse response files"** — iZotope, in Ableton while fine in REAPER. Same class:
`Program Files/iZotope` is empty or absent in that prefix. Note that an **empty directory is not
a missing one** — an install that created the path and never filled it looks the same from the
outside.

**"One of the files this plug-in needs cannot be found, please reinstall"** — iZotope, and the
message is a lie about the cause. It is the plugin's own wording when its **registry**
`CorePath` is empty. Reinstalling cannot help, because the installer writes that key into the
prefix it is pointed at.

**A plugin that no DAW lists, but `regsvr32` loads fine** — a `LoadLibrary` test is not a
plugin test. It proves the image maps; it never instantiates the component class and never reads
a data file. The message only appears once the plugin is actually used.

**A repackaged plugin that will not load, in either VST2 or VST3** — check for mangled imports.
Some repacks rename Windows system DLLs and ship their own copies; if those copies are not
installed, the plugin cannot load. Look for imports that are not real DLL names.

**A scan that finds nothing and writes nothing** — check the date on Ableton's
`PluginScanDb.txt`. If it predates recent scans while `Preferences.cfg` is current, the
directory is writable and Ableton is finding nothing new. Empty a plugin's own data requirements
first: the failing vendor usually resolves its data through the registry, not the filesystem.

**`wine client error: version mismatch`** — a wineserver of a different build than your client
holds the prefix. Check what each running wineserver serves before killing anything; a stray
one on the wrong prefix is also the condition behind the REAPER abort above.

**A Hyprland rule that silently stopped applying** — check `hyprctl configerrors`. A Lua syntax
error anywhere in the config kills **every rule after it**, and the file looks fine everywhere
else. When injecting a block into a config from a shell script, never extract it by
pattern-matching comment markers: those same markers appear in the injecting script's own
`sed`/`grep` command, and the range ends there. Keep the block in its own file with no shell in
it, and verify the result parses before writing it.

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

## Parked work

`future/install-many.action` holds an `install-many` backend that is **not wired in** —
`install-many` is not a valid action. It ran every installer concurrently, each in its own
process group, with `link_prefix_to_vst` once before any of them, `post_install` once at the end
(`APM_DEFER_SYNC` on each child, the pattern already proven for uninstall batches), and a JSON
summary of status, exit code and log tail per file. A failing installer did not stop the rest.

It is parked because the half the user meets was never written: superfile still returns a single
path, so there is no queue screen, no scroll, no selection limit, no end-of-install recap, and
`Esc` during an install still means *quit* rather than *interrupt*. Wiring the action in as it
stands would add a second way to install one file at a time with none of the affordances that
make several files bearable.

Worth knowing before reviving it: **superfile has no per-item select key**. Toggling an item is
`confirm` — the same `Enter` / `Right` / `l` that opens a file — so inside selection mode the key
you would press to confirm is the key that flips a checkbox. The flow is `v`, `a` (or `A`),
`v` again, `Enter`. An invented binding is not an option: superfile validates its hotkey file
and warns on unknown fields.

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
