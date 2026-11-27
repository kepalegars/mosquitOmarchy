#!/usr/bin/env bash
# patch-ableton.sh — Patch Ableton : installe l'app « R2R System v1.5.2.exe »
# (installateur Windows présent dans PATCH/tools/) dans LE WINE D'ABLETON
# (le runtime patché ~/.local/opt/wine-d2d1-nspa-11.13), puis ouvre un fichier
# (à configurer ci-dessous, présent dans PATCH/tools/) avec l'application
# ainsi installée. À la façon du patch 2 (glisser-déposer) :
#
#     wine "R2R System v1.5.2.exe" "C:\...\Ableton Live 12 Suite.exe"
#     wine "<app installée>" "Z:\...\fichier.r2rwm"
#
# Déroulement, dans l'ordre :
#   1) Détecte les éditions Ableton installées dans le prefix (menu si plusieurs,
#      sinon l'unique ; avec -y la plus récente) — c'est l'Ableton ciblé,
#   2) copie vcruntime140_1.dll (depuis PATCH/tools/) à côté de Ableton.exe
#      de l'édition choisie (le dossier d'install où le reste du script agit),
#   3) si l'app installée est déjà présente dans le prefix (auto-détection
#      WitchWand.exe sous TEAM R2R/R2R System) → on SAUTE l'installation ; sinon
#      on lance « R2R System v1.5.2.exe » (présent dans tools/) avec
#      le chemin Windows de l'exe Ableton ciblé, dans l'environnement Ableton,
#   4) ouvre AVEC l'app installée le fichier $TARGET_FILE (configuré ci-dessous).
#
# Usage :
#   ./patch-ableton.sh                         # sélection édition → install + ouverture
#   ./patch-ableton.sh -y                      # non interactif (édition la plus récente)
#   ./patch-ableton.sh --list                  # détecte (éditions + app) sans rien lancer
#   ./patch-ableton.sh --target DIR            # fore le dossier d'install de l'exe Ableton
#   ./patch-ableton.sh --app EXE               # fore le chemin de l'app installée
#   ./patch-ableton.sh --file CHEMIN           # fichier à ouvrir (sinon celui configuré)
#   ./patch-ableton.sh --no-run                # prépare (copie vcruntime) sans lancer
#   ./patch-ableton.sh -h                      # aide
set -euo pipefail

G='\033[1;32m'; B='\033[1;34m'; Y='\033[1;33m'; R='\033[1;31m'; N='\033[0m'
msg(){ printf "${B}==>${N} %s\n" "$*"; }
ok(){ printf " ${G}✓${N} %s\n" "$*"; }
warn(){ printf " ${Y}!${N} %s\n" "$*"; }
err(){ printf " ${R}✗${N} %s\n" "$*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$SCRIPT_DIR/tools"

# ── Gestion du terminal jetable (si ce script est lancé par double-clic) ──────
if [[ ! -t 0 ]] && [[ -z "${MOSQUITOMARCHY_TUI:-}${MOSQUITOMARCHY_NO_GUI:-}" ]] \
   && [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] && command -v foot >/dev/null \
   && [[ "${ABLE_PATCH_HELD:-}" != 1 ]]; then
  export ABLE_PATCH_HELD=1
  exec foot --hold --title "ableton patch-ableton" -- "$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")" "$@"
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

# ═════════════════════════════════════════════════════════════════════════════
#  À CONFIGURER : fichier à ouvrir avec l'application installée.
#  Présent dans PATCH/tools/ — mets ici le chemin exact (sinon --file).
# ═════════════════════════════════════════════════════════════════════════════
TARGET_FILE="${TARGET_FILE:-$TOOLS_DIR/WM_Ableton.r2rwm}"
# Application installée par WINSTALLER — laissé vide = auto-détection (ou --app).
R2R_APP="${R2R_APP:-}"

