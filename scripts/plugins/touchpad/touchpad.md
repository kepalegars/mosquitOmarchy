# Touchpad-only configuration — Omarchy module

Configures the **touchpad only** (per-device `hl.device` config) without touching the mouse/trackpoint: `adaptive` acceleration (Omarchy global = `flat`), `sensitivity 0.0` (the mouse keeps the separate global `input.lua` pointer settings), and `scroll_factor 1.8` by default. Detects the device (`hyprctl devices`, names `*-touchpad`), regenerates `~/.config/hypr/touchpad.lua` (idempotent) and registers `require("hypr.touchpad")` in `hyprland.lua`.

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
TOUCHPAD_NAME=syna8018:00-06cb:ce67-touchpad TOUCHPAD_SENSITIVITY=0.0 \
  bash scripts/plugins/touchpad/touchpad.sh
```

> If an Omarchy update overwrites `hyprland.lua`, re-running this script is enough to restore the module registration.

## Kinetic scrolling

Kinetic/inertial scrolling is enabled by default through the `hypr-kinetic-scroll`
Hyprland plugin, installed with `hyprpm`. The script installs a pinned revision
of upstream PR #23 until it is merged: upstream `master` is not yet safe on
Hyprland 0.56 (its config values abort the compositor on load/unload).

Hyprland 0.56 rejects hyphenated plugin keys in `hl.config`. The generated
`touchpad.lua` therefore sets the deceleration through the plugin's Lua
namespace (`hl.config({ plugin = { kinetic_scroll = { decel = 0.96 } } })`) and
applies per-app opt-outs through `hl.plugin.kinetic_scroll.disable(...)`. The global
touchpad scroll factor is aligned with the touchpad's own scroll factor, so
momentum follows the same scrolling direction.

Override the deceleration with `KINETIC_DECEL` (closer to 1 = longer glide)
before re-running the script.

Zen is always opted out of kinetic momentum and its touchpad speed is pinned to
the stock magnitude (`0.5`), so the kinetic settings never change browser
scrolling (not even the speed). `scroll_touchpad` replaces the factor outright
and Hyprland rejects negative rule values, so the stock sign (`-0.5`) cannot be
reproduced per window: the browser follows the system's scroll direction. Set
`KINETIC_DISABLED_CLASSES="org.telegram.desktop steam"` to opt additional apps
out. Set `KINETIC_SCROLL_ENABLED=0` before running the script to keep the
classic touchpad configuration without the kinetic plugin.

Verify the plugin after applying:

```bash
hyprpm list                          # Plugin hypr-kinetic-scroll, enabled: true
hyprctl plugin list                  # hypr-kinetic-scroll loaded
hyprctl getoption plugin:kinetic-scroll:enabled
```

If install fails, rerun the script to see the full `hyprpm` output. A manual
retry is:

```bash
hyprpm update
echo y | hyprpm add https://github.com/oliverlukschander/hypr-kinetic-scroll \
  f533b6cd24447a9b4191bf5c798a267f64026f0b
hyprpm enable hypr-kinetic-scroll
hyprpm reload
```


## Together: touchpad + MX Master (or any mouse)

Both modules compose without conflict — each writes its OWN marker block in
`hyprland.lua` and its OWN device file, applied in any order:

- the **touchpad** module writes `~/.config/hypr/touchpad.lua` with
  `hl.device({ name = <touchpad>, … })` (adaptive / 0.0 / 1.8 by default),
- the **MX Master** module (or any mouse that picks its own settings) writes
  `~/.config/hypr/mx-master.lua` with `hl.device({ name = <mouse>, … })`
  (flat / 1.0 / same as the global mouse block in `input.lua`).

Device blocks are the most specific Hyprland match, so the touchpad always
gets its settings and the mouse always gets its own — apply either, both, or
remove either in any order; the live config always reflects it.

The same pattern applies to any pair of pointer devices: write one
`hl.device` block per device, named after its `hyprctl devices` name. Add
your own module by copying `scripts/plugins/touchpad/touchpad.sh` (or `mx-master.sh`),
swapping the device name and the values you want. The marker blocks and the
`require()` line in `hyprland.lua` are independent.
