#!/usr/bin/env bash
# =============================================================================
# Omarchy Custom - Display brightness: Omarchy DEFAULT + 0% (screen off)
# =============================================================================
# The previous version replaced Omarchy's brightness with a perceptual (gamma)
# curve and a custom helper. This version goes BACK to Omarchy's default tool
# (`omarchy-brightness-display`) and only adds what it lacks: a real 0%.
#
# Behaviour:
#   • MonBrightnessUp / Down : exactly Omarchy's default (+5% / 5%-), via a
#     thin wrapper that just adds the 0% transition.
#   • At 1%, pressing Down   : 0% -> the screen turns OFF (DPMS off).
#   • Pressing Up while off  : the screen turns back ON, then normal steps.
#   • SHIFT + Down           : 0% (screen off) directly.
#   • SHIFT + Up, ALT ±      : untouched — Omarchy's stock bindings.
#
# It also cleans up the old perceptual helper (backlight) if present.
#
# Usage:
#   ./fix-optimized-brightness.sh            # applies (idempotent)
#   ./fix-optimized-brightness.sh --remove   # restores stock Omarchy brightness
# =============================================================================
set -euo pipefail

info() { echo -e "\033[1;34m==>\033[0m $*"; }
ok()   { echo -e "\033[1;32m ✓\033[0m $*"; }
warn() { echo -e "\033[1;33m !\033[0m $*"; }
err()  { echo -e "\033[1;31m ✗\033[0m $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_HOME="${HOME}"
BIN_DIR="$REAL_HOME/.local/bin"
BIN_NAME="brightness-0"
BIN="$BIN_DIR/$BIN_NAME"
BIN_SRC="$SCRIPT_DIR/$BIN_NAME"
OLD_BIN="$BIN_DIR/backlight"

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

read_block() {
  cat <<BLOCK_EOF
$BLOCK_START
-- Omarchy's default display brightness, plus 0% = screen off.
-- (wrapper: omarchy-brightness-display for normal steps, DPMS off/on at 0%.)
hl.unbind("XF86MonBrightnessUp")
o.bind("XF86MonBrightnessUp", "Brightness up", "$BIN up", { locked = true, repeating = true })
hl.unbind("XF86MonBrightnessDown")
o.bind("XF86MonBrightnessDown", "Brightness down", "$BIN down", { locked = true, repeating = true })
hl.unbind("SHIFT + XF86MonBrightnessDown")
o.bind("SHIFT + XF86MonBrightnessDown", "Brightness 0% (screen off)", "omarchy-brightness-display off", { locked = true, repeating = true })
$BLOCK_END
BLOCK_EOF
}

# -----------------------------------------------------------------------------
# Helper deployment
# -----------------------------------------------------------------------------
rm -f "$OLD_BIN" 2>/dev/null || true   # drop the old perceptual helper

if [[ $REMOVE == true ]]; then
  rm -f "$BIN"
  ok "Helper $BIN removed"
else
  info "Deploying helper $BIN"
  [[ -f "$BIN_SRC" ]] || { err "Source not found: $BIN_SRC"; exit 1; }
  mkdir -p "$BIN_DIR"
  cp "$BIN_SRC" "$BIN"
  chmod +x "$BIN"
  bash -n "$BIN" || { err "Invalid syntax: $BIN"; rm -f "$BIN"; exit 1; }
  ok "Helper deployed ($BIN)"
fi

# -----------------------------------------------------------------------------
# Hyprland bindings block (delimited, idempotent)
# -----------------------------------------------------------------------------
remove_block() {
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
  remove_block && ok "Brightness block removed from $BINDINGS" || ok "No Brightness block, nothing to do."
  exit 0
fi

info "Integrating the brightness bindings"
mkdir -p "$HYPR_DIR"
remove_block || true
BLOCK_TMP=$(mktemp); read_block > "$BLOCK_TMP"
if [[ -s $BINDINGS ]]; then
  { echo ""; cat "$BLOCK_TMP"; echo ""; } >> "$BINDINGS"
else
  { echo "-- Brightness block installed by fix-optimized-brightness.sh"; cat "$BLOCK_TMP"; echo ""; } > "$BINDINGS"
fi
rm -f "$BLOCK_TMP"
ok "Brightness block written to $BINDINGS"

# -----------------------------------------------------------------------------
# Hyprland reload + validation
# -----------------------------------------------------------------------------
if command -v hyprctl >/dev/null 2>&1; then
  if hyprctl reload >/dev/null 2>&1; then
    errors="$(hyprctl configerrors 2>/dev/null || true)"
    if [[ -n "$errors" ]]; then warn "Reloaded with warnings:"; printf '%s\n' "$errors" | sed 's/^/    /'
    else ok "Hyprland reloaded, config valid"; fi
  else
    warn "hyprctl reload failed — check manually: hyprctl reload"
  fi
fi

echo ""
info "Done. Brightness = Omarchy default, plus 0%:"
echo "  • Up / Down       -> Omarchy default (+5% / 5%-), Down at 1% => 0% (screen off)"
echo "  • Up while off    -> screen back on"
echo "  • SHIFT + Down    -> 0% (screen off)     • SHIFT + Up / ALT ± -> stock"
echo "  • Restore stock   -> ./fix-optimized-brightness.sh --remove"