# ───────────────────────── Arguments ─────────────────────────
NO_RUN=0
LIST_ONLY=0
YES=0
MODE="patch"
TARGET_DIR="${TARGET_DIR:-}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-run)   NO_RUN=1 ;;
    --list)     LIST_ONLY=1 ;;
    --patch)    MODE="patch" ;;           # action par défaut (compat install-ableton.sh)
    --check)    MODE="check" ;;           # état du patch (read-only)
    --revert)   MODE="revert" ;;          # désinstalle le patch (restaure l'état)
    --target)   shift; TARGET_DIR="$1" ;;
    --app)      shift; R2R_APP="$1" ;;
    --file)     shift; TARGET_FILE="$1" ;;
    -y|--yes)   YES=1 ;;
    -h|--help)  sed -n '2,32p' "$0"; exit 0 ;;
    *) err "Option inconnue : $1 (voir -h)"; exit 1 ;;
  esac
  shift
done

ASK(){
  # pose une question ; avec -y on répond toujours oui
  if (( YES )); then ok "(auto) $* -> oui"; return 0; fi
  local r
  read -rp "$* [O/n] " r
  [[ "${r:-o}" =~ ^[oOyY] ]]
}

# ───────────────────────── Environnement Ableton-Wine ─────────────────────────
ABLETON_PREFIX="${ABLETON_PREFIX:-$HOME/.wine-ableton}"
WINE_BIN="$(ls -1 "$HOME/.local/opt"/wine-*/bin/wine 2>/dev/null | head -1 || true)"
[ -n "$WINE_BIN" ] || WINE_BIN="$HOME/.local/opt/wine-d2d1-nspa-11.13/bin/wine"
WINEPREFIX="$ABLETON_PREFIX"

[ -x "$WINE_BIN" ] || { err "wine d'Ableton introuvable ($WINE_BIN) — le runtime est-il installé ?"; exit 1; }
[ -d "$ABLETON_PREFIX" ] || { err "Prefix Ableton introuvable : $ABLETON_PREFIX"; exit 1; }

WINSTALLER="$TOOLS_DIR/R2R System v1.5.2.exe"
VCRUNTIME_SRC="$TOOLS_DIR/vcruntime140_1.dll"

# ───────────────────────── HWID → presse-papiers (au lancement) ─────────────────────────
# Dès l'ouverture du patch, on lit le challenge_code (HWID) stocké par Live dans
# Unlock.json et on le copie dans le presse-papiers, pour le coller directement
# quand le patcher/installateur le demande. (même logique que patch-3-auto.sh)
# --check/--revert are status/removal operations: do not touch the clipboard
# or announce a HWID there.
if [[ "$MODE" == patch ]]; then
PY_FOR_JSON=""
for _c in python3 python; do command -v "$_c" >/dev/null 2>&1 && { PY_FOR_JSON="$_c"; break; }; done
read_hwid(){
  local f="$1"
  "$PY_FOR_JSON" - "$f" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as fh:
    d = json.load(fh)
prods = d.get('products') or []
code = prods[0].get('challenge_code', '') if prods else ''
sys.stdout.write(code)
PY
}
find_latest_unlock(){
  find "$WINEPREFIX/drive_c/users" -path '*/AppData/Roaming/Ableton/Live 12*/Unlock/Unlock.json' \
       -type f -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -1 | cut -d' ' -f2-
}
HWID=""
if command -v "$PY_FOR_JSON" >/dev/null 2>&1; then
  UNLOCK_FILE="$(find_latest_unlock)"
  if [[ -n "$UNLOCK_FILE" && -f "$UNLOCK_FILE" ]]; then
    HWID="$(read_hwid "$UNLOCK_FILE")"
  fi
