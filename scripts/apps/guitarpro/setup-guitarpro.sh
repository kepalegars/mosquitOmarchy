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
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/wine-menu.bash"  # wine-menu: drop the shortcuts Wine republishes for this prefix
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PFX="$HOME/.wine-guitarpro8"
GP_EXE="$PFX/drive_c/Program Files/Arobas Music/Guitar Pro 8/GuitarPro.exe"
# The icon ships as an SVG (guitar-pro.svg) and is rasterised to the themed
# XDG PNG the menu references by name. A raster source is still accepted so an
# existing icon.png keeps working, but SVG wins: it is what the repo carries.
ICON_SRC_SVG="$SCRIPT_DIR/guitar-pro.svg"
ICON_SRC_PNG="$SCRIPT_DIR/icon.png"
ICON_SRC=""
[[ -f $ICON_SRC_SVG ]] && ICON_SRC="$ICON_SRC_SVG"
[[ -z $ICON_SRC && -f $ICON_SRC_PNG ]] && ICON_SRC="$ICON_SRC_PNG"
# The icon is INSTALLED as a themed XDG icon and referenced BY NAME. It used to
# be written into the .desktop as Icon=$SCRIPT_DIR/icon.png, i.e. an absolute
# path inside the checkout: renaming the repo (Omarchy_Custom_Scripts ->
# mosquitOmarchy) silently invalidated it and the entry showed up in the app
# menu with no icon at all, while everything else about it looked correct. A
# name lookup survives the repo moving and is what every menu actually resolves.
ICON_NAME="guitarpro"
ICON_DST="$HOME/.local/share/icons/hicolor/256x256/apps/$ICON_NAME.png"
ICON_SIZE=256
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

# -y means "take the DEFAULT answer", not "answer yes to everything": the
# previous hardcoded `return 0` silently turned every default-n question into
# a yes, which is how a re-run ended up asking (and auto-answering) "Recreate
# the prefix (overwrites the existing one) ?" with a yes — wiping a working
# prefix and re-doing the whole font setup from scratch.
ask(){
  local q="$1" def="${2:-y}" r
  if ((YES)); then
    [[ $def = y ]] && { ok "(auto) $q -> yes (default)"; return 0; }
    warn "(auto) $q -> no (default)"
    return 1
  fi
  read -rp "$q [$([ $def = y ] && echo Y/n || echo y/N)] " r
  r="${r:-$def}"; [[ $r =~ ^[oOyY] ]]
}

pkg_has(){ pacman -Q "$1" &>/dev/null; }

# ───────────────────── Quiet winetricks / installer ─────────────────────
# winetricks is pathologically verbose: for every font it unpacks a cab and
# spawns wine regedit.exe TWICE (wow64 + native), each printing its own
# "Executing …" block. `allfonts` is ~17 packages, i.e. several thousand lines
# of identical output, all of it dumped straight onto the terminal — the log
# became effectively infinite and writing it was itself a big part of the wait.
# Everything now goes to a log file; the screen only gets a one-line result and,
# on failure, the tail that matters. WINETRICKS_VERBOSE=1 restores the full
# stream when someone actually needs to watch it.
LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/mosquitOmarchy/guitarpro"
LOG_TIMEOUT_WINE=1800
LOG_TIMEOUT_INSTALL=3600

run_quiet(){
  # run_quiet <log-name> <timeout> <label> <cmd...>
  local name="$1" tmo="$2" label="$3"; shift 3
  local log="$LOG_DIR/$name.log" t0=$SECONDS rc=0
  mkdir -p "$LOG_DIR"
  if [[ -n ${WINETRICKS_VERBOSE:-} ]]; then
    "$@"; return $?
  fi
  printf '  %s… ' "$label"
  if timeout "$tmo" "$@" >"$log" 2>&1; then rc=0; else rc=$?; fi
  local secs=$(( SECONDS - t0 ))
  if (( rc == 0 )); then
    printf '\r\033[K  %s✓ %s — %ss\033[0m\n' "$G" "$label" "$secs"
  elif (( rc == 124 )); then
    printf '\r\033[K  %s✗ %s — timed out after %ss\033[0m\n' "$R" "$label" "$tmo"
    warn "Last lines of $log:"; tail -n 5 "$log" | sed 's/^/    /' >&2
  else
    printf '\r\033[K  %s✗ %s — failed (rc=%s, %ss)\033[0m\n' "$R" "$label" "$rc" "$secs"
    warn "Last lines of $log:"; tail -n 5 "$log" | sed 's/^/    /' >&2
  fi
  return $rc
}

