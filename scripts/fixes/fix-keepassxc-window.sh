#!/usr/bin/env bash
# fix-keepassxc-window.sh — KeePassXC float rule for Hyprland.
#
# KeePassXC doesn't adapt well when it is tiled next to other Hyprland
# windows (templates/dialogs/styling are made for a fixed-size window).
# This injects an idempotent marked block into ~/.config/hypr/hyprland.lua
# (same pattern as setup-ableton-move-manager.sh / setup-vst-manager.sh)
# that floats + centers KeePassXC's main window instead of tiling it,
# reusing Omarchy's own "floating-window" tag so size matches the rest of
# the desktop's floating popups. Matches both the native Wayland app-id
# (org.keepassxc.KeePassXC) and the XWayland class (keepassxc, per its
# StartupWMClass) — one or the other depending on the platform the app
# actually runs under. Safe to re-run: it strips the previous block first.
set -euo pipefail

echo "=== Fix KeePassXC window (Hyprland float rule) ==="

CONF="${HOME}/.config/hypr/hyprland.lua"
mkdir -p "$HOME/.config/hypr"
touch "$CONF"
sed -i '/-- >>> keepassxc-window-setup >>>/,/-- <<< keepassxc-window-setup <<</d' "$CONF"
cat >> "$CONF" <<'EOF'
-- >>> keepassxc-window-setup >>> float KeePassXC (tiled next to other
-- windows it doesn't adapt well) instead of the tiled default. Matches the
-- native Wayland app-id and the XWayland class (StartupWMClass=keepassxc).
o.window("org.keepassxc.KeePassXC", { tag = "+floating-window" })
o.window({ class = "^keepassxc$" }, { tag = "+floating-window" })
-- <<< keepassxc-window-setup <<<
EOF
hyprctl reload >/dev/null 2>&1 || true

echo "Hyprland float rule for KeePassXC installed/updated ($CONF)"
echo "Test: open KeePassXC — its window should float instead of tiling."