# Battery management — Omarchy module

This module used to provide **ultra-save**, an aggressive low-power mode that forced the power-saver profile and capped CPU performance, with a watchdog to warn when that cap stalled work. That mode was abandoned. The module is now a simple power-profile panel: it changes the battery icon color to match the selected profile and turns it red below 10% charge.

- **performance** — blue
- **power-saver** — green
- **balanced/other** — normal adaptive bar color
- **below 10% battery** — red

The installer deploys corrected `battery-status` telemetry, `battery-temps` (live CPU/GPU temperatures) and the `power-helper`, and provisions the `mosquito.power`, `mosquito.indicators`, and `mosquito.confirm` plugins. The power panel's status line reads `CPU 56°C` (plus `GPU 54°C` when a discrete GPU is present) instead of the rotating phrases. It also removes legacy ultra-save binaries, state, timer, sudoers, and menu entries when possible.

Coffee mode (`mega-caffeine`) is independent: [code/modules/mosquito/mega-caffeine](../../mosquito/mega-caffeine/README.md).

## Usage

```bash
code/modules/Plugins/battery-management/setup-battery-management.sh
code/modules/Plugins/battery-management/setup-battery-management.sh --remove
code/modules/Plugins/battery-management/setup-battery-management.sh --refresh-plugin power
```

Run as the desktop user for plugins and as root when removing the retired sudoers or legacy charge-control rule.
