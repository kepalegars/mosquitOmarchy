#!/usr/bin/env bash
# uninstall-webapps.sh — Removes the Omarchy webapps of the "apps" module
# (webapps.catalog).
#
# Part of the modular apps module: one uninstall script per type, mirroring
# webapps/setup-webapps.sh. DESTRUCTIVE: interactively you tick what to
# remove (NOTHING checked by default); with -y you must explicitly give --all
# or --from-backup= to remove something.
#
#   • webapps → launchers removed via `omarchy webapp remove <name>`.
#
# Usage :
#   ./uninstall-webapps.sh            # interactive: tick what to remove (nothing by default)
#   ./uninstall-webapps.sh --all -y   # removes every webapp of the catalog
#   ./uninstall-webapps.sh --from-backup=BACKUP.tar.gz -y   # removes exactly a selection
#   ./uninstall-webapps.sh --status   # state (same entries, non destructive)
#   ./uninstall-webapps.sh -h
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/gui-run.bash"  # gui-run: reopen in a terminal when launched from a file manager
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.bash"

TYPE="WEB"
TYPE_ARR=CAT_WEB
ARRNAME=CAT_WEB
TYPE_PLURAL="Webapps"
TYPE_TAG=webapps

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
  ((STATUS_ONLY)) && { status_type "$TYPE" "$TYPE_ARR" "$TYPE_PLURAL"; exit 0; }

  if [[ -n $FROM ]]; then
    [[ -f $FROM ]] || FROM="$BACKUP_DIR/$FROM"
    extract_selection "$FROM" || exit 1
    trap 'rm -f "$SEC_FILE"' EXIT
    selection_of_type || exit 1
  else
    all_catalog_type
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
  hr
  ((rc == 0)) && ok "Done." || err "Some uninstalls failed."
  return $rc
}

main "$@"
