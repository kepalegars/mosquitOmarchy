#!/usr/bin/env bash
# open-patched-folder.sh — Ouvre le dossier d'installation du dernier Ableton
# patché (celui où se trouve «Ableton Live 12 … .exe») dans l'explorateur de
# fichiers. Une seule édition → ouverture directe ; plusieurs → menu de choix.
#
# Sourçable : diversification via
#   . ./open-patched-folder.sh    puis    ableton_open_folder [--all]
# (utilisé par install-ableton.sh pour ouvrir le dossier en fin, sur une touche).
#
# Usage direct :
#   ./open-patched-folder.sh           # choisit/ouvre le dossier de l'exe
#   ./open-patched-folder.sh --all     # liste toutes les éditions au lieu d'ouvrir
#   ./open-patched-folder.sh -h        # aide
set -euo pipefail

G='\033[1;32m'; B='\033[1;34m'; Y='\033[1;33m'; R='\033[1;31m'; N='\033[0m'
msg(){ printf "${B}==>${N} %s\n" "$*"; }
ok(){ printf " ${G}✓${N} %s\n" "$*"; }
warn(){ printf " ${Y}!${N} %s\n" "$*"; }
err(){ printf " ${R}✗${N} %s\n" "$*" >&2; }
hr(){ printf '%.0s─' {1..60}; echo; }

# ───────────────────────── Fonction appelable (sourçable ET directe) ─────────────────────────
# Ouverture du dossier du dernier Ableton patché dans l'explorateur.
# ableton_open_folder [--all]   (--all : liste les éditions sans ouvrir)
ableton_open_folder(){
  local list_only=0
  [[ "${1:-}" == "--all" || "${1:-}" == "-l" ]] && list_only=1

  # Détection des éditions (uniquement les vrais exes, pas les résidus "…_updated").
  local prefix root exes editions folder target i n
  prefix="${ABLETON_PREFIX:-$HOME/.wine-ableton}"
  root="$prefix/drive_c/ProgramData/Ableton"
  mapfile -d '' exes < <(find "$root" -maxdepth 4 -type f -iname 'Ableton Live 12*.exe' \
    -not -path '*_updated*' -print0 2>/dev/null || true)
  mapfile -t editions < <(printf '%s\000' "${exes[@]}" | xargs -0 -r -I{} sh -c \
    'printf "%s %s\n" "$(stat -c %Y "{}")" "{}"' | sort -n | cut -d' ' -f2-)

  hr
  if (( ${#editions[@]} == 0 )); then
    warn "Aucun exe Ableton Live 12 trouvé dans $root"
  elif (( list_only )); then
    msg "Éditions Ableton détectées :"
    i=1
    for exe in "${editions[@]}"; do
      printf '  %d) %s\n' "$i" "$(sed -E 's#.*/ProgramData/Ableton/##' <<<"$exe")"
      i=$((i+1))
    done
  else
    if (( ${#editions[@]} == 1 )); then
      target="${editions[0]}"
    else
      i=1
      n=
      msg "${#editions[@]} éditions détectées."
      for exe in "${editions[@]}"; do
        printf '  %d) %s\n' "$i" "$(sed -E 's#.*/ProgramData/Ableton/##' <<<"$exe")"
        i=$((i+1))
      done
      echo
      read -rp "  Laquelle ouvrir ? [1-${#editions[@]}] : " n
      [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#editions[@]} )) || { err "Choix invalide."; exit 1; }
      target="${editions[$((n-1))]}"
    fi
    folder="$(dirname "$target")"
    msg "Ouverture du dossier : $folder"
    # Sur Hyprland/Wayland, xdg-open peut rester bloqué ou ne rien ouvrir.
    # Nautilus (handler par défaut vérifié) ouvre de façon fiable avec --new-window.
    local opener= xdg_ok=0
    command -v xdg-open >/dev/null 2>&1 && xdg_ok=1
    if command -v nautilus >/dev/null 2>&1; then
      opener="nautilus --new-window"
    elif [ "$xdg_ok" -eq 1 ]; then
      opener="xdg-open"
    fi
    if [ -z "$opener" ]; then
      ok "Aucun ouvreur de dossier (xdg-open absent) — dossier : $folder"
      return 0
    fi
    setsid nohup $opener -- "$folder" >/dev/null 2>&1 < /dev/null &
    disown 2>/dev/null || true
    ok "Explorateur lancé (détaché)."
  fi
  hr
}

# ───────────────────────── Mode direct uniquement ─────────────────────────
# (quand le script est exécuté lui-même, pas sourcé : install-ableton.sh appelle
#  ableton_open_folder directement, sans tout ce qui suit)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  # Gestion du terminal jetable (si lancé par double-clic)
  if [[ ! -t 0 ]] && [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] && command -v foot >/dev/null \
     && [[ "${ABLE_PATCH_HELD:-}" != 1 ]]; then
    export ABLE_PATCH_HELD=1
    exec foot --hold --title "ableton dossier" -- "$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")" "$@"
  fi

  HOLD_WINDOW=0
  if [[ "${ABLE_PATCH_HELD:-}" != 1 ]] && [[ -t 0 ]]; then
    _pp="${PPID:-}"
    _pp_comm="$(cat "/proc/$_pp/comm" 2>/dev/null || true)"
    _pp_cmd="$(tr '\0' ' ' < "/proc/$_pp/cmdline" 2>/dev/null || true)"
    case "$_pp_comm" in
      foot|footclient|kitty|alacritty|ghostty|kgx|xfce4-terminal|gnome-terminal|konsole|xterm|urxvt|wezterm)
        case "$_pp_cmd" in
          *"$(basename "${BASH_SOURCE[0]}")"*) HOLD_WINDOW=1 ;;
        esac ;;
    esac
  fi

  hold_window_at_exit(){
    [ "$HOLD_WINDOW" -eq 1 ] || return 0
    [ -t 0 ] || return 0
    printf '\n  %bTerminé — appuie sur une touche pour fermer cette fenêtre.%b ' "$Y" "$N"
    read -r -s -n1 2>/dev/null || true
    printf '\r\033[K\n'
  }
  trap 'hold_window_at_exit' EXIT

  case "${1:-}" in
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    --all|-l|-*) ;;
  esac

  ableton_open_folder "${1:-}"
  exit 0
fi