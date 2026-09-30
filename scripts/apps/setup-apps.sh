#!/usr/bin/env bash
# setup-apps.sh — Dispatcher of the "apps" module (apps / tuis / webapps).
#
# The module is now modular: one folder + catalog + script per type under
# apps/gui, apps/tui-tools, apps/webapps (shared helpers in
# lib/common.bash). This installer KEEPS the historical interface: it reads the
# app selection saved by the backup (mosquitomarchy-setup.sh --backup) (apps.selected), lets you tick
# it (EVERYTHING checked by default, like before, plus the catalog entries not
# in the backup) then calls each per-type installer with its selection subset
# (see delegate_types() at the bottom of main()). Adding a type only requires a
# catalog + folder + script in apps/ — the dispatcher picks them up.
#
# Complement to the backup (mosquitomarchy-setup.sh --backup) which, during a backup, can save the list
# of apps, TUIs and webapps you have (multi-select) in the ' apps.selected ' file
# inside the dated archive (~/omarchy-backups/).
#
# Usage :
#   ./setup-apps.sh                 # interactive: choose backup then tick the selection (gum multi-select)
#   ./setup-apps.sh -y              # non-interactive: most recent backup selection, EVERYTHING installed
#   ./setup-apps.sh --from-backup=F      # uses the dated backup F (or an apps.selected file)
#   ./setup-apps.sh --only=<gui|tui|webapps>  # restrict to one catalog type (used by the
#                                             # launcher categories TUIs / Webapps; falls
#                                             # back to the full catalog when the backup
#                                             # has nothing for that type)
#   ./setup-apps.sh --list-selection     # lists/ticks the selection, without installing anything
#   ./setup-apps.sh --status             # state of apps/tuis/webapps, without modifying anything
#   ./setup-apps.sh -h                   # help
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/gui-run.bash"  # gui-run: reopen in a terminal when launched from a file manager
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.bash"

# Per-type installers (modular module)
GUI_INSTALL="$APP_DIR/gui/setup-guis.sh"
TUI_INSTALL="$APP_DIR/tui/setup-tuis.sh"
WEB_INSTALL="$APP_DIR/webapps/setup-webapps.sh"

YES=0 STATUS_ONLY=0 LIST_ONLY=0 FROM_BACKUP="" ONLY=""
for a in "$@"; do case "$a" in
  -y|--yes) YES=1 ;;
  --status) STATUS_ONLY=1 ;;
  --list-selection) LIST_ONLY=1 ;;
  --from-backup=*) FROM_BACKUP="${a#*=}" ;;
  --only=*) ONLY="${a#*=}" ;;
  -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
  *) echo "Unknown option: $a (see -h)" >&2; exit 1 ;;
esac; done
case $ONLY in gui|tui|webapps|"") : ;; *) echo "Unknown --only value: $ONLY (gui|tui|webapps)" >&2; exit 1 ;; esac

# ─────────────────────────── State (--status) ───────────────────────────
do_status(){
  load_catalog || { err "No catalog found (gui/guis.catalog, tui/tuis.catalog, webapps/webapps.catalog)."; exit 1; }
  status_type APP CAT_APP "GUI apps"
  status_type TUI CAT_TUI "TUIs"
  status_type WEB CAT_WEB "Webapps"
  status_type PLUG CAT_PLUG "Plugins"
  echo "  A backup with an app selection exists: $(find_backups_with_selection | wc -l) found"
}

