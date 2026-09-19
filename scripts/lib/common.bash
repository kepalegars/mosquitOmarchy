# lib/common.bash — shared helpers for the apps/ module
#
# Sourced by setup-apps.sh / uninstall-apps.sh (dispatchers) and by the
# per-type scripts (gui/setup-guis.sh, tui-tools/setup-tuis.sh,
# webapps/setup-webapps.sh and their uninstall counterparts).
#
# This file lives in scripts/lib/ → APP_DIR resolves to scripts/apps.
[[ -n ${OMARCHY_APPS_LIB_SOURCED:-} ]] && return 0
OMARCHY_APPS_LIB_SOURCED=1

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../apps" && pwd)"

# Shared privilege-elevation helper (mq_sudo): native pkexec prompt when not
# already root, so package installs/removals go through the Omarchy polkit GUI.
# shellcheck source=elevate.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/elevate.bash"

# One catalog per type (the "apps" module, modular catalogs).
# Note: catalog PATHS use CAT_FILE_* — the names CAT_APP/CAT_TUI/CAT_WEB are
# reserved for the loaded entry ARRAYS (a name collision would clobber the paths).
CAT_FILE_GUI="$APP_DIR/gui/guis.catalog"
CAT_FILE_TUI="$APP_DIR/tui-tools/tuis.catalog"
CAT_FILE_WEB="$APP_DIR/webapps/webapps.catalog"

BACKUP_DIR="${OMARCHY_BACKUP_DIR:-$HOME/omarchy-backups}"
BACKUP_GLOB="$BACKUP_DIR/omarchy-backup-*.tar.gz"

# Omarchy themes export a GREY GUM_CHOOSE_SELECTED_BACKGROUND (#918f93): the
# selected row then shows as a big grey box. Clearing it leaves only the "[x]"
# checkmark, which is all we want for a multi-select. Harmless for single-select.
export GUM_CHOOSE_SELECTED_BACKGROUND=""
export GUM_FILTER_SELECTED_BACKGROUND=""

G='\033[1;32m'; B='\033[1;34m'; Y='\033[1;33m'; R='\033[1;31m'; D='\033[2m'; N='\033[0m'
msg(){ printf "${B}==>${N} %s\n" "$*"; }
ok(){ printf " ${G}✓${N} %s\n" "$*"; }
warn(){ printf " ${Y}!${N} %s\n" "$*"; }
err(){ printf " ${R}✗${N} %s\n" "$*" >&2; }
hr(){ printf '%.0s─' {1..72}; echo; }

ask(){
  local q="$1" def="${2:-y}" r
  ((YES)) && { ok "(auto) $q -> yes"; return 0; }
  if command -v gum >/dev/null; then
    gum confirm "$q" --default=$([[ $def == y ]] && echo true || echo false) && return 0 || return 1
  fi
  read -rp "$q [$([ $def = y ] && echo Y/n || echo y/N)] " r
  r="${r:-$def}"; [[ $r =~ ^[oOyY] ]]
}

pkg_has(){ pacman -Q "$1" &>/dev/null; }

is_webapp_installed(){
  [[ -f "$HOME/.local/share/applications/$1.desktop" ]] \
    && grep -qE '^Exec=.*(omarchy-launch-webapp|omarchy-webapp-handler)' \
         "$HOME/.local/share/applications/$1.desktop"
}

# PLUG entries are git-based Omarchy shell plugins (omarchy plugin add/remove),
# not pacman packages — checked by plugin id against `omarchy plugin list`.
plugin_installed(){
  command -v omarchy >/dev/null 2>&1 || return 1
  omarchy plugin list --json 2>/dev/null | jq -e --arg id "$1" '.[] | select(.id==$id)' >/dev/null 2>&1
}

require_yay(){
  if ! command -v yay >/dev/null; then
    err "No AUR helper detected (yay missing). Install it:  sudo pacman -S --needed base-devel git && git clone https://aur.archlinux.org/yay.git && cd yay && makepkg -si"
    return 1
  fi
}

