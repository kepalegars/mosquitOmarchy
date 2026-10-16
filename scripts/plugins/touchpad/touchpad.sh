#!/usr/bin/env bash
# =============================================================================
# Omarchy Custom - Touchpad (per-device config, pad only)
# =============================================================================
# Configures ONLY the laptop's touchpad:
#   • Pointer acceleration: "adaptive" profile (whereas Omarchy's global
#     setting is "flat", which disables all acceleration).
#   • Pointer sensitivity: -0.2 (the mouse keeps the separate global
#     input.lua pointer settings).
#   • Touch scroll sensitivity: 1.2 by default (the global touchpad
#     scroll_factor is -0.5; natural_scroll stays false, defined globally in
#     input.lua).
# The EXTERNAL MOUSE is NOT modified: the block is passed as per-device
# configuration (hl.device <name>) and only affects the detected touchpad.
#
# DESIGNED TO COMBINE WITH THE MX-MASTER MODULE: both modules write their OWN
# marker-delimited require block in hyprland.lua and their own device file
# (touchpad.lua / mx-master mouse block). Device-specific settings always win
# over the global input block, so applying one, the other, or both — in ANY
# order — yields the same result: pad settings for the pad, mouse settings for
# the mouse. Removing one never touches the other.
#
# What this script does:
#   1. Detects the touchpad (hyprctl devices, read-only).
#   2. Regenerates ~/.config/hypr/touchpad.lua (hl.device block delimited by
#      markers, idempotent).
#   3. Registers require("hypr.touchpad") in hyprland.lua (delimited block,
#      idempotent, added after require("hypr.autostart")).
#   4. Reloads Hyprland and checks the config errors.
#
# Default values (environment variables to change them):
#   TOUCHPAD_NAME            device name (detected otherwise: *-touchpad)
#   TOUCHPAD_ACCEL           accel_profile by default  "adaptive"
#   TOUCHPAD_SENSITIVITY     sensitivity (pointer)     -0.2
#   TOUCHPAD_SCROLL_FACTOR   scroll_factor (scroll)     1.2
#   KINETIC_SCROLL_ENABLED   kinetic scroll plugin     1 (set to 0 to disable)
#   KINETIC_DECEL            decel multiplier           0.98
#   KINETIC_MIN_VELOCITY     min velocity threshold     0.5
#   KINETIC_INTERVAL_MS      decay frame interval       16
#   KINETIC_DELTA_MULT       delta multiplier           1.25
#   KINETIC_DISABLE_BROWSER  disable in browsers        1
#   KINETIC_STOP_TARGET      stop on target change      1
#   KINETIC_DISABLED_CLASSES comma-separated classes    ""
#   KINETIC_DEBUG            debug logging              0
#
# Hyprland NOTE: SCROLL acceleration (scroll_points curve) is only exposed
# with accel_profile = "custom" and remains ambiguous for a touchpad; this
# module therefore tunes scroll sensitivity via scroll_factor.
# The kinetic-scroll plugin is a Hyprland plugin (built via hyprpm) that
# adds inertial scrolling. Its settings live in the same generated
# touchpad.lua file, separately from the per-device hl.device block; the
# global touchpad scroll factor is aligned to the touchpad's scroll factor so
# kinetic momentum follows the same scrolling direction.
#
# Usage:
#   ./touchpad.sh            # applies (idempotent), reload + check
#   ./touchpad.sh --status   # status (detected device, current values)
#   ./touchpad.sh --remove   # removes touchpad.lua + require, restores
#   ./touchpad.sh -y         # non-interactive (equivalent to asking nothing)
#
# NOTE: if an Omarchy update overwrites hyprland.lua, rerunning this script
# is enough to restore the module registration.
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/gui-run.bash"  # gui-run: reopen in a terminal when launched from a file manager
set -euo pipefail

info() { echo -e "\033[1;34m==>\033[0m $*"; }
ok()   { echo -e "\033[1;32m ✓\033[0m $*"; }
warn() { echo -e "\033[1;33m !\033[0m $*"; }
err()  { echo -e "\033[1;31m ✗\033[0m $*" >&2; }

REAL_HOME="${HOME}"
HYPR_DIR="$REAL_HOME/.config/hypr"
HYPRLAND="$HYPR_DIR/hyprland.lua"
TOUCHPAD_LUA="$HYPR_DIR/touchpad.lua"
BLOCK_START="-- >>> Omarchy_Custom_Scripts_Touchpad"
BLOCK_END="-- <<< Omarchy_Custom_Scripts_Touchpad"