# ─────────────────────────── Selection (tick) ───────────────────────────
# Asks (gum multi-select, everything checked by default) which entries to
# install; otherwise adopts the default selection. Fills FINAL_SEL (canonical
# "TYPE name|..." entries, prefixed by type).
choose_selection(){
  ((YES)) && { FINAL_SEL=("${SELECTED[@]}"); return 0; }
  if command -v gum >/dev/null; then
    local -a labels=() e name
    for e in "${SELECTED[@]:-}"; do
      case $e in
        APP*)  name="${e#APP }"; name="${name%%|*}"; labels+=("App   ${name}  —  $(label_of CAT_APP "$name")") ;;
        TUI*)  name="${e#TUI }"; name="${name%%|*}"; labels+=("Tui   $name  —  $(label_of CAT_TUI "$name")") ;;
        WEB*)  name="${e#WEB }"; name="${name%%|*}"; labels+=("Web   $name") ;;
        PLUG*) name="${e#PLUG }"; name="${name%%|*}"; labels+=("Plug  $name  —  $(echo "${e#PLUG }" | cut -d'|' -f3)") ;;
      esac
    done
    local -a picks
    mapfile -t picks < <(gum choose --no-limit --selected "*" --header "Apps / TUIs / webapps / plugins to install (Tab/x = uncheck, Enter = confirm):" \
      --cursor-prefix "[ ] " --selected-prefix "[x] " --unselected-prefix "[ ] " "${labels[@]}")
    FINAL_SEL=()
    local wanted p
    for p in "${picks[@]}"; do
      wanted="${p#*  }"        # removes the "App  " / "Tui  " / "Web  " / "Plug  " prefix
      wanted="${wanted%%  —*}"
      for e in "${SELECTED[@]:-}"; do
        case $e in
          APP*)  name="${e#APP }"; name="${name%%|*}"; [[ $name == "$wanted" ]] && FINAL_SEL+=("$e") ;;
          TUI*)  name="${e#TUI }"; name="${name%%|*}"; [[ $name == "$wanted" ]] && FINAL_SEL+=("$e") ;;
          WEB*)  name="${e#WEB }"; name="${name%%|*}"; [[ $name == "$wanted" ]] && FINAL_SEL+=("$e") ;;
          PLUG*) name="${e#PLUG }"; name="${name%%|*}"; [[ $name == "$wanted" ]] && FINAL_SEL+=("$e") ;;
        esac
      done
    done
  else
    echo "Default selection (everything checked) — Enter to keep all, or remove some numbers:"
    local i=1 e
    for e in "${SELECTED[@]:-}"; do printf '  %2d) %s\n' "$i" "$e"; i=$((i+1)); done
    echo "  (edit via numbers: '2 5' removes entries 2 and 5 — 'a' = all)"
    local ans; read -r -p "Choice [Enter = all]: " ans
    if [[ -z $ans || $ans == a ]]; then FINAL_SEL=("${SELECTED[@]}")
    else
      local -a drop=()
      for n in $ans; do drop+=("$n"); done
      FINAL_SEL=(); local j=1 n2
      for e in "${SELECTED[@]:-}"; do
        local keep=1
        for n2 in "${drop[@]}"; do [[ $j -eq $n2 ]] && keep=0; done
        ((keep)) && FINAL_SEL+=("$e")
        j=$((j+1))
      done
    fi
  fi
}

# Proposes the catalog entries NOT present in the backup (e.g. apps recently
# added to a catalog like stremio) so you can add them without re-running a
# backup. With -y they are ignored (only the backup/default is kept).
add_extra_candidates(){
  ((YES)) && return 0
  local only="${ONLY:-}"
  local -a candidates=() labels=() e name in_backup=0 cand
  if [[ $only != tui && $only != webapps ]]; then
  for e in "${CAT_APP[@]:-}"; do
    name="${e%%|*}"; in_backup=0
    for cand in "${SELECTED[@]:-}"; do [[ $cand == "APP $name" ]] && in_backup=1 && break; done
    ((in_backup)) || candidates+=("APP $name")
  done
  fi
  if [[ $only != gui && $only != webapps ]]; then
  for e in "${CAT_TUI[@]:-}"; do
    name="${e%%|*}"; in_backup=0
    for cand in "${SELECTED[@]:-}"; do [[ $cand == "TUI $name" ]] && in_backup=1 && break; done
    ((in_backup)) || candidates+=("TUI $name")
  done
  fi
  if [[ $only != gui && $only != tui ]]; then
  for e in "${CAT_WEB[@]:-}"; do
    name="${e%%|*}"; in_backup=0
    for cand in "${SELECTED[@]:-}"; do [[ $cand == "WEB $e" ]] && in_backup=1 && break; done
    ((in_backup)) || candidates+=("WEB $e")
  done
  fi
  if [[ $only != gui && $only != webapps ]]; then
  for e in "${CAT_PLUG[@]:-}"; do
    name="${e%%|*}"; in_backup=0
    for cand in "${SELECTED[@]:-}"; do [[ $cand == "PLUG $e" ]] && in_backup=1 && break; done
    ((in_backup)) || candidates+=("PLUG $e")
  done
  fi
  ((${#candidates[@]})) || return 0
  for e in "${candidates[@]}"; do
    case $e in
      APP*)  name="${e#APP }"; labels+=("App   $name  —  $(label_of CAT_APP "$name")") ;;
      TUI*)  name="${e#TUI }"; labels+=("Tui   $name  —  $(label_of CAT_TUI "$name")") ;;
      WEB*)  name="${e#WEB }"; labels+=("Web   $name") ;;
      PLUG*) name="${e#PLUG }"; labels+=("Plug  ${name%%|*}  —  $(echo "$name" | cut -d'|' -f3)") ;;
    esac
  done
  if command -v gum >/dev/null; then
    local -a extra_picks p
    mapfile -t extra_picks < <(gum choose --no-limit \
      --header "Other catalog apps to add (Tab/x = select, Enter = confirm):" \
      --cursor-prefix "[ ] " --selected-prefix "[x] " --unselected-prefix "[ ] " "${labels[@]}")
    for p in "${extra_picks[@]}"; do
      local wanted="${p#*  }"; wanted="${wanted%%  —*}"
      for cand in "${candidates[@]}"; do
        local name2="${cand#* }"; name2="${name2%%|*}"
        [[ $name2 == "$wanted" ]] && FINAL_SEL+=("$cand") && break
      done
    done
  else
    echo "Other catalog apps (outside the backup) available:"
    local i=1 ans n
    for cand in "${candidates[@]}"; do printf '  %2d) %s\n' "$i" "$cand"; i=$((i+1)); done
    read -rp "Add some numbers? [empty = none]: " ans
    for n in $ans; do
      [[ "$n" =~ ^[0-9]+$ ]] && ((n >= 1 && n <= ${#candidates[@]})) \
        && FINAL_SEL+=("${candidates[$((n-1))]}")
    done
  fi
}

# ─────────────────────────── Per-type delegation ───────────────────────────
# For each type: filter FINAL_SEL lines, hand the subset to the type installer.
delegate_types(){
  local rc=0
  # tui bucket also carries PLUG entries (Omarchy shell plugins like
  # Monitor-TUI-Omarchy) — setup-tuis.sh/uninstall-tuis.sh handle both kinds.
  local -A prefixes=( [gui]="APP" [tui]="TUI PLUG" [webapps]="WEB" )
  local t script tmpf line p
  local -a types=(gui tui webapps)
  [[ -n $ONLY ]] && types=( "$ONLY" )
  for t in "${types[@]}"; do
    case $t in
      gui)     script="$GUI_INSTALL" ;;
      tui)     script="$TUI_INSTALL" ;;
      webapps) script="$WEB_INSTALL" ;;
    esac
    tmpf="$(mktemp)"
    for line in "${FINAL_SEL[@]:-}"; do
      for p in ${prefixes[$t]}; do
        [[ $line == "$p "* ]] && { echo "$line" >> "$tmpf"; break; }
      done
    done
    if [[ -s $tmpf ]]; then
      msg "→ $t ($(wc -l < "$tmpf") entry/ies)"
      bash "$script" --from-backup="$tmpf" -y || { err "$t install failed"; rc=1; }
    else
      ok "$t : nothing selected"
    fi
    rm -f "$tmpf"
  done
  return $rc
}

