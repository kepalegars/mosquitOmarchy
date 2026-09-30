#!/usr/bin/env bash
# =============================================================================
# Omarchy Custom - Wine: remove the installer shortcuts Wine republishes into
# the Omarchy launcher.
# =============================================================================
# THE PROBLEM
#   A Windows installer writes its shortcuts into the prefix's Start Menu
#   (ProgramData/Microsoft/Windows/Start Menu/Programs), and Wine then copies
#   every one of them into
#   ~/.local/share/applications/wine/Programs/<vendor>/<app>/*.desktop, which is
#   a launcher in its own right. For an app mosquitOmarchy installs AND
#   uninstalls, that produces exactly the wrong entries:
#
#     * "Uninstall" — launches unins000.exe from the app menu, while the whole
#       point of the module is that uninstalling happens from mosquitOmarchy;
#     * "Manual" — a PDF in a wine window;
#     * a duplicate of the app entry the module already published;
#     * and the empty "Wine / Programs / <vendor>" publisher folders they leave
#       behind once the entries inside are gone.
#
#   Observed on this machine: "Uninstall" (smartEQ4), "Uninstall" (FabFilter),
#   "Un-install CrispyTuner", plus a dangling "Arobas Music" folder.
#
# WHAT THIS DOES
#   Deletes those launcher entries and the publishers they leave empty, then
#   refreshes the desktop database. Scoped to the wine prefixes mosquitOmarchy
#   owns, so a Windows app the user runs on their own keeps its entry.
#
#   It is already applied automatically at the end of the relevant setups
#   (audio plugin manager, audio stack, Guitar Pro). This script is the manual
#   "clean it now" action, and the --status report.
#
# WHAT THIS DOES NOT TOUCH
#   The file-association entries (wine-extension-* / wine-protocol-*,
#   NoDisplay=true): those are what makes "open a .gp5 with Guitar Pro" work.
#
# Usage:
#   ./fix-wine-menu.sh                  # clean the mosquitOmarchy prefixes
#   ./fix-wine-menu.sh --status         # read-only report, changes nothing
#   ./fix-wine-menu.sh --prefix DIR     # also clean one specific prefix
#   ./fix-wine-menu.sh --all-prefixes   # clean EVERY wine prefix found
#   ./fix-wine-menu.sh -y               # non-interactive (nothing is prompted)
#   ./fix-wine-menu.sh -h
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/gui-run.bash"  # gui-run: reopen in a terminal when launched from a file manager
set -uo pipefail

_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/wine-menu.bash"
[[ -f $_lib ]] || _lib="$HOME/mosquitOmarchy/scripts/lib/wine-menu.bash"
if [[ ! -f $_lib ]]; then
  echo " ! wine-menu.bash not found (looked for $_lib)" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$_lib"

G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; B='\033[1;34m'; N='\033[0m'
msg(){ printf "${B}==>${N} %s\n" "$*"; }
ok(){ printf " ${G}✓${N} %s\n" "$*"; }
warn(){ printf " ${Y}!${N} %s\n" "$*" >&2; }
err(){ printf " ${R}✗${N} %s\n" "$*" >&2; }

STATUS_ONLY=false
ALL_PREFIXES=false
EXTRA_PREFIXES=()
while (( $# )); do case "$1" in
  -y|--yes) ;;
  --status) STATUS_ONLY=true; shift ;;
  --all-prefixes) ALL_PREFIXES=true; shift ;;
  --prefix) shift; [[ -n "${1:-}" ]] || { err "--prefix needs a directory"; exit 1; }; EXTRA_PREFIXES+=("$1"); shift ;;
  -h|--help) sed -n '2,50p' "$0"; exit 0 ;;
  *) err "Unknown option: $1 (supported: -y --status --prefix DIR --all-prefixes)"; exit 1 ;;
esac; shift || true; done

# The prefixes mosquitOmarchy owns. ~/.wine is deliberately absent: it is the
# generic prefix where a user runs their own Windows apps, and those must keep
# their launcher entries. The plugin manager still cleans it per-install, when
# it is the one that just ran an installer there.
owned_prefixes() {
  local p
  for p in "$HOME"/.wine-vst*; do
    [[ -d $p/drive_c ]] && printf '%s\n' "$p"
  done
  printf '%s\n' "$HOME/.wine-guitarpro8"
}

all_prefixes() {
  local p
  for p in "$HOME"/.wine*; do
    [[ -d $p/drive_c ]] && printf '%s\n' "$p"
  done
}

# ── Status ───────────────────────────────────────────────────────────────────
if $STATUS_ONLY; then
  msg "Wine-published launcher entries"
  left="$(mosquitomarchy_wine_menu_report)"
  if [[ -n $left ]]; then
    while IFS= read -r _l; do [[ -n $_l ]] && printf '     %s\n' "$_l"; done <<< "$left"
    warn "$(printf '%s\n' "$left" | wc -l) entry(ies) — run without --status to remove the ones"
    warn "  belonging to the prefixes mosquitOmarchy owns."
  else
    ok "none — the launcher is clean."
  fi
  exit 0
fi

# ── Clean ────────────────────────────────────────────────────────────────────
declare -a targets=()
if $ALL_PREFIXES; then
  while IFS= read -r p; do targets+=("$p"); done < <(all_prefixes)
else
  while IFS= read -r p; do targets+=("$p"); done < <(owned_prefixes)
  targets+=("${EXTRA_PREFIXES[@]:-}")
fi

msg "Removing the installer shortcuts Wine published (${#targets[@]} prefix(es))"
removed=0
for p in "${targets[@]}"; do
  [[ -n $p && -d $p/drive_c ]] || continue
  while IFS= read -r line; do
    removed=$((removed + 1))
    ok "removed ${line#removed }"
  done < <(mosquitomarchy_wine_menu_sweep "$p")
done

# Sweep with no argument too: prunes the publishers left orphaned by an earlier
# version of this script or by a manual rm.
mosquitomarchy_wine_menu_sweep >/dev/null

if (( removed == 0 )); then
  ok "nothing to remove (already clean)"
else
  ok "$removed launcher entry(ies) removed"
fi

left="$(mosquitomarchy_wine_menu_report)"
if [[ -n $left ]]; then
  warn "left in place on purpose (published by a prefix mosquitOmarchy does not own):"
  while IFS= read -r _l; do [[ -n $_l ]] && printf '     %s\n' "$_l" >&2; done <<< "$left"
  warn "  re-run with --all-prefixes to remove those too."
else
  ok "the launcher is clean."
fi
