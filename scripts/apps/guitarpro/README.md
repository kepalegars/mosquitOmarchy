# Guitar Pro 8 — Omarchy module

Installs **Guitar Pro 8** via a dedicated wine prefix (`~/.wine-guitarpro8`), corefonts, PipeWire audio (48 ms latency), `~/.local/bin/guitarpro` launcher and menu shortcut. Place `guitar-pro-8-setup.exe` in `scripts/apps/guitarpro/` before running: at opening, the script verifies it is present and otherwise warns which file is missing (then offers rescan / a typed path).

## Usage

```bash
scripts/apps/guitarpro/setup-guitarpro.sh        # interactive (-y: defaults, --status: state)
scripts/apps/guitarpro/setup-guitarpro.sh --dpi 120   # force the Wine DPI (96..192) instead of auto
scripts/apps/guitarpro/uninstall-guitarpro.sh      # uninstalls (prefix preserved by default)
```

`-y` means "take the default answer of each question", **not** "yes to
everything": re-running the script on a machine that already has Guitar Pro
keeps the prefix, skips the fonts and skips the Windows installer — a few
seconds, just enough to repair the menu entry. Everything destructive is a `y`
default or an explicit opt-in.

## Re-runs are cheap

| Step | Behaviour on a second run |
|---|---|
| Wine prefix | kept (`Recreate the prefix ?` defaults to **no**) |
| `winetricks corefonts` | skipped if already registered in the prefix |
| `winetricks allfonts` | opt-in, therefore **off** under `-y` |
| Windows installer | skipped if `GuitarPro.exe` is already there |

## Logs

winetricks and the Windows installer are pathologically verbose (two `regedit`
spawns per font, hundreds of `fixme:` lines from the installer). Their output
goes to `~/.local/state/mosquitOmarchy/guitarpro/{corefonts,allfonts,installer}.log`
and the terminal only shows a one-line result plus the log tail on failure. Set
`WINETRICKS_VERBOSE=1` to stream everything again.

## Fonts & DPI

Wine ignores the Hyprland scaling: text in Guitar Pro can show up too small, blurry, or with missing glyphs. The installer applies a **font/DPI hardening step** to the prefix:

- `LogPixels` auto-computed from your Hyprland scale (override with `--dpi 96..192`) ;
- standard font smoothing registry values (`FontSmoothing` / `FontSmoothingType` / `FontSmoothingGamma`) ;
- optional `winetricks allfonts` (proposed interactively) — fixes empty boxes / missing Tahoma glyphs.

## Menu (no duplicates)

The Windows installer checks *"create the shortcut"* by default: Wine then
publishes its own entries under `~/.local/share/applications/wine/Programs/…`,
next to ours. At the end of the setup the **whole `wine/Programs/Arobas Music`
tree is removed** — including the Windows *"Uninstall"* shortcut, which has no
business in a launcher and is already covered by `scripts/apps/guitarpro/uninstall-guitarpro.sh``. The
Omarchy menu keeps **one** Guitar Pro 8 entry, declared with a single main
category (`AudioVideo`) so a menu cannot list it twice. The `wine-extension-*` /
`wine-protocol-*` file associations are `NoDisplay=true` and are kept.
`uninstall-guitarpro.sh` cleans these Wine leftovers too, and `--status`
reports any that reappeared.
