# scripts/fixes — Omarchy fix scripts

Every fix shipped in this folder, what it does, and how to run it. All of them
are **idempotent** (safe to re-run).

They come in three groups:

1. **Quick fixes** — wired into `setup-customarchy.sh` (the "quick fixes"
   question, and the launcher's **setup → Quick fixes** category): small,
   one-shot, machine-level repairs.
2. **Display / input / hardware modules** — real modules with their own
   `st_*`/`run_*`/`un_*` in the orchestrator, each documented in its own file.
3. **Optional helper** — a deliberate system change that stays OUT of the
   catalogs and the quick-fix list.

---

## 1. Quick fixes (the `FIXES` array of `setup-customarchy.sh`)

| id | Script | What it fixes |
|---|---|---|
| `keyring` | `fix-keyring.sh` | Kills the "Enter password to unlock your login keyring" prompt at app startup: creates an empty `login` keyring and removes the duplicates, points the default at it. |
| `keepassxc-window` | `fix-keepassxc-window.sh` | KeePassXC window floats + centers in Hyprland instead of behaving badly when tiled (idempotent marked block in `hyprland.lua`; matches the native Wayland app-id and the XWayland class). |
| `tui-theme` | `fix-tui-theme.sh` | Regenerates the current Omarchy palette (`omarchy theme refresh`) and rebuilds + redeploys both Go TUIs so their colors match the ACTIVE theme. The dynamic theme (palette re-read at each start) already ships in `scripts/lib/tui-kit`. |
| `omarchy-menu` | `fix-omarchy-menu.sh` | Recovers a broken Omarchy menu (blank rows / empty Apps list) caused by a user-space clone of `omarchy.menu`: removes the clones, re-enables the stock menu, restarts the shell. |
| `hyprland-crash` | `fix-hyprland-crash.sh` | Self-heals the usual "desktop came up broken" after a Hyprland crash: restores a truncated/fragmented `hyprland.lua` from the newest valid backup, normalizes fatal Lua escapes, re-arms the keyboard layout / Omarchy shell. Also installs a post-boot hook (`~/.config/omarchy/hooks/post-boot.d/zzz-fix-hyprland-crash`). |
| `ableton-wine-scroll` | `fix-wine-scroll.sh` | While Ableton (Wine/XWayland) is open, the patched Wine's optional pointer features (precise scrolling, inertia, pinch zoom, middle-drag, warp emulation) create an XInput2 implicit device grab that freezes trackpad scrolling **in the other apps**. Sets those seven features to `disabled` in the `~/.wine-ableton` registry — the persistent form of upstream's `WINE_X11_POINTER_FEATURES=disabled` master switch (issue-122 clipping repair stays active). Reversible via `--remove`. |

Run them all: `./setup-customarchy.sh` → **setup → Quick fixes** (or pick them
in the wizard's quick-fixes question).
Run one directly: `bash scripts/fixes/<script>.sh`.

## 2. Display / input / hardware modules

| Module | Script | Doc |
|---|---|---|
| `brightness` | `fix-optimized-brightness.sh` | Perceptual (gamma) brightness — 0% = screen really off (DPMS). Deploys the `backlight` helper to `~/.local/bin/`. |
| `keyboard-backlight` | `fix-keyboard-backlight-menu.sh` | Adds the Trigger > Hardware > Keyboard Backlight toggle + `kbd-toggle`. |
| `mx-master` | `fix-mx-master.sh` | Logitech MX Master thumb gesture button → SUPER (logiops daemon). |
| `touchpad` | `fix-touchpad.sh` | Touchpad-only `hl.device` tuning (adaptive, sensitivity, scroll factor) — the mouse/trackpoint are untouched. |

Details and usage: see `display-fixes.md` (brightness + keyboard backlight),
`fix-mx-master.md`, `fix-touchpad.md`. These are full orchestrator modules, so
they also run through `setup-customarchy.sh` (setup → Plugins) and report their
state in `--status`.

## 3. Optional helper (not in the quick-fix list)

| Script | What it does |
|---|---|
| `fix-replace-evince-with-papers.sh` | Swaps the system document viewer for **Papers** (GNOME). Deliberately NOT auto-run: replacing the default PDF/DJVU/TIFF… handler is a system-wide change. `--status` / `--uninstall` supported; Evince stays installed as an invisible backend so Nautilus previews keep working. |

---

## Notes

- The two display fixes are independent: brightness ≠ keyboard backlight, and
  either can be applied alone. Re-running a script re-applies the change after
  an Omarchy update overwrote `bindings.lua` / `hyprland.lua` — that is the
  intended repair path (no manual diffing).
- `scripts/fixes/backlight` is the deployed `~/.local/bin/backlight` helper
  source, not a directory.
- Quick-fix ids map 1:1 to the orchestrator's `FIXES` array; a fix not listed
  there (e.g. the Papers swap) is deliberately opt-in and never offered
  automatically.