#!/usr/bin/env bash
# Omarchy : prepares REAPER for optimal operation under Hyprland/Wayland
# - launches REAPER directly on Hyprland's native Xwayland instead of
#   xwayland-satellite: the class/title properties are then known instantly
#   at window-open, so plain static window rules apply correctly the first
#   time (no more late-arrival glitches on float/opacity/menus). Drag & drop
#   from external apps into REAPER is NOT fixed by this and isn't pursued
#   further -- REAPER's own Linux (SWELL) port has its own unreliable D&D
#   independent of the compositor ; use REAPER's Media Explorer / Insert Media
#   File instead.
# - neutralizes GDK_SCALE (huge UI) and REAPER's own auto DPI (blurry/zoomed) ;
#   Omarchy already forces xwayland.force_zero_scaling globally, so native
#   Xwayland + ui_scale_auto=0 is enough to get a crisp, correctly-sized UI
# - main window tiled ; every other REAPER window (prefs, dialogs, menus,
#   tooltips) floating, fully opaque, no blur, exempt from Omarchy's default
#   window opacity
# Idempotent: may be re-run without risk.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/gui-run.bash"  # gui-run: reopen in a terminal when launched from a file manager
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/elevate.bash"  # mq_sudo: native pkexec prompt when not root
set -euo pipefail

echo "== 1/5 Packages (reaper) =="
mq_sudo pacman -S --needed --noconfirm reaper

BIN=""
for c in /usr/lib/REAPER/reaper /opt/REAPER/reaper; do
  [ -x "$c" ] && BIN="$c" && break
done
[ -z "$BIN" ] && { echo "REAPER binary not found"; exit 1; }

echo "== 2/5 Launch wrapper =="
mkdir -p "$HOME/.local/bin"
rm -f "$HOME/.local/bin/reaper-satellite"  # old xwayland-satellite-based wrapper, superseded
# The wrapper MUST put Ableton's patched wine runtime (d2d1-nspa) first in PATH:
# REAPER resolves `wine` from PATH, and the system wine-staging has no working
# DirectComposition, so a VST3 editor that needs it dies during creation with
# STATUS_STACK_BUFFER_OVERRUN / c0000409 inside dcomp -- the Serum 2 crash.
#
# This was written into ~/.local/bin/reaper, a wrapper nothing launches, while
# the desktop entry execs reaper-launch (below) with the system wine. The
# resolution + the wrapper body now live in one shared place so the two DAW
# launchers cannot drift apart again.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/wine-runtime-daw.bash"
if ! mosquitomarchy_apply_daw_wine_runtime; then
  echo "   WARNING: no wine-d2d1-nspa runtime in ~/.local/opt. REAPER will use the" >&2
  echo "   system wine, and VST3 editors needing DirectComposition (Serum 2) may" >&2
  echo "   crash on open. Run the Ableton setup, or scripts/fixes/fix-daw-wine-runtime.sh." >&2
fi

echo "== 3/5 Application shortcut =="
mkdir -p "$HOME/.local/share/applications"
DESK="$HOME/.local/share/applications/cockos-reaper.desktop"
SRC=""
for c in /usr/share/applications/cockos-reaper.desktop /usr/share/applications/reaper.desktop; do
  [ -f "$c" ] && SRC="$c" && break
done
[ -n "$SRC" ] && cp "$SRC" "$DESK" || touch "$DESK"
sed -i -E "s|^Exec=.*|Exec=$HOME/.local/bin/reaper-launch %F|" "$DESK"
update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true

echo "== 4/5 Hyprland rules (main window tiled, dialogs centered+opaque+no blur) =="
CONF="$HOME/.config/hypr/hyprland.lua"
mkdir -p "$HOME/.config/hypr"
touch "$CONF"
# Strip any previously-injected block so re-running the script after an edit
# actually updates hyprland.lua instead of being a no-op (idempotent update,
# not just idempotent insert).
sed -i '/-- >>> reaper-setup >>>/,/-- <<< reaper-setup <<</d' "$CONF"
cat >> "$CONF" <<'EOF'
-- >>> reaper-setup >>> main window tiled ; every other REAPER-classed window
-- (prefs, save confirmation, media explorer, any dialog) floating, opaque, no
-- blur, exempt from the Omarchy default opacity. REAPER reuses the "REAPER"
-- class for all of its windows, so the main window is told apart by its title,
-- which always contains "REAPER v<version>" (unlike prefs/dialogs).
--
-- WHY center IS NOT FORCED ANY MORE. It used to be on the broad rule, so that
-- REAPER's own dialogs would not open flush against the monitor's top-left
-- corner. That is a cosmetic problem, and it was paid for with a functional
-- one: a VST3 editor window is also classed REAPER, and `center` MOVES it away
-- from the screen origin. Wine's X11 window embedding computes the pointer
-- coordinates a VST editor receives from its own window's position, so under
-- XWayland an editor that is not at (0,0) gets every click offset by that
-- distance -- the window is visible, the knobs highlight, nothing you click
-- does what you aimed at. Reported upstream for exactly this stack
-- (REAPER + yabridge + Wine >= 9.22 + Wayland) in robbert-vdh/yabridge#409,
-- where the documented behaviour is "they do not even register mouse input"
-- and the workaround is to nudge the window by a pixel.
--
-- Letting the editor sit where REAPER puts it keeps REAPER's own placement
-- (the pre-existing behaviour) and, for an editor that happens to open near
-- the origin, the offset stays small. Nothing is forced onto the plugin
-- windows any more.
o.window({ class = "^REAPER$" }, { tag = "-default-opacity", float = true, opaque = true, no_blur = true })
o.window({ class = "^REAPER$", title = ".*REAPER v[0-9].*" }, { float = false, tile = true })
-- <<< reaper-setup <<<
EOF
hyprctl reload >/dev/null 2>&1 || true

echo "== 5/5 REAPER settings (auto DPI off, initial size) =="
INI="$HOME/.config/REAPER/reaper.ini"
mkdir -p "$HOME/.config/REAPER"
touch "$INI"
set_key() { # set_key <key> <value>
  grep -q "^$1=" "$INI" && sed -i "s|^$1=.*|$1=$2|" "$INI" || echo "$1=$2" >> "$INI"
}
set_key ui_scale_auto 0   # disables the system DPI detection (source of the giant zoom)
set_key wnd_width 1600    # initial main window size ; afterwards REAPER
set_key wnd_height 900    # remembers the last used size itself

echo "Done. Launch REAPER from the launcher (or: ~/.local/bin/reaper-launch)."
