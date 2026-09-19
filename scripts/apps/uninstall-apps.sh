#!/usr/bin/env bash
# uninstall-apps.sh — Dispatcher removing the apps / TUIs / webapps managed by
# the "apps" module.
#
# Like setup-apps.sh, this is the historical entry that covers all three
# types (gui/ tui/ webapps/) of the modular apps module; it delegates the real
# work to the per-type uninstallers, each fed with its own selection subset.
#
# Works on the CATALOG entries (gui/guis.catalog, tui/tuis.catalog,
# webapps/webapps.catalog) or on a backup selection (--from-backup).
# DESTRUCTIVE uninstall: interactively you tick what you want to remove
# (NOTHING checked by default); with -y you must explicitly provide --all or
# --from-backup= to remove something.
#
#   • apps / TUIs → packages removed via pacman -Rns (personal data is not
#     touched: ~/.config, ~/.local/share, etc. are kept by -Rns) ;
#   • webapps      → launchers removed via `omarchy webapp remove <name>`.
#
# Usage :
#   ./uninstall-apps.sh                # interactive: tick what to remove (nothing by default)
#   ./uninstall-apps.sh --all -y       # removes ALL catalog entries
#   ./uninstall-apps.sh --from-backup=F -y   # removes exactly a backup selection
#   ./uninstall-apps.sh --status       # state (same entries, non destructive)
#   ./uninstall-apps.sh -h
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/gui-run.bash"  # gui-run: reopen in a terminal when launched from a file manager
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.bash"

GUI_UNINSTALL="$APP_DIR/gui/uninstall-guis.sh"
TUI_UNINSTALL="$APP_DIR/tui/uninstall-tuis.sh"
WEB_UNINSTALL="$APP_DIR/webapps/uninstall-webapps.sh"

YES=0 STATUS_ONLY=0 ALL=0 FROM_BACKUP=""
for a in "$@"; do case "$a" in
  -y|--yes) YES=1 ;;
  --status) STATUS_ONLY=1 ;;
  --all) ALL=1 ;;
  --from-backup=*) FROM_BACKUP="${a#*=}" ;;
  -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
  *) echo "Unknown option: $a (see -h)" >&2; exit 1 ;;
esac; done

# ─────────────────────── Selection (removal) ───────────────────────
# All canonical catalog entries → TARGET
all_catalog_entries(){
  TARGET=()
  local e
  for e in "${CAT_APP[@]:-}"; do TARGET+=("APP ${e%%|*}"); done
  for e in "${CAT_TUI[@]:-}"; do TARGET+=("TUI ${e%%|*}"); done
  for e in "${CAT_WEB[@]:-}"; do TARGET+=("WEB ${e}"); done
}