# ─────────────────────────── Catalogs ───────────────────────────
# Loads the three per-type catalogs into CAT_APP / CAT_TUI / CAT_WEB
# (entries without the type prefix, e.g. "name|label" or a WEB "name|url|icon").
load_catalog(){
  # declare -g: must write the GLOBAL arrays even when a caller holds a
  # nameref (local -n) over them — otherwise bash's nameref scoping breaks
  # the assignment (unbound variable under set -u).
  declare -g CAT_APP=(); declare -g CAT_TUI=(); declare -g CAT_WEB=(); declare -g CAT_PLUG=()
  local line kind f
  for f in "$CAT_FILE_GUI" "$CAT_FILE_TUI" "$CAT_FILE_WEB"; do
    [[ -f $f ]] || continue
    while IFS= read -r line || [[ -n $line ]]; do
      line="${line%%$'\r'}"
      [[ -z $line || $line == \#* ]] && continue
      kind="${line%%[ |]*}"
      case $kind in
        APP)  CAT_APP+=("${line#*[ ]}") ;;
        TUI)  CAT_TUI+=("${line#*[ ]}") ;;
        WEB)  CAT_WEB+=("${line#*[ ]}") ;;
        PLUG) CAT_PLUG+=("${line#*[ ]}") ;;
      esac
    done < "$f"
  done
  return 0
}

# At least one per-type catalog exists?
catalog_present(){ [[ -f $CAT_FILE_GUI || -f $CAT_FILE_TUI || -f $CAT_FILE_WEB ]]; }

# Looks up a "pkg|label" entry in an array (returns the label, or the pkg)
label_of(){
  local kind="$1" pkg="$2" entry lbl
  local -n arr="$kind"
  for entry in "${arr[@]:-}"; do
    [[ "${entry%%|*}" == "$pkg" ]] && { echo "${entry#*|}"; return; }
  done
  echo "$pkg"
}

