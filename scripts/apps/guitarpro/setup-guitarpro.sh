#!/usr/bin/env bash
# setup-guitarpro.sh — Installs Guitar Pro 8 on Linux via Wine
#
# Put guitar-pro-8-setup.exe in this folder before launching.
# The script creates a dedicated wine prefix, installs corefonts, launches the installer,
# configures the PipeWire audio, and creates a menu shortcut.
#
# Usage :
#   ./setup-guitarpro.sh             # interactive
#   ./setup-guitarpro.sh -y          # non-interactive (default choices)
#   ./setup-guitarpro.sh --status    # shows the installation state
#   ./setup-guitarpro.sh --dpi 120   # force the Wine DPI (96..192), default:
#                                    #   auto (follows the Hyprland scale)

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/gui-run.bash"  # gui-run: reopen in a terminal when launched from a file manager
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PFX="$HOME/.wine-guitarpro8"
GP_EXE="$PFX/drive_c/Program Files/Arobas Music/Guitar Pro 8/GuitarPro.exe"
ICON="$SCRIPT_DIR/icon.png"
DESKTOP_DST="$HOME/.local/share/applications/guitarpro.desktop"
LAUNCHER="$HOME/.local/bin/guitarpro"
EXE_NAME="guitar-pro-8-setup.exe"

YES=0 STATUS=0 DPI=""
while (( $# )); do a="$1"; case "$a" in
  -y|--yes) YES=1 ;;
  --status) STATUS=1 ;;
  --dpi)
    shift; DPI="${1:-}"
    [[ "$DPI" =~ ^[0-9]+$ ]] && (( DPI >= 96 && DPI <= 192 )) || { echo "Invalid --dpi value: $DPI (96..192)" >&2; exit 1; }
    ;;
  -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
  *) echo "Unknown option: $a" >&2; exit 1 ;;
esac; shift; done

G='\033[1;32m'; B='\033[1;34m'; Y='\033[1;33m'; R='\033[1;31m'; N='\033[0m'
msg(){ printf "${B}==>${N} %s\n" "$*"; }
ok(){ printf " ${G}✓${N} %s\n" "$*"; }
warn(){ printf " ${Y}!${N} %s\n" "$*"; }
err(){ printf " ${R}✗${N} %s\n" "$*" >&2; }
hr(){ printf '%.0s─' {1..70}; echo; }

ask(){
  local q="$1" def="${2:-y}" r
  ((YES)) && { ok "(auto) $q -> yes"; return 0; }
  read -rp "$q [$([ $def = y ] && echo Y/n || echo y/N)] " r
  r="${r:-$def}"; [[ $r =~ ^[oOyY] ]]
}

pkg_has(){ pacman -Q "$1" &>/dev/null; }

# ───────────────────── Installer missing ? rescan / path / cancel ─────────────────────
# The installer (guitar-pro-8-setup.exe) must be in the script folder. If it is
# missing, we propose (interactive): rescan (you just copied it), type its full
# path elsewhere, or cancel. With -y, we stop cleanly.
INSTALLER_PATH=""
resolve_installer(){
  if [[ -f "$INSTALLER_PATH" ]]; then return 0; fi
  local choice manual=""
  ((YES)) && { err "File not found: $INSTALLER_PATH"; return 1; }
  while [[ ! -f "$INSTALLER_PATH" ]]; do
    hr; msg "No Guitar Pro installer in $SCRIPT_DIR/ ($EXE_NAME)"
    echo
    echo "   1) Rescan          (I just copied it into the folder)"
    echo "   2) Type a path     (installer elsewhere on the disk)"
    echo "   3) Cancel          (come back later)"
    echo
    if ! read -rp "  Choice [1-3] : " choice; then err "Input closed — installation cancelled."; return 1; fi
    case "$choice" in
      1) [[ -f "$SCRIPT_DIR/$EXE_NAME" ]] && { INSTALLER_PATH="$SCRIPT_DIR/$EXE_NAME"; ok "Installer found: $EXE_NAME"; }
         ;;
      2) read -rp "  Full installer path : " manual
         [[ -f "$manual" ]] && { INSTALLER_PATH="$manual"; ok "Installer retained: $manual"; }
         ;;
      3) err "Stopped — drop $EXE_NAME in $SCRIPT_DIR/ then relaunch."; return 1 ;;
      *) warn "Invalid choice ($choice)." ;;
    esac
  done
}

