# Display — Omarchy module (brightness)

Omarchy default brightness plus 0% screen-off and a 1% hold ramp.

## Brightness — `scripts/plugins/brightness/optimized-brightness.sh`

Keeps Omarchy's default brightness behavior and adds **0 % = screen actually off**
(DPMS off); pressing brightness up turns it back on. On the internal display, held
brightness keys use short 1% steps for smoother holding.

| Shortcut | Effect |
|---|---|
| `MonBrightnessUp` / `Down` | +/‑ 5 % |
| `ALT + Up` / `Down` | 1 % steps |
| `SHIFT + MonBrightnessDown` | 0 % = screen off |
| `SHIFT + MonBrightnessUp` | 100 % |

Run these from the repository root:

```bash
bash scripts/plugins/brightness/optimized-brightness.sh            # applies (idempotent)
bash scripts/plugins/brightness/optimized-brightness.sh --remove   # removes bindings + helper, restores Omarchy
```

> If an Omarchy update overwrites `bindings.lua` or the deployed
> `~/.local/bin/brightness-0` helper, re-running the script is enough to
> re-apply the change.
