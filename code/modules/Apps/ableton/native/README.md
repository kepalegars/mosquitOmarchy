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

## Hardware ID and offline authorization

`PATCH/patch-ableton-native.sh` reads the challenge code (HWID) from the
**native** `Unlock.json`
(`$XDG_DATA_HOME/Ableton/Live 12.4.7/Unlock/Unlock.json` — never from a Wine
prefix), copies it to the clipboard, launches
`~/Documents/new patch/WM_Ableton.r2rwm`, waits for you to close it, then copies
the new `.auz` into the install folder and opens that folder.

Press **p** on the `ableton-native` row in mosquitomarchy Setup to run it; the
confirm explains the HWID → tool → `.auz` steps first.

```sh
PATCH/patch-ableton-native.sh --no-run   # only read/copy the HWID
PATCH/patch-ableton-native.sh            # full flow
PATCH/patch-ableton-native.sh --check    # applied / not applied (used by p)
PATCH/patch-ableton-native.sh --revert   # remove only the .auz files it copied
R2RWM_TOOL=/path/to/tool bash PATCH/patch-ableton-native.sh
```

Live must have been started once for `Unlock.json` to exist. The `.r2rwm` tool
is a Windows binary, so it is launched with Wine (the Ableton Wine runtime if
present), but no `WINEPREFIX` is forced and nothing is written to a prefix.

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
