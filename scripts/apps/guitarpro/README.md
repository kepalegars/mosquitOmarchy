# Guitar Pro 8 — Omarchy module

Installs **Guitar Pro 8** via a dedicated wine prefix (`~/.wine-guitarpro8`), corefonts, PipeWire audio (48 ms latency), `~/.local/bin/guitarpro` launcher and menu shortcut. Place `guitar-pro-8-setup.exe` in `scripts/apps/guitarpro/` before running.

## Usage

```bash
./setup-guitarpro.sh        # interactive (-y: defaults, --status: state)
./setup-guitarpro.sh --dpi 120   # force the Wine DPI (96..192) instead of auto
./uninstall-guitarpro.sh      # uninstalls (prefix preserved by default)
```

## Fonts & DPI

Wine ignores the Hyprland scaling: text in Guitar Pro can show up too small, blurry, or with missing glyphs. The installer applies a **font/DPI hardening step** to the prefix:

- `LogPixels` auto-computed from your Hyprland scale (override with `--dpi 96..192`) ;
- standard font smoothing registry values (`FontSmoothing` / `FontSmoothingType` / `FontSmoothingGamma`) ;
- optional `winetricks allfonts` (proposed interactively) — fixes empty boxes / missing Tahoma glyphs.

## Menu (no duplicates)

The Windows installer checks *"create a shortcut"* by default: Wine then publishes a second entry under the Wine start menu (`wine/Programs/…`). At the end of the setup the Wine duplicate is deleted, so the Omarchy menu keeps **one** Guitar Pro 8 entry. `uninstall-guitarpro.sh` cleans these Wine leftovers too.