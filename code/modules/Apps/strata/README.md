# Strata — Omarchy module (`code/modules/Apps/strata`)

Installs [Strata](https://stratafiles.io) (`strata`, a GTK4 file manager from the Omarchy
repository) and makes it the system file manager: folders, "Open file location" from other
applications, Open/Save dialogs, and Omarchy's file-manager shortcuts.

The package ships the binary and the desktop entry; this module adds the per-user wiring on
top. Everything it changes is reversible.

## What it installs

| Item | Path |
|---|---|
| Package | `strata` (Omarchy repository) → `/usr/bin/strata` |
| Menu entry | `/usr/share/applications/io.github.lgse.Strata.desktop` (from the package) |
| Default folder handler | `inode/directory` → `io.github.lgse.Strata.desktop` |
| "Open file location" | `~/.local/share/dbus-1/services/io.github.lgse.Strata.FileManager1.service` |
| Open/Save dialogs | `org.freedesktop.impl.portal.FileChooser` in `~/.config/xdg-desktop-portal/hyprland-portals.conf` |
| Omarchy keybinds | `SUPER+SHIFT+F`, `SUPER+ALT+SHIFT+F` in `~/.config/hypr/bindings.lua` (marked block) |
| Previous handler | `~/.config/strata-module/previous-folder-handler` |

Only one per-user FileManager1 provider can exist, so another one (the `flea` module installs
its own) is set aside in `~/.config/strata-module/previous-filemanager1/` and put back by
`--remove`. The portal entry keeps the other choosers in its list as fallbacks; Strata only
goes first.

## Usage

```bash
code/modules/Apps/strata/setup-strata.sh              # install
code/modules/Apps/strata/setup-strata.sh -y           # non-interactive install
code/modules/Apps/strata/setup-strata.sh --status
code/modules/Apps/strata/setup-strata.sh --remove     # undo the wiring, keep the package
code/modules/Apps/strata/setup-strata.sh --uninstall  # undo the wiring + remove the package
```

`--remove` undoes exactly what the module added: the portal preference, the FileManager1
service, the marked Omarchy keybind block, and the folder association (restored to the handler
recorded at install time, or left to the system default if that handler is gone). User
settings and themes under `~/.config/strata` are kept.

## Notes

- Re-running is safe: the keybind block is detected, not duplicated, and the previous handler
  is only recorded once.
- Strata updates with the rest of the system (`pacman -Syu`).
