# Touchpad-only configuration — Omarchy module

Configures the **touchpad only** (per-device `hl.device` config) without touching the mouse/trackpoint: `adaptive` acceleration (Omarchy global = `flat`), `sensitivity -0.2` (the mouse keeps the separate global `input.lua` pointer settings), and `scroll_factor 1.2` by default. Detects the device (`hyprctl devices`, names `*-touchpad`), regenerates `~/.config/hypr/touchpad.lua` (idempotent) and registers `require("hypr.touchpad")` in `hyprland.lua`.

## Usage

Run these from the repository root:

```bash
bash scripts/plugins/touchpad/touchpad.sh            # applies (idempotent), reload + check
bash scripts/plugins/touchpad/touchpad.sh --status   # detected device + current values
bash scripts/plugins/touchpad/touchpad.sh --remove   # removes touchpad.lua + require, restores the stock values
bash scripts/plugins/touchpad/touchpad.sh -y         # non-interactive
```

Override (e.g. device or values):

```bash
TOUCHPAD_NAME=syna8018:00-06cb:ce67-touchpad TOUCHPAD_SENSITIVITY=-0.2 \
  bash scripts/plugins/touchpad/touchpad.sh
```

> If an Omarchy update overwrites `hyprland.lua`, re-running this script is enough to restore the module registration.

## Kinetic scrolling

Kinetic/inertial scrolling is enabled by default through the `hypr-kinetic-scroll`
Hyprland plugin, installed with `hyprpm`. The generated `touchpad.lua` keeps the
plugin settings separate from the per-device `hl.device` block and aligns the
global touchpad scroll factor with the touchpad's own scroll factor, so momentum
follows the same scrolling direction. Current defaults are:

- `KINETIC_DECEL=0.98`
- `KINETIC_MIN_VELOCITY=0.5`
- `KINETIC_INTERVAL_MS=16`
- `KINETIC_DELTA_MULT=1.25`
- `KINETIC_DISABLE_BROWSER=1`
- global `scroll_factor=1.2`

Set `KINETIC_SCROLL_ENABLED=0` before running the script to keep the classic
touchpad configuration without the kinetic plugin.


## Together: touchpad + MX Master (or any mouse)

Both modules compose without conflict — each writes its OWN marker block in
`hyprland.lua` and its OWN device file, applied in any order:

- the **touchpad** module writes `~/.config/hypr/touchpad.lua` with
  `hl.device({ name = <touchpad>, … })` (adaptive / -0.2 / 1.2 by default),
- the **MX Master** module (or any mouse that picks its own settings) writes
  `~/.config/hypr/mx-master.lua` with `hl.device({ name = <mouse>, … })`
  (flat / 1.0 / same as the global mouse block in `input.lua`).

Device blocks are the most specific Hyprland match, so the touchpad always
gets its settings and the mouse always gets its own — apply either, both, or
remove either in any order; the live config always reflects it.

The same pattern applies to any pair of pointer devices: write one
`hl.device` block per device, named after its `hyprctl devices` name. Add
your own module by copying `scripts/plugins/touchpad/touchpad.sh` (or `fix-mx-master.sh`),
swapping the device name and the values you want. The marker blocks and the
`require()` line in `hyprland.lua` are independent.
