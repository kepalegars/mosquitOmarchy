#!/usr/bin/env bash
# fix-hyprland-autofocus.sh — native Hyprland focus, without pointer warps.
#
# Hyprland already focuses the window you open, the window you hover and a
# client's activation request. This writes one marked Lua block that keeps
# that behaviour intact and only stops the pointer from jumping to the middle
# of a window when focus changes:
#
#   cursor:no_warps = true
#
# There is no heuristic about user intent and no per-app list: every window
# behaves the same way, opened from a keybind, the apps menu or by an app
# itself. The block is idempotent and reversible; other options and window
# rules are untouched.
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
    printf '    %-34s %s\n' cursor:no_warps \
      "$(hyprctl getoption cursor:no_warps 2>/dev/null | head -n1)"
  fi
}

apply() {
  marker_strip "$HYPR" "$BEGIN" "$END" 2>/dev/null || true
  cat >>"$HYPR" <<'EOF'

-- >>> mosquito-no-autofocus >>> native focus, no pointer warp
-- Hyprland decides focus as usual (new window, activation, pointer-follow).
-- Only the pointer jumping to the middle of a window on focus change is
-- disabled. Remove with: fix-hyprland-autofocus.sh --remove
hl.config({
  cursor = { no_warps = true },
})
-- <<< mosquito-no-autofocus <<<
EOF
  if command -v luac >/dev/null 2>&1; then
    luac -p "$HYPR" 2>/dev/null || { err "hyprland.lua is not valid Lua — block left as-is"; return 1; }
  fi
  if command -v hyprctl >/dev/null 2>&1; then
    hyprctl reload >/dev/null 2>&1 || true
    local errors
    errors="$(hyprctl configerrors 2>/dev/null || true)"
    [[ -z $errors ]] || warn "Hyprland reported config errors: $errors"
  fi
  ok "Native focus kept, pointer warps disabled. Reloaded Hyprland."
}

remove() {
  marker_strip "$HYPR" "$BEGIN" "$END"
  if command -v luac >/dev/null 2>&1; then
    luac -p "$HYPR" 2>/dev/null || warn "hyprland.lua did not parse after removal — check it by hand."
  fi
  command -v hyprctl >/dev/null 2>&1 && hyprctl reload >/dev/null 2>&1 || true
  ok "Pointer warps restored (previous Hyprland behaviour)."
}

case "${1:-apply}" in
  apply|--apply) apply ;;
  --status)      status ;;
  --remove|--uninstall) remove ;;
  -h|--help)     sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) err "Unknown option: $1 (apply --status --remove)"; exit 1 ;;
esac