ACCEL="${TOUCHPAD_ACCEL:-adaptive}"
SENS="${TOUCHPAD_SENSITIVITY:--0.2}"
SCROLL="${TOUCHPAD_SCROLL_FACTOR:-1.2}"
# Kinetic scroll (hypr-kinetic-scroll plugin) — optional
KINETIC_ENABLED="${KINETIC_SCROLL_ENABLED:-1}"
KINETIC_DECEL="${KINETIC_DECEL:-0.98}"
KINETIC_MIN_VEL="${KINETIC_MIN_VELOCITY:-0.5}"
KINETIC_INTERVAL="${KINETIC_INTERVAL_MS:-16}"
KINETIC_DELTA_MULT="${KINETIC_DELTA_MULT:-1.25}"
KINETIC_DISABLE_BROWSER="${KINETIC_DISABLE_BROWSER:-1}"
KINETIC_STOP_TARGET="${KINETIC_STOP_TARGET:-1}"
KINETIC_DISABLED_CLASSES="${KINETIC_DISABLED_CLASSES:-}"
KINETIC_DEBUG="${KINETIC_DEBUG:-0}"

if [[ ! -d /usr/share/omarchy ]]; then
  echo "This script is meant for Omarchy." >&2
  exit 1
fi

STATUS_ONLY=false REMOVE=false
for a in "$@"; do case "$a" in
  -y|--yes) : ;;
  --status) STATUS_ONLY=true ;;
  --remove) REMOVE=true ;;
  -h|--help) sed -n '1,44p' "$0"; exit 0 ;;
  *) echo "Unknown option: $a (supported: -y --status --remove)" >&2; exit 1 ;;
esac; done

# -----------------------------------------------------------------------------
# Touchpad detection (read-only)
# -----------------------------------------------------------------------------
# Returns the device name (name of the pad, or empty). Does NOT touch the
# trackpoint nor the external mouse: only names ending in "-touchpad" are kept.
detect_touchpad(){
  if [[ -n ${TOUCHPAD_NAME:-} ]]; then echo "$TOUCHPAD_NAME"; return 0; fi
  if command -v hyprctl >/dev/null 2>&1; then
    hyprctl devices 2>/dev/null | awk '$1 ~ /-touchpad$/ { print $1; exit }'
  elif command -v libinput >/dev/null 2>&1; then
    libinput list-devices 2>/dev/null | grep -oE '[^ ]+-(touchpad|Touchpad)$' | head -1
  fi
}

# -----------------------------------------------------------------------------
# require block registered in hyprland.lua
# -----------------------------------------------------------------------------
require_block() {
  cat <<BLOCK_EOF
$BLOCK_START
require("hypr.touchpad")
$BLOCK_END
BLOCK_EOF
}

# -----------------------------------------------------------------------------
# 1. Generation of touchpad.lua (idempotent)
# -----------------------------------------------------------------------------
gen_touchpad_lua() {
  local name="$1"
  mkdir -p "$HYPR_DIR"
  local tmp
  tmp=$(mktemp)
  {
    echo "$BLOCK_START"
    echo "-- Configuration of the TOUCHPAD only (device \"$name\"). The external"
    echo "-- mouse keeps the global input.lua settings. Generated by"
    echo "-- plugins/touchpad/touchpad.sh — rerun the script to re-apply."
    echo "hl.device({"
    echo "    name = \"$name\","
    echo "    -- Pointer acceleration: adaptive (the global \"flat\" profile disables it)"
    echo "    accel_profile = \"$ACCEL\","
    echo "    -- Pointer sensitivity: $SENS (the mouse keeps the global input.lua pointer settings)"
    echo "    sensitivity = $SENS,"
    echo "    -- Touch scroll sensitivity: $SCROLL (global touchpad scroll_factor: -0.5)"
    echo "    scroll_factor = $SCROLL,"
    echo "})"
    # Kinetic scroll (hypr-kinetic-scroll) — plugin config, applied only if the
    # plugin is loaded by hyprpm at config time. Writing it unconditionally
    # would only cause "unknown config key" parse warnings, so it stays guarded.
    if [[ $KINETIC_ENABLED -eq 1 ]]; then
      echo "-- Kinetic (inertial) scrolling via the hypr-kinetic-scroll plugin (hyprpm)."
      echo "if hl.plugin.kinetic_scroll then"
      echo "  hl.config({"
      echo "    plugin = {"
      echo "      kinetic_scroll = {"
      echo "        enabled = 1,"
      echo "        decel = $KINETIC_DECEL,"
      echo "        min_velocity = $KINETIC_MIN_VEL,"
      echo "        interval_ms = $KINETIC_INTERVAL,"
      echo "        delta_multiplier = $KINETIC_DELTA_MULT,"
      echo "        disable_in_browser = $KINETIC_DISABLE_BROWSER,"
      echo "        stop_on_target_change = $KINETIC_STOP_TARGET,"
      echo "        disabled_classes = \"$KINETIC_DISABLED_CLASSES\","
      echo "        debug = $KINETIC_DEBUG"
      echo "      }"
      echo "    }"
      echo "  })"
      echo "end"
    fi
    if [[ $KINETIC_ENABLED -eq 1 ]]; then
      echo "-- Keep Hyprland's global touchpad scroll_factor = $SCROLL for the"
      echo "-- hypr-kinetic-scroll plugin (which reads input:touchpad:scroll_factor)"
      echo "-- so kinetic momentum is neither reversed nor over-scaled."
      echo "hl.config({ input = { touchpad = { scroll_factor = $SCROLL } } })"
    fi
    echo "$BLOCK_END"
  } > "$tmp"
  mv "$tmp" "$TOUCHPAD_LUA"
  ok "touchpad.lua written ($name)"
}