do_status(){
  hr; msg "Guitar Pro 8 state"
  if [[ -d "$PFX/drive_c" ]]; then ok "Wine prefix : $PFX"
  else warn "Wine prefix : missing"; fi
  if [[ -f "$GP_EXE" ]]; then ok "GuitarPro.exe : $GP_EXE"
  else warn "GuitarPro.exe : not found (installation not finished ?)"; fi
  if [[ -x "$LAUNCHER" ]]; then ok "Launcher : $LAUNCHER"
  else warn "Launcher : missing"; fi
  if [[ -f "$DESKTOP_DST" ]]; then ok "Menu shortcut : $DESKTOP_DST"
  else warn "Menu shortcut : missing"; fi
  if [[ -f "$SCRIPT_DIR/$EXE_NAME" ]]; then ok "Installer : present"
  else warn "Installer missing : put $EXE_NAME in $SCRIPT_DIR"; fi
  if [[ -d "$PATCH_DIR" ]] && [[ -n "$(find "$PATCH_DIR" -maxdepth 1 -type f ! -name '.*' 2>/dev/null | head -1)" ]]
  then ok "Patch : present (split files)"
  else warn "Patch : not provided (skip)"; fi
  hr
}

# ───────────────────── Optional patch (PATCH folder) ─────────────────────
# The PATCH/ folder (next to this script) contains the patched files
# (GuitarPro.exe...) and the patch-guitarpro helper that copies them into
# the Guitar Pro installation folder (where GuitarPro.exe lives). Optional:
# if the helper is missing, the step is simply ignored.
PATCH_DIR="$SCRIPT_DIR/PATCH"
PATCH_SCRIPT="$PATCH_DIR/patch-guitarpro"
apply_optional_patch(){
  hr; msg "Guitar Pro patch (optional)"
  if [[ ! -x "$PATCH_SCRIPT" ]]; then
    warn "Patch tool not found — patch step ignored."
    return 0
  fi
  # Already patched? Propose to remove it (restore the .stock originals) instead
  # of silently re-applying it.
  if bash "$PATCH_SCRIPT" --check 2>/dev/null | grep -q 'fully applied'; then
    ok "The patch is already applied."
    if ((YES == 0)) && ask "Remove the patch (restore the original .stock files) ?" n; then
      bash "$PATCH_SCRIPT" --revert || { err "Unpatch returned an error."; return 1; }
    else
      ok "Patch kept."
    fi
    return 0
  fi
  if ((YES)) || ask "Patch detected, patch now ?" y; then
    bash "$PATCH_SCRIPT" || { err "patch-guitarpro returned an error."; return 1; }
  else
    warn "Patch not run — run it manually:  bash \"$PATCH_SCRIPT\""
  fi
  return 0
}

# ───────────────────── Font & DPI hardening (Wine) ─────────────────────
# Writes the Wine font/DPI settings into the prefix so Guitar Pro renders at
# the right size (Windows apps ignore the Hyprland scale). Auto-detects the
# scale from Hyprland unless --dpi N is given. Also adds the extra Windows
# fonts (winetricks allfonts) that fix missing glyphs (empty boxes, etc.).
step_fonts(){
  local dpi="$DPI"
  if [[ -z "$dpi" ]]; then
    local scale
    scale="$(hyprctl monitors -j 2>/dev/null | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin)[0].get("scale",1))
except Exception:
    print(1)' 2>/dev/null || echo 1)"
    dpi="$(awk -v s="$scale" 'BEGIN{d=int(96*s+0.5); print (d<96?96:(d>192?192:d))}')"
    msg "Font & DPI hardening — detected Hyprland scale=$scale → LogPixels=$dpi"
  else
    msg "Font & DPI hardening — forced LogPixels=$dpi"
  fi

  # Registry values (standard Wine font smoothing + scale).
  local reg_ok=1
  WINEARCH=win64 WINEPREFIX="$PFX" wine reg add 'HKCU\Control Panel\Desktop' /v LogPixels /t REG_DWORD /d "$dpi" /f >/dev/null 2>&1 || reg_ok=0
  WINEARCH=win64 WINEPREFIX="$PFX" wine reg add 'HKCU\Control Panel\Desktop' /v FontSmoothing /t REG_SZ /d 2 /f >/dev/null 2>&1 || reg_ok=0
  WINEARCH=win64 WINEPREFIX="$PFX" wine reg add 'HKCU\Control Panel\Desktop' /v FontSmoothingType /t REG_DWORD /d 2 /f >/dev/null 2>&1 || reg_ok=0
  WINEARCH=win64 WINEPREFIX="$PFX" wine reg add 'HKCU\Control Panel\Desktop' /v FontSmoothingGamma /t REG_DWORD /d 1000 /f >/dev/null 2>&1 || reg_ok=0
  if (( reg_ok )); then
    ok "DPI=$dpi and font smoothing written to the prefix registry"
  else
    warn "Some wine reg add calls failed — Guitar Pro may still render wrongly"
  fi

  # Extra Windows fonts (Tahoma...): opt-in, slow, non-fatal.
  if ((YES)) || ask "Install the extra Windows fonts (winetricks allfonts, fixes missing glyphs)?" n; then
    warn "Downloading/installing the ~17 Windows fonts (winetricks allfonts) —"
    warn "can take a few minutes. Progress is shown below; if the network is slow the"
    warn "terminal may look idle between downloads, please let it finish (hard limit: 15 min)."
    if timeout 900 env WINEARCH=win64 WINEPREFIX="$PFX" winetricks allfonts; then
      ok "allfonts installed"
    else
      warn "winetricks allfonts failed or timed out — continue anyway"
    fi
  fi
}

