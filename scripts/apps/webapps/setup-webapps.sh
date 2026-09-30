#!/usr/bin/env bash
# setup-webapps.sh — Installs the Omarchy webapps of the "apps" module
# (webapps.catalog).
#
# Part of the modular apps module: one script per type (gui/ tui/ webapps/),
# each with its own catalog and helpers from lib/common.bash. This script only
# handles the WEB entries (launchers via `omarchy webapp install`).
#
# The selection sources:
#   --all                 → the whole webapps.catalog
#   --from-backup=SRC     → a backup tar.gz or an apps.selected file
#                          (only its WEB entries are kept)
# Without -y, the entries are presented (gum multi-select, all checked).
#
# Usage :
#   ./setup-webapps.sh --all -y        # install every webapp of the catalog
#   ./setup-webapps.sh --from-backup=BACKUP.tar.gz -y
#   ./setup-webapps.sh --list-selection --from-backup=BACKUP.tar.gz
#   ./setup-webapps.sh --status        # state of the catalog entries (nothing done)
#   ./setup-webapps.sh -h
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/gui-run.bash"  # gui-run: reopen in a terminal when launched from a file manager
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.bash"

TYPE="WEB"
TYPE_ARR=CAT_WEB
ARRNAME=CAT_WEB
TYPE_PLURAL="Webapps"
TYPE_TAG=webapps

YES=0 STATUS_ONLY=0 LIST_ONLY=0 ALL=0 FROM=""
for a in "$@"; do case "$a" in
  -y|--yes) YES=1 ;;
  --status) STATUS_ONLY=1 ;;
  --list-selection) LIST_ONLY=1 ;;
  --all) ALL=1 ;;
  --from-backup=*) FROM="${a#*=}" ;;
  -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
  *) echo "Unknown option: $a (see -h)" >&2; exit 1 ;;
esac; done

main(){
  ((STATUS_ONLY)) && { status_type "$TYPE" "$TYPE_ARR" "$TYPE_PLURAL"; exit 0; }

  [[ -n $FROM || $ALL == 1 ]] || {
    err "Nothing to do: give --all or --from-backup=SRC (a backup or an apps.selected file)."
    err "The main entry is setup-apps.sh (backup flow); this script handles the $TYPE_TAG type alone."
    exit 0
  }

  if [[ -n $FROM ]]; then
    [[ -f $FROM ]] || FROM="$BACKUP_DIR/$FROM"
    extract_selection "$FROM" || exit 1
    trap 'rm -f "$SEC_FILE"' EXIT
    selection_of_type || exit 1
    ((${#BASE[@]})) || { warn "No $TYPE_PLURAL entry in this selection."; exit 0; }
  else
    all_catalog_type
    ((${#BASE[@]})) || { warn "$TYPE_PLURAL catalog is empty ($CAT_FILE_WEB)."; exit 0; }
  fi

  ((LIST_ONLY)) && {
    hr; msg "$TYPE_PLURAL in the selection:"
    local e
    for e in "${BASE[@]:-}"; do echo "  $e"; done
    hr; exit 0
  }

  tick_entries
  ((${#INSTALL_LIST[@]})) || { warn "Nothing selected — nothing installed."; exit 0; }
  printf "\n"
  install_entries
  local rc=$?
  hr
  ((rc == 0)) && ok "Done." || err "Some entries failed (relaunch to resume)."
  return $rc
}

main "$@"
