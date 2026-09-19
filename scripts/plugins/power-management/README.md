# Battery / power management — Omarchy module

One-stop install/uninstall for the whole battery module:
- **install** → `setup-battery-management.sh` (also the `battery` module of `setup-customarchy.sh`)
- **uninstall** → `setup-battery-management.sh --remove`, or the `battery` module of `setup-customarchy.sh --uninstall`

Deploys `ultra-save`, `power-helper`, `mega-caffeine`, `ultra-save-watch`; NOPASSWD sudoers + udev rule `99-lenovo-charge-threshold.rules` (Lenovo charge thresholds); removes the old systemd timer and the "System > Ultra-save" menu entry; adds a `Trigger > Toggle > Mega caffeine` menu entry.

It also provisions the **custom Omarchy plugins** (clone `omarchy.power` → `custom.power` for battery/ultra-save, clone `omarchy.indicators` → `mosquito.indicators`, install the `mosquito.confirm` overlay) and applies the customized QML sources shipped in `omarchy-plugins/` so a fresh machine reproduces this machine's customizations.

## Usage

```bash
./setup-battery-management.sh            # applies everything (sudo once for udev/sudoers)
./setup-battery-management.sh --remove   # removes udev+sudoers+menu, stops caffeine
```

`--remove` stops an active coffee mode and clears its state (`~/.local/state/caffeine`); the binaries stay in `~/.local/bin` (remove them via the `battery` module of `setup-customarchy.sh --uninstall`).

## Battery icon colors (custom.power)

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

Coffee-mode toasts (`mega-caffeine`) follow the same policy: the *activation*
("Always awake no matter what…") and the *battery-too-low abort* are sent
persistent (stay up until dismissed, cleared again by `stop_caffeine`), while
one-shot confirmations ("Already active/off", "Deactivated") stay transient.

```bash
ultra-save-watch            # run one check now (what the timer calls)
```

Tuning (top of the script): `BUSY_THRESHOLD`, `SAMPLES`, `LOAD_FACTOR`,
`COOLDOWN_SEC`.

## power-helper

Backend helper for the `custom.power` plugin, composing charge preservation and ultra-save in one panel:

```bash
power-helper charging probe
power-helper charging list [--active-state]
power-helper charging set <start> <end>       # custom threshold, e.g. 50 80
power-helper charging preset <name>           # off/1d/1w...
power-helper ultrasave status
power-helper ultrasave on|off|toggle
```

Output is plain `key\tvalue` per line (like `omarchy-battery-status --shell`) so the QML process can parse it.

## mega-caffeine

**Coffee mode**: close the laptop, let everything run — tints the screen red (`hyprsunset`), blocks sleep when the lid is closed (`systemd-inhibit`), monitors shutdown conditions. Duration in **natural language** (`90`, `1h30`, `2 days`, empty = unlimited); auto stop if CPU > **85 °C** or battery < **10 %** (adjustable thresholds).

```bash
mega-caffeine on|off|toggle|status            # --status: JSON for widgets
mega-caffeine on --duration "2h30"            # no prompt
mega-caffeine --temp-limit 90 --tint 2400     # thresholds
mega-caffeine probe                           # diagnostic (temp, battery, tint)
```

Native Omarchy UI (no `gum`):

- **Duration prompt** — a native menu input appears when no `--duration` is given;
- **Ultra-save confirmation** — a native square overlay (Yes/No) is shown instead of a terminal prompt;
- **stay-awake integration** — while active, the idle-service stay-awake is forced on and restored on exit (the indicator shows a **red icon** with the remaining time / "unlimited" in its tooltip, click = stop).

Full stop (`on`/`off`/expiry/threshold) disables the `systemd-inhibit`, restores the tint to daylight, and cleans its state files.