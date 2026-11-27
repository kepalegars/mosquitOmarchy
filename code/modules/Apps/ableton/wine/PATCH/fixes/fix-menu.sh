#!/usr/bin/env bash
# fix-menu.sh — Recrée l'entrée de menu « Ableton Live » si elle a disparu.
#
# Le launcher natif (ableton-live) régénère sa propre entrée à chaque lancement ;
# mais si le menu Omarchy n'affiche plus Ableton (entrée supprimée/cassée après
# une mise à jour système, updater-desktop-database, etc.), relance ce script :
#
#   bash ~/mosquitOmarchy/code/modules/Apps/ableton/wine/PATCH/fixes/fix-menu.sh
#
# Politique identique à install-ableton.sh :
#   • édition unique   → une seule entrée (celle du launcher), pas de doublon ;
#   • plusieurs éditions → une entrée par édition (exe ciblé), générique retirée.
set -euo pipefail

PREFIX="$HOME/.wine-ableton"
LAUNCHER="$HOME/.local/bin/ableton-live"
APPS="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
ICONS="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/scalable/apps"

G='\033[1;32m'; B='\033[1;34m'; Y='\033[1;33m'; R='\033[1;31m'; N='\033[0m'
msg(){ printf "${B}==>${N} %s\n" "$*"; }
ok(){ printf " ${G}✓${N} %s\n" "$*"; }
warn(){ printf " ${Y}!${N} %s\n" "$*"; }
err(){ printf " ${R}✗${N} %s\n" "$*" >&2; }

edition_of(){ printf '%s' "$1" | awk '{print tolower($NF)}'; }

write_entry(){ # write_entry FILE NAME EXEC EXTRA_DESKTOP_LINES
  local file="$1" name="$2" exec_line="$3" extra="${4:-}"
  local wmclass icon
  wmclass="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
  icon="live-$(edition_of "$name")"
  [[ -f "$ICONS/$icon.svg" ]] || icon="live-intro"
  {
    printf '[Desktop Entry]\n'
    printf 'Name=%s (Wine)\n' "$name"
    printf 'Comment=Music production and performance\n'
    printf 'Exec=%s\n' "$exec_line"
    printf 'Type=Application\n'
    printf 'StartupNotify=true\n'
    printf 'Path=%s\n' "$PREFIX"
    printf 'Icon=%s\n' "$icon"
    [[ -z "$extra" ]] || printf '%s\n' "$extra"
    printf 'Categories=AudioVideo;Audio;\n'
  } > "$file"
  chmod 644 "$file"
}

main(){
  msg "Réparation de l'entrée de menu Ableton (PATCH/fix-menu.sh)"
  [[ -x "$LAUNCHER" ]] || {
    err "Launcher absent : $LAUNCHER"
    err "Réinstalle d'abord : sh ~/Omarchy_Custom_Scripts/ableton/install-ableton.sh -y"
    exit 1
  }
  mkdir -p "$APPS"
  declare -a exes=()
  local exe base name generic ed file
  while IFS= read -r exe; do [[ -f "$exe" ]] && exes+=("$exe"); done \
    < <(ls -1 "$PREFIX"/drive_c/ProgramData/Ableton/*/Program/"Ableton Live"*.exe 2>/dev/null | sort -V)
  if (( ${#exes[@]} == 0 )); then
    warn "Aucune édition installée dans $PREFIX — rien à afficher au menu."
    warn "Vérifie : ls \"$PREFIX\"/drive_c/ProgramData/Ableton/"
    warn "Si elle manque, réinstalle : sh ~/Omarchy_Custom_Scripts/ableton/install-ableton.sh -y"
    exit 0
  fi
  generic="$APPS/ableton-live.desktop"
  if (( ${#exes[@]} == 1 )); then
    rm -f -- "$APPS"/ableton-live-*.desktop
    exe="${exes[0]}"
    name="$(basename "$exe")"; name="${name%.exe}"
    write_entry "$generic" "$name" "$LAUNCHER %f"
    ok "Entrée unique restaurée : $generic  →  « $name »"
  else
    rm -f -- "$generic"
    for exe in "${exes[@]}"; do
      name="$(basename "$exe")"; name="${name%.exe}"
      ed="$(edition_of "$name")"
      file="$APPS/ableton-live-$ed.desktop"
      wmclass="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
      write_entry "$file" "$name" "env ABLETON_LIVE_EXE=\"$exe\" $LAUNCHER %f" "StartupWMClass=$wmclass"
      ok "Entrée restaurée : « $name » → $file"
    done
  fi
  command -v update-desktop-database >/dev/null && update-desktop-database "$APPS" >/dev/null 2>&1
  ok "Prêt — vérifie dans le menu d'applications Omarchy."
}
main