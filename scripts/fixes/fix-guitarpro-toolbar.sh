#!/usr/bin/env bash
# fix-guitarpro-toolbar.sh — Fix Guitar Pro 8 toolbar/UI glyph issues
# Applies ableton-linux style font fixes to the Guitar Pro Wine prefix.
# Run anytime, idempotent. Does NOT touch the installer script.

set -euo pipefail

PFX="$HOME/.wine-guitarpro8"
WINEROOT=""

# Find the wine binary (prefer ableton-linux runtime, fallback to system)
for w in "$HOME/.local/opt/wine-d2d1-nspa-11.13/bin/wine" \
         "$HOME/.local/opt/wine-d2d1-nspa-"*/bin/wine \
         "/usr/bin/wine"; do
  [[ -x $w ]] && { WINEROOT="${w%/bin/wine}"; break; }
done

G='\033[1;32m'; B='\033[1;34m'; Y='\033[1;33m'; R='\033[1;31m'; N='\033[0m'
msg(){ printf "${B}==>${N} %s\n" "$*"; }
ok(){ printf " ${G}✓${N} %s\n" "$*"; }
warn(){ printf " ${Y}!${N} %s\n" "$*"; }
err(){ printf " ${R}✗${N} %s\n" "$*" >&2; }

[[ -d "$PFX/drive_c" ]] || { err "Prefix not found: $PFX"; exit 1; }
[[ -n "$WINEROOT" ]] || { err "No wine binary found"; exit 1; }

msg "Fixing Guitar Pro toolbar/UI glyphs in $PFX"
msg "Using wine: $WINEROOT/bin/wine"

# Kill any existing wine processes for this prefix
pkill -f "WINEPREFIX=$PFX" 2>/dev/null || true
"$WINEROOT/bin/wineserver" -k 2>/dev/null || true
sleep 1

# 1) Bitstream Vera fonts (fallback chain for UI glyphs — same as ableton-linux)
msg "Installing Bitstream Vera fonts (fallback chain)"
WINFONTS="$PFX/drive_c/windows/Fonts"
SRC=""
for d in \
  /usr/share/fonts/truetype/ttf-bitstream-vera \
  /usr/share/fonts/bitstream-vera \
  /usr/share/fonts/TTF; do
  [[ -f "$d/Vera.ttf" ]] && { SRC="$d"; break; }
done

if [[ -n $SRC ]]; then
    mkdir -p "$WINFONTS"
    cp -u "$SRC"/Vera*.ttf "$WINFONTS/" 2>/dev/null || true
    # Use reg add (more reliable than reg import) for each font entry
    local wine_bin="$WINEROOT/bin/wine"
    local entries=(
      "Bitstream Vera Sans (TrueType)|C:\\windows\\Fonts\\Vera.ttf"
      "Bitstream Vera Sans Bold (TrueType)|C:\\windows\\Fonts\\VeraBd.ttf"
      "Bitstream Vera Sans Oblique (TrueType)|C:\\windows\\Fonts\\VeraIt.ttf"
      "Bitstream Vera Sans Bold Oblique (TrueType)|C:\\windows\\Fonts\\VeraBI.ttf"
      "Bitstream Vera Sans Mono (TrueType)|C:\\windows\\Fonts\\VeraMono.ttf"
      "Bitstream Vera Sans Mono Bold (TrueType)|C:\\windows\\Fonts\\VeraMoBd.ttf"
      "Bitstream Vera Sans Mono Oblique (TrueType)|C:\\windows\\Fonts\\VeraMoIt.ttf"
      "Bitstream Vera Sans Mono Bold Oblique (TrueType)|C:\\windows\\Fonts\\VeraMoBI.ttf"
      "Bitstream Vera Serif (TrueType)|C:\\windows\\Fonts\\VeraSe.ttf"
      "Bitstream Vera Serif Bold (TrueType)|C:\\windows\\Fonts\\VeraSeBd.ttf"
    )
    for entry in "${entries[@]}"; do
      IFS='|' read -r name path <<< "$entry"
      timeout 10 WINEPREFIX="$PFX" "$wine_bin" reg add "HKLM\\Software\\Microsoft\\Windows NT\\CurrentVersion\\Fonts" /v "$name" /t REG_SZ /d "$path" /f >/dev/null 2>&1 || true
    done
    ok "Bitstream Vera installed + registered (10 fonts)"
else
  warn "ttf-bitstream-vera not on system — install it first:"
  warn "  sudo pacman -S ttf-bitstream-vera"
  warn "Then re-run this script."
  exit 1
fi

# 2) DPI / Font smoothing (detect Hyprland scale)
msg "Applying DPI & font smoothing"
SCALE=$(hyprctl monitors -j 2>/dev/null | python3 -c '
import json,sys
try: print(json.load(sys.stdin)[0].get("scale",1))
except: print(1)
' 2>/dev/null || echo 1)
DPI=$(awk -v s="$SCALE" 'BEGIN{d=int(96*s+0.5); print (d<96?96:(d>192?192:d))}')
msg "Detected scale=$SCALE → LogPixels=$DPI"

timeout 30 WINEPREFIX="$PFX" "$WINEROOT/bin/wine" reg add 'HKCU\Control Panel\Desktop' /v LogPixels /t REG_DWORD /d "$DPI" /f >/dev/null 2>&1
timeout 30 WINEPREFIX="$PFX" "$WINEROOT/bin/wine" reg add 'HKCU\Control Panel\Desktop' /v FontSmoothing /t REG_SZ /d 2 /f >/dev/null 2>&1
timeout 30 WINEPREFIX="$PFX" "$WINEROOT/bin/wine" reg add 'HKCU\Control Panel\Desktop' /v FontSmoothingType /t REG_DWORD /d 2 /f >/dev/null 2>&1
timeout 30 WINEPREFIX="$PFX" "$WINEROOT/bin/wine" reg add 'HKCU\Control Panel\Desktop' /v FontSmoothingGamma /t REG_DWORD /d 1000 /f >/dev/null 2>&1
ok "DPI=$DPI + font smoothing written"

# 3) Disable winemenubuilder in this prefix (stops Wine republishing shortcuts)
msg "Disabling winemenubuilder (prevents Wine menu duplicates)"
timeout 30 WINEPREFIX="$PFX" "$WINEROOT/bin/wine" reg add 'HKCU\Software\Wine\DllOverrides' /v winemenubuilder.exe /t REG_SZ /d '' /f >/dev/null 2>&1
ok "winemenubuilder disabled"

# 4) Clean Wine menu duplicates (Arobas Music tree)
msg "Cleaning Wine menu duplicates"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/wine-menu.bash" 2>/dev/null || true
if declare -F mosquitomarchy_wine_menu_remove >/dev/null 2>&1; then
  mosquitomarchy_wine_menu_remove 'guitar|arobas'
  mosquitomarchy_wine_menu_sweep
  ok "Wine menu cleaned"
else
  warn "wine-menu.bash not available — skipping menu cleanup"
fi

# 5) Restart wineserver to pick up changes
msg "Restarting wineserver"
"$WINEROOT/bin/wineserver" -k 2>/dev/null || true
sleep 1
ok "Done"

hr(){ printf '%.0s─' {1..60}; echo; }
hr
ok "Guitar Pro toolbar fix applied."
echo " • Launch Guitar Pro — toolbar should render correctly now"
echo " • If still broken: sudo pacman -S ttf-bitstream-vera then re-run"
hr
ok "Guitar Pro toolbar fix applied."
echo " • Launch Guitar Pro — toolbar should render correctly now"
echo " • If still broken: sudo pacman -S ttf-bitstream-vera then re-run"
hr