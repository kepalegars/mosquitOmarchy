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

If either is missing, the script downloads it from that URL. They are symlinked
into the upstream checkout (never copied), so each archive exists only once.

## Disk space

From upstream `install.sh` (`set_version`, Live 12): **25 GB** is the peak while
installing, **13 GB** if the program is already in place, **1 GB** if the content
is too, and about **7 GB** remains afterwards. Those figures assume both zips
are already on disk. The zips themselves are 7.50 GB and 4.45 GB (their CDN
`Content-Length`), so a fresh install with neither archive present needs about
**37 GB** free; with both present, about **25 GB**. The module keeps the zips,
so the final footprint is roughly 19 GB (7 GB program + 12 GB archives) unless
you delete them.

The Setup confirm shows the live estimate: it adds the archive downloads only
when they are missing. Zips still in `~/Downloads` count as available — the
script symlinks them instead of downloading a second copy. The preflight uses
the same numbers. The `GiB` shown by the TUI is the same space as upstream's
`GB` (25 GB = 23.3 GiB), just in binary units.

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