# Is a winetricks verb already registered in THIS prefix? Re-running a verb that
# is installed re-registers every font (minutes of regedit spawns) for nothing.
verb_installed(){
  local verb="$1"
  WINEPREFIX="$PFX" WINEDEBUG=-all timeout 120 winetricks list-installed 2>/dev/null \
    | tr ' ' '\n' | grep -qx "$verb"
}

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

# At opening: name the manually-downloaded installer if it is missing.
check_manual_installer(){
  if [[ -f "$SCRIPT_DIR/$EXE_NAME" ]]; then
    ok "Installer present: $EXE_NAME"
    return 0
  fi
  hr
  warn "Missing manual download — $EXE_NAME is not in $SCRIPT_DIR/"
  warn "  Expected file: $EXE_NAME"
  warn "  → download Guitar Pro 8 from Arobas Music and drop the .exe here:"
  warn "    $SCRIPT_DIR/"
  hr
  return 1
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
  # An entry can be "present" and still render with no icon, so report the two
  # halves separately: the themed icon on disk, and what the entry references.
  if [[ -f "$ICON_DST" ]]; then ok "Icon installed : $ICON_DST"
  else warn "Icon missing : $ICON_DST (menu entry shows a generic icon)"; fi
  if [[ -f "$SCRIPT_DIR/$EXE_NAME" ]]; then ok "Installer : present"
  else warn "Installer missing : put $EXE_NAME in $SCRIPT_DIR"; fi
  if [[ -d "$PATCH_DIR" ]] && [[ -n "$(find "$PATCH_DIR" -maxdepth 1 -type f ! -name '.*' 2>/dev/null | head -1)" ]]
  then ok "Patch : present (split files)"
  else warn "Patch : not provided (skip)"; fi
  # Wine republishes the Windows shortcuts after every install; a leftover
  # "Uninstall" entry in the launcher is the classic symptom.
  local leftover="" f
  while IFS= read -r f; do
    [[ -n $f ]] || continue
    if rg -qi 'guitar|arobas' "$f" 2>/dev/null; then leftover+="$f"$'\n'; fi
  done < <(find "$HOME/.local/share/applications/wine/Programs" -type f -name '*.desktop' 2>/dev/null || true)
  if [[ -n $leftover ]]; then
    warn "Wine duplicate(s) still in the menu:"
    printf '    %s' "$leftover" >&2
    warn "  → they are removed at the end of the install; to clean now:"
    warn "    rm -rf \"$HOME/.local/share/applications/wine/Programs/Arobas Music\""
  else
    ok "Menu duplicates : none"
  fi
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
  # Driven by the mosquitOmarchy TUI: never auto-apply here. The TUI proposes the
  # patch (only when the script is present) after the install.
  if [[ -n ${MOSQUITOMARCHY_TUI:-} ]]; then
    ok "Patch available — the TUI proposes it after the install."
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
  # The `((YES)) ||` short-circuit used to sit in front of ask(): under -y (which
  # is how the mosquitOmarchy TUI runs the script) it forced allfonts ON, i.e.
  # ~17 extra font packages, thousands of log lines and several minutes — for
  # something documented as opt-in. ask() now handles -y itself, by default.
  if ask "Install the extra Windows fonts (winetricks allfonts, fixes missing glyphs)?" n; then
    if verb_installed allfonts; then
      ok "allfonts already installed in this prefix — skipped"
    elif run_quiet allfonts 1800 "allfonts (~17 font packages)" \
         env WINEARCH=win64 WINEPREFIX="$PFX" WINEDEBUG=-all winetricks allfonts; then
      ok "allfonts installed"
    else
      warn "winetricks allfonts failed or timed out — continue anyway"
    fi
  fi
}

