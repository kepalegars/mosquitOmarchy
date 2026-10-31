# Battery management — Omarchy module

This module used to provide **ultra-save**, an aggressive low-power mode that forced the power-saver profile and capped CPU performance, with a watchdog to warn when that cap stalled work. That mode was abandoned. The module is now a simple power-profile panel: it changes the battery icon color to match the selected profile and turns it red below 10% charge.

- **performance** — blue
- **power-saver** — green
- **balanced/other** — normal adaptive bar color
- **below 10% battery** — red

The installer deploys corrected `battery-status` telemetry and the `power-helper`, and provisions the `mosquito.power`, `mosquito.indicators`, and `mosquito.confirm` plugins. It also removes legacy ultra-save binaries, state, timer, sudoers, and menu entries when possible.

Coffee mode (`mega-caffeine`) is independent: [scripts/mosquito/mega-caffeine](../../mosquito/mega-caffeine/README.md).

## Usage

```bash
scripts/plugins/battery-management/setup-battery-management.sh
scripts/plugins/battery-management/setup-battery-management.sh --remove
scripts/plugins/battery-management/setup-battery-management.sh --refresh-plugin power
```

Run as the desktop user for plugins and as root when removing the retired sudoers or legacy charge-control rule.
