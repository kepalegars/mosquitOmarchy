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
cat > "$HOME/.local/bin/reaper-launch" <<EOF
#!/usr/bin/env bash
exec /usr/bin/env -u GDK_SCALE -u GDK_DPI_SCALE -u QT_SCALE_FACTOR $BIN "\$@"
EOF
chmod +x "$HOME/.local/bin/reaper-launch"

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
-- (prefs, save confirmation, media explorer, any dialog) floating, centered,
-- opaque, no blur, exempt from the Omarchy default opacity. REAPER reuses the
-- "REAPER" class for all of its windows, so the main window is told apart by
-- its title, which always contains "REAPER v<version>" (unlike prefs/
-- dialogs). All static rules: class/title are known at window-open time now
-- that REAPER runs on native Xwayland instead of xwayland-satellite (which
-- relayed them late and needed a runtime hook to work around it -- no longer
-- necessary).
-- Rules are processed top to bottom, last match wins per field:
-- 1) broad: every REAPER window floats, opaque, no blur, centered on monitor
--    -- without this, dialogs/confirmations opened flush at the monitor's
--    top-left corner instead of a sane spot.
-- 2) but REAPER's own popup menus (File/Edit/right-click, always titled
--    exactly "menu") and empty-titled transient windows (tooltips) must NOT
--    be forced to the monitor center -- they need to stay wherever REAPER
--    put them (near the click/cursor), so center is turned back off for them.
-- 3) the main window is tiled instead (center only affects floating windows,
--    so this doesn't need to touch center at all).
o.window({ class = "^REAPER$" }, { tag = "-default-opacity", float = true, opaque = true, no_blur = true, center = true })
o.window({ class = "^REAPER$", title = "^menu$" }, { center = false })
o.window({ class = "^REAPER$", title = "^$" }, { center = false })
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