# ───────────────────── Backup selection (apps.selected) ─────────────────────
# The selection chosen at backup is stored in ' apps.selected ' in the archive.
# These helpers locate it in a backup and extract/load it.
find_backups_with_selection(){
  local f; local -a found=()
  for f in "$BACKUP_DIR"/omarchy-backup-*.tar.gz; do
    [[ -f $f ]] && tar tzf "$f" 2>/dev/null | grep -q '^\./apps.selected$' && found+=("$f")
  done
  ((${#found[@]})) && printf '%s\n' "${found[@]}"
}

pick_backup(){
  # Interactive: picks the backup (chronological, most recent first).
  local -a files=() f
  while IFS= read -r f; do [[ -n $f ]] && files+=("$f"); done < <(find_backups_with_selection)
  ((${#files[@]})) || { err "No backup with an app selection in $BACKUP_DIR."; return 1; }
  if command -v gum >/dev/null; then
    local -a display=() b
    for ((b=${#files[@]}-1; b>=0; b--)); do display+=("$(basename "${files[$b]}")"); done
    local choice
    choice="$(gum choose "${display[@]}" --header "Which backup (app selection) ?" --height 10)"
    [[ -n $choice ]] || { err "No backup chosen."; return 1; }
    echo "$BACKUP_DIR/$choice"
  else
    echo "Backups with an app selection:"
    local i n
    for ((i=${#files[@]}-1; i>=0; i--)); do printf '  %2d) %s\n' $(( ${#files[@]} - i )) "$(basename "${files[$i]}")"; done
    read -rp "Number [default 1 = most recent]: " n; n="${n:-1}"
    echo "${files[$(( ${#files[@]} - n ))]}"
  fi
}

# Extracts the selection (apps.selected file or plain selection file) from a
# source (backup tar or apps.selected file) → SEC_FILE (global).
extract_selection(){
  local src="$1"
  [[ -f $src ]] || { err "Source not found: $src"; return 1; }
  SEC_FILE="$(mktemp)"
  if tar tzf "$src" 2>/dev/null | grep -q '^\./apps.selected$'; then
    tar xzf "$src" -C "$(dirname "$SEC_FILE")" ./apps.selected 2>/dev/null \
      && mv "$(dirname "$SEC_FILE")/apps.selected" "$SEC_FILE"
  elif grep -qE '^(APP|TUI|WEB|PLUG) ' "$src"; then
    cp "$src" "$SEC_FILE"
  else
    err "No app selection (apps.selected) in $src."
    rm -f "$SEC_FILE"; return 1
  fi
}

# Loads SEC_FILE into SELECTED (array of canonical entries, prefixed by type)
load_selection(){
  SELECTED=()
  [[ -f $SEC_FILE ]] || { err "No selection to load."; return 1; }
  local line
  while IFS= read -r line || [[ -n $line ]]; do
    line="${line%%$'\r'}"
    [[ -z $line || $line == \#* ]] && continue
    SELECTED+=("$line")
  done < "$SEC_FILE"
  return 0
}

# Per-type selection sources (used by the gui/tui/webapps scripts).
# TYPE = APP | TUI | WEB ; ARRNAME = CAT_APP / CAT_TUI / CAT_WEB.
# BASE / INSTALL_LIST / REMOVE_LIST are canonical "TYPE name|..." entries.

# Filters the loaded selection (SEC_FILE) down to one type → BASE
selection_of_type(){
  BASE=()
  [[ -f $SEC_FILE ]] || { err "No selection loaded."; return 1; }
  local line
  while IFS= read -r line || [[ -n $line ]]; do
    line="${line%%$'\r'}"
    [[ $line == "$TYPE "* ]] && BASE+=("$line")
  done < "$SEC_FILE"
  return 0
}

# Builds the BASE from the whole catalog of one type
all_catalog_type(){
  BASE=()
  load_catalog
  local -n arr="$ARRNAME"
  local entry
  for entry in "${arr[@]:-}"; do BASE+=("$TYPE $entry"); done
}

# Multi-type variants: TYPES=(A B ...) → BASE (entries of every listed type,
# each still self-tagged "TYPE name|..." so install_one/remove_one/tick_*
# dispatch correctly per-entry). Used where one script's catalog folder mixes
# kinds (e.g. tui/tuis.catalog holding both TUI and PLUG entries).
selection_of_types(){
  BASE=()
  [[ -f $SEC_FILE ]] || { err "No selection loaded."; return 1; }
  local line t
  while IFS= read -r line || [[ -n $line ]]; do
    line="${line%%$'\r'}"
    for t in "${TYPES[@]}"; do
      [[ $line == "$t "* ]] && { BASE+=("$line"); break; }
    done
  done < "$SEC_FILE"
  return 0
}

all_catalog_types(){
  BASE=()
  load_catalog
  local -A arrmap=( [APP]=CAT_APP [TUI]=CAT_TUI [WEB]=CAT_WEB [PLUG]=CAT_PLUG )
  local t entry
  for t in "${TYPES[@]}"; do
    local -n arr="${arrmap[$t]}"
    for entry in "${arr[@]:-}"; do BASE+=("$t $entry"); done
  done
}

# Base → INSTALL_LIST (gum multi-select, everything checked by default;
# with -y the base is kept as is)
tick_entries(){
  INSTALL_LIST=("${BASE[@]:-}")
  ((YES)) && return 0
  if command -v gum >/dev/null; then
    local -a labels=() picks out=() e name
    local kind
    for e in "${BASE[@]:-}"; do
      kind="${e%% *}"; name="${e#* }"; name="${name%%|*}"
      case $kind in
        APP)  labels+=("App   $name  —  $(label_of CAT_APP "$name")") ;;
        TUI)  labels+=("Tui   $name  —  $(label_of CAT_TUI "$name")") ;;
        WEB)  labels+=("Web   $name") ;;
        PLUG) labels+=("Plug  $name  —  $(echo "${e#* }" | cut -d'|' -f3)") ;;
      esac
    done
    mapfile -t picks < <(gum choose --no-limit --selected "*" --header "Entries to install (Tab/x = uncheck, Enter = confirm):" \
      --cursor-prefix "[ ] " --selected-prefix "[x] " --unselected-prefix "[ ] " "${labels[@]}")
    local wanted p
    for p in "${picks[@]}"; do
      wanted="${p#*  }"; wanted="${wanted%%  —*}"
      for e in "${BASE[@]:-}"; do
        name="${e#* }"; name="${name%%|*}"
        [[ $name == "$wanted" ]] && out+=("$e") && break
      done
    done
    INSTALL_LIST=("${out[@]}")
  else
    echo "Entries to install (Enter = all, or numbers to remove, e.g. '2 5'):"
    local i=1 ans n
    for e in "${BASE[@]:-}"; do printf '  %2d) %s\n' "$i" "$e"; i=$((i+1)); done
    read -rp "Choice: " ans
    if [[ -z $ans ]]; then INSTALL_LIST=("${BASE[@]:-}")
    else
      local -a drop=() out=() n2; local j=1 keep=1
      for n in $ans; do drop+=("$n"); done
      for e in "${BASE[@]:-}"; do
        keep=1
        for n2 in "${drop[@]}"; do [[ $j -eq $n2 ]] && keep=0; done
        ((keep)) && out+=("$e")
        j=$((j+1))
      done
      INSTALL_LIST=("${out[@]}")
    fi
  fi
}

# Interactive removal selection (gum, NOTHING checked by default ⇒ safe) over
# BASE → REMOVE_LIST. With -y the whole BASE is used when --all/--from-backup
# was given (up to the caller).
tick_removal(){
  REMOVE_LIST=()
  if command -v gum >/dev/null; then
    local -a labels=() picks out=() e name
    local kind
    for e in "${BASE[@]:-}"; do
      kind="${e%% *}"; name="${e#* }"; name="${name%%|*}"
      case $kind in
        APP)  labels+=("App   $name  —  $(label_of CAT_APP "$name")") ;;
        TUI)  labels+=("Tui   $name  —  $(label_of CAT_TUI "$name")") ;;
        WEB)  labels+=("Web   $name") ;;
        PLUG) labels+=("Plug  $name  —  $(echo "${e#* }" | cut -d'|' -f3)") ;;
      esac
    done
    mapfile -t picks < <(gum choose --no-limit --header "Choose what to uninstall (Tab/x = check, Enter = confirm):" \
      --cursor-prefix "[ ] " --selected-prefix "[x] " --unselected-prefix "[ ] " "${labels[@]}")
    local wanted p
    for p in "${picks[@]}"; do
      wanted="${p#*  }"; wanted="${wanted%%  —*}"
      for e in "${BASE[@]:-}"; do
        name="${e#* }"; name="${name%%|*}"
        [[ $name == "$wanted" ]] && out+=("$e") && break
      done
    done
    REMOVE_LIST=("${out[@]}")
  else
    echo "Entries to uninstall (numbers, e.g. '1 3'; empty = none):"
    local i=1 ans n
    for e in "${BASE[@]:-}"; do printf '  %2d) %s\n' "$i" "$e"; i=$((i+1)); done
    read -rp "Numbers: " ans
    for n in $ans; do
      [[ "$n" =~ ^[0-9]+$ ]] && ((n >= 1 && n <= ${#BASE[@]})) && REMOVE_LIST+=("${BASE[$((n-1))]}")
    done
  fi
}

# State of one type (from its catalog) — no modification
status_type(){
  local type="$1" arrname="$2" label="$3"
  load_catalog
  hr; msg "State of $label"
  local -n arr="$arrname"
  local entry name
  for entry in "${arr[@]:-}"; do
    name="${entry%%|*}"
    if [[ $type == WEB ]]; then
      if is_webapp_installed "$name"; then printf " ${G}✓${N} %-24s web  %s\n" "$name" "$(echo "$entry" | cut -d'|' -f2)"
      else printf " ${D}—${N} %-24s web  %s${D} (not installed)${N}\n" "$name" "$(echo "$entry" | cut -d'|' -f2)"; fi
    elif [[ $type == PLUG ]]; then
      if plugin_installed "$name"; then printf " ${G}✓${N} %-24s plug %s\n" "$name" "$(echo "$entry" | cut -d'|' -f3)"
      else printf " ${D}—${N} %-24s plug %s${D} (not installed)${N}\n" "$name" "$(echo "$entry" | cut -d'|' -f3)"; fi
    else
      if pkg_has "$name"; then printf " ${G}✓${N} %-24s %-4s %s\n" "$name" "$type" "${entry#*|}"
      else printf " ${D}—${N} %-24s %-4s %s${D} (not installed)${N}\n" "$name" "$type" "${entry#*|}"; fi
    fi
  done
  hr
}

# ─────────────────────────── Install / remove ───────────────────────────
# install_one KIND ENTRY with ENTRY = "name|label" (APP/TUI) or "name|url|icon" (WEB)
install_one(){
  local kind="$1" entry="$2" name url icon
  case $kind in
    APP|TUI)
      name="${entry%%|*}"
      pkg_has "$name" && { ok "$name : already installed"; return 0; }
      msg "Installing: $name"
      require_yay || return 1
      if yay -S --needed --noconfirm "$name"; then ok "$name : installed"
      else err "$name : INSTALL FAILED"; return 1; fi
      ;;
    WEB)
      name="${entry%%|*}"; url="$(echo "$entry" | cut -d'|' -f2)"; icon="$(echo "$entry" | cut -d'|' -f3)"
      is_webapp_installed "$name" && { ok "Webapp $name : already present"; return 0; }
      msg "Webapp: $name ($url)"
      if omarchy webapp install "$name" "$url" "$icon" 2>/dev/null; then ok "Webapp $name : installed"
      else err "Webapp $name : FAILED"; return 1; fi
      ;;
    PLUG)
      name="${entry%%|*}"; url="$(echo "$entry" | cut -d'|' -f2)"
      plugin_installed "$name" && { ok "Plugin $name : already present"; return 0; }
      msg "Plugin: $name ($url)"
      if omarchy plugin add "$url" --enable --yes >/dev/null 2>&1; then ok "Plugin $name : installed"
      else err "Plugin $name : FAILED"; return 1; fi
      ;;
  esac
}

remove_one(){
  local kind="$1" entry="$2" name
  case $kind in
    APP|TUI)
      name="${entry%%|*}"
      if pkg_has "$name"; then
        msg "Uninstalling: $name"
        if mq_sudo pacman -Rns --noconfirm "$name" 2>/dev/null; then ok "$name : uninstalled"
        else err "$name : FAILED"; return 1; fi
      else ok "$name : not installed"; fi
      ;;
    WEB)
      name="${entry%%|*}"
      if is_webapp_installed "$name"; then
        msg "Webapp: removing $name"
        if omarchy webapp remove "$name" 2>/dev/null; then ok "Webapp $name : removed"
        else err "Webapp $name : FAILED"; return 1; fi
      else ok "Webapp $name : not present"; fi
      ;;
    PLUG)
      name="${entry%%|*}"
      if plugin_installed "$name"; then
        msg "Plugin: removing $name"
        if omarchy plugin remove "$name" --yes >/dev/null 2>&1; then ok "Plugin $name : removed"
        else err "Plugin $name : FAILED"; return 1; fi
      else ok "Plugin $name : not present"; fi
      ;;
  esac
}

# Installs the canonical entries of INSTALL_LIST (calls install_one) → rc
install_entries(){
  ((${#INSTALL_LIST[@]})) || { warn "Nothing to install."; return 0; }
  msg "Installing ${#INSTALL_LIST[@]} item(s)"
  local e kind entry rc=0
  for e in "${INSTALL_LIST[@]}"; do
    kind="${e%% *}"; entry="${e#* }"
    install_one "$kind" "$entry" || rc=1
  done
  return $rc
}

remove_entries(){
  ((${#REMOVE_LIST[@]})) || { warn "Nothing to uninstall."; return 0; }
  msg "Uninstalling ${#REMOVE_LIST[@]} item(s)"
  local e kind entry rc=0
  for e in "${REMOVE_LIST[@]}"; do
    kind="${e%% *}"; entry="${e#* }"
    remove_one "$kind" "$entry" || rc=1
  done
  return $rc
}

# ─────────────────── TUI icon / launcher finery (common.bash) ───────────────────
# Some TUI packages (bare -bin releases) ship no .desktop nor icon. If a
# "NAME-logo.png" asset sits next to the TUI catalog (scripts/apps/tui-tools/), it is
# installed as the app icon and a Terminal=true launcher is created for the app
# menu. The asset lives in the repo → always available from a backup selection.
TUI_ASSETS_DIR="$APP_DIR/tui-tools"
TUI_ICONS_DIR="$HOME/.local/share/icons/hicolor/256x256/apps"
TUI_DESKTOPS_DIR="$HOME/.local/share/applications"

install_icon_and_launcher(){
  local e kind name base logo dst desktop
  for e in "${INSTALL_LIST[@]:-}"; do
    kind="${e%% *}"; [[ $kind == "TUI" ]] || continue
    name="${e#* }"; name="${name%%|*}"
    base="${name%-bin}"
    logo="$TUI_ASSETS_DIR/$base-logo.png"
    [[ -f $logo ]] || continue
    dst="$TUI_ICONS_DIR/$base.png"
    if [[ ! -f $dst ]] || ! cmp -s "$logo" "$dst"; then
      mkdir -p "$TUI_ICONS_DIR"
      cp "$logo" "$dst"
      ok "$base : icon installed ($dst)"
    else
      ok "$base : icon already in place ($dst)"
    fi
    desktop="$TUI_DESKTOPS_DIR/$base.desktop"
    # Apps with a dedicated per-app integration script (setup-<base>-menu.sh,
    # e.g. setup-septabee-menu.sh) own their .desktop/menu — the generic
    # helper only ensures the icon here.
    if [[ -f "$TUI_ASSETS_DIR/setup-$base-menu.sh" ]]; then
      ok "$base : desktop/menu managed by setup-$base-menu.sh (icon only)"
      continue
    fi
    if [[ ! -f $desktop ]] || ! grep -q "^Exec=$name\b" "$desktop"; then
      mkdir -p "$TUI_DESKTOPS_DIR"
      cat > "$desktop" <<EOF
[Desktop Entry]
Type=Application
Name=$base
GenericName=Cache & junk cleaner
Comment=Installed via mosquitOmarchy (setup-tuis.sh)
Exec=$name
Terminal=true
Icon=$base
Categories=Utility;System;
EOF
      ok "$base : launcher installed ($desktop)"
    else
      ok "$base : launcher already in place ($desktop)"
    fi
  done
  command -v gtk-update-icon-cache >/dev/null 2>&1 \
    && gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" >/dev/null 2>&1 || true
}

remove_icon_and_launcher(){
  local e kind name base
  for e in "${REMOVE_LIST[@]:-}"; do
    kind="${e%% *}"; [[ $kind == "TUI" ]] || continue
    name="${e#* }"; name="${name%%|*}"
    base="${name%-bin}"
    if [[ -f "$TUI_ASSETS_DIR/setup-$base-menu.sh" ]]; then
      ok "$base : desktop/menu removal handled by setup-$base-menu.sh"
      continue
    fi
    [[ -f "$TUI_ASSETS_DIR/$base-logo.png" ]] || continue
    [[ -f "$TUI_ICONS_DIR/$base.png" ]] && rm -f "$TUI_ICONS_DIR/$base.png"
    [[ -f "$TUI_DESKTOPS_DIR/$base.desktop" ]] && rm -f "$TUI_DESKTOPS_DIR/$base.desktop"
    ok "$base : icon/launcher removed"
  done
  command -v gtk-update-icon-cache >/dev/null 2>&1 \
    && gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" >/dev/null 2>&1 || true
}