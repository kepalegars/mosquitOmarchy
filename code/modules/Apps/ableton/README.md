# Ableton Live — two independent installs

This module folder holds **two separate ways to run Ableton Live**. Neither is
preferred over the other; they can be installed side by side or separately.

| Setup row | What it installs | Install folder | Menu entry |
|---|---|---|---|
| `ableton-native` | **Ableton Live Suite 12.4.7 only**, from the [velkajelka/linux-native-ableton](https://github.com/velkajelka/linux-native-ableton) project (Push 3 recovery image's native Linux build + Windows Suite content) | `~/.local/share/ableton-live-12` | `Ableton Live 12 (Native)` |
| `ableton-wine` | Any Live edition through the Wine-based `shibco/ableton-linux` installer, with shared VST links and the optional Move patch | `~/.wine-ableton` | `Ableton Live <edition> (Wine)` |

They share no state: different prefixes, different desktop files, different
uninstallers. Uninstalling one never touches the other. The Move patch (`P` on
the Wine row) applies to Wine only.

- [Native setup + the two 12.4.7 archives](native/README.md)
- [Wine setup, patches and troubleshooting](wine/README.md)

Large installers are never in git. `./bootstrap.sh` files them out of
`~/Downloads`; the native module also downloads its own two archives if they
are missing.
