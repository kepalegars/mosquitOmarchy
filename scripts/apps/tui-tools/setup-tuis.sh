#!/usr/bin/env bash
# setup-tuis.sh — Installs the terminal tools of the "apps" module (tuis.catalog).
#
# Part of the modular apps module: one script per type (gui/ tui/ webapps/),
# each with its own catalog and helpers from lib/common.bash. This script only
# handles the TUI entries (AUR/official packages via yay).
#
# The selection sources:
#   --all                 → the whole tuis.catalog
#   --from-backup=SRC     → a backup tar.gz or an apps.selected file
#                          (only its TUI entries are kept)
# Without -y, the entries are presented (gum multi-select, all checked).
#
# Usage :
#   ./setup-tuis.sh --all -y        # install every TUI of the catalog
#   ./setup-tuis.sh --from-backup=BACKUP.tar.gz -y
#   ./setup-tuis.sh --list-selection --from-backup=BACKUP.tar.gz
#   ./setup-tuis.sh --status        # state of the catalog entries (nothing done)
#   ./setup-tuis.sh -h
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
# Monitor-TUI-Omarchy) — proposed by default alongside plain TUIs here.
TYPES=(TUI PLUG)

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
  ((STATUS_ONLY)) && {
    status_type TUI CAT_TUI "TUIs"
    status_type PLUG CAT_PLUG "Plugins"
    exit 0
  }

  [[ -n $FROM || $ALL == 1 ]] || {
    err "Nothing to do: give --all or --from-backup=SRC (a backup or an apps.selected file)."
    err "The main entry is setup-apps.sh (backup flow); this script handles the $TYPE_TAG type alone."
    exit 0
  }

  if [[ -n $FROM ]]; then
    [[ -f $FROM ]] || FROM="$BACKUP_DIR/$FROM"
    extract_selection "$FROM" || exit 1
    trap 'rm -f "$SEC_FILE"' EXIT
    selection_of_types || exit 1
    ((${#BASE[@]})) || { warn "No $TYPE_PLURAL entry in this selection."; exit 0; }
  else
    all_catalog_types
    ((${#BASE[@]})) || { warn "$TYPE_PLURAL catalog is empty ($CAT_FILE_TUI)."; exit 0; }
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
  install_icon_and_launcher
  # Some AUR TUIs (septabee, caligula-git…) ship no usable launcher, or one
  # whose menu entry must be created here: every cataloged TUI that has a
  # scripts/apps/tui-tools/setup-<base>-menu.sh companion gets it run (idempotent,
  # never aborts the batch).
  local e pkg stem
  for e in "${INSTALL_LIST[@]:-}"; do
    [[ $e == TUI\ * ]] || continue
    pkg="${e#TUI }"
    stem="${pkg%-git}"; stem="${stem%-bin}"
    [[ -x "$SCRIPT_DIR/setup-$stem-menu.sh" ]] && "$SCRIPT_DIR/setup-$stem-menu.sh" || true
  done
  hr
  ((rc == 0)) && ok "Done." || err "Some entries failed (relaunch to resume)."
  return $rc
}

main "$@"
