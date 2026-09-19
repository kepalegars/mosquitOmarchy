#!/usr/bin/env bash
# =============================================================================
# Omarchy Custom - Brightness (perceptual curve, 0% = screen off)
# =============================================================================
# Replaces Omarchy's linear display brightness with a perceptual (gamma) curve
# driven by a dedicated helper, which:
#
#   1. Maps the brightness onto the panel's REAL LUMINANCE
#      (actual_brightness, via a calibration table), so each step down/up
#      produces an observable change — even in the low range the amdgpu
#      backlight "crushed" (hardware steps).
#   2. Recreates the Windows behaviour: **0% actually turns the screen off**
#      (DPMS off), and a "raise" press turns it back on.
#
# What this script does:
#   1. Deploys $SCRIPT_DIR/backlight to ~/.local/bin/
#   2. Replaces in ~/.config/hypr/bindings.lua the default brightness bindings
#      (omarchy-brightness-display) with those using the helper
#      (block delimited by markers, idempotent).
#   3. Reloads Hyprland and checks the config errors.
#
# Keys (unchanged):
#   MonBrightnessUp/Down      : 5% steps
#   ALT + Up/Down             : precise 1% steps
#   SHIFT + MonBrightnessDown : 0%  => turns the screen off
#   SHIFT + MonBrightnessUp   : 100%
#
# Usage:
#   ./fix-optimized-brightness.sh            # applies (idempotent)
#   ./fix-optimized-brightness.sh --remove   # removes bindings + helper, restores Omarchy
#
# NOTE: if an Omarchy update overwrites bindings.lua or the helper, rerunning
# this script is enough to re-apply the change.
# =============================================================================
set -euo pipefail

