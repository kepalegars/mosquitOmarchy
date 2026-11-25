#!/usr/bin/env bash
# fix-hyprland-autofocus.sh — smart focus: only the app you are using may take
# focus, and focusing never warps the pointer.
#
# By default a client may ask for focus (misc:focus_on_activate), a new window
# takes focus when it maps, and activation warps the pointer to the window's
# middle. This writes one marked Lua block that stops all three, then gives
# focus back only when the new window belongs to the app already focused (same
# PID, or same non-empty class — Wine dialogs share their main window's
# PID/class):
#
#   misc:focus_on_activate = false
#   cursor:no_warps = true
#   window rule: no_initial_focus for every window
#   hl.on("window.urgent" / "window.open") → focus if same app
#
# Pointer-follow is left at the Omarchy/Hyprland default: hovering a window
# still focuses it. Result: a background app finishing its load does not steal
# focus, a dialog opened by the app you are using does, and the pointer never
# jumps to the middle of a window. The block is idempotent and reversible;
# other window rules are untouched.
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
    if grep -qF 'window.urgent' "$HYPR"; then
      printf '    block  : installed (smart)\n'
    else
      printf '    block  : installed (legacy)\n'
    fi
  else
    printf '    block  : absent\n'
  fi
  if command -v hyprctl >/dev/null 2>&1; then
    local o
    for o in misc:focus_on_activate cursor:no_warps; do
      printf '    %-34s %s\n' "$o" "$(hyprctl getoption "$o" 2>/dev/null | head -n1)"
    done
  fi
}

apply() {
  marker_strip "$HYPR" "$BEGIN" "$END" 2>/dev/null || true
  cat >>"$HYPR" <<'EOF'

-- >>> mosquito-no-autofocus >>> smart focus: the app you are using keeps it
-- New windows never focus themselves (no_initial_focus) and activation
-- requests are ignored (focus_on_activate); the callbacks hand focus back
-- only to a window of the app already focused — same PID, or same non-empty
-- class (Wine dialogs share the main window's PID/class). Pointer-follow stays
-- at the Omarchy default, and no_warps keeps the pointer where it is when
-- focus changes. Remove with: fix-hyprland-autofocus.sh --remove
hl.config({
  misc = { focus_on_activate = false },
  cursor = { no_warps = true },
})
o.window(".*", { no_initial_focus = true })

local function mosquito_same_app(a, b)
  if not a or not b then return false end
  if a.pid == b.pid then return true end
  return a.class ~= "" and a.class == b.class
end

local function mosquito_focus_if_same_app(w)
  if not w or w.active or not w.mapped then return end
  local focused = hl.get_active_window()
  if not focused or mosquito_same_app(w, focused) then
    hl.dispatch(hl.dsp.focus({ window = "address:" .. w.address }))
  end
end

-- An app explicitly asking for focus: Wine dialogs, save prompts, activation.
hl.on("window.urgent", mosquito_focus_if_same_app)
-- New native Wayland windows. XWayland is skipped: Wine menus and tooltips
-- also arrive as windows; real XWayland dialogs come through `urgent`.
hl.on("window.open", function(w)
  if w.xwayland then return end
  mosquito_focus_if_same_app(w)
end)
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
  ok "Smart auto-focus installed (pointer-follow kept; same-app dialogs still focus). Reloaded Hyprland."
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
  -h|--help)     sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) err "Unknown option: $1 (apply --status --remove)"; exit 1 ;;
esac
