# Ableton Live — two independent installs

This module folder holds **two separate ways to run Ableton Live**. Neither is
preferred over the other; they can be installed side by side or separately.

| Setup row | What it installs | Install folder | Menu entry |
|---|---|---|---|
| `ableton-native` | **Ableton Live Suite 12.4.7 only**, from the [velkajelka/linux-native-ableton](https://github.com/velkajelka/linux-native-ableton) project (Push 3 recovery image's native Linux build + Windows Suite content) | `~/.local/share/ableton-live-12` | `Ableton Live 12 (Native)` |
| `ableton-wires` | Any Live edition through the Wires Wine runtime, with shared VST links and the optional Move patch | `~/.local/share/mosquitomarchy/runtime/wires/root/Works/Music-Production` | `Ableton Live <edition> (Wires)` |

They share no state: different prefixes, different desktop files, different
uninstallers. Uninstalling one never touches the other. The Move patch (`P` on
the Wires row) applies to Wires only.

- [Native setup + the two 12.4.7 archives](native/README.md)
- [Wires setup, patches and downloads](wires/README.md)

Large installers are never in git. `./bootstrap.sh` files them out of
`~/Downloads`; the native module also downloads its own two archives if they
are missing.
