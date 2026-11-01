# Touchpad-only configuration — Omarchy module

Configures the **touchpad only** (per-device `hl.device` config) without touching the mouse/trackpoint: `adaptive` acceleration (Omarchy global = `flat`), `sensitivity 0.0` (the mouse keeps the separate global `input.lua` pointer settings), and a base `scroll_factor 0.5` (native apps get their 1.8 gesture from the non-browser `scroll_touchpad` rule in `input.lua`). Detects the device (`hyprctl devices`, names `*-touchpad`), regenerates `~/.config/hypr/touchpad.lua` (idempotent) and registers `require("hypr.touchpad")` in `hyprland.lua`.

## Usage

Run these from the repository root:

```bash
bash code/modules/Plugins/touchpad/touchpad.sh            # applies (idempotent), reload + check
bash code/modules/Plugins/touchpad/touchpad.sh --status   # detected device + current values
bash code/modules/Plugins/touchpad/touchpad.sh --remove   # removes touchpad.lua + require, restores the stock values
bash code/modules/Plugins/touchpad/touchpad.sh -y         # non-interactive
```

Override (e.g. device or values):

```bash
TOUCHPAD_NAME=syna8018:00-06cb:ce67-touchpad TOUCHPAD_SENSITIVITY=0.0 \
  bash code/modules/Plugins/touchpad/touchpad.sh
```

> If an Omarchy update overwrites `hyprland.lua`, re-running this script is enough to restore the module registration.

## Kinetic scrolling

Kinetic/inertial scrolling is enabled by default through the `hypr-kinetic-scroll`
Hyprland plugin, installed with `hyprpm`. The script installs a pinned revision
of upstream PR #23 until it is merged: upstream `master` is not yet safe on
Hyprland 0.56 (its config values abort the compositor on load/unload).

Hyprland 0.56 rejects hyphenated plugin keys in `hl.config`. The generated
`touchpad.lua` therefore sets the deceleration and `disable_in_browser = 0`
through the plugin's Lua namespace, and applies per-app opt-outs through
`hl.plugin.kinetic_scroll.disable(...)`. The global touchpad scroll factor is
the BASE (0.5) that the plugin reads for its synthetic momentum events.

Browsers GET kinetic momentum now (they are no longer opted out). Their gesture
speed is the base 0.5; native apps get 1.8 from the non-browser
`scroll_touchpad` rule in `input.lua`. App-specific opt-outs belong to the
app's own installer (the Ableton installer disables momentum for
`ableton live 12 suite.exe`/standard/intro); the touchpad module keeps
`KINETIC_DISABLED_CLASSES` empty by default. Override it with
`KINETIC_DISABLED_CLASSES="class1,class2"` if another app needs it. Set
`KINETIC_SCROLL_ENABLED=0`
before running the script to keep the classic touchpad configuration without
the kinetic plugin.

Note: the plugin's momentum always uses the global `input:touchpad:scroll_factor`
(window rules do not apply to synthetic events), so keep the BASE low (0.5) and
use the `scroll_touchpad` window rule for native apps. Raising the global to
1.8 makes browser momentum much faster than its gesture.

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
  `hl.device({ name = <touchpad>, … })` (adaptive / 0.0 / base 0.5; native 1.8 via `input.lua`),
- the **MX Master** module (or any mouse that picks its own settings) writes
  `~/.config/hypr/mx-master.lua` with `hl.device({ name = <mouse>, … })`
  (flat / 1.0 / same as the global mouse block in `input.lua`).

Device blocks are the most specific Hyprland match, so the touchpad always
gets its settings and the mouse always gets its own — apply either, both, or
remove either in any order; the live config always reflects it.

The same pattern applies to any pair of pointer devices: write one
`hl.device` block per device, named after its `hyprctl devices` name. Add
your own module by copying `code/modules/Plugins/touchpad/touchpad.sh` (or `mx-master.sh`),
swapping the device name and the values you want. The marker blocks and the
`require()` line in `hyprland.lua` are independent.
