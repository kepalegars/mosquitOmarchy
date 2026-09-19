#!/usr/bin/env bash
# uninstall-guitarpro.sh — Removes Guitar Pro 8 and its wine prefix
#
# Runs the real Windows uninstaller (Inno Setup unins000.exe) FIRST for a
# clean app-level removal, then offers to delete the wine prefix and the
# launcher/menu entries.
#
# Usage :
#   ./uninstall-guitarpro.sh             # interactive
#   ./uninstall-guitarpro.sh -y          # remove everything without confirmation

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/gui-run.bash"  # gui-run: reopen in a terminal when launched from a file manager
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PFX="$HOME/.wine-guitarpro8"
LAUNCHER="$HOME/.local/bin/guitarpro"
DESKTOP="$HOME/.local/share/applications/guitarpro.desktop"

YES=0
while (( $# )); do a="$1"; case "$a" in
  -y|--yes) YES=1 ;;
  -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
  *) echo "Unknown option: $a" >&2; exit 1 ;;
esac; shift; done

G='\033[1;32m'; B='\033[1;34m'; Y='\033[1;33m'; R='\033[1;31m'; N='\033[0m'
msg(){ printf "${B}==>${N} %s\n" "$*"; }
ok(){ printf " ${G}✓${N} %s\n" "$*"; }
warn(){ printf " ${Y}!${N} %s\n" "$*"; }
hr(){ printf '%.0s─' {1..70}; echo; }

ask(){
  local q="$1" def="${2:-y}" r
  ((YES)) && { ok "(auto) $q -> yes"; return 0; }
  read -rp "$q [$([ $def = y ] && echo Y/n || echo y/N)] " r
  r="${r:-$def}"; [[ $r =~ ^[oOyY] ]]
}

hr
msg "Uninstalling Guitar Pro 8"

found=0
[[ -d "$PFX" ]] && found=1
[[ -x "$LAUNCHER" ]] && found=1
[[ -f "$DESKTOP" ]] && found=1

if (( ! found )); then
  warn "Nothing to remove — Guitar Pro 8 is not installed."
  hr; exit 0
fi

[[ -d "$PFX" ]] && warn "Wine prefix: $PFX"
[[ -x "$LAUNCHER" ]] && warn "Launcher: $LAUNCHER"
[[ -f "$DESKTOP" ]] && warn "Menu shortcut: $DESKTOP"
echo

# ── Clean Windows uninstall first (Inno Setup uninstaller of the app) ──
find_uninstaller(){
  # The real Inno Setup uninstaller next to the app (never wine's own
  # windows/system32/uninstaller.exe). The prefix must still exist.
  [[ -d "$PFX/drive_c" ]] || return 1
  local dir
  for dir in "$PFX/drive_c/Program Files" "$PFX/drive_c/Program Files (x86)"; do
    find "$dir/Arobas Music" -maxdepth 2 -iname 'unins000.exe' 2>/dev/null | head -1
  done
  return 0
}

run_uninstaller(){
  local un appdir
  un="$(find_uninstaller | head -1)"
  [[ -n $un && -f $un ]] || { ok "No Inno Setup uninstaller found in the prefix — the Windows-level uninstall will be skipped."; return 0; }
  appdir="$(dirname "$un")"
  warn "Windows Uninstall entry found (Inno Setup): ${un#$PFX/drive_c/}"
  if ask "Run the Windows uninstaller FIRST (clean uninstall of Guitar Pro)?" y; then
    msg "Running: WINEPREFIX=\"$PFX\" wine $(basename "$un")  /VERYSILENT /NORESTART /NOCANCEL"
    if ( cd "$appdir" && WINEPREFIX="$PFX" wine "$(basename "$un")" /VERYSILENT /NORESTART /NOCANCEL ); then
      ok "Windows uninstaller finished."
    else
      warn "The Windows uninstaller did not report success — continue with manual removal anyway."
    fi
  else
    ok "Windows uninstaller skipped (prefix will be removed as-is)."
  fi
}

if [[ -d "$PFX" ]]; then
  run_uninstaller
  echo
fi

if ask "Remove the wine prefix (all Guitar Pro data)?" n; then
  rm -rf "$PFX"
  ok "Prefix removed"
else
  ok "Prefix kept"
fi

if [[ -x "$LAUNCHER" ]] && ask "Remove the launcher (~/.local/bin/guitarpro)?" y; then
  rm -f "$LAUNCHER"
  ok "Launcher removed"
fi

if [[ -f "$DESKTOP" ]] && ask "Remove the menu shortcut?" y; then
  rm -f "$DESKTOP"
  ok "Shortcut removed"
  command -v update-desktop-database >/dev/null 2>&1 \
    && update-desktop-database "$(dirname "$DESKTOP")" 2>/dev/null || true
fi

# Wine start-menu leftovers (duplicates created by the Windows installer)
if ask "Remove the Wine start-menu leftovers (wine/Programs/…, duplicates)?" y; then
  apps="$HOME/.local/share/applications" dd="$HOME/.local/share/desktop-directories" removed=0
  while IFS= read -r -d '' f; do
    if rg -qi 'guitar|arobas' "$f" 2>/dev/null; then
      rm -f "$f" && { ok "Removed: ${f#$apps/}"; removed=1; }
    fi
  done < <(find "$apps/wine/Programs" -maxdepth 5 -type f -name '*.desktop' -print0 2>/dev/null)
  while IFS= read -r -d '' f; do
    if rg -qi 'guitar|arobas' "$f" 2>/dev/null; then rm -f "$f" && removed=1; fi
  done < <(find "$dd" -maxdepth 5 -type f -name '*.directory' -print0 2>/dev/null)
  find "$apps/wine/Programs" -type d -empty -delete 2>/dev/null || true
  if (( removed )); then
    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$apps" 2>/dev/null || true
    ok "Wine start-menu entries cleaned."
  else
    warn "Nothing to clean."
  fi
fi

echo
ok "Done."
hr
