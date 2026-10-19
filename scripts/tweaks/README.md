# `scripts/tweaks`

Small, idempotent **preferences**. They do not repair anything: the desktop already works,
these only make it behave the way the user wants (appearance, window behaviour,
de-cluttering). Re-running one re-applies it, which is the point.

They are the entries of the orchestrator's `TWEAKS` array — offered at setup and under
**Setup → Tweaks** in the TUI, and runnable directly with `bash scripts/tweaks/<script>.sh`.
They are **opt-in**: unlike `FIXES`, the unattended `-y` pass never applies them.

They were split out of `scripts/fixes/` so the two families read apart: a *fix* restores a
broken state, a *tweak* is a taste. See `../fixes/README.md` for the repairs.

| id | Script | What it changes |
|---|---|---|
| `keepassxc-window` | `tweak-keepassxc-window.sh` | Floats/centers KeePassXC in Hyprland instead of tiling it (its fixed-size templates/dialogs expect a floating window). Idempotent marked block in `hyprland.lua`, matching both the native app-id and the XWayland class. `--remove` drops the block. |
| `tui-theme` | `tweak-tui-theme.sh` | Regenerates the Omarchy palette and rebuilds every Go TUI so their colours follow the **active** theme. The dynamic palette re-read already ships in `tui-kit`; this forces it. |
| `terminal-padding` | `tweak-terminal-padding.sh` | Omarchy pads every terminal by 14px and paints that padding with the theme background, so on a dark theme the text block reads as a dark slab inside a light window. Keeps the padding but makes it take the terminal's own background. `--remove` reverts. |
| `wine-menu` | `tweak-wine-menu.sh` | `Uninstall` / `Manual` entries cluttering the launcher: a Windows installer wrote Start-Menu shortcuts into its prefix and Wine republished each as an app entry. Removes the ones belonging to prefixes mosquitOmarchy manages, plus the empty publisher folders, and refreshes the desktop database. `--all-prefixes` widens it; the `NoDisplay` file associations are never touched. Also applied at the end of the audio plugin manager, the audio stack and the Guitar Pro setup. |
| `wine-theme` | `tweak-wine-theme.sh` | Makes every native Wine window (the small "Configuration in progress / Updating…" dialogs, uninstallers, stock controls) follow the desktop's dark/light palette, by writing `[Control Panel\Colors]` in every prefix's `user.reg`. Installs a `theme-set` hook so the palette is re-applied on every theme change. `--remove` restores the saved `user.reg` files. |

## Opt-in only

`tweak-replace-evince-with-papers.sh` swaps the system document viewer for Papers. It is
deliberately **not** a quick tweak and never offered automatically: changing the default PDF
handler is a system-wide decision. `--status` and `--uninstall` are supported, and Evince
stays installed as an invisible backend so previews keep working.

## Notes

- A tweak absent from the `TWEAKS` array is opt-in by design, and stays out of the automatic pass.
