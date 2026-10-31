#!/usr/bin/env bash
# tweak-keepassxc-window.sh — keep KeePassXC's window floating in Hyprland.
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
# actually runs under.
#
# A preference, not a repair: KeePassXC works tiled, this only makes it behave
# the way its fixed-size UI expects. Safe to re-run (it strips the previous
# block first).
#
# Usage:
#   ./tweak-keepassxc-window.sh            # apply (idempotent)
#   ./tweak-keepassxc-window.sh --status   # report only
#   ./tweak-keepassxc-window.sh --remove   # drop the block
#   ./tweak-keepassxc-window.sh -h
set -euo pipefail

MARK="keepassxc-window-setup"
CONF="${HOME}/.config/hypr/hyprland.lua"

G='\033[1;32m'; B='\033[1;34m'; N='\033[0m'
msg(){ printf "${B}==>${N} %s\n" "$*"; }
ok(){ printf " ${G}✓${N} %s\n" "$*"; }

status(){
  if [[ -f $CONF ]] && grep -q -- ">>> $MARK >>>" "$CONF"; then
    echo "applied"
  else
    echo "not applied"
  fi
}

remove_block(){
  [[ -f $CONF ]] || return 0
  sed -i "/-- >>> $MARK >>>/,/-- <<< $MARK <<</d" "$CONF"
  command -v hyprctl >/dev/null 2>&1 && hyprctl reload >/dev/null 2>&1 || true
}

apply(){
  mkdir -p "$HOME/.config/hypr"
  touch "$CONF"
  remove_block
  cat >> "$CONF" <<'EOF'
-- >>> keepassxc-window-setup >>> float KeePassXC (tiled next to other
-- windows it doesn't adapt well) instead of the tiled default. Matches the
-- native Wayland app-id and the XWayland class (StartupWMClass=keepassxc).
o.window("org.keepassxc.KeePassXC", { tag = "+floating-window" })
o.window({ class = "^keepassxc$" }, { tag = "+floating-window" })
-- <<< keepassxc-window-setup <<<
EOF
  command -v hyprctl >/dev/null 2>&1 && hyprctl reload >/dev/null 2>&1 || true
  msg "KeePassXC float/center rule installed/updated ($CONF)"
  echo "Test: open KeePassXC — its window should float instead of tiling."
}

case "${1:-}" in
  --status) status ;;
  --remove|--uninstall) remove_block; ok "KeePassXC window rule removed" ;;
  -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) apply ;;
esac