# -----------------------------------------------------------------------------
# 2. require("hypr.touchpad") registration in hyprland.lua
# -----------------------------------------------------------------------------
ensure_require() {
  [[ -f $HYPRLAND ]] || { err "$HYPRLAND not found — cannot register the module."; return 1; }
  local tmp_block tmp_out start_line end_line
  tmp_block=$(mktemp)
  tmp_out=$(mktemp)
  require_block > "$tmp_block"

  if grep -qF -- "$BLOCK_START" "$HYPRLAND"; then
    start_line=$(grep -nF -- "$BLOCK_START" "$HYPRLAND" | cut -d: -f1 | head -1)
    end_line=$(grep -nF -- "$BLOCK_END" "$HYPRLAND" | cut -d: -f1 | head -1)
    if [[ -z $start_line || -z $end_line || $end_line -le $start_line ]]; then
      rm -f "$tmp_block"; rm -f "$tmp_out"
      err "Inconsistent markers in $HYPRLAND, manual correction needed."
      return 1
    fi
    { head -n $((start_line - 1)) "$HYPRLAND"; cat "$tmp_block"; tail -n +$((end_line + 1)) "$HYPRLAND"; } > "$tmp_out"
    mv "$tmp_out" "$HYPRLAND"
    ok "require hypr.touchpad updated in $HYPRLAND"
  else
    # Backup of the user file on first insertion.
    if [[ ! -f "$HYPRLAND.bak" ]]; then
      cp "$HYPRLAND" "$HYPRLAND.bak"
      info "Initial backup: $HYPRLAND.bak"
    fi
    awk -v bk="$tmp_block" -v tok='require("hypr.autostart")' '
      index($0, tok) == 1 && !done {
        print; print ""
        while ((getline l < bk) > 0) print l
        close(bk); done = 1; next
      }
      { print }
      END {
        if (!done) { print ""; while ((getline l < bk) > 0) print l; close(bk) }
      }
    ' "$HYPRLAND" > "$tmp_out"
    mv "$tmp_out" "$HYPRLAND"
    ok "require hypr.touchpad added in $HYPRLAND"
  fi
  rm -f "$tmp_block"
}

remove_require() {
  [[ -f $HYPRLAND ]] || return 0
  if grep -qF -- "$BLOCK_START" "$HYPRLAND"; then
    local start_line end_line tmp
    start_line=$(grep -nF -- "$BLOCK_START" "$HYPRLAND" | cut -d: -f1 | head -1)
    end_line=$(grep -nF -- "$BLOCK_END" "$HYPRLAND" | cut -d: -f1 | head -1)
    if [[ -n $start_line && -n $end_line && $end_line -gt $start_line ]]; then
      tmp=$(mktemp)
      head -n $((start_line - 1)) "$HYPRLAND" > "$tmp"
      tail -n +$((end_line + 1)) "$HYPRLAND" >> "$tmp"
      mv "$tmp" "$HYPRLAND"
      ok "require block removed from $HYPRLAND"
    else
      warn "Inconsistent markers in $HYPRLAND, nothing removed."
    fi
  else
    ok "No touchpad require block in $HYPRLAND."
  fi
}

