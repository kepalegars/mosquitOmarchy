#!/usr/bin/env bash
# =============================================================================
# Omarchy Custom - Wine/Ableton: stop the patched-Wine pointer features from
# swallowing trackpad scrolling in the rest of the desktop.
# =============================================================================
# CAUSE (shibco/ableton-linux, the Wine runtime used by ableton-live)
#   The patched Wine's winex11 driver adds optional pointer features: precise
#   ("smooth") scrolling, touchpad inertia, pinch zoom, middle-button
#   navigation and the XWayland warp emulation. To receive them Wine selects
#   XInput2 events, and while a button is held that XI2 selection creates an
#   implicit device grab. Under XWayland the grab captures the touchpad for
#   the Ableton window, so two-finger / trackpad scrolling stops reaching the
#   other applications for as long as Live is open.
#
#   Upstream's one-launch master switch, quoted from TROUBLESHOOTING.md
#   ("Scrolling, panning or dragging stops working"):
#       env WINE_X11_POINTER_FEATURES=disabled ableton-live
#   BUILDING.md calls it "a master switch that turns the optional pointer
#   features off for one launch ... restoring stock pointer behaviour", and
#   notes (.github) that "the launcher exports none of them, and registry
#   values hold the persistent settings" (notes/ABLETON-WINE-POINTER-GESTURES.md).
#
# WHAT THIS DOES
#   Writes the seven optional pointer features as "disabled" in the Ableton
#   Wine prefix registry -- the persistent equivalent of the master switch --
#   leaving the issue-122 clipping-state repair active. This is per-prefix,
#   non-destructive and reversible. The setting is read by Wine when its X11
#   driver starts, so it applies to EVERY Ableton launch (the launcher, the
#   Move manager, or a desktop entry) without touching the launcher file that
#   ableton-linux regenerates on update. Close Live before applying for the
#   next launch to pick it up. Re-run after a reinstall/update.
#
# Usage:
#   ./fix-wine-scroll.sh                 # apply (idempotent)
#   ./fix-wine-scroll.sh --status        # read-only report, changes nothing
#   ./fix-wine-scroll.sh --remove        # restore the values saved before apply
#   ./fix-wine-scroll.sh -y              # non-interactive (nothing is prompted)
#   ./fix-wine-scroll.sh --prefix DIR    # target another Wine prefix
#   ./fix-wine-scroll.sh -h
#
# Environment: WINEPREFIX (default ~/.wine-ableton),
#              ABLETON_WINE_ROOT (patched Wine root; auto-detected otherwise).
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/gui-run.bash"  # gui-run: reopen in a terminal when launched from a file manager
set -uo pipefail

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m !\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m ✗\033[0m %s\n' "$*" >&2; }

REAL_HOME="${HOME}"
REGKEY='HKCU\Software\Wine\X11 Driver'
STATE_DIR="$REAL_HOME/.local/state/omarchy-ableton-scroll"
BACKUP_FILE="$STATE_DIR/backup.tsv"

# The optional pointer features gated by WINE_X11_POINTER_FEATURES=disabled.
FEATURES=(
  SmoothScrolling
  TouchpadInertia
  PinchZoom
  MiddleDrag
  MiddleDragThrow
  WheelWhileButtonHeld
  WarpEmulation
)

STATUS_ONLY=false REMOVE=false PREFIX_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) shift ;;
    --status) STATUS_ONLY=true; shift ;;
    --remove|--uninstall) REMOVE=true; shift ;;
    --prefix) PREFIX_ARG="${2:-}"; shift 2 ;;
    --prefix=*) PREFIX_ARG="${1#--prefix=}"; shift ;;
    -h|--help) sed -n '1,45p' "$0"; exit 0 ;;
    *) err "Unknown option: $1 (supported: -y --status --remove --prefix DIR)"; exit 1 ;;
  esac
done

PREFIX="${PREFIX_ARG:-${WINEPREFIX:-$REAL_HOME/.wine-ableton}}"

detect_wine() {
  local w
  if [[ -n ${ABLETON_WINE_ROOT:-} && -x ${ABLETON_WINE_ROOT}/bin/wine ]]; then
    printf '%s\n' "${ABLETON_WINE_ROOT}/bin/wine"; return 0
  fi
  while IFS= read -r w; do printf '%s\n' "$w"; return 0; done < <(
    find "$REAL_HOME/.local/opt" -maxdepth 3 -type f -path '*/bin/wine' 2>/dev/null \
      | grep -E '/wine-d2d1-nspa-[^/]+/bin/wine$' \
      | grep -vE 'rollback|transaction' | sort -Vr
  )
  while IFS= read -r w; do printf '%s\n' "$w"; return 0; done < <(
    find "$REAL_HOME/.local/opt" -maxdepth 3 -type f -path '*/bin/wine' 2>/dev/null | sort -Vr
  )
  command -v wine 2>/dev/null
}