fi
if [[ "$HWID" =~ ^([0-9A-Fa-f]{4}-){5}[0-9A-Fa-f]{4}$ ]]; then
  HWID="$(printf '%s' "$HWID" | tr 'a-f' 'A-F')"
  CLIP_TOOL=""
  for c in wl-copy xclip xsel; do command -v "$c" >/dev/null 2>&1 && { CLIP_TOOL="$c"; break; }; done
  if [[ -n "$CLIP_TOOL" ]]; then
    # Détaché (setsid + &) : wl-copy/xclip gardent la propriété du presse-papiers
    # en arrière-plan sans bloquer le script dans un contexte non-interactif.
    case "$CLIP_TOOL" in
      wl-copy) setsid sh -c 'printf "%s" "$1" | wl-copy' _ "$HWID" >/dev/null 2>&1 < /dev/null & ;;
      xclip)   setsid sh -c 'printf "%s" "$1" | xclip -selection clipboard' _ "$HWID" >/dev/null 2>&1 < /dev/null & ;;
      xsel)    setsid sh -c 'printf "%s" "$1" | xsel --clipboard --input' _ "$HWID" >/dev/null 2>&1 < /dev/null & ;;
    esac
    disown 2>/dev/null || true
    ok "HWID copié dans le presse-papiers : $HWID"
  else
    warn "HWID : $HWID (aucun wl-copy/xclip/xsel pour la copie auto)."
  fi
else
  warn "HWID introuvable dans Unlock.json — copie auto non faite."
fi
fi

# ───────────────────────── Détection des éditions Ableton ─────────────────────────
# Liste tous les exes « Ableton Live 12 ….exe » (pas les résidus *_updated), les
# plus récemment modifiés en premier. Chaque entrée = le PROGRAM (Ableton.exe).
list_editions(){
  local root exes
  root="$ABLETON_PREFIX/drive_c/ProgramData/Ableton"
  mapfile -d '' exes < <(find "$root" -maxdepth 4 -type f -iname 'Ableton Live 12*.exe' \
    -not -path '*_updated*' -print0 2>/dev/null || true)
  [[ -z "${exes-}" ]] && return 0
  printf '%s\000' "${exes[@]}" | xargs -0 -r -I{} sh -c \
    'printf "%s %s\n" "$(stat -c %Y "{}" 2>/dev/null || echo 0)" "{}"' | sort -rn | cut -d' ' -f2-
}

