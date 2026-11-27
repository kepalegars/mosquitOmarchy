#!/usr/bin/env bash
# uninstall-witchwand.sh — Désinstalle l'application R2R (TEAM R2R) installée
# dans le wine d'Ableton par « Patching System WINSTALLER.exe » / « R2R System ».
#
# L'app vit dans  <prefix>/drive_c/Program Files*/TEAM R2R/  avec son outil de
# désinstallation unins000.exe qui possède des manifestes *.klg. Après son
# exécution on expurge les restes (dossier si vide, .klg, registres/apps wine)
# pour laisser le prefix propre.
#
# Usage :
#   ./uninstall-witchwand.sh              # désinstalle l'app R2R via unins000
#   ./uninstall-witchwand.sh --purge      # supprime aussi les restes après unins
#   ./uninstall-witchwand.sh -y           # passe unins000 en silencieux
#   ./uninstall-witchwand.sh --no-run     # montre le chemin sans lancer
#   ./uninstall-witchwand.sh -h           # aide
set -euo pipefail

G='\033[1;32m'; B='\033[1;34m'; Y='\033[1;33m'; R='\033[1;31m'; N='\033[0m'
msg(){ printf "${B}==>${N} %s\n" "$*"; }
ok(){ printf " ${G}✓${N} %s\n" "$*"; }
warn(){ printf " ${Y}!${N} %s\n" "$*"; }
err(){ printf " ${R}✗${N} %s\n" "$*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ───────────────────────── Arguments ─────────────────────────
PURGE=0
NO_RUN=0
SILENT=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --purge)    PURGE=1 ;;
    --no-run)   NO_RUN=1 ;;
    -y|--silent) SILENT=1 ;;
    -h|--help)  sed -n '2,20p' "$0"; exit 0 ;;
    *) err "Option inconnue : $1 (voir -h)"; exit 1 ;;
  esac
  shift
done

# ───────────────────────── Environnement Ableton-Wine ─────────────────────────
ABLETON_PREFIX="${ABLETON_PREFIX:-$HOME/.wine-ableton}"
WINE_BIN="$(ls -1 "$HOME/.local/opt"/wine-*/bin/wine 2>/dev/null | head -1 || true)"
[ -n "$WINE_BIN" ] || WINE_BIN="$HOME/.local/opt/wine-d2d1-nspa-11.13/bin/wine"
WINEPREFIX="$ABLETON_PREFIX"

[ -x "$WINE_BIN" ] || { err "wine d'Ableton introuvable ($WINE_BIN)."; exit 1; }
[ -d "$ABLETON_PREFIX" ] || { err "Prefix Ableton introuvable : $ABLETON_PREFIX"; exit 1; }

# ───────────────────────── Localiser l'app R2R ─────────────────────────
# Répertoires d'installation possibles de l'app R2R.
R2R_DIR=""
for d in \
  "$ABLETON_PREFIX/drive_c/Program Files/TEAM R2R" \
  "$ABLETON_PREFIX/drive_c/Program Files (x86)/TEAM R2R"; do
  [[ -d "$d" ]] && { R2R_DIR="$d"; break; }
done

R2R_ROOT="$(dirname "$R2R_DIR" 2>/dev/null)"
UNINS=""
[[ -n "$R2R_DIR" ]] && UNINS="$R2R_DIR/R2R System/unins000.exe"
PREFIX_R2R="/mnt/data/programdata/r2rsys"   # chemin wine sympa (affichage seulement)

# ── Affichage de ce qui va être touché ──
msg "Désinstallation de l'app R2R (TEAM R2R) du prefix Ableton"
msg "  Prefix : $ABLETON_PREFIX"
if [[ -z "$R2R_DIR" || ! -f "$UNINS" ]]; then
  warn "Dossier d'installation R2R introuvable (ou unins000.exe absent)."
  if [[ -n "$R2R_DIR" ]]; then
    warn "  Trouvé : $R2R_DIR"
    warn "  unins000.exe : $UNINS"
  fi
  warn "Rien à désinstaller via unins — rien à faire au niveau registre."
  if (( PURGE )) && [[ -n "$R2R_DIR" ]]; then
    msg "Purge des restes éventuels :"
    rm -rf "$R2R_DIR"
    ok "Supprimé : $R2R_DIR"
    # En pure hygiène, retire le dossier parent s'il est devenu vide.
    rmdir "$R2R_ROOT" 2>/dev/null || true
  fi
  exit 0
fi

[ "$NO_RUN" -eq 1 ] && { ok "Fluage — chemin unins : $UNINS"; exit 0; }

# ── Exécuter unins000.exe (- /SILENT pour ne pas demander) ──
msg "Lancement du désinstalleur : $UNINS"
if ! pgrep -f "wineserver" >/dev/null 2>&1; then
  WINEPREFIX="$WINEPREFIX" "$WINE_BIN" wineboot -u >/dev/null 2>&1 || true
fi

set +e
# /SP- supprime la question "voulez-vous continuer"
if (( SILENT )); then
  WINEPREFIX="$WINEPREFIX" "$WINE_BIN" "$UNINS" /SP- /SILENT /NORESTART
else
  WINEPREFIX="$WINEPREFIX" "$WINE_BIN" "$UNINS" /SP-
fi
rc=$?
set -e
printf '\r\033[K'
if [ "$rc" -eq 0 ]; then
  ok "Désinstalleur terminé normalement (rc=0)."
else
  warn "Le désinstalleur s'est terminé avec le code $rc."
  if [[ "$rc" == 2* ]]; then
    warn "Code 2xx : l'utilisateur a annulé ou une app tournait encore."
  fi
fi

# ── Nettoyage des restes (unins000 est auto-supprimé, purge des résidus) ──
msg "Vérification des restes :"
for f in "$R2R_DIR"/*.klg "$R2R_DIR"/r2rew.klg; do
  [[ -e "$f" ]] || continue
  rm -f "$f" && ok "Supprimé : $f"
done

if [[ -d "$R2R_DIR" ]] && [[ -z "$(ls -A "$R2R_DIR" 2>/dev/null)" ]]; then
  rmdir "$R2R_DIR"
  ok "Dossier devenu vide supprimé : $R2R_DIR"
fi

if (( PURGE )); then
  warn "Purge forcée (--purge) : supprime le dossier R2R restant."
  rm -rf "$R2R_DIR"
  rmdir "$R2R_ROOT" 2>/dev/null || true
else
  echo
  if [[ -d "$R2R_DIR" ]]; then
    msg "Le dossier $R2R_DIR contient encore :"
    ls -la "$R2R_DIR"
    warn "Relance ce script avec --purge pour le retirer complètement."
  else
    ok "App R2R entièrement désinstallée — prefix propre."
  fi
fi

exit 0