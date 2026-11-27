# Ableton Live Suite 12.4.7 (Native)

`setup-ableton-native.sh` automates the manual steps of
[velkajelka/linux-native-ableton](https://github.com/velkajelka/linux-native-ableton):
it clones the upstream project, installs the tools its installer needs, makes
sure both 12.4.7 archives are next to `install.sh`, and runs that installer.

**This installs Ableton Live Suite 12.4.7 only** — no other Live version or
edition is installed by this module.

## Archives

The two files must be in this folder (bootstrap moves them here from
`~/Downloads`):

- `Push3-RecoveryImage-2.4.7.zip` —
  <https://cdn-downloads.ableton.com/hardware_updates/push3/2.4.7/Push3-RecoveryImage-2.4.7.zip>
- `ableton_live_suite_12.4.7_64.zip` —
  <https://cdn-downloads.ableton.com/channels/12.4.7/ableton_live_suite_12.4.7_64.zip>

If either is found in `~/Downloads`, the installer **moves** it here (it never
copies and never overwrites an existing file). If neither is available, the
script downloads them from those URLs. The archives are then symlinked into the
upstream checkout, so each archive exists only once.

## Disk space

From upstream `install.sh` (`set_version`, Live 12): **25 GB** is the peak while
installing, **13 GB** if the program is already in place, **1 GB** if the content
is too, and about **7 GB** remains afterwards. Those figures assume both zips
are already on disk. The zips themselves are 7.50 GB and 4.45 GB (their CDN
`Content-Length`), so a fresh install with neither archive present needs about
**37 GB** free; with both present, about **25 GB**. The module keeps the zips,
so the final footprint is roughly 19 GB (7 GB program + 12 GB archives) unless
you delete them.

The Setup confirm uses the same GiB display as the rest of the TUI: about
**23.3 GiB** (upstream's 25 GB) when the zips are already available, and about
**34.4 GiB** when both still have to be downloaded. Zips in `~/Downloads` count
as available — the script moves them into this folder instead of downloading a
second copy. The install preflight uses the same numbers.

## Patch (local PATCH folder)

**The whole `PATCH/` folder is local-only and gitignored.** Nothing in it is
shipped by the repo; the Setup row advertises `p` only when the script is
actually present on this machine.

`PATCH/patch-ableton-native.sh` adapts
[ReXulEc/abletonPatcherGUI](https://github.com/ReXulEc/abletonPatcherGUI) to
this build. Upstream's CLI backend generates a signed `Authorize.auz` and
replaces an 886-byte DSA key blob **inside the app binary**. That blob also
exists in the native ELF `push3_opt/push3/Live`, so the script points the CLI
at it. The hardware code is detected from a file Live itself generated
(`Unlock.json` or the "Instructions for Offline Authorization" note) — `.auz`
license files are ignored because they contain unrelated hex codes.

```sh
PATCH/patch-ableton-native.sh            # patch, then open the install folder
PATCH/patch-ableton-native.sh --check    # applied / not applied
PATCH/patch-ableton-native.sh --revert   # restore the backed-up ELF, remove our .auz
PATCH/patch-ableton-native.sh --no-run   # only detect the HWID
```

`Live` is backed up as `Live.mosquitomarchy-backup` before the first patch, and
the generated `Authorize.auz` is copied into the install folder. Both the
folder **and the `.auz`** are opened at the end: `xdg-open` uses the
`application/x-ableton-authorization` handler registered by the installer, so
Live imports the authorization directly. The upstream checkout and its Node
dependencies live in
`PATCH/abletonPatcherGUI/`. The script bypasses the interactive prompts by
writing `config/cache.json` from the detected HWID, then runs the same
`node util/patcher.js` backend as `npm run cli`. It also fixes an upstream case
bug: `config.json` stores the keys in uppercase while `Buffer.toString("hex")`
returns lowercase.

## Old R2R/WitchWand flow (backup)

`PATCH/old/` keeps the previous local patch (`patch-ableton-native.sh`,
`WM_Ableton.r2rwm`, `vcruntime140_1.dll`). It detected the HWID, copied it to
the clipboard, opened the `.r2rwm` with `WitchWand.exe` under Wine and staged
the resulting `.auz`. It is kept as a fallback only; the `p` shortcut now runs
the ELF patcher above.

## What this build can and cannot do

- It is **X11 only**: the bundled Qt has only the `xcb` platform plugin, so on
  Hyprland it runs through Xwayland. There is no native Wayland backend.
- It reads VST3 bundles (`~/.vst3`, `/usr/lib/vst3`, …). This build **does not
  support VST2**, so yabridged VST2 `.so` files in `~/.vst` are invisible;
  only Windows plugins bridged as VST3 (e.g. `~/.vst3/yabridge/*.vst3`) show up.

## Usage

```sh
./setup-ableton-native.sh            # install, prompts kept
./setup-ableton-native.sh -i         # same, used by the TUI
./setup-ableton-native.sh -y         # non-interactive
./setup-ableton-native.sh --status
./setup-ableton-native.sh -u         # uninstall via upstream uninstall.sh
```

Dependencies (`unzip`, `e2fsprogs`/`debugfs`, `cabextract`, `python3`,
`pipewire-alsa`) are installed with `pacman` on Arch, or `apt`/`dnf`/`zypper`
elsewhere. The upstream installer may ask about the `/lib/ld-linux-x86-64.so.2`
loader link and the Push USB udev rule; in `-y` mode the safe defaults are used
(Arch already has the linker). Live starts unauthorized: authorize it with your
Ableton account as usual.

The generated menu entry is renamed to `Ableton Live 12 (Native)` so it is
distinguishable from the Wine module's `Ableton Live … (Wine)` entries.

## yabridge VST3 plug-ins

This Live build scans the **top level** of `~/.vst3` and cannot load the Windows
`.vst3` bundles that APM links into the shared VST root. yabridge keeps its
Linux wrappers one level down in `~/.vst3/yabridge/`, so the installer now
exposes them as top-level symlinks:

```sh
./setup-ableton-native.sh --links   # idempotent; run after adding plug-ins
```

Existing files with the same name are never overwritten. Restart Live and
rescan plug-ins afterwards. VST2 yabridge wrappers in `~/.vst` remain invisible:
this build has no VST2 support.

## Move / USB devices

`patch-move-native.sh` is the native counterpart of the Wine Move patch. It
only installs the udev rule for Ableton USB devices (vendor `2982`); the Wine
patch's `libusb-1.0` DllOverride has no equivalent for a Linux ELF, so no Wine
prefix or Windows DLL is touched. Press **P** on the `ableton-native` row to
apply it; **P** in the Uninstall tree removes it.

```sh
patch-move-native.sh            # apply
patch-move-native.sh --check    # move-native: applied | not applied
patch-move-native.sh --revert   # remove only the rule we installed
```

The rule grants access; whether the Move is actually supported depends on the
Move/companion support compiled into this Push 3 based build of Live.
