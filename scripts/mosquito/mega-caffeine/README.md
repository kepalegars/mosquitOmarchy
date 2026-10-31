# mega-caffeine — Omarchy module

**Coffee mode**: close the laptop, let everything run — tints the screen red
(`hyprsunset`), blocks sleep when the lid is closed (`systemd-inhibit`), monitors
shutdown conditions. Duration in **natural language** (`90`, `1h30`, `2 days`,
empty = unlimited); auto stop if CPU > **85 °C** or battery < **10 %** (adjustable
thresholds).

- **install** → `setup-mega-caffeine.sh` (also the `mega-caffeine` module of `mosquitomarchy-setup.sh`)
- **uninstall** → `setup-mega-caffeine.sh --remove`, or the `mega-caffeine` module of `mosquitomarchy-setup.sh --uninstall`

The installer deploys the binary and the `Trigger > Toggle > Mega caffeine` menu
entry. Mega caffeine does not depend on battery-management.

```bash
scripts/mosquito/mega-caffeine/setup-mega-caffeine.sh          # install (idempotent)
scripts/mosquito/mega-caffeine/setup-mega-caffeine.sh --remove # stop + remove menu entry
scripts/mosquito/mega-caffeine/setup-mega-caffeine.sh --status # 0 when installed
```

## Usage

```bash
mega-caffeine on|off|toggle|status            # --status: JSON for widgets
mega-caffeine on --duration "2h30"            # no prompt
mega-caffeine --temp-limit 90 --tint 2400     # thresholds
mega-caffeine probe                           # diagnostic (temp, battery, tint)
```

Native Omarchy UI (no `gum`):

- **Duration prompt** — a native menu input appears when no `--duration` is given;
- **stay-awake integration** — while active, the idle-service stay-awake is forced on and restored on exit (the indicator shows a **red icon** with the remaining time / "unlimited" in its tooltip, click = stop).

Full stop (`on`/`off`/expiry/threshold) disables the `systemd-inhibit`, restores the tint to daylight, and cleans its state files.

Coffee-mode toasts follow the battery watchdog policy: the *activation*
("Always awake no matter what…") and the *battery-too-low abort* are sent
persistent (stay up until dismissed, cleared again by `stop_caffeine`), while
one-shot confirmations ("Already active/off", "Deactivated") stay transient.