# ─────────────────────────── Main ───────────────────────────
main(){
  # --status : global state of the catalogs (no modification)
  if ((STATUS_ONLY)); then do_status; exit 0; fi

  load_catalog || { err "No catalog found (gui/guis.catalog, tui/tuis.catalog, webapps/webapps.catalog)."; exit 1; }

  # --list-selection : shows the default selection of a backup without installing
  local src=""
  if [[ -n $FROM_BACKUP ]]; then
    src="$FROM_BACKUP"
    [[ -f $src ]] || src="$BACKUP_DIR/$FROM_BACKUP"
  else
    src="$(pick_backup)" || exit 1
  fi
  extract_selection "$src" || exit 1
  load_selection || exit 1
  trap 'rm -f "$SEC_FILE"' EXIT

  # --only=<gui|tui|webapps>: keep only that type's entries; if the backup has
  # none for it, seed the selection from the type's own catalog so "setup TUIs"
  # (launcher) works even without a prior backup of that type.
  if [[ -n $ONLY ]]; then
    local -A pre=( [gui]="APP" [tui]="TUI PLUG" [webapps]="WEB" )
    local -a sel=()
    local e pp
    for e in "${SELECTED[@]:-}"; do
      for pp in ${pre[$ONLY]}; do [[ $e == "$pp "* ]] && sel+=("$e") && break; done
    done
    if ((${#sel[@]} == 0)); then
      local e2
      case $ONLY in
        gui)     for e2 in "${CAT_APP[@]:-}"; do sel+=("APP $e2"); done ;;
        tui)     for e2 in "${CAT_TUI[@]:-}"; do sel+=("TUI $e2"); done ;;
        webapps) for e2 in "${CAT_WEB[@]:-}"; do sel+=("WEB $e2"); done ;;
      esac
      ((${#sel[@]})) && ok "No '$ONLY' selection in this backup — proposing the whole $ONLY catalog."
    fi
    SELECTED=("${sel[@]}")
  fi

  if ((LIST_ONLY)); then
    hr; msg "App/TUI/webapp selection in $(basename "$src"):"
    local e
    for e in "${SELECTED[@]:-}"; do echo "  $e"; done
    hr; exit 0
  fi

  if ((${#SELECTED[@]} == 0)); then
    warn "No app selection in this backup. Run a backup with an app selection (--backup) first."
    exit 0
  fi

  choose_selection
  add_extra_candidates

  ((${#FINAL_SEL[@]})) || { warn "No retained entry — nothing installed."; exit 0; }

  delegate_types
  local rc=$?
  hr
  ((rc == 0)) && ok "Done." || err "Some entries failed (relaunch to resume)."
  return $rc
}

main "$@"
