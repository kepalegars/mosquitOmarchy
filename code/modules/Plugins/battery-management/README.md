# Battery management — Omarchy module

This module is a power-profile panel: it changes the battery icon color to match the selected profile and turns it red below 10% charge. Installing it replaces the stock battery/power bar widget in place, keeping its position and settings.

- **performance** — blue
- **power-saver** — green
- **balanced/other** — normal adaptive bar color
- **below 10% battery** — red

The installer deploys corrected `battery-status` telemetry, `battery-temps` (live CPU/GPU temperatures) and the `power-helper`, and provisions the `mosquito.battery` plugin (battery service + power-profile bar widget), which also hosts the module's own confirm card. The bar's coffee indicator is not managed here: it belongs to mega-caffeine, which also reads the Live Mode state. The battery panel's status line reads `CPU 56°C` (plus `GPU 54°C` when a discrete GPU is present) instead of the rotating phrases.

Coffee mode (`mega-caffeine`) is independent: [code/modules/mosquito/mega-caffeine](../../mosquito/mega-caffeine/README.md).

## Usage

```bash
code/modules/Plugins/battery-management/setup-battery-management.sh
code/modules/Plugins/battery-management/setup-battery-management.sh --remove
code/modules/Plugins/battery-management/setup-battery-management.sh --refresh-plugin battery
```

Run as the desktop user for plugins and as root when removing the legacy charge-control rule.