# Choix interactif : une seule édition → la sienne ; plusieurs → menu ; -y → la 1re.
pick_ableton(){
  local i n exe line
  local -a list=()
  while IFS= read -r line; do [[ -n "$line" ]] && list+=("$line"); done < <(list_editions)

  if [[ -n "$TARGET_DIR" ]]; then
    # --target : on vérifie simplement qu'un Ableton.exe est là
    [[ -f "$TARGET_DIR/Ableton Live"*.exe ]] || { err "Aucun 'Ableton Live*.exe' dans : $TARGET_DIR"; exit 1; }
    printf '%s\n' "$TARGET_DIR"; return 0
  fi
  if (( ${#list[@]} == 0 )); then
    err "Aucun exe 'Ableton Live 12' trouvé dans $ABLETON_PREFIX/drive_c/ProgramData/Ableton."
    exit 1
  fi
  if (( ${#list[@]} == 1 )); then
    printf '%s\n' "${list[0]}"; return 0
  fi
  if (( YES )); then
    printf '%s\n' "${list[0]}"; return 0
  fi
  msg "${#list[@]} éditions Ableton détectées :"
  i=1
  for exe in "${list[@]}"; do
    printf '  %d) %s\n' "$i" "$(sed -E 's#.*/ProgramData/Ableton/##' <<<"$exe")"
    i=$((i+1))
  done
  read -rp "   Quelle édition utiliser ? [1-${#list[@]}] : " n
  [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#list[@]} )) || { err "Choix invalide."; exit 1; }
  printf '%s\n' "${list[$((n-1))]}"
}

# ───────────────────────── Application installée (ouverture du fichier) ─────────────────────────
# Auto-détection : l'app installée par WINSTALLER vit dans
#   <prefix>/drive_c/Program Files*/TEAM R2R/R2R System/  (exe « Witch*.exe »,
#   préférence WitchWand.exe, qui ouvre le fichier .r2rwm). On exclut les faux
#   positifs (*WINSTALLER*, wmplayer / Windows Media Player).
find_app(){
  [[ -n "${R2R_APP:-}" ]] && [[ -f "$R2R_APP" ]] && { printf '%s\n' "$R2R_APP"; return 0; }
  local d exe
  local -a dirs=(
    "$ABLETON_PREFIX/drive_c/Program Files/TEAM R2R/R2R System"
    "$ABLETON_PREFIX/drive_c/Program Files (x86)/TEAM R2R/R2R System"
  )
  # Exe tout en haut de la priorité : WitchWand.exe (l'ouvreur principal).
  for d in "${dirs[@]}"; do
    [[ -f "$d/WitchWand.exe" ]] && { printf '%s\n' "$d/WitchWand.exe"; return 0; }
  done
  local best="" best_m=-1 m
  for d in "${dirs[@]}"; do
    [[ -d "$d" ]] || continue
    while IFS= read -r -d '' exe; do
      case "$exe" in *WINSTALLER*) continue ;; esac
      m="$(stat -c %Y "$exe" 2>/dev/null || echo 0)"
      if (( m > best_m )); then best="$exe"; best_m="$m"; fi
    done < <(find "$d" -maxdepth 2 -type f -iname '*.exe' -print0 2>/dev/null || true)
  done
  [[ -n "$best" ]] && printf '%s\n' "$best"
}

# ───────────── --check / --revert : état et DÉSINSTALLATION du patch ─────────────
if [[ "$MODE" == check ]]; then
  _app="$(find_app || true)"
  if [[ -n "$_app" && -f "$_app" ]]; then
    ok "binary patched — revert possible via --revert ($_app)"
  else
    echo "not applied"
  fi
  exit 0
fi
if [[ "$MODE" == revert ]]; then
  msg "Suppression du patch Ableton (R2R System + vcruntime copiés)"
  _r=0
  for d in "$ABLETON_PREFIX/drive_c/Program Files/TEAM R2R" \
           "$ABLETON_PREFIX/drive_c/Program Files (x86)/TEAM R2R"; do
    if [[ -d "$d" ]]; then rm -rf "$d" && ok "supprimé : $d" || _r=1; fi
  done
  while IFS= read -r -d '' _f; do
    rm -f "$_f" && ok "supprimé : $_f"
  done < <(find "$ABLETON_PREFIX/drive_c/ProgramData/Ableton" -maxdepth 5 \
             -name vcruntime140_1.dll -print0 2>/dev/null || true)
  if ((_r)); then err "Certains éléments n'ont pas pu être supprimés."; exit 1; fi
  ok "Patch Ableton retiré."
  exit 0
fi

# ───────────────────────── Exécution ─────────────────────────
msg "Patch Ableton — installateur R2R lancé dans le wine d'Ableton"
msg "  Prefix  : $ABLETON_PREFIX"
msg "  Wine    : $WINE_BIN"

DEST_DIR="$(dirname "$(pick_ableton)")"
ABLETON_EXE="$(find "$DEST_DIR" -maxdepth 1 -iname 'Ableton Live 12*.exe' -not -name '*_updated*' | head -1)"

# ── 1) copie vcruntime140_1.dll à côté de Ableton.exe (édition choisie) ──
if [[ -f "$VCRUNTIME_SRC" ]]; then
  if [[ ! -f "$DEST_DIR/vcruntime140_1.dll" ]] \
     || ! cmp -s "$VCRUNTIME_SRC" "$DEST_DIR/vcruntime140_1.dll"; then
    cp -f "$VCRUNTIME_SRC" "$DEST_DIR/vcruntime140_1.dll"
    ok "vcruntime140_1.dll copié vers : $(basename "$DEST_DIR")"
  else
    ok "vcruntime140_1.dll déjà présent : $(basename "$DEST_DIR")"
  fi
else
  warn "vcruntime140_1.dll absent de $TOOLS_DIR/ — étape ignorée."
fi

[ "$NO_RUN" -eq 1 ] && { ok "Préparation terminée (--no-run) — pas de lancement."; exit 0; }

# ── 2) conversion des chemins, puis résumé ──
ableton_win="${ABLETON_EXE#*drive_c}"
ableton_win="C:${ableton_win//\//\\}"
if [[ "$TARGET_FILE" == /* ]]; then
  file_win="Z:${TARGET_FILE//\//\\}"
else
  warn "TARGET_FILE n'est pas un chemin absolu — tenté tel quel : $TARGET_FILE"
  file_win="$TARGET_FILE"
fi

if (( LIST_ONLY )); then
  msg "Édition choisie : $ABLETON_EXE"
  msg "  → Windows   : $ableton_win"
  msg "Dossier extrait : $(basename "$DEST_DIR")"
  msg "Installateur : $WINSTALLER"
  msg "Fichier à ouvrir : $TARGET_FILE"
  local_app="$(find_app || true)"
  msg "App installée (auto-dét.) : ${local_app:-introuvable}"
  exit 0
fi

# ── 3) installer l'app si elle n'est pas déjà installée (manière patch-2) ──
msg "Édition ciblée : $ABLETON_EXE"

# L'app est-elle déjà présente dans le prefix ? (WitchWand.exe sous TEAM R2R…)
R2R_APP="$(find_app || true)"
if [[ -n "$R2R_APP" && -f "$R2R_APP" ]]; then
  ok "App déjà installée : $R2R_APP"
else
  if [[ ! -f "$WINSTALLER" ]]; then
    err "Installateur absent : $WINSTALLER"
    exit 1
  fi
  msg "Lancement de « $(basename "$WINSTALLER") » avec la cible : $ableton_win"
  if ((YES)) || ASK "Lancer l'installateur maintenant ?" y; then
    if ! pgrep -f "wineserver" >/dev/null 2>&1; then
      WINEPREFIX="$WINEPREFIX" "$WINE_BIN" wineboot -u >/dev/null 2>&1 || true
    fi
    set +e
    WINEPREFIX="$WINEPREFIX" "$WINE_BIN" "$WINSTALLER" "$ableton_win"
    rc=$?
    set -e
    printf '\r\033[K'
    if [ "$rc" -eq 0 ]; then
      ok "L'installateur s'est terminé normalement (rc=0)."
    else
      warn "L'installateur s'est terminé avec le code $rc."
    fi
  else
    warn "Installateur non lancé."
  fi
  # Après installation (ou refus), on re-détecte l'app installée.
  R2R_APP="$(find_app || true)"
fi

# ── 4) ouvrir le fichier avec l'application installée ──
if [[ -z "$R2R_APP" || ! -f "$R2R_APP" ]]; then
  warn "Application installée introuvable — lance le fichier manuellement :"
  warn "  $WINE_BIN \"$file_win\""
  warn "(auto-détection : Witch*.exe sous TEAM R2R/R2R System ; force avec --app)"
else
  msg "Ouverture du fichier avec l'app installée :"
  msg "  App    : $R2R_APP"
  msg "  Fichier: $file_win"
  if ((YES)) || ASK "Ouvrir le fichier maintenant ?" y; then
    set +e
    WINEPREFIX="$WINEPREFIX" "$WINE_BIN" "$R2R_APP" "$file_win"
    rc=$?
    set -e
    printf '\r\033[K'
    if [ "$rc" -eq 0 ]; then
      ok "Fichier ouvert avec l'app (rc=0)."
    else
      warn "L'app s'est terminée avec le code $rc."
    fi
  else
    warn "Ouverture du fichier sautée."
  fi
fi

exit 0