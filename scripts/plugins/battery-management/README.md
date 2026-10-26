# Battery management — Omarchy module

One-stop install/uninstall for the battery/power tooling:
- **install** → `setup-battery-management.sh` (also the `battery-management` module of `mosquitomarchy-setup.sh`)
- **uninstall** → `setup-battery-management.sh --remove`, or the `battery-management` module of `mosquitomarchy-setup.sh --uninstall`

Deploys `ultra-save`, `power-helper`, `ultra-save-watch`; NOPASSWD sudoers; removes the old systemd timer, the legacy charge-threshold udev rule and the "System > Ultra-save" menu entry.

It also provisions the **custom Omarchy plugins** (clone `omarchy.power` → `mosquito.power` for battery/ultra-save, clone `omarchy.indicators` → `mosquito.indicators`, install the `mosquito.confirm` overlay) and applies the customized QML sources shipped in `omarchy-plugins/` so a fresh machine reproduces this machine's customizations.

Coffee mode (`mega-caffeine`) is a **separate module**: [scripts/mosquito/mega-caffeine](../../mosquito/mega-caffeine/README.md). Installing it pulls battery management in automatically when missing; battery management never installs or touches coffee mode.

## Usage

```bash
scripts/plugins/battery-management/setup-battery-management.sh            # applies everything (sudo once for sudoers)
scripts/plugins/battery-management/setup-battery-management.sh --remove   # removes sudoers + legacy udev rule
```

`--remove` leaves the binaries in `~/.local/bin`; remove them via the `battery-management` module of `mosquitomarchy-setup.sh --uninstall`.

## Battery icon colors (mosquito.power)

The bar battery icon is tinted by the active power profile:

| Profile | Icon color |
|---|---|
| **eco** (`power-saver`) | green |
| **performance** | blue |
| **ultra-save** (ultra-save on) | orange |
| **balanced** | the normal icon color (white on dark) |

Ultra-save always forces the `power-saver` profile internally, but it is its own mode: while it is on, **no standard power plan shows as selected** in the panel (only the Ultra-save toggle is checked). Picking a plan turns ultra-save off first.

## ultra-save

Ultra-low-power toggle designed for AMD Ryzen 7000 + power-profiles-daemon (target 6–8 W on battery): caps the CPU, dims the brightness, switches the power profile.

```bash
ultra-save on|off|toggle|status
```

## ultra-save-watch

**Saturation watchdog** — protects the desktop from freezing when ultra-save's
CPU cap (30% max frequency, no boost) is overwhelmed, e.g. a DAW render in
Reaper/Ableton while on battery. Runs every 60s via a systemd --user timer
(`mosquito-ultra-save-watch.timer`, installed by the setup script); no-op when
ultra-save is off.

When the CPU is saturated (≥ 80% busy on every sample, and/or a 1-minute load
average at the core count), it posts a **critical Omarchy notification**
("Ultra-save is maxed out" / *"Your computer is about to be frozen by the power
cap. Click this notification to disable ultra-save now."*, snowflake glyph)
that recommends switching to another power profile. **Clicking the notification
disables ultra-save** (`sudo -n ultra-save off`, NOPASSWD sudoers) so the
frequency/boost caps are reversed and the machine becomes usable again. A 10-
minute cooldown avoids nagging.

The toast is persistent (`-t 0`: it stays on screen until clicked or dismissed)
and bypasses Do-Not-Disturb (sent as `--app-name notify-send -u critical`, one of
the two channels Omarchy lets through the silencer; the generic `omarchy-action`
default of `omarchy-notification-send` bypasses it too) — it appears even when
notifications are silenced. It shows no percentage — the point is the *action*
("disable ultra-save"), not a reading the user can't act on in time.

```bash
ultra-save-watch            # run one check now (what the timer calls)
```

Tuning (top of the script): `BUSY_THRESHOLD`, `SAMPLES`, `LOAD_FACTOR`,
`COOLDOWN_SEC`.

## power-helper

Backend helper for the `mosquito.power` plugin, composing power profiles and ultra-save in one panel:

```bash
power-helper profile set <ac|battery> <profile> [drop-ultrasave|keep-ultrasave]
power-helper profile state
power-helper ultrasave status
power-helper ultrasave on|off|toggle
```

Output is plain `key\tvalue` per line (like `omarchy-battery-status --shell`) so the QML process can parse it.

## battery-status

Corrected battery telemetry (charger detection, 0 W readings) used by the panel.
