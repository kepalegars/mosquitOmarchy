#!/usr/bin/env bash
# hypr-tui.sh — the one float rule every mosquito TUI window gets.
#
# WHY A COMPUTED WIDTH, NOT A FIXED ONE
#   A TUI draws a fixed column grid. Its widest line is the boxed wordmark
#   (121 columns, code/lib/tui-kit/mosquito_banner.go) plus one margin column
#   each side. Turning that grid into pixels needs the terminal's font metrics
#   (foot: size in points, pad in pixels) and the screen DPI. A hardcoded
#   875x600 or 1000x780 is cramped on a small laptop and bloated on a large
#   monitor.
#
# WHAT IT WRITES
#   width  = (121 + 2) columns * cell width at the screen DPI + 2 * pad,
#            rounded up to the next 10 px (a little breathing room), and
#   height = width * monitor_h / monitor_w — an expression Hyprland evaluates
#            on the monitor the window opens on, so the ratio follows the screen.
#
# Both numbers end up in Hyprland window rules, which are in LOGICAL pixels.
# foot sizes a 9 pt font at 96 DPI whatever the output scale (dpi-aware=no,
# Omarchy's default), so the scaling factor cancels between the physical cell
# width and the logical rule; using the monitor scale here keeps the formula
# correct if Omarchy ever switches foot to dpi-aware=yes.
#
# Usage (CLI, used by the setup scripts):
#   hypr-tui.sh width [columns]                 # print the computed logical width
#   hypr-tui.sh rule <app-id> [columns]         # print the o.window rule
#   hypr-tui.sh install <app-id> <marker> [columns]  # rewrite the marked block
#   hypr-tui.sh remove <marker>
#   hypr-tui.sh status <marker>
#
# shortcut: 0.6 em is JetBrainsMono's advance (Omarchy's foot font). A different
# monospace font changes the width by a few columns — pass the new column count
# or update the constant then.

MQ_TUI_COLS="${MQ_TUI_COLS:-121}"   # ANSI Shadow wordmark = the widest TUI line

# marker_strip: a block whose END marker is malformed must not delete the rest
# of hyprland.lua (this repo has been bitten by sed ranges running to EOF).
MQ_TUI_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$MQ_TUI_LIB_DIR/marker-strip.bash"

mq_tui_file(){ printf '%s' "${HYPRLAND_CONFIG:-$HOME/.config/hypr/hyprland.lua}"; }

# Logical px needed to show <cols> columns plus one margin column each side.
mq_tui_width(){
  local cols="${1:-$MQ_TUI_COLS}"
  local foot="${XDG_CONFIG_HOME:-$HOME/.config}/foot/foot.ini"
  local pt=9 padx=14 dpi=96 scale=1 v
  if [[ -f $foot ]]; then
    v="$(sed -n 's/^font=.*size=\([0-9.]*\).*/\1/p' "$foot" | tail -1)"; [[ -n $v ]] && pt=$v
    v="$(sed -n 's/^pad=\([0-9]*\)x.*/\1/p' "$foot" | tail -1)";         [[ -n $v ]] && padx=$v
    v="$(sed -n 's/^dpi=\([0-9.]*\).*/\1/p' "$foot" | tail -1)";         [[ -n $v ]] && dpi=$v
  fi
  if command -v hyprctl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    v="$(hyprctl monitors -j 2>/dev/null | jq -r '[.[] | select(.focused)][0].scale // 1' 2>/dev/null)"
    [[ -n $v && $v != null ]] && scale=$v
  fi
  awk -v c="$cols" -v pt="$pt" -v pad="$padx" -v dpi="$dpi" -v s="$scale" 'BEGIN {
    cell = pt * dpi * s / 72 * 0.6 / s   # physical px at the screen DPI, back to logical
    w = (c + 2) * cell + 2 * pad         # grid + one margin column each side + pad
    printf "%d", int((w + 9) / 10) * 10
  }'
}

# The rule itself, multi-line so the expressions stay readable.
mq_tui_rule(){
  local app="$1" w
  w="$(mq_tui_width "${2:-}")"
  printf 'o.window("%s", {\n  float = true,\n  center = true,\n  size = { %s, "%s * monitor_h / monitor_w" },\n})\n' \
    "$app" "$w" "$w"
}

mq_tui_remove(){
  local mark="$1" f
  f="$(mq_tui_file)"
  [[ -f $f ]] || return 0
  # Older blocks (the live-mode one) closed with a ">>> mark <<<" typo. Repair
  # it to a real end marker first, otherwise marker_strip cannot see where the
  # block ends and the old rules survive as leftovers next to the new ones.
  sed -i "\|^-- >>> ${mark} <<<|s|.*|-- <<< ${mark} <<<|" "$f"
  marker_strip "$f" "-- >>> ${mark} >>>" "-- <<< ${mark} <<<"
}

mq_tui_status(){
  local mark="$1" f
  f="$(mq_tui_file)"
  [[ -f $f ]] && grep -qF -- "-- >>> ${mark} >>>" "$f" && echo installed || echo missing
}

mq_tui_install(){
  local app="$1" mark="$2" f
  f="$(mq_tui_file)"
  [[ -f $f ]] || { echo "no hyprland config at $f" >&2; return 1; }
  mq_tui_remove "$mark"
  {
    printf -- '-- >>> %s >>> one size for every mosquito TUI: width from the\n' "$mark"
    printf -- '-- column grid at the screen DPI, height from the monitor ratio.\n'
    mq_tui_rule "$app" "${3:-}"
    printf -- '-- <<< %s <<<\n' "$mark"
  } >> "$f"
  command -v hyprctl >/dev/null 2>&1 && hyprctl reload >/dev/null 2>&1 || true
  echo "TUI float rule installed for $app"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  set -uo pipefail
  case "${1:-}" in
    width)   mq_tui_width "${2:-}" ;;
    rule)    mq_tui_rule "${2:?app id required}" "${3:-}" ;;
    install) mq_tui_install "${2:?app id required}" "${3:?marker required}" "${4:-}" ;;
    remove)  mq_tui_remove "${2:?marker required}" ;;
    status)  mq_tui_status "${2:?marker required}" ;;
    *) echo "Usage: $0 width|rule|install|remove|status ..." >&2; exit 2 ;;
  esac
fi