info() { echo -e "\033[1;34m==>\033[0m $*"; }
ok()   { echo -e "\033[1;32m ✓\033[0m $*"; }
warn() { echo -e "\033[1;33m !\033[0m $*"; }
err()  { echo -e "\033[1;31m ✗\033[0m $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_HOME="${HOME}"
BIN_DIR="$REAL_HOME/.local/bin"
BIN_NAME="backlight"
BIN="$BIN_DIR/$BIN_NAME"
BIN_SRC="$SCRIPT_DIR/$BIN_NAME"

HYPR_DIR="$REAL_HOME/.config/hypr"
BINDINGS="$HYPR_DIR/bindings.lua"
BLOCK_START="-- >>> Omarchy_Custom_Scripts_Brightness"
BLOCK_END="-- <<< Omarchy_Custom_Scripts_Brightness"

if [[ ! -d /usr/share/omarchy ]]; then
  echo "This script is meant for Omarchy." >&2
  exit 1
fi

REMOVE=false
[[ ${1:-} == "--remove" ]] && REMOVE=true

# -----------------------------------------------------------------------------
# Bindings block inserted into bindings.lua
# -----------------------------------------------------------------------------
read_block() {
  cat <<BLOCK_EOF
$BLOCK_START
-- Perceptually-mapped display brightness (gamma curve, can reach 0% = off).
-- Overrides the stock linear omarchy-brightness-display bindings.
hl.unbind("XF86MonBrightnessUp")
o.bind("XF86MonBrightnessUp", "Brightness up", "$BIN +5%", { locked = true, repeating = true })
hl.unbind("XF86MonBrightnessDown")
o.bind("XF86MonBrightnessDown", "Brightness down", "$BIN 5%-", { locked = true, repeating = true })
hl.unbind("SHIFT + XF86MonBrightnessUp")
o.bind("SHIFT + XF86MonBrightnessUp", "Brightness maximum", "$BIN 100%", { locked = true, repeating = true })
hl.unbind("SHIFT + XF86MonBrightnessDown")
o.bind("SHIFT + XF86MonBrightnessDown", "Brightness minimum", "$BIN 0%", { locked = true, repeating = true })
hl.unbind("ALT + XF86MonBrightnessUp")
o.bind("ALT + XF86MonBrightnessUp", "Brightness up precise", "$BIN +1%", { locked = true, repeating = true })
hl.unbind("ALT + XF86MonBrightnessDown")
o.bind("ALT + XF86MonBrightnessDown", "Brightness down precise", "$BIN 1%-", { locked = true, repeating = true })
$BLOCK_END
BLOCK_EOF
}

# -----------------------------------------------------------------------------
# 1. Helper deployment
# -----------------------------------------------------------------------------
if [[ $REMOVE == true ]]; then
  rm -f "$BIN"
  ok "Helper $BIN removed"
else
  info "Deploying helper $BIN"
  if [[ ! -f "$BIN_SRC" ]]; then
    err "Source not found: $BIN_SRC (missing from the scripts folder)."
    exit 1
  fi
  mkdir -p "$BIN_DIR"
  cp "$BIN_SRC" "$BIN"
  chmod +x "$BIN"
  bash -n "$BIN" || { err "Invalid syntax: $BIN"; rm -f "$BIN"; exit 1; }
  ok "Helper deployed ($BIN)"
fi

# -----------------------------------------------------------------------------
# 2. Hyprland bindings (delimited block, idempotent)
# -----------------------------------------------------------------------------
if [[ $REMOVE == true ]]; then
  if [[ -f $BINDINGS ]] && grep -qF -- "$BLOCK_START" "$BINDINGS"; then
    start_line=$(grep -nF -- "$BLOCK_START" "$BINDINGS" | cut -d: -f1 | head -1)
    end_line=$(grep -nF -- "$BLOCK_END" "$BINDINGS" | cut -d: -f1 | head -1)
    if [[ -n $start_line && -n $end_line && $end_line -gt $start_line ]]; then
      tmp=$(mktemp)
      head -n $((start_line - 1)) "$BINDINGS" > "$tmp"
      tail -n +$((end_line + 1)) "$BINDINGS" >> "$tmp"
      mv "$tmp" "$BINDINGS"
      ok "Brightness block removed from $BINDINGS"
    else
      warn "Inconsistent markers in $BINDINGS, nothing removed."
    fi
  else
    ok "No Brightness block in $BINDINGS, nothing to do."
  fi
  exit 0
fi

info "Integrating the brightness bindings"
mkdir -p "$HYPR_DIR"

BLOCK_TMP=$(mktemp)
read_block > "$BLOCK_TMP"

if [[ ! -f $BINDINGS ]]; then
  {
    echo "-- Brightness block installed by fix-optimized-brightness.sh"
    cat "$BLOCK_TMP"
    echo ""
  } > "$BINDINGS"
elif grep -qF -- "$BLOCK_START" "$BINDINGS"; then
  start_line=$(grep -nF -- "$BLOCK_START" "$BINDINGS" | cut -d: -f1 | head -1)
  end_line=$(grep -nF -- "$BLOCK_END" "$BINDINGS" | cut -d: -f1 | head -1)
  if [[ -z $start_line || -z $end_line || $end_line -le $start_line ]]; then
    rm -f "$BLOCK_TMP"
    err "Inconsistent markers in $BINDINGS, manual correction needed."
    exit 1
  fi
  tmp=$(mktemp)
  head -n $((start_line - 1)) "$BINDINGS" > "$tmp"
  cat "$BLOCK_TMP" >> "$tmp"
  tail -n +$((end_line + 1)) "$BINDINGS" >> "$tmp"
  mv "$tmp" "$BINDINGS"
  ok "Brightness block updated in $BINDINGS"
else
  # Append the block at the end of the user file.
  { echo ""; cat "$BLOCK_TMP"; echo ""; } >> "$BINDINGS"
  ok "Brightness block appended to $BINDINGS"
fi
rm -f "$BLOCK_TMP"

# -----------------------------------------------------------------------------
# 3. Hyprland reload + validation
# -----------------------------------------------------------------------------
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
  warn "hyprctl not found (non-Hyprland session?) — the bindings will be taken at next login."
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
info "Setup complete. Summary:"
echo "  • Helper          -> $BIN (gamma curve on the real luminance)"
echo "  • Keys            -> MonBrightnessUp/Down (5%), ALT± (1%), SHIFT+Down = off (0%), SHIFT+Up = 100%"
echo "  • Remove          -> ./fix-optimized-brightness.sh --remove"
