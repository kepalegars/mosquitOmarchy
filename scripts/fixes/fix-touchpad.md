# Touchpad-only configuration — Omarchy module

Configures the **touchpad only** (per-device `hl.device` config) without touching the mouse/trackpoint: `adaptive` acceleration (Omarchy global = `flat`), `sensitivity -0.2` (instead of `-0.4`), `scroll_factor 0.6` (instead of `0.4`). Detects the device (`hyprctl devices`, names `*-touchpad`), regenerates `~/.config/hypr/touchpad.lua` (idempotent) and registers `require("hypr.touchpad")` in `hyprland.lua`.

## Usage

```bash
./fix-touchpad.sh            # applies (idempotent), reload + check
./fix-touchpad.sh --status   # detected device + current values
./fix-touchpad.sh --remove   # removes touchpad.lua + require, restores the stock values
./fix-touchpad.sh -y         # non-interactive
```

Override (e.g. device or values):

```bash
TOUCHPAD_NAME=syna8018:00-06cb:ce67-touchpad TOUCHPAD_SENSITIVITY=-0.2 \
  ./fix-touchpad.sh
```

> If an Omarchy update overwrites `hyprland.lua`, re-running this script is enough to restore the module registration.


## Together: touchpad + MX Master (or any mouse)

Both modules compose without conflict — each writes its OWN marker block in
`hyprland.lua` and its OWN device file, applied in any order:

- the **touchpad** module writes `~/.config/hypr/touchpad.lua` with
  `hl.device({ name = <touchpad>, … })` (adaptive / -0.2 / 0.6),
- the **MX Master** module (or any mouse that picks its own settings) writes
  `~/.config/hypr/mx-master.lua` with `hl.device({ name = <mouse>, … })`
  (flat / 1.0 / same as the global mouse block in `input.lua`).

Device blocks are the most specific Hyprland match, so the touchpad always
gets its settings and the mouse always gets its own — apply either, both, or
remove either in any order; the live config always reflects it.

The same pattern applies to any pair of pointer devices: write one
`hl.device` block per device, named after its `hyprctl devices` name. Add
your own module by copying `scripts/fixes/fix-touchpad.sh` (or `fix-mx-master.sh`),
swapping the device name and the values you want. The marker blocks and the
`require()` line in `hyprland.lua` are independent.
