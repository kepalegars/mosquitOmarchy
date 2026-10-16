#!/bin/bash
# optimized-brightness.sh — Omarchy display brightness: default, plus 0%
# (screen off), plus a short 1% ramp for smooth holding.
#
# Combined single script:
#   * run it directly (or ./script -y) to install/update;
#   * run it as `brightness-0 ...` (via ~/.local/bin/brightness-0, a copy of
#     this same file) and it acts as the brightness helper (up/down/...).
#
# Install: deploys itself to ~/.local/bin/brightness-0, registers the Hyprland
# bindings, reloads the config. Remove: restores Omarchy's stock bindings.
set -euo pipefail

# ---------------------------------------------------------------------------
# installer mode
# ---------------------------------------------------------------------------
if [[ "$(basename "$0")" != "brightness-0" ]]; then
  REAL_HOME="${HOME}"
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  BIN_DIR="$REAL_HOME/.local/bin"
  BIN="$BIN_DIR/brightness-0"
  HYPR_DIR="$REAL_HOME/.config/hypr"
  BINDINGS="$HYPR_DIR/bindings.lua"
  BLOCK_START="-- >>> Omarchy_Custom_Scripts_Brightness"
  BLOCK_END="-- <<< Omarchy_Custom_Scripts_Brightness"

  info(){ echo -e "\033[1;34m==>\033[0m $*"; }
  ok(){  echo -e "\033[1;32m ✓\033[0m $*"; }
  warn(){ echo -e "\033[1;33m !\033[0m $*"; }
  err(){ echo -e "\033[1;31m ✗\033[0m $*" >&2; }

  if [[ ! -d /usr/share/omarchy ]]; then
    echo "This script is meant for Omarchy." >&2
    exit 1
  fi

  REMOVE=false
  for a in "$@"; do case "$a" in
    --remove) REMOVE=true ;;
    -y|--yes|"") : ;;
    -h|--help) sed -n '1,25p' "$0"; exit 0 ;;
    *) err "unknown option: $a"; exit 1 ;;
  esac; done

  mkdir -p "$BIN_DIR"

  if [[ $REMOVE == true ]]; then
    info "Removing brightness helper $BIN"
    rm -f "$BIN"
    ok "Helper removed"
  else
    info "Deploying helper $BIN"
    install -m 0755 "$0" "$BIN"
    bash -n "$BIN" || { err "Invalid syntax: $BIN"; rm -f "$BIN"; exit 1; }
    ok "Helper deployed ($BIN)"
  fi

  remove_block(){ # remove delimited block from bindings
    [[ -f $BINDINGS ]] || return 0
    grep -qF -- "$BLOCK_START" "$BINDINGS" || return 0
    local s e tmp
    s=$(grep -nF -- "$BLOCK_START" "$BINDINGS" | cut -d: -f1 | head -1)
    e=$(grep -nF -- "$BLOCK_END" "$BINDINGS" | cut -d: -f1 | head -1)
    if [[ -n $s && -n $e && $e -gt $s ]]; then
      tmp=$(mktemp); head -n $((s - 1)) "$BINDINGS" > "$tmp"; tail -n +$((e + 1)) "$BINDINGS" >> "$tmp"; mv "$tmp" "$BINDINGS"
      return 0
    fi
    return 1
  }

  if [[ $REMOVE == true ]]; then
    remove_block && ok "Brightness block removed from $BINDINGS" || ok "No Brightness block"
    [[ -f $BINDINGS ]] && hyprctl reload >/dev/null 2>&1 || true
    exit 0
  fi

  info "Integrating brightness bindings"
  mkdir -p "$HYPR_DIR"
  remove_block || true
  bt=$(mktemp)
  cat > "$bt" <<BLOCK
