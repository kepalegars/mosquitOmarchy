#!/usr/bin/env bash
# uninstall-tuis.sh — Removes the terminal tools of the "apps" module
# (tuis.catalog).
#
# Part of the modular apps module: one uninstall script per type, mirroring
# tui/setup-tuis.sh. DESTRUCTIVE: interactively you tick what to remove
# (NOTHING checked by default); with -y you must explicitly give --all or
# --from-backup= to remove something.
#
#   • packages removed via pacman -Rns (personal data is not touched:
#     ~/.config, ~/.local/share, etc. are kept by -Rns).
#
# Usage :
#   ./uninstall-tuis.sh            # interactive: tick what to remove (nothing by default)
#   ./uninstall-tuis.sh --all -y   # removes every TUI of the catalog
#   ./uninstall-tuis.sh --from-backup=BACKUP.tar.gz -y   # removes exactly a selection
#   ./uninstall-tuis.sh --status   # state (same entries, non destructive)
#   ./uninstall-tuis.sh -h
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/gui-run.bash"  # gui-run: reopen in a terminal when launched from a file manager
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.bash"

TYPE="TUI"
TYPE_ARR=CAT_TUI
ARRNAME=CAT_TUI
TYPE_PLURAL="TUIs"
TYPE_TAG=tuis
# tuis.catalog also holds PLUG entries (Omarchy shell plugins, e.g.
# Monitor-TUI-Omarchy) — removed alongside plain TUIs here.
TYPES=(TUI PLUG)

YES=0 STATUS_ONLY=0 ALL=0 FROM=""
for a in "$@"; do case "$a" in
  -y|--yes) YES=1 ;;
  --status) STATUS_ONLY=1 ;;
  --all) ALL=1 ;;
  --from-backup=*) FROM="${a#*=}" ;;
  -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
  *) echo "Unknown option: $a (see -h)" >&2; exit 1 ;;
esac; done

main(){
  ((STATUS_ONLY)) && {
    status_type TUI CAT_TUI "TUIs"
    status_type PLUG CAT_PLUG "Plugins"
    exit 0
  }

  if [[ -n $FROM ]]; then
    [[ -f $FROM ]] || FROM="$BACKUP_DIR/$FROM"
    extract_selection "$FROM" || exit 1
    trap 'rm -f "$SEC_FILE"' EXIT
    selection_of_types || exit 1
  else
    all_catalog_types
  fi

  if ((ALL)) || { ((YES)) && [[ -n $FROM ]]; }; then
    REMOVE_LIST=("${BASE[@]:-}")
  elif ((YES)); then
    warn "--all or --from-backup= required with -y (destructive uninstall, nothing by default)."
    exit 0
  else
    tick_removal
  fi

  ((${#REMOVE_LIST[@]})) || { warn "Nothing to uninstall."; exit 0; }
  if ((YES == 0)); then
    msg "$TYPE_PLURAL to uninstall:"
    local e
    for e in "${REMOVE_LIST[@]}"; do echo "  - $e"; done
    ask "Confirm uninstalling these ${#REMOVE_LIST[@]} entries ?" n || { warn "Cancelled."; exit 0; }
  fi

  remove_entries
  local rc=$?
  remove_icon_and_launcher
  # Reverse of setup's hook: any cataloged TUI with a setup-<base>-menu.sh
  # companion undoes its menu entry + icon/launcher finery on uninstall.
  local e pkg stem
  for e in "${REMOVE_LIST[@]:-}"; do
    [[ $e == TUI\ * ]] || continue
    pkg="${e#TUI }"
    stem="${pkg%-git}"; stem="${stem%-bin}"
    [[ -x "$SCRIPT_DIR/setup-$stem-menu.sh" ]] && "$SCRIPT_DIR/setup-$stem-menu.sh" --remove || true
  done
  hr
  ((rc == 0)) && ok "Done." || err "Some uninstalls failed."
  return $rc
}

main "$@"