# -----------------------------------------------------------------------------
# Plugin: hypr-kinetic-scroll (installed via hyprpm, built locally)
# -----------------------------------------------------------------------------
ensure_kinetic_scroll_plugin() {
  if [[ $KINETIC_ENABLED -ne 1 ]]; then
    return 0
  fi
  if ! command -v hyprpm >/dev/null 2>&1; then
    warn "hyprpm not found — kinetic scroll plugin will not be installed."
    return 1
  fi
  # Check if already enabled
  if hyprpm list 2>/dev/null | grep -q 'hypr-kinetic-scroll'; then
    # Ensure it's enabled
    hyprpm enable hypr-kinetic-scroll >/dev/null 2>&1 || true
    ok "hypr-kinetic-scroll already installed and enabled"
    return 0
  fi
  info "Installing hypr-kinetic-scroll via hyprpm (builds locally for your Hyprland ABI)..."
  # hyprpm add + update + enable — builds from source against your Hyprland headers.
  # `hyprpm add' prompts "are you sure?"; feed it a yes on stdin so this works
  # both interactively and under the manager TUI.
  if echo y | hyprpm add https://github.com/savonovv/hypr-kinetic-scroll >/dev/null 2>&1 && \
     hyprpm update >/dev/null 2>&1 && \
     hyprpm enable hypr-kinetic-scroll >/dev/null 2>&1; then
    ok "hypr-kinetic-scroll installed and enabled"
  else
    warn "hypr-kinetic-scroll installation failed — kinetic scroll will not work."
    warn "You can retry manually: hyprpm add https://github.com/savonovv/hypr-kinetic-scroll && hyprpm update && hyprpm enable hypr-kinetic-scroll"
    return 1
  fi
}

# -----------------------------------------------------------------------------
# 3. Hyprland reload + validation
# -----------------------------------------------------------------------------
reload_hypr() {
  if command -v hyprctl >/dev/null 2>&1; then
    if hyprctl reload >/dev/null 2>&1; then
      errors="$(hyprctl configerrors 2>/dev/null || true)"
      if [[ -n "$errors" ]]; then
        warn "Hyprland reloaded but with config warnings:"
        printf '%s\n' "$errors" | sed 's/^/    /'
      else
        ok "Hyprland reloaded, config valid"
      fi
    else
      warn "hyprctl reload failed — check manually: hyprctl reload"
    fi
  else
    warn "hyprctl not found (non-Hyprland session?) — config taken at next login."
  fi
}

# -----------------------------------------------------------------------------
# --status
# -----------------------------------------------------------------------------
do_status() {
  info "Touchpad configuration status"
  local name
  name="$(detect_touchpad)"
  if [[ -n $name ]]; then
    echo "  • Touchpad detected: $name"
  else
    if [[ -n ${TOUCHPAD_NAME:-} ]]; then
      echo "  • TOUCHPAD_NAME (forced): $TOUCHPAD_NAME"
      name="$TOUCHPAD_NAME"
    else
      echo "  • No touchpad detected (Hyprland session?)."
    fi
  fi
  if [[ -f $TOUCHPAD_LUA ]]; then
    echo "  • $TOUCHPAD_LUA: present"
    grep -E 'accel_profile|sensitivity|scroll_factor' "$TOUCHPAD_LUA" | sed 's/^/      /'
  else
    echo "  • $TOUCHPAD_LUA: absent"
  fi
  if [[ -f $HYPRLAND ]] && grep -qF -- "$BLOCK_START" "$HYPRLAND"; then
    echo "  • Registration in hyprland.lua: yes"
  else
    echo "  • Registration in hyprland.lua: no"
  fi
}

# -----------------------------------------------------------------------------
# --remove
# -----------------------------------------------------------------------------
do_remove() {
  [[ -f $TOUCHPAD_LUA ]] && { rm -f "$TOUCHPAD_LUA"; ok "touchpad.lua removed"; } \
                        || ok "touchpad.lua already absent."
  remove_require
  reload_hypr
}

# -----------------------------------------------------------------------------
# MAIN
# -----------------------------------------------------------------------------
if [[ $STATUS_ONLY == true ]]; then
  do_status
  exit 0
fi

if [[ $REMOVE == true ]]; then
  do_remove
  exit 0
fi

NAME="$(detect_touchpad)"
if [[ -z $NAME ]]; then
  err "No touchpad detected (run in the Hyprland session, or set TOUCHPAD_NAME=<name>)."
  exit 1
fi

info "Configuring the touchpad ($NAME)"
ensure_kinetic_scroll_plugin || true
gen_touchpad_lua "$NAME"
ensure_require
reload_hypr

echo ""
info "Setup complete. Summary:"
echo "  • Device        -> $NAME (touchpad only, external mouse untouched)"
echo "  • Pointer       -> accel_profile $ACCEL, sensitivity $SENS (mouse keeps global input.lua settings)"
echo "  • Scroll        -> scroll_factor $SCROLL — no scroll acceleration on the Hyprland side"
if [[ $KINETIC_ENABLED -eq 1 ]]; then
  echo "  • Kinetic scroll -> enabled (decel $KINETIC_DECEL, min_vel $KINETIC_MIN_VEL, interval ${KINETIC_INTERVAL}ms; global touchpad factor aligned to $SCROLL)"
fi
echo "  • Files         -> $TOUCHPAD_LUA + require in $HYPRLAND"
echo "  • Remove        -> $0 --remove"
