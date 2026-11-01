#!/usr/bin/env bash
# fix-hyprland-autofocus.sh — turn Hyprland's automatic focus OFF.
#
# Default Hyprland behaviour, in three places: the pointer focuses the window
# under it (input:follow_mouse), a client may ask for focus (misc:
# focus_on_activate), moving the pointer to another monitor focuses that
# monitor, and a new window takes focus when it maps. This writes one marked
# Lua block that disables all four:
#
#   input:follow_mouse = 0
#   misc:focus_on_activate = false
#   misc:mouse_move_focuses_monitor = false
#   general:no_focus_fallback = true
#   window rule: no_initial_focus for every window
#
# From then on only an explicit click/bind changes focus. The block is
# idempotent and reversible; other window rules are untouched.
#
# Usage:
#   ./fix-hyprland-autofocus.sh            # apply
#   ./fix-hyprland-autofocus.sh --status   # report
#   ./fix-hyprland-autofocus.sh --remove   # restore the previous behaviour
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/gui-run.bash"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/marker-strip.bash"
set -euo pipefail

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m !\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m ✗\033[0m %s\n' "$*" >&2; }

HYPR="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/hyprland.lua"
BEGIN='-- >>> mosquito-no-autofocus >>>'
END='-- <<< mosquito-no-autofocus <<<'

[[ -f $HYPR ]] || { err "Hyprland config not found: $HYPR"; exit 1; }

status() {
  info "Hyprland auto-focus fix — status"
  printf '    config : %s\n' "$HYPR"
  if grep -qF -- "$BEGIN" "$HYPR"; then
    printf '    block  : installed\n'
  else
    printf '    block  : absent\n'
  fi
  if command -v hyprctl >/dev/null 2>&1; then
    local o
    for o in input:follow_mouse misc:focus_on_activate \
             misc:mouse_move_focuses_monitor general:no_focus_fallback; do
      printf '    %-34s %s\n' "$o" "$(hyprctl getoption "$o" 2>/dev/null | head -n1)"
    done
  fi
}

apply() {
  marker_strip "$HYPR" "$BEGIN" "$END" 2>/dev/null || true
  cat >>"$HYPR" <<'EOF'

-- >>> mosquito-no-autofocus >>> disable every automatic focus change
-- One click/bind changes focus; pointer moves, new windows and client
-- activation requests do not. Remove with: fix-hyprland-autofocus.sh --remove
hl.config({
  input = { follow_mouse = 0 },
  misc = {
    focus_on_activate = false,
    mouse_move_focuses_monitor = false,
  },
  general = { no_focus_fallback = true },
})
o.window(".*", { no_initial_focus = true })
-- <<< mosquito-no-autofocus <<<
EOF
  if command -v luac >/dev/null 2>&1; then
    luac -p "$HYPR" 2>/dev/null || { err "hyprland.lua is not valid Lua — block left as-is"; return 1; }
  fi
  command -v hyprctl >/dev/null 2>&1 && hyprctl reload >/dev/null 2>&1 || true
  ok "Automatic focus disabled (click/bind only). Reloaded Hyprland."
}

remove() {
  marker_strip "$HYPR" "$BEGIN" "$END"
  if command -v luac >/dev/null 2>&1; then
    luac -p "$HYPR" 2>/dev/null || warn "hyprland.lua did not parse after removal — check it by hand."
  fi
  command -v hyprctl >/dev/null 2>&1 && hyprctl reload >/dev/null 2>&1 || true
  ok "Automatic focus restored (previous Hyprland behaviour)."
}

case "${1:-apply}" in
  apply|--apply) apply ;;
  --status)      status ;;
  --remove|--uninstall) remove ;;
  -h|--help)     sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) err "Unknown option: $1 (apply --status --remove)"; exit 1 ;;
esac
