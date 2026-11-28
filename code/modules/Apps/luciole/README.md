# Luciole — Omarchy module (`code/modules/Apps/luciole`)

Installs [Luciole](https://github.com/noctalia-dev/luciole) (the native Wayland
file manager from the Noctalia team, AUR `luciole-git`) and makes it the file
manager everywhere, then deploys the author's Luciole settings and keeps the
palette in sync with the active Omarchy theme.

## What it installs

| Item | Path |
|---|---|
| Package | `luciole-git` (AUR) → `/usr/bin/luciole` + menu entry |
| Default folder handler | `inode/directory` → `dev.noctalia.luciole.desktop` |
| "Open file location" | `~/.local/share/dbus-1/services/org.freedesktop.FileManager1.service` |
| Open/Save dialogs | `org.freedesktop.impl.portal.FileChooser` in `~/.config/xdg-desktop-portal/hyprland-portals.conf` (Luciole first, other choosers kept) |
| Omarchy keybinds | `SUPER+SHIFT+F`, `SUPER+ALT+SHIFT+F` in `~/.config/hypr/bindings.lua` (marked block) |
| Settings | `seed/settings.toml` → `~/.config/luciole/settings.toml`, deployed right after install |
| Theme sync | `~/.config/luciole/colors.toml` generated from Omarchy's `colors.toml` + `~/.config/omarchy/hooks/theme-set.d/luciole-module.sh` |

Only one per-user FileManager1 provider can own the name. If another one is
installed (the `strata` module registers its own), it is set aside in
`~/.config/luciole-module/previous-filemanager1/` and put back by `--remove`.
The previous folder handler is recorded in `~/.config/luciole-module/previous-folder-handler`.

Luciole's `color_scheme = "auto"` is set in its declarative `config.toml` (a file
Luciole never writes itself), so the generated `[colors]` palette follows every
Omarchy theme switch. A running Luciole reloads `colors.toml` live.

## Usage

```bash
code/modules/Apps/luciole/setup-luciole.sh              # install
code/modules/Apps/luciole/setup-luciole.sh -y           # non-interactive install
code/modules/Apps/luciole/setup-luciole.sh --status
code/modules/Apps/luciole/setup-luciole.sh --remove     # undo wiring, keep package
code/modules/Apps/luciole/setup-luciole.sh --uninstall  # undo wiring + remove package
code/modules/Apps/luciole/setup-luciole.sh --apply-theme  # hook entry point: palette only
```

## Notes

- Re-running is safe: the keybind block is detected, the portal list is
  de-duplicated, and an existing `settings.toml` is kept rather than overwritten
  (it is the user's live state).
- `--remove` restores the previous FileManager1 provider, folder handler and
  portal chooser list; it leaves `settings.toml` and the package in place.
- Luciole updates via `yay -Syu luciole-git`.