WINE="$(detect_wine || true)"

# Read one registry string value (empty when absent / unreadable).
reg_query() {
  local name="$1"
  WINEPREFIX="$PREFIX" "$WINE" reg query "$REGKEY" /v "$name" 2>/dev/null \
    | tr -d '\r' \
    | awk -v n="$name" '$1==n { out=""; for (i=3; i<=NF; i++) out=out (i>3?" ":"") $i; print out; exit }'
}

usage_prefix_check() {
  if [[ ! -d $PREFIX/drive_c ]]; then
    err "No Wine prefix at $PREFIX (drive_c missing) — set --prefix/WINEPREFIX."
    exit 1
  fi
}

status() {
  info "Ableton pointer-scroll fix — status"
  printf '    prefix : %s\n' "$PREFIX"
  printf '    wine   : %s\n' "${WINE:-<not found>}"
  printf '    registry key : %s\n' "$REGKEY"
  if [[ -z ${WINE:-} || ! -x $WINE ]]; then
    warn "patched Wine binary not found — cannot read the registry."
    return 0
  fi
  local n v
  for n in "${FEATURES[@]}"; do
    v="$(reg_query "$n" || true)"
    printf '    %-22s = %s\n' "$n" "${v:-<unset>}"
  done
  echo
  if [[ -f $BACKUP_FILE ]]; then
    printf '    previous values saved: %s\n' "$BACKUP_FILE"
  fi
}

apply() {
  [[ -n ${WINE:-} && -x $WINE ]] || { err "patched Wine binary not found (set ABLETON_WINE_ROOT)."; return 1; }
  usage_prefix_check
  mkdir -p "$STATE_DIR"

  if [[ ! -f $BACKUP_FILE ]]; then
    : > "$BACKUP_FILE"
    local n v
    for n in "${FEATURES[@]}"; do
      v="$(reg_query "$n" || true)"
      printf '%s\t%s\n' "$n" "${v:-__ABSENT__}" >> "$BACKUP_FILE"
    done
    info "Saved previous pointer settings to $BACKUP_FILE"
  fi

  local n rc=0
  for n in "${FEATURES[@]}"; do
    if ! WINEPREFIX="$PREFIX" "$WINE" reg add "$REGKEY" /v "$n" /d disabled /f >/dev/null 2>&1; then
      err "failed to set $n"; rc=1
    fi
  done
  (( rc == 0 )) || return 1

  for n in "${FEATURES[@]}"; do
    [[ "$(reg_query "$n" || true)" == disabled ]] || { err "$n is not disabled after write"; rc=1; }
  done
  (( rc == 0 )) || return 1

  ok "Optional Wine pointer features disabled in $PREFIX (persistent master switch)."
  echo "    Close any running Live window, then start Live again."
  echo "    Undo:  ./fix-wine-scroll.sh --remove"
}

remove() {
  [[ -n ${WINE:-} && -x $WINE ]] || { err "patched Wine binary not found (set ABLETON_WINE_ROOT)."; return 1; }
  usage_prefix_check
  local n v
  if [[ -f $BACKUP_FILE ]]; then
    while IFS=$'\t' read -r n v; do
      [[ -n $n ]] || continue
      if [[ $v == __ABSENT__ ]]; then
        WINEPREFIX="$PREFIX" "$WINE" reg delete "$REGKEY" /v "$n" /f >/dev/null 2>&1 || true
      else
        WINEPREFIX="$PREFIX" "$WINE" reg add "$REGKEY" /v "$n" /d "$v" /f >/dev/null 2>&1 || true
      fi
    done < "$BACKUP_FILE"
    rm -f "$BACKUP_FILE"
    ok "Restored the pointer settings saved before the fix was applied."
  else
    for n in "${FEATURES[@]}"; do
      WINEPREFIX="$PREFIX" "$WINE" reg delete "$REGKEY" /v "$n" /f >/dev/null 2>&1 || true
    done
    ok "Removed the disabled pointer settings (no previous-value backup found)."
  fi
}

if $STATUS_ONLY; then
  status
elif $REMOVE; then
  info "Removing the Ableton/Wine pointer-scroll fix"
  remove
else
  info "Applying the Ableton/Wine pointer-scroll fix"
  apply
fi
