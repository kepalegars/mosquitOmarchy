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

echo "== 4/6 Hyprland rules (main window tiled, dialogs centered+opaque+no blur) =="
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
--
-- REAPER's own small modal dialogs -- the unsaved-changes / save confirmation
-- ("REAPER Query") and its error/warning/info boxes ("REAPER Error", ...) --
-- are bare Win32 message boxes (measured: 234x66 and 194x77) that Wine maps at
-- (0,0), so they showed up as tiny boxes glued to the monitor's top-left
-- corner. Matching them by TITLE is what makes this safe: the class is the
-- same "REAPER" as every dialog and as a VST3 editor window, but a plugin
-- editor's title is the plugin's own name ("Serum", "ReaEQ"), never one of
-- these, and the main window's title ("REAPER v7.79 - EVALUATION LICENSE")
-- cannot match "^REAPER " followed by a dialog word. So this rule cannot move
-- an editor and cannot reintroduce the yabridge#409 click-offset bug.
o.window({ class = "^REAPER$", title = "^REAPER (Query|Error|Warning|Info|Message|MsgBox|Confirm)$" }, { float = true, center = true, size = { 440, 200 } })
--
-- There is deliberately NO keybinding here for the UI scale. It was tried, and
-- it was the wrong shape: REAPER reads ui_scale once at startup and writes its
-- own value back to reaper.ini on exit, so the only moment the value can be
-- set is before the process exists -- which means a keypress could never be
-- correct, only "run it before you launch REAPER and remember".
--
-- Instead the launcher does it. ~/.local/bin/reaper-launch runs reaper-ui-scale
-- before exec, so launching REAPER from the Omarchy menu, from the desktop
-- entry or from a shell all produce the right DPI with nothing to remember.
-- The launcher is generated by scripts/lib/wine-runtime-daw.bash, which is
-- where that hook lives; run setup after changing either side.
-- <<< reaper-setup <<</d' "$CONF"
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
--
-- REAPER's own small modal dialogs -- the unsaved-changes / save confirmation
-- ("REAPER Query") and its error/warning/info boxes ("REAPER Error", ...) --
-- are bare Win32 message boxes (measured: 234x66 and 194x77) that Wine maps at
-- (0,0), so they showed up as tiny boxes glued to the monitor's top-left
-- corner. Matching them by TITLE is what makes this safe: the class is the
-- same "REAPER" as every dialog and as a VST3 editor window, but a plugin
-- editor's title is the plugin's own name ("Serum", "ReaEQ"), never one of
-- these, and the main window's title ("REAPER v7.79 - EVALUATION LICENSE")
-- cannot match "^REAPER " followed by a dialog word. So this rule cannot move
-- an editor and cannot reintroduce the yabridge#409 click-offset bug.
o.window({ class = "^REAPER$", title = "^REAPER (Query|Error|Warning|Info|Message|MsgBox|Confirm)$" }, { float = true, center = true, size = { 440, 200 } })
--
-- There is deliberately NO keybinding here for the UI scale, and there was one
-- until this was understood properly. REAPER reads ui_scale once at startup and
-- writes its own value back to reaper.ini when it exits, so the only moment the
-- value can be set is BEFORE the process exists. A keypress could therefore
-- never be correct -- at best "run this first and remember".
--
-- The launcher does it instead: ~/.local/bin/reaper-launch runs reaper-ui-scale
-- before exec, so every way of starting REAPER (Omarchy menu, desktop entry,
-- shell) gets the right DPI with nothing to remember. That wrapper is generated
-- by scripts/lib/wine-runtime-daw.bash, which is where the hook lives -- if
-- you change one, re-run this setup so both sides agree.
-- <<< reaper-setup <<<
EOF
hyprctl reload >/dev/null 2>&1 || true

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
