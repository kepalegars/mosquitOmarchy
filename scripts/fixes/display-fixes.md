# Display — Omarchy module (brightness + keyboard backlight)

Two independent customizations of the Omarchy display stack.

## Perceptual brightness — fix-optimized-brightness.sh

Replaces Omarchy's linear brightness with a **perceptual curve** (gamma) driving `actual_brightness` (the real perceived brightness); **0 % = screen actually off** (DPMS off), pressing brightness up turns it back on.

| Shortcut | Effect |
|---|---|
| `MonBrightnessUp` / `Down` | +/‑ 5 % |
| `ALT + Up` / `Down` | 1 % steps |
| `SHIFT + MonBrightnessDown` | 0 % = screen off |
| `SHIFT + MonBrightnessUp` | 100 % |

```bash
./fix-optimized-brightness.sh            # applies (idempotent)
./fix-optimized-brightness.sh --remove   # removes bindings + helper, restores Omarchy
```

> Curve adjustable via the `GAMMA` variable at the top of `~/.local/bin/backlight`. If an Omarchy update overwrites `bindings.lua` or the helper, re-running the script is enough to re-apply the change.

## Keyboard backlight menu entry — fix-keyboard-backlight-menu.sh

Adds the **Trigger > Hardware > Keyboard Backlight** menu entry (toggle on/off) and the `kbd-toggle [on|off]` helper. Detects the device (`tpacpi::kbd_backlight`...), remembers the last level, hides the entry if there is no backlight, and keeps the JSONC menu entry valid after writes (repaired if needed).

```bash
./fix-keyboard-backlight-menu.sh            # applies (idempotent)
./fix-keyboard-backlight-menu.sh --remove
```