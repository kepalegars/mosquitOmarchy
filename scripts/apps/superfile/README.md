# SuperFile — Omarchy module (`scripts/apps/superfile`)

Installs [superfile](https://superfile.dev) (`spf`, a terminal file manager) as a **regular
application you launch** on Omarchy. It does **not** become the system file manager: it never
runs `xdg-mime default`, never registers a default-file-manager `.desktop` role, and never
overrides the FileChooser portal. The system's default file manager (normally Nautilus) is left
exactly as it is.

Everything is user-scoped and reversible; the package install asks for `sudo` explicitly at the
point it is needed (same convention as this repo's other AUR/app modules).

## What it installs

| Item | Path |
|---|---|
| Package | `superfile` (pacman, official repo — an existing AUR `superfile-git` also satisfies it) |
| Menu entry | `~/.local/share/applications/superfile.desktop` (launches `spf` in a terminal) |
| Icon | `~/.local/share/icons/hicolor/256x256/apps/superfile.png` |
| Script/executable launcher | `~/.local/bin/superfile-open-exec` |
| Theme | `~/.config/superfile/theme/omarchy.toml` + `theme` line in `~/.config/superfile/config.toml` |
| Theme-change hook | `~/.config/omarchy/hooks/theme-set.d/superfile-module.sh` |

There is a single script — `setup-superfile.sh`. The theme generator used to live in a separate
`apply-omarchy-theme.sh`; it is now the `apply_omarchy_theme()` function inside
`setup-superfile.sh`, invoked at install time and re-invoked by the theme-set hook via
`setup-superfile.sh --apply-theme`.

## Usage

```bash
./setup-superfile.sh                # install
./setup-superfile.sh -y             # non-interactive install
./setup-superfile.sh --apply-theme  # regenerate the theme only (used by the hook)
./setup-superfile.sh --status
./setup-superfile.sh --remove
```

`--remove` reverses only what this module installs: the menu entry, icon, wrapper, the
`[open_with]` keys it added (between the `superfile-module-exec-open` markers), generated theme
+ config `theme` line, and the theme-set hook (plus the stale `superfile-apply-omarchy-theme`
copy left by older installs). It also strips the legacy `superfile-module-keybindings` block
from `~/.config/hypr/bindings.lua` if an earlier version added it, and deletes any stale editor
preference (`~/.config/superfile-module/editor`) left by those older installs. The `superfile`
package itself is left installed (remove it with `sudo pacman -Rns superfile` if wanted).

## Running scripts and editing (part of the install)

There is **no editor choice**. Superfile's `[open_with]` table is configured so that pressing
**Enter/Right on a `.sh` (or `.bash`/`.zsh`) file RUNS it** (via `bash`/`zsh`) in a new,
held-open terminal instead of opening it in the editor. Bare executables (no extension, or
`chmod +x`'d AppImages) are executed directly the same way.

A small wrapper is used (`~/.local/bin/superfile-open-exec`) because Superfile runs `[open_with]`
commands *detached from the terminal* — `utils.DetachFromTerminal()` starts the command in a new
session with stdin/stdout/stderr set to nil (see `executeOpenCommand()` in
`src/internal/handle_panel_movement.go`). A bare `sh = "bash"` would therefore execute the
script with no visible output and no way to interact with it; the wrapper opens the terminal for
you.

Editing is unchanged and separate: use Superfile's own editor hotkey — `e` for the focused file,
`E` for the current directory — which uses config.toml's `editor`. This module leaves `editor`
blank, so it falls back to `$EDITOR` (the Omarchy/system default) and then `nano`.

Limitation: `.sh`/`.bash` files are always run with `bash`, so a non-executable `.sh` still runs
but one that relies on a different shebang interpreter is run with bash anyway. Only the
extensions listed above are intercepted; everything else (images, video, PDFs, archives, other
text/code) still goes to `xdg-open` as before.

## Omarchy theme

`apply_omarchy_theme()` reads Omarchy's active theme colors
(`~/.local/state/omarchy/current/theme/colors.toml`), writes
`~/.config/superfile/theme/omarchy.toml`, and points `config.toml`'s `theme` value at
`"omarchy"`. It runs once at install and again on every Omarchy theme switch through the
theme-set hook, so superfile always tracks the desktop theme. It is idempotent and only touches
the managed `omarchy.toml` file and the single `theme = …` line.

## Shortcut

There is no built-in keybinding. Add or change one through the normal keybindings menu:

```bash
scripts/setup-keybindings.sh
# Add a keybinding -> Quick function -> SuperFile  (command: foot -e spf)
```

## Icon

The official SuperFile icon is committed next to this script:

- `superfile-icon.png` — the official asset from
  [yorukot/superfile](https://github.com/yorukot/superfile) rendered to a 256×256 PNG
  (centered on a transparent square) for the hicolor theme / `.desktop` entry

`setup-superfile.sh` copies the PNG to
`~/.local/share/icons/hicolor/256x256/apps/superfile.png` and the menu entry references it as
`Icon=superfile`.
