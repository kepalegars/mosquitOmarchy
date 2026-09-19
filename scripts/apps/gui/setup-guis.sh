#!/usr/bin/env bash
# setup-guis.sh — Installs the GUI apps of the "apps" module (guis.catalog).
#
# Part of the modular apps module: one script per type (gui/ tui/ webapps/),
# each with its own catalog and helpers from lib/common.bash. This script only
# handles the APP entries (AUR/official packages via yay).
#
# The selection sources:
#   --all                 → the whole guis.catalog
#   --from-backup=SRC     → a backup tar.gz or an apps.selected file
#                          (only its APP entries are kept)
# Without -y, the entries are presented (gum multi-select, all checked).
#
# Usage :
#   ./setup-guis.sh                 # interactive: prompt for source? no — see below
#   ./setup-guis.sh --all -y        # install every GUI app of the catalog
#   ./setup-guis.sh --from-backup=BACKUP.tar.gz -y
#   ./setup-guis.sh --list-selection --from-backup=BACKUP.tar.gz
#   ./setup-guis.sh --status        # state of the catalog entries (nothing done)
#   ./setup-guis.sh -h
#
# Optional extra (NOT in the catalog — a system-wide viewer swap): replace
# Evince with Papers:  ../fixes/fix-replace-evince-with-papers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/gui-run.bash"  # gui-run: reopen in a terminal when launched from a file manager
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.bash"

TYPE="APP"
TYPE_ARR=CAT_APP
ARRNAME=CAT_APP
TYPE_PLURAL="GUI apps"
TYPE_TAG=guis

YES=0 STATUS_ONLY=0 LIST_ONLY=0 ALL=0 FROM=""
for a in "$@"; do case "$a" in
  -y|--yes) YES=1 ;;
  --status) STATUS_ONLY=1 ;;
  --list-selection) LIST_ONLY=1 ;;
  --all) ALL=1 ;;
  --from-backup=*) FROM="${a#*=}" ;;
  -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
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
    ((${#BASE[@]})) || { warn "$TYPE_PLURAL catalog is empty ($CAT_FILE_GUI)."; exit 0; }
  fi

  ((LIST_ONLY)) && {
    hr; msg "$TYPE_PLURAL in the selection:"
    local e
    for e in "${BASE[@]:-}"; do echo "  $e"; done
    hr; exit 0
  }

  tick_entries
  ((${#INSTALL_LIST[@]})) || { warn "Nothing selected — nothing installed."; exit 0; }
  # Flag when the Zen browser or KeePassXC are among the entries being
  # installed, so the post-install summary points at the dedicated config
  # module / window fix for each.
  ZEN_JUST_INSTALLED=0
  KPXC_JUST_INSTALLED=0
  local _z
  for _z in "${INSTALL_LIST[@]}"; do
    case $_z in
      "+ APP zen-browser-bin"*|"APP zen-browser-bin"*) ZEN_JUST_INSTALLED=1 ;;
      "+ APP keepassxc"*|"APP keepassxc"*) KPXC_JUST_INSTALLED=1 ;;
    esac
  done
  printf "\n"
  install_entries
  local rc=$?
  hr
  # Post-install: the Zen browser was (re)installed → point the user at the
  # dedicated zen module (plugins/settings/chrome config deployment).
  if [[ ${ZEN_JUST_INSTALLED:-0} == 1 ]]; then
    warn "Zen Browser was installed — remember its config module:"
    echo "    ./setup-customarchy.sh --include=zen   (or run ./setup-customarchy.sh without -y)"
    echo "    (deploys the seed plugins/settings/chrome into the active profile)"
  fi
  # Post-install: KeePassXC was (re)installed → the Hyprland window fix and
  # the README section for it (browser integration, backup of the database).
  if [[ ${KPXC_JUST_INSTALLED:-0} == 1 ]]; then
    warn "KeePassXC was installed — remember its window fix and docs:"
    echo "    ./scripts/fixes/fix-keepassxc-window.sh   (float/center in Hyprland)"
    echo "    See scripts/apps/gui/README.md — KeePassXC (browser integration, backup)"
  fi
  ((rc == 0)) && ok "Done." || err "Some entries failed (relaunch to resume)."
  return $rc
}

main "$@"
