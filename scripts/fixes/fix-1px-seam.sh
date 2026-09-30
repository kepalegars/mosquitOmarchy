#!/usr/bin/env bash
# =============================================================================
# Omarchy Custom - 1px seam: hair-thin transparent line under the bar (no gaps)
# =============================================================================
# In borderless / no-gaps tiling, Hyprland's optimized blur path can flash a
# hair-thin transparent line (a "1px seam") between the opaque Omarchy bar and
# a window touching it. Switching the blur to the legacy (non-optimized) path
# removes that boundary artifact.
#
# What this script does (idempotent):
#   1. Adds `new_optimizations = false` inside the blur block of
#      ~/.config/hypr/looknfeel.lua, marked with a trailing
#      `# mosquitomarchy-1px-seam` comment so it can be removed precisely.
#   2. Reloads Hyprland and reports configerrors.
#
# Only useful when blur is enabled (`decoration:blur:enabled = true`, the
# Omarchy default) — with blur off the seam has nothing to do with it.
#
# Usage:
#   ./fix-1px-seam.sh            # apply (idempotent)
#   ./fix-1px-seam.sh --status   # status only
#   ./fix-1px-seam.sh --remove   # remove the marked line (back to defaults)
#   ./fix-1px-seam.sh -y         # non-interactive
# =============================================================================
set -euo pipefail

LOOK="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/looknfeel.lua"
MARK="mosquitomarchy-1px-seam"

info() { echo -e "\033[1;34m==>\033[0m $*"; }
ok()   { echo -e "\033[1;32m ✓\033[0m $*"; }
warn() { echo -e "\033[1;33m !\033[0m $*"; }
err()  { echo -e "\033[1;31m ✗\033[0m $*" >&2; }

reload_report(){
  hyprctl reload >/dev/null 2>&1 || true
  local errs
  errs="$(hyprctl configerrors 2>/dev/null | tr -d '[:space:]')"
  if [[ -n "${errs:-}" ]]; then err "hyprctl configerrors: ${errs}"; return 1; fi
  ok "Hyprland reloaded without configuration errors."
}

seam_status(){
  if [[ ! -f $LOOK ]]; then echo missing; return; fi
  grep -q -- "$MARK" "$LOOK" && { echo applied; return; }
  grep -q 'new_optimizations' "$LOOK" && { echo foreign; return; }
  echo default
}

do_apply(){
  [[ -f $LOOK ]] || { err "$LOOK not found — nothing to patch."; return 1; }
  local st; st="$(seam_status)"
  case $st in
    applied) ok "Already applied — new_optimizations = false is set in looknfeel.lua."; return 0 ;;
    foreign) warn "looknfeel.lua already sets new_optimizations itself — nothing to do."; return 0 ;;
  esac
  if ! grep -q 'blur = {' "$LOOK"; then
    err "No blur block found in looknfeel.lua — cannot place the fix."
    return 1
  fi
  # Insert right after the `blur = {` opening, with our marker comment (Lua
  # `--`, NOT `#` — a bare # is the Lua length operator and breaks the file)
  # so --remove can find and drop exactly this line.
  awk -v mark="$MARK" '
    !done && /blur[ ]*=[ ]*{/ {
      print
      print "      new_optimizations = false,  -- " mark
      done=1; next
    }
    { print }
  ' "$LOOK" > "$LOOK.tmp" && mv "$LOOK.tmp" "$LOOK"
  ok "Legacy blur path enabled (new_optimizations = false) in looknfeel.lua."
  reload_report
}

do_remove(){
  local st; st="$(seam_status)"
  if [[ $st != applied ]]; then
    ok "Nothing to remove — the marked line is not present."
    return 0
  fi
  grep -v -- "$MARK" "$LOOK" > "$LOOK.tmp" && mv "$LOOK.tmp" "$LOOK"
  ok "Marked line removed — blur back to the Omarchy default (optimized path)."
  reload_report
}

case "${1:-}" in
  --status) seam_status ;;
  --remove|--uninstall) do_remove ;;
  *) do_apply ;;
esac