# ───────────────────── Menu cleanup (Wine duplicates) ─────────────────────
# The Windows installer creates shortcuts in the Wine start menu ("Programs").
# Wine then publishes them in the user menu (wine/Programs/…) where they show
# up next to our own launcher. We delete those so ONLY the Omarchy entry
# (guitarpro.desktop) plus the REAL Windows "Uninstall" entry remain. The
# wine-extension-* / wine-protocol-* files (file associations) are
# NoDisplay=true and are kept. The .directory files (start-menu folders) are
# kept so the Uninstall entry stays reachable.
dedupe_menu_entries(){
  msg "Menu cleanup — removing the Wine shortcut duplicates (Uninstall entry kept)"
  local apps="$HOME/.local/share/applications" n=0 f
  while IFS= read -r -d '' f; do
    [[ "$(basename "$f")" == Uninstall* ]] && continue
    if rg -qi 'guitar|arobas' "$f" 2>/dev/null; then
      rm -f "$f" && { ok "Removed: ${f#$apps/}"; n=$((n+1)); }
    fi
  done < <(find "$apps/wine/Programs" -maxdepth 5 -type f -name '*.desktop' -print0 2>/dev/null)
  # Empty folders left in the Wine start menu (non-empty ones keep the
  # Uninstall entry reachable in the menu).
  find "$apps/wine/Programs" -type d -empty -delete 2>/dev/null || true
  if (( n == 0 )); then warn "No Wine-generated shortcut to remove (all clean)." ; fi
  command -v update-desktop-database >/dev/null && update-desktop-database "$apps" >/dev/null 2>&1 || true
  if [[ -f "$apps/wine/Programs/Arobas Music/Guitar Pro 8/Uninstall.desktop" ]]; then
    ok "Windows Uninstall entry kept (wine/Programs/…/Guitar Pro 8/Uninstall.desktop)"
  fi
}

