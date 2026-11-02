#!/usr/bin/env bash
# tweak-keepassxc-window.sh — legacy re-apply of KeePassXC's float rule.
#
# The keepassxc module now installs this rule itself, so the tweak is no
# longer offered in the Tweaks catalog. This script remains for old backups
# that still carry "tweaks/keepassxc-window", and to remove the rule by hand.
# It uses the same marker as the module (the module replaces the old broken
# "tag = +floating-window" block).
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
-- >>> keepassxc-window-setup >>> KeePassXC is a fixed-size password window:
-- float and center it instead of tiling it. Matches the native Wayland app-id
-- and the XWayland class (StartupWMClass=keepassxc). Managed by the
-- keepassxc module — no separate tweak to apply.
o.window("org.keepassxc.KeePassXC", { float = true, center = true, size = { 1000, 700 } })
o.window({ class = "^keepassxc$" }, { float = true, center = true, size = { 1000, 700 } })
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
