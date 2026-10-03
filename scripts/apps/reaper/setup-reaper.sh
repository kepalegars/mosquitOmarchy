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

echo "== 4/6 Hyprland rules (float + opaque + no blur, main window tiled) =="
# The REAPER block lives in scripts/apps/reaper/reaper-apply-block, NOT inline in
# a heredoc here.
#
# It used to be inline, and that was a trap. Anything that later wanted to
# EXTRACT the block from this file -- to re-apply it after an edit, or to diff it
# -- had to find it by pattern-matching the `-- >>> reaper-setup >>>` /
# `-- <<< reaper-setup <<<` markers. Those same markers also appear in THIS
# file's own `sed -i '/-- >>> reaper-setup >>>/,/-- <<< reaper-setup <<</d'`
# line, so the extraction matched it and `p` printed the surrounding shell,
# ending up with `cat >> "$CONF" <<'EOF'` inside hyprland.lua. That is a Lua
# syntax error near '>>', and it silently killed every rule after it.
#
# reaper-apply-block reads the body by line, refuses a body that still contains
# shell code or is missing its markers, and refuses to write a file that does
# not parse. One command, safe to re-run.
if bash "$(dirname "${BASH_SOURCE[0]}")/reaper-apply-block"; then
  hyprctl reload >/dev/null 2>&1 || true
else
  warn "could not update $HOME/.config/hypr/hyprland.lua — the Hyprland rules for REAPER are unchanged"
fi

echo "== 5/6 reaper-ui-scale (per-monitor UI scale) =="
UI_SCALE_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/reaper-ui-scale"
mkdir -p "$HOME/.local/bin"
if [[ -f $UI_SCALE_SRC ]]; then
  cp "$UI_SCALE_SRC" "$HOME/.local/bin/reaper-ui-scale"
  chmod +x "$HOME/.local/bin/reaper-ui-scale"
  echo "installed: ~/.local/bin/reaper-ui-scale  (SUPER SHIFT ALT + Y)"
else
  echo "WARNING: reaper-ui-scale not found next to this script; the bind will do nothing."
fi

echo "== 6/6 REAPER settings (initial window size) =="
INI="$HOME/.config/REAPER/reaper.ini"
mkdir -p "$HOME/.config/REAPER"
touch "$INI"
set_key() { # set_key <key> <value>
  grep -q "^$1=" "$INI" && sed -i "s|^$1=.*|$1=$2|" "$INI" || echo "$1=$2" >> "$INI"
}
# ui_scale is deliberately NOT pinned here. It used to be pinned to 1.0 with
# ui_scale_auto 0, on the theory that REAPER's own DPI detection was producing
# "the giant zoom". That detection cannot do per-monitor anything -- it reads one
# system-wide DPI, which X11 only has one of -- so pinning it just meant every
# monitor got the same wrong size. `reaper-ui-scale` now writes this key from the
# focused monitor's Hyprland scale, and says so instead of silently overriding.
set_key wnd_width 1600    # initial main window size ; afterwards REAPER
set_key wnd_height 900    # remembers the last used size itself

echo "Done. Launch REAPER from the launcher (or: ~/.local/bin/reaper-launch)."