do_install(){
  hr; msg "Guitar Pro 8 installation"

  # Fills INSTALLER_PATH (global): the installer path to use.
  INSTALLER_PATH="$SCRIPT_DIR/$EXE_NAME"
  resolve_installer || return 1
  local exe_path="$INSTALLER_PATH"
  ok "Installer: $(du -h "$exe_path" | cut -f1) ($exe_path)"

  # 1) Check the dependencies
  msg "Checking the dependencies"
  local missing=()
  for p in wine winetricks; do
    command -v "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  if ((${#missing[@]})); then
    err "Missing dependencies: ${missing[*]}"
    err "Install them: sudo pacman -S --needed wine-staging winetricks"
    exit 1
  fi
  ok "wine $(wine --version 2>/dev/null || echo '?') / winetricks present"

  # 2) Check multilib for lib32
  if ! grep -A5 '^\[multilib\]' /etc/pacman.conf 2>/dev/null | grep -q '^Server'; then
    warn "[multilib] repo inactive — some 32-bit font packages could be missing."
  fi

  # 3) Create the wine prefix
  if [[ -d "$PFX/drive_c" ]]; then
    warn "Prefix $PFX already exists."
    if ! ask "Recreate the prefix (overwrites the existing one) ?" n; then
      ok "Keeping the existing prefix"
    else
      rm -rf "$PFX"
    fi
  fi

  if [[ ! -d "$PFX/drive_c" ]]; then
    msg "Creating the wine prefix (win64, Windows 7)..."
    WINEARCH=win64 WINEPREFIX="$PFX" wineboot --init >/dev/null 2>&1 || true
    ok "Prefix created"
  fi

  # 4) Install corefonts (required by Guitar Pro 8)
  msg "Installing the Windows fonts (corefonts)..."
  warn "(progress is shown below — waits for winetricks to fetch the fonts)"
  if timeout 600 env WINEARCH=win64 WINEPREFIX="$PFX" winetricks corefonts; then
    ok "corefonts installed"
  else
    warn "winetricks corefonts returned an error or timed out — Guitar Pro may still work"
  fi

  # 4bis) Font & DPI hardening — fixes too small / blurry / broken text in
  # Guitar Pro under Wine (common on HiDPI or scaled Hyprland setups).
  step_fonts

  # 5) Launch the installer
  hr
  msg "Launching the Guitar Pro 8 installer"
  echo "  → A Wine window will open. Follow the installation steps."
  echo "  → Install to the default path (change nothing)."
  echo "  → You can close this window once the installer is finished."
  echo
  WINEARCH=win64 WINEPREFIX="$PFX" wine "$exe_path" &
  local wine_pid=$!

  # Wait for the installer to close
  echo "  Waiting for the installer to finish..."
  wait "$wine_pid" 2>/dev/null || true
  echo

  if [[ ! -f "$GP_EXE" ]]; then
    err "GuitarPro.exe not found after the installation."
    err "Check that the installer finished correctly."
    err "Expected path: $GP_EXE"
    exit 1
  fi
  ok "GuitarPro.exe found"

  # 5bis) Optional patch: runs patch-guitarpro (PATCH/ → installation folder,
  # where GuitarPro.exe lives).
  apply_optional_patch

  # 6) Audio — configure PipeWire for the prefix
  msg "PipeWire/Wine audio configuration..."
  # wine-staging 11.x uses the PipeWire driver by default if available.
  # We make sure the environment variables are correct.
  local audio_env="$PFX/.guitarpro-audio-env"
  cat > "$audio_env" <<'ENVEOF'
# Audio environment for Guitar Pro 8 (sourced by the launcher)
# wine-staging 11.x PipeWire backend — active by default with pipewire
export WINE_PIPEWIRE=1
# Audio latency (ms) — increase if crackling during playback
export WINE_PIPEWIRE_LATENCY=48
ENVEOF
  ok "audio-environment file created"

  # 7) Create the launcher
  msg "Creating the launcher"
  cat > "$LAUNCHER" <<LAUNCHEOF
#!/usr/bin/env bash
# Guitar Pro 8 — launcher
# Generated by setup-guitarpro.sh

PFX="$PFX"
GP_EXE="$GP_EXE"

# Load the audio environment if present
[[ -f "\$PFX/.guitarpro-audio-env" ]] && source "\$PFX/.guitarpro-audio-env"

# Launch Guitar Pro 8
exec WINEARCH=win64 WINEPREFIX="\$PFX" wine "\$GP_EXE" "\$@"
LAUNCHEOF
  chmod +x "$LAUNCHER"
  ok "Launcher: $LAUNCHER"

  # 8) Create the .desktop shortcut
  msg "Creating the menu shortcut"
  mkdir -p "$(dirname "$DESKTOP_DST")"
  cat > "$DESKTOP_DST" <<DESKEOF
[Desktop Entry]
Type=Application
Name=Guitar Pro 8
Comment=Score and tablature editor
Exec=$LAUNCHER
Icon=$ICON
Terminal=false
Categories=AudioVideo;Audio;Music;Utility;
MimeType=application/x-guitarpro;audio/x-gp3;audio/x-gp4;audio/x-gp5;audio/x-gp;
Keywords=guitar;tab;tablature;partition;music;
DESKEOF
  ok "Shortcut: $DESKTOP_DST"

  # 9) Update the application database
  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$(dirname "$DESKTOP_DST")" 2>/dev/null || true
  fi

  # 10) Remove the Wine start-menu duplicates (only the Omarchy entry stays)
  dedupe_menu_entries

  hr
  msg "Installation finished!"
  echo " • Launch from the ' Guitar Pro 8 ' menu or directly: guitarpro"
  echo " • The dedicated wine prefix: $PFX"
  echo " • To uninstall: ./uninstall-guitarpro.sh"
  hr
}

# ═══════════════════════════════════════════════════════════════════
main(){
  if ((STATUS)); then do_status; exit 0; fi
  do_install
}

main "$@"
