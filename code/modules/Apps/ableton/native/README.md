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
into the upstream checkout (never copied), so a 4.5 GB archive exists only once.
About 25 GB of free disk space is needed while installing.

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