$BLOCK_START
-- Omarchy's default display brightness, plus 0% = screen off.
-- (wrapper: brightness-0 adds the 0% step and a short 1% ramp.)
hl.unbind("XF86MonBrightnessUp")
o.bind("XF86MonBrightnessUp", "Brightness up", "$BIN up", { locked = true, repeating = true })
hl.unbind("XF86MonBrightnessDown")
o.bind("XF86MonBrightnessDown", "Brightness down", "$BIN down", { locked = true, repeating = true })
hl.unbind("SHIFT + XF86MonBrightnessDown")
o.bind("SHIFT + XF86MonBrightnessDown", "Brightness 0% (screen off)", "omarchy-brightness-display off", { locked = true, repeating = true })
$BLOCK_END
BLOCK
  if [[ -s $BINDINGS ]]; then
    { echo ""; cat "$bt"; echo ""; } >> "$BINDINGS"
  else
    echo "-- Brightness block installed" > "$BINDINGS"
    cat "$bt" >> "$BINDINGS"
  fi
  rm -f "$bt"
  ok "Brightness block written to $BINDINGS"

  if command -v hyprctl >/dev/null 2>&1; then
    if hyprctl reload >/dev/null 2>&1; then
      errs="$(hyprctl configerrors 2>/dev/null || true)"
      [[ -n "$errs" ]] && { warn "Reloaded with warnings:"; printf '%s\n' "$errs" | sed 's/^/    /'; } || ok "Hyprland reloaded, config valid"
    else
      warn "hyprctl reload failed — check manually"
    fi
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# helper mode  (invoked as `brightness-0`)
# ---------------------------------------------------------------------------
set -uo pipefail

focused_monitor() { omarchy-hyprland-monitor-focused 2>/dev/null || true; }

dpms_off() {
  command -v jq >/dev/null 2>&1 || return 1
  local mon; mon="$(focused_monitor)"
  hyprctl monitors -j 2>/dev/null \
    | jq -e --arg m "$mon" '.[] | select(.name == $m) | .dpmsStatus == false' >/dev/null 2>&1
}

is_internal() {
  local mon; mon="$(focused_monitor)"
  [[ $mon =~ ^(eDP|LVDS|DSI)- ]]
}

ramp_internal() {
  local dir="$1" device cur target diff inc i val
  device="$(omarchy-hw-display 2>/dev/null)" || return 1
  cur="$(brightnessctl -d "$device" -m 2>/dev/null | awk -F, '{ gsub("%", "", $4); print $4 }')"
  [[ $cur =~ ^[0-9]+$ ]] || return 1

  if [[ $dir == up ]]; then
    if (( cur < 5 )); then (( target = cur + 1 )); else (( target = cur + 5 )); fi
  else
    if (( cur <= 5 )); then (( target = cur - 1 )); else (( target = cur - 5 )); fi
  fi
  (( target > 100 )) && target=100
  (( target < 1 )) && target=1
  (( target == cur )) && return 0

  exec {lock_fd}>"${XDG_RUNTIME_DIR:-/tmp}/omarchy-brightness-display.lock"
  if ! flock -n "$lock_fd"; then
    brightnessctl -d "$device" set "${target}%" >/dev/null 2>&1
    omarchy-osd -i brightness -p "$(brightnessctl -d "$device" -m 2>/dev/null | awk -F, '{ gsub("%", "", $4); print $4 }')" >/dev/null 2>&1 || true
    return 0
  fi

  diff=$(( target - cur ))
  local inc_dec
  if (( diff > 0 )); then inc=1; else inc=-1; fi
  local steps=${diff#-}
  local val=$cur
  for (( i = 0; i < steps; i++ )); do
    val=$(( val + inc ))
    brightnessctl -d "$device" set "${val}%" >/dev/null 2>&1 || true
    sleep 0.02
  done
  brightnessctl -d "$device" set "${target}%" >/dev/null 2>&1 || true
  omarchy-osd -i brightness -p "$(brightnessctl -d "$device" -m 2>/dev/null | awk -F, '{ gsub("%", "", $4); print $4 }')" >/dev/null 2>&1 || true
}

case "${1:-}" in
  down)
    if ! is_internal; then
      exec omarchy-brightness-display 5%-
    fi
    cur="$(brightnessctl -d "$(omarchy-hw-display)" -m 2>/dev/null | awk -F, '{ gsub("%", "", $4); print $4 }')"
    [[ $cur =~ ^[0-9]+$ ]] || cur="$(omarchy-brightness-display 2>/dev/null || true)"
    if [[ $cur =~ ^[0-9]+$ ]] && (( cur <= 1 )); then
      omarchy-brightness-display off
      exit 0
    fi
    ramp_internal down
    ;;

  up)
    if dpms_off; then
      omarchy-brightness-display on
      exit 0
    fi
    if ! is_internal; then
      exec omarchy-brightness-display +5%
    fi
    ramp_internal up
    ;;

  *)
    exec omarchy-brightness-display "$@"
    ;;
esac