load_backup_target(){
  local src="$1"
  [[ -f $src ]] || src="$BACKUP_DIR/$src"
  [[ -f $src ]] || { err "Backup not found: $src"; return 1; }
  local tmp; tmp="$(mktemp -d)"; TARGET=()
  if tar tzf "$src" 2>/dev/null | grep -q '^\./apps.selected$'; then
    tar xzf "$src" -C "$tmp" ./apps.selected 2>/dev/null
    while IFS= read -r e || [[ -n $e ]]; do
      e="${e%%$'\r'}"; [[ -z $e || $e == \#* ]] && continue
      TARGET+=("${e%%|*}")
    done < "$tmp/apps.selected"
  else
    err "No app selection (apps.selected) in $src."
    rm -rf "$tmp"; return 1
  fi
  rm -rf "$tmp"
}

do_status(){
  load_catalog || exit 1
  status_type APP CAT_APP "GUI apps"
  status_type TUI CAT_TUI "TUIs"
  status_type WEB CAT_WEB "Webapps"
}

# Interactive removal selection across the three types (NOTHING checked by
# default) → TARGET
choose_removal(){
  TARGET=()
  local -a labels=() e name
  for e in "${CAT_APP[@]:-}"; do name="${e%%|*}"; labels+=("App   $name  —  ${e#*|}"); done
  for e in "${CAT_TUI[@]:-}"; do name="${e%%|*}"; labels+=("Tui   $name  —  ${e#*|}"); done
  for e in "${CAT_WEB[@]:-}"; do name="${e%%|*}"; labels+=("Web   $name"); done
  if command -v gum >/dev/null; then
    local -a picks
    mapfile -t picks < <(gum choose --no-limit --header "Choose what to uninstall (Tab/x = check, Enter = confirm):" \
      --cursor-prefix "[ ] " --selected-prefix "[x] " --unselected-prefix "[ ] " "${labels[@]}")
    for e in "${picks[@]}"; do
      name="${e#*  }"; name="${name%%  —*}"
      case $e in
        App*) TARGET+=("APP $name") ;;
        Tui*) TARGET+=("TUI $name") ;;
        Web*) TARGET+=("WEB $name") ;;
      esac
    done
  else
    echo "Remove entries? (numbers separated by spaces, e.g. '2 5')"
    local i=1 n ans
    for e in "${labels[@]}"; do printf '  %2d) %s\n' "$i" "$e"; i=$((i+1)); done
    read -rp "Numbers to uninstall [empty = none]: " ans
    for n in $ans; do
      [[ "$n" =~ ^[0-9]+$ ]] && {
        local sel="${labels[$((n-1))]}"; sel="${sel#*  }"; sel="${sel%%  —*}"
        case ${labels[$((n-1))]} in App*) TARGET+=("APP $sel");; Tui*) TARGET+=("TUI $sel");; Web*) TARGET+=("WEB $sel");; esac
      }
    done
  fi
}

# ─────────────────────── Per-type delegation ───────────────────────
delegate_types(){
  local rc=0
  local -A prefix=( [gui]="APP " [tui]="TUI " [webapps]="WEB " )
  local t script tmpf line
  for t in gui tui webapps; do
    case $t in
      gui)     script="$GUI_UNINSTALL" ;;
      tui)     script="$TUI_UNINSTALL" ;;
      webapps) script="$WEB_UNINSTALL" ;;
    esac
    tmpf="$(mktemp)"
    for line in "${TARGET[@]:-}"; do [[ $line == "${prefix[$t]}"* ]] && echo "$line" >> "$tmpf"; done
    if [[ -s $tmpf ]]; then
      msg "→ $t ($(wc -l < "$tmpf") entry/ies)"
      bash "$script" --from-backup="$tmpf" -y || { err "$t uninstall failed"; rc=1; }
    else
      ok "$t : nothing to remove"
    fi
    rm -f "$tmpf"
  done
  return $rc
}

# ─────────────────────────── Main ───────────────────────────
main(){
  if ((STATUS_ONLY)); then do_status; exit 0; fi
  load_catalog || exit 1

  if [[ -n $FROM_BACKUP ]]; then
    load_backup_target "$FROM_BACKUP" || exit 1
  elif ((ALL)); then
    all_catalog_entries
  elif ((YES)); then
    warn "--all or --from-backup= required with -y (destructive uninstall, nothing by default)."
    exit 0
  else
    choose_removal
  fi

  # With -y, everything in TARGET is removed; otherwise we re-confirm the final list.
  if ((YES == 0)); then
    ((${#TARGET[@]})) || { warn "Nothing to uninstall."; exit 0; }
    msg "Entries to uninstall:"
    local e
    for e in "${TARGET[@]}"; do echo "  - $e"; done
    ask "Confirm uninstalling these ${#TARGET[@]} entries ?" n || { warn "Cancelled."; exit 0; }
  fi

  ((${#TARGET[@]})) || { warn "Nothing to uninstall."; exit 0; }
  delegate_types
  local rc=$?
  hr
  ((rc == 0)) && ok "Done." || err "Some uninstalls failed."
  return $rc
}

main "$@"