# ───────────────────── Menu cleanup (Wine duplicates) ─────────────────────
# The Windows installer creates shortcuts in the Wine start menu ("Programs").
# Wine then publishes them in the user menu (wine/Programs/…) where they show
# up next to our own launcher, so the whole Arobas Music tree goes away and
# ONLY the Omarchy entry (guitarpro.desktop) remains.
#
# It used to spare Uninstall.desktop (and keep the enclosing .directory files
# "so the Uninstall entry stays reachable"): an Uninstall shortcut pointing at
# unins000.exe has no business in an app launcher — it is a maintenance action,
# it is already covered by ./uninstall-guitarpro.sh, and it is the entry people
# keep clicking by mistake. The file-associations (wine-extension-* /
# wine-protocol-*) are NoDisplay=true and are left alone.
#
# The mechanics now live in scripts/lib/wine-menu.bash, shared with the other
# wine modules: it also prunes the .directory publishers, which this script used
# to leave behind (an empty "Arobas Music" folder kept showing in the menu).
dedupe_menu_entries(){
  msg "Menu cleanup — removing the Wine-generated entries for Guitar Pro"
  local line n=0
  while IFS= read -r line; do
    n=$((n + 1)); ok "Removed: ${line#removed }"
  done < <(mosquitomarchy_wine_menu_remove 'guitar|arobas')
  mosquitomarchy_wine_menu_sweep
  (( n == 0 )) && ok "No Wine-generated shortcut left (all clean)."
  if [[ -e "$HOME/.local/share/applications/wine/Programs/Arobas Music" ]]; then
    warn "Arobas Music tree still present under applications/wine/Programs"
  else
    ok "Menu is clean: only the 'Guitar Pro 8' entry remains."
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
  msg "Windows fonts (winetricks corefonts)"
  if verb_installed corefonts; then
    ok "corefonts already installed in this prefix — skipped (log: $LOG_DIR/corefonts.log)"
  else
    if run_quiet corefonts 1800 "corefonts" \
         env WINEARCH=win64 WINEPREFIX="$PFX" WINEDEBUG=-all winetricks corefonts; then
      ok "corefonts installed"
    else
      warn "winetricks corefonts failed or timed out — Guitar Pro may still work"
    fi
  fi

  # 4bis) Font & DPI hardening — fixes too small / blurry / broken text in
  # Guitar Pro under Wine (common on HiDPI or scaled Hyprland setups).
  step_fonts

  # 5) Launch the installer
  hr
  mkdir -p "$LOG_DIR"
  # Already there? Re-running the 1 GB Windows installer to repair a menu entry
  # is a waste of ten minutes, so make it an explicit opt-in (default no, and
  # therefore also no under -y).
  local skip_installer=0
  if [[ -f "$GP_EXE" ]]; then
    if ask "Guitar Pro 8 is already installed ($GP_EXE) — run the Windows installer again ?" n; then
      :
    else
      skip_installer=1
    fi
  fi
  if (( skip_installer )); then
    ok "Keeping the existing installation — installer step skipped."
  else
    msg "Launching the Guitar Pro 8 installer"
    echo "  → A Wine window will open. Follow the installation steps."
    echo "  → Install to the default path (change nothing)."
    echo "  → You can close this window once the installer is finished."
    echo "  → Installer output is written to $LOG_DIR/installer.log"
    echo
    # WINEDEBUG=-all: the installer otherwise sprays several hundred
    # "fixme:…" lines (every unimplemented Windows API it touches) over the
    # terminal, burying the progress messages.
    ( WINEARCH=win64 WINEPREFIX="$PFX" WINEDEBUG=-all wine "$exe_path" \
        >"$LOG_DIR/installer.log" 2>&1 || true ) &
    local wine_pid=$!

    # Wait for the installer to close
    echo "  Waiting for the installer to finish…"
    wait "$wine_pid" 2>/dev/null || true
    echo

    if [[ ! -f "$GP_EXE" ]]; then
      err "GuitarPro.exe not found after the installation."
      err "Check that the installer finished correctly."
      err "Expected path: $GP_EXE"
      exit 1
    fi
    ok "GuitarPro.exe found"
  fi

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

# Launch Guitar Pro 8.
# WINEARCH/WINEPREFIX are EXPORTED, not passed as a prefix to exec: an
# environment assignment only applies to a simple command, and \`exec\` is a
# special builtin that takes a command word — so \`exec WINEARCH=win64 ...\`
# looks for a program literally named "WINEARCH=win64" and dies with
# "exec: WINEARCH=win64: not found". That is what made the menu entry do
# nothing at all: the install was fine, the launcher could never run.
export WINEARCH=win64
export WINEPREFIX="\$PFX"
exec wine "\$GP_EXE" "\$@"
LAUNCHEOF
  chmod +x "$LAUNCHER"
  ok "Launcher: $LAUNCHER"

  # 8) Create the .desktop shortcut
  msg "Creating the menu shortcut"
  mkdir -p "$(dirname "$DESKTOP_DST")"
  # Install the icon first, so the entry can reference it by name.
  if [[ -n $ICON_SRC ]]; then
    mkdir -p "$(dirname "$ICON_DST")"
    if [[ $ICON_SRC == *.svg ]]; then
      # rsvg-convert keeps the vector crisp at any size; magick/convert are the
      # fallbacks. Without one of them the PNG is simply not installed and the
      # entry falls back to a generic icon, which is reported below.
      if command -v rsvg-convert >/dev/null 2>&1; then
        rsvg-convert -w "$ICON_SIZE" -h "$ICON_SIZE" "$ICON_SRC" -o "$ICON_DST" \
          && ok "Icon rendered from $(basename "$ICON_SRC") to $ICON_DST" \
          || warn "Could not rasterise $ICON_SRC"
      elif command -v magick >/dev/null 2>&1; then
        magick -background none "$ICON_SRC" -resize "${ICON_SIZE}x${ICON_SIZE}" "$ICON_DST" \
          && ok "Icon rendered from $(basename "$ICON_SRC") to $ICON_DST" \
          || warn "Could not rasterise $ICON_SRC"
      elif command -v convert >/dev/null 2>&1; then
        convert -background none "$ICON_SRC" -resize "${ICON_SIZE}x${ICON_SIZE}" "$ICON_DST" \
          && ok "Icon rendered from $(basename "$ICON_SRC") to $ICON_DST" \
          || warn "Could not rasterise $ICON_SRC"
      else
        warn "No SVG rasteriser (rsvg-convert / magick / convert) — icon not installed"
      fi
    else
      install -m 0644 "$ICON_SRC" "$ICON_DST"
      ok "Icon installed: $ICON_DST"
    fi
    [[ -f $ICON_DST ]] && command -v gtk-update-icon-cache >/dev/null 2>&1 \
      && gtk-update-icon-cache -f -t ~/.local/share/icons/hicolor >/dev/null 2>&1 || true
  else
    warn "Icon source missing ($ICON_SRC_SVG) — the menu entry will show a generic icon"
  fi
  # One MAIN category only (AudioVideo): "AudioVideo;Audio;Music;Utility;" gave
  # the entry three main categories, and a menu is then free to list the same
  # application three times. "Music" is a sub-category, so it is free.
  cat > "$DESKTOP_DST" <<DESKEOF
[Desktop Entry]
Type=Application
Name=Guitar Pro 8
Comment=Score and tablature editor
Exec=$LAUNCHER
Icon=$ICON_NAME
Terminal=false
Categories=AudioVideo;Music;
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
  # Strong detection: name the missing manually-downloaded installer and, in
  # non-interactive runs (the TUI passes -y), abort before touching anything.
  if ! check_manual_installer; then
    if ((YES)) || [[ ! -t 0 ]]; then
      err "Aborting: place $EXE_NAME in $SCRIPT_DIR/ (see above) and relaunch."
      exit 1
    fi
  fi
  do_install
}

main "$@"
