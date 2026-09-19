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