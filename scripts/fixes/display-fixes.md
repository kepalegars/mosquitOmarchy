# Display — Omarchy module (brightness)

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
