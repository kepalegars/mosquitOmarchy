#!/usr/bin/env bash
# setup-davinci.sh — Installs DaVinci Resolve (Studio or free) on Omarchy / Arch Linux
#
# The official installer must be dropped in this folder (zip from the Blackmagic
# website — account required). ANY version is accepted — whatever releases
# Blackmagic names it (18, 19, 20…), the file name in the folder chooses the
# edition, not the version:
#   DaVinci_Resolve_*_Linux.zip          → FREE Resolve
#   DaVinci_Resolve_Studio_*_Linux.zip   → STUDIO Resolve
# If both are present, the script asks which one to install.
# Download pages:
#   https://www.blackmagicdesign.com/support/family/davinci-resolve-and-fusion
#   https://www.blackmagicdesign.com/support/download/59dd4eef1f4941c29fb8dc48b33f5c87/Linux   (free)
#   https://www.blackmagicdesign.com/support/download/baf7c071c0524fbf8ccc961925c9f443/Linux   (Studio)
#
# H.264/H.265: NATIVE in Resolve Studio. The FREE Linux build does NOT ship
# H.264/H.265 (commercial license): the script reminds about DNxHR transcoding.
# AAC: NOT decodable on Linux in EITHER edition (Blackmagic removed it for
# licensing). For Studio 21.x the script offers resolve-aacfix
# (https://github.com/josephg/resolve-aacfix, reversible); otherwise transcode
# the audio to PCM. For Studio, an FFmpeg encoding plugin (x264/x265/SVT-AV1/VAAPI)
# can be added: drop the ffmpeg_encoder_plugin.dvcp.bundle.zip here or
# downloaded from GitHub.
#
# OFX option: the free "SpectraFilm" plugin (photochemical film simulation)
# can be installed straight into DaVinci Resolve (/usr/OFX/Plugins).
#
# Usage :
#   ./setup-davinci.sh                     # interactive
#   ./setup-davinci.sh -y                  # non-interactive (default choices)
#   ./setup-davinci.sh --studio|--free     # force the edition if ambiguous
#   ./setup-davinci.sh --with-spektrafilm  # also installs the SpectraFilm OFX
#   ./setup-davinci.sh --no-codecs         # leave codec setup alone
#   ./setup-davinci.sh --keep-mesa         # do not remove opencl-mesa (AMD)
#   ./setup-davinci.sh --status            # current state, changes nothing
#   ./setup-davinci.sh -h                  # help

# Launched from a file manager (Nautilus)? Reopen in a terminal and keep the
# window open until a key is pressed (cf. gui-run.bash).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/gui-run.bash"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/elevate.bash"  # mq_sudo: native pkexec prompt when not root

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVE_DIR=/opt/resolve
BIN_DIR="$HOME/.local/bin"
APPS_DIR="$HOME/.local/share/applications"
LAUNCHER="$BIN_DIR/davinci-resolve"
DESKTOP="$APPS_DIR/davinci-resolve.desktop"
OFX_PLUGIN_DIR=/usr/OFX/Plugins
FFMPEG_PLUGIN_URL="https://github.com/EdvinNilsson/ffmpeg_encoder_plugin/releases/latest/download/ffmpeg_encoder_plugin.dvcp.bundle.zip"
SPEKTRAFILM_URL="https://downloads.spektrafilm.114c.de/latest/spektrafilm-OFX-linux.zip"

YES=0 STATUS_ONLY=0 FORCE_ED="" WITH_SPEKTRA=0 SKIP_CODECS=0 KEEP_MESA=0
while (( $# )); do a="$1"; case "$a" in
  -y|--yes) YES=1 ;;
  --status) STATUS_ONLY=1 ;;
  --studio|--free) FORCE_ED="${a#--}" ;;
  --with-spektrafilm) WITH_SPEKTRA=1 ;;
  --no-codecs) SKIP_CODECS=1 ;;
  --keep-mesa) KEEP_MESA=1 ;;
  -h|--help) sed -n '2,/^# Launched from a file manager/p' "$0" | head -n -1 || true; exit 0 ;;
  *) echo "Unknown option: $a" >&2; exit 1 ;;
esac; shift; done

G='\033[1;32m'; B='\033[1;34m'; Y='\033[1;33m'; R='\033[1;31m'; N='\033[0m'
msg(){ printf "${B}==>${N} %s\n" "$*"; }
ok(){ printf " ${G}✓${N} %s\n" "$*"; }
warn(){ printf " ${Y}!${N} %s\n" "$*"; }
err(){ printf " ${R}✗${N} %s\n" "$*" >&2; }
hr(){ printf '%.0s─' {1..70}; echo; }


# Clickable hyperlink (OSC 8): shown as text, opens the URL in the browser on
# click (foot/kitty/GNOME Terminal). Printed as a plain URL if unsupported.
url(){
  # OSC 8 clickable hyperlink in a real terminal; plain "label — url" otherwise
  # (a TUI's Runner log has no hyperlink support and the escape bytes would
  # garble the display).
  if [[ -t 1 ]]; then printf '\e]8;;%s\e\\%s\e]8;;\e\\' "$1" "$2"
  else printf '%s — %s' "$2" "$1"; fi
}
davinci_download_links(){
  warn "Download from Blackmagic (account required) — any version works, the file name chooses the edition:"
  warn "  $(url 'https://www.blackmagicdesign.com/support/family/davinci-resolve-and-fusion' 'All DaVinci Resolve versions (family page)')"
  warn "  $(url 'https://www.blackmagicdesign.com/support/download/59dd4eef1f4941c29fb8dc48b33f5c87/Linux' 'DaVinci Resolve (free) — direct Linux download')"
  warn "  $(url 'https://www.blackmagicdesign.com/support/download/baf7c071c0524fbf8ccc961925c9f443/Linux' 'DaVinci Resolve Studio — direct Linux download')"
  warn "  (click / Ctrl+click the links above) then drop the zip here: $SCRIPT_DIR/"
}

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
resolve_installed(){ [[ -x "$RESOLVE_DIR/bin/resolve" ]]; }

# Persistent state outside /opt/resolve (which a Resolve update replaces):
# lets the mosquitOmarchy update flow notice a user-installed Resolve update
# and re-apply the integration/patches that were enabled before it.
DAVINCI_STATE="${XDG_STATE_HOME:-$HOME/.local/state}/mosquitomarchy/davinci-state"

resolve_version(){
  local f="$RESOLVE_DIR/docs/ReadMe.html"
  if [[ -r "$f" ]]; then
    sed -n 's:.*<title>DaVinci Resolve \([0-9][0-9.]*\)</title>.*:\1:p' "$f" | head -n1
    return 0
  fi
  f="$RESOLVE_DIR/docs/Welcome.txt"
  [[ -r "$f" ]] && grep -oE 'DaVinci Resolve [0-9]+\.[0-9]+(\.[0-9]+)?' "$f" | head -n1 | awk '{print $3}'
}

state_get(){
  [[ -r "$DAVINCI_STATE" ]] || return 0
  sed -n "s/^$1=//p" "$DAVINCI_STATE" | head -n1
}

license_patched(){
  local s="$SCRIPT_DIR/PATCH/patch-resolve.sh"
  [[ -x "$s" ]] || return 1
  bash "$s" --check 2>/dev/null | grep -q 'binary patched'
}

save_davinci_state(){
  local ed="${1:-}" lic="${2:-}" aac="${3:-}" ff="${4:-}"
  [[ -n "$lic" ]] || lic=$(license_patched && echo 1 || echo 0)
  [[ -n "$aac" ]] || aac=$([[ -e "$RESOLVE_DIR/bin/resolve.aac-orig" ]] && echo 1 || echo 0)
  [[ -n "$ff" ]] || ff=$([[ -d "$RESOLVE_DIR/IOPlugins/ffmpeg_encoder_plugin.dvcp.bundle" ]] && echo 1 || echo 0)
  mkdir -p "$(dirname "$DAVINCI_STATE")"
  {
    echo "version=$(resolve_version)"
    echo "edition=$ed"
    echo "aacfix=$aac"
    echo "license_patch=$lic"
    echo "ffmpeg_plugin=$ff"
  } > "$DAVINCI_STATE"
}

infer_edition(){
  local z
  z="$(davinci_zips | head -n1 || true)"
  if [[ -n "$z" ]]; then edition_of "$z"; else echo studio; fi
}

# Detection of the edition from the zip name (Studio or free), case-insensitive
# and version-agnostic: only "resolve_studio" vs "resolve" matters, so EVERY
# Blackmagic release (18, 19, 20…) and any capitalisation is accepted.
edition_of(){
  local n; n="$(basename "${1:-}")"
  shopt -s nocasematch
  case "$n" in
    *resolve_studio*) echo studio ;;
    *resolve*)        echo free ;;
    *)                echo "?" ;;
  esac
  shopt -u nocasematch
}
edition_label(){ [[ "${1:-}" == studio ]] && echo "Studio" || echo "free"; }

# Any DaVinci Resolve installer zip dropped in the folder — ALL versions, any
# case. Matches both the free and the Studio build (edition_of() tells them
# apart), plus a generic DaVinci*-named archive.
davinci_zips(){
  local f
  for f in "$SCRIPT_DIR"/*[Rr]esolve*.zip "$SCRIPT_DIR"/[Dd]a[Vv]inci*.zip; do
    [[ -f $f ]] && printf '%s\n' "$f"
  done | sort -u
}

# At opening: name the manually-downloaded installer if it is missing.
check_manual_installer(){
  local -a z=()
  while IFS= read -r f; do [[ -n $f ]] && z+=("$f"); done < <(davinci_zips)
  if ((${#z[@]})); then
    ok "DaVinci Resolve installer present: $(basename "${z[0]}")"
    return 0
  fi
  hr
  # A Blackmagic zip that is NOT DaVinci Resolve (Fusion Studio, Render Node…)
  # is a common mix-up — say it plainly instead of just "missing".
  local bad
  bad="$(compgen -G "$SCRIPT_DIR/*[Ff]usion*.zip" 2>/dev/null | head -1)"
  [[ -z $bad ]] && bad="$(compgen -G "$SCRIPT_DIR/Blackmagic_*.zip" 2>/dev/null | head -1)"
  if [[ -n $bad ]]; then
    err "Found $(basename "$bad") — that's Blackmagic Fusion Studio, NOT DaVinci Resolve."
    warn "  Download DaVinci Resolve (free or Studio) and drop its zip here: $SCRIPT_DIR/"
    hr
    return 1
  fi
  warn "Missing manual download — no DaVinci Resolve zip in $SCRIPT_DIR/"
  warn "  Expected file: DaVinci_Resolve_<version>_Linux.zip          (free)"
  warn "                 DaVinci_Resolve_Studio_<version>_Linux.zip   (Studio)"
  warn "  Any version works (18/19/20…). Download from Blackmagic (account required):"
  warn "    https://www.blackmagicdesign.com/support/family/davinci-resolve-and-fusion"
  warn "    $SCRIPT_DIR/"
  hr
  return 1
}

# Extraction must run on a real filesystem with room for the ~15 GB payload.
# /tmp is often a small tmpfs (e.g. 14 GB of RAM), which fills up and makes
# `unzip` fail with a bare "Cannot extract" — while a manual extraction onto the
# big disk works. Pick a writable base that actually has the space.
davinci_work_base(){
  local base best="" best_avail=0 avail
  for base in "$HOME/.cache" "${TMPDIR:-/tmp}" /var/tmp /opt; do
    [[ -d $base && -w $base ]] || continue
    avail=$(df -Pk -- "$base" 2>/dev/null | awk 'NR==2 {print int($4/1024/1024)}')
    ((avail >= 30)) && { printf '%s' "$base"; return 0; }
    ((avail > best_avail)) && { best=$base; best_avail=$avail; }
  done
  [[ -n $best ]] && { printf '%s' "$best"; return 0; }
  printf '%s' "${TMPDIR:-/tmp}"
}
davinci_tmpdir(){ # mktemp -d on the chosen base
  mktemp -d "$(davinci_work_base)/davinci-$1.XXXXXX"
}

# Remove extraction dirs left by an interrupted run (a closed terminal, a killed
# pkexec, a reboot): a single one can be ~25 GB and would otherwise fill the disk
# and make every later install fail with an opaque unzip error.
davinci_clean_stale(){
  local base
  for base in "$HOME/.cache" "${TMPDIR:-/tmp}" /var/tmp; do
    [[ -d $base ]] || continue
    rm -rf "$base"/davinci-* 2>/dev/null || true
  done
}

install_tmp=""
trap 'rm -rf "${install_tmp:-}"' EXIT
# The EXIT trap already cleans on normal/signal exits; make INT/TERM actually
# terminate so that trap runs (a bare trap without exit would continue).
trap 'exit 130' INT
trap 'exit 143' TERM

# ───────────────────────── Status ─────────────────────────
do_status(){
  hr; msg "DaVinci Resolve status"
  if resolve_installed; then ok "Binary         : $RESOLVE_DIR/bin/resolve"
  else warn "Binary         : absent (not installed)"; fi
  if [[ -x "$LAUNCHER" ]]; then ok "Launcher       : $LAUNCHER"
  else warn "Launcher       : absent"; fi
  if [[ -f "$DESKTOP" ]]; then ok "Menu shortcut  : present"
  else warn "Menu shortcut  : absent"; fi
  if [[ -e "$RESOLVE_DIR/bin/resolve.aac-orig" ]]; then ok "AAC decode     : enabled (resolve-aacfix)"
  else warn "AAC decode     : not enabled (AAC imports are silent)"; fi
  if [[ -d "$RESOLVE_DIR/IOPlugins/ffmpeg_encoder_plugin.dvcp.bundle" ]]; then ok "FFmpeg encoder plugin : installed (Studio)"
  else warn "FFmpeg encoder plugin : absent"; fi
  if [[ -d "$OFX_PLUGIN_DIR" ]] && find "$OFX_PLUGIN_DIR" -maxdepth 1 -iname '*spektra*' -print -quit 2>/dev/null | grep -q .; then
    ok "SpectraFilm OFX : installed"
  else
    warn "SpectraFilm OFX : absent"
  fi
  if command -v drwrap >/dev/null 2>&1; then
    if systemctl --user is-enabled drwrap.service >/dev/null 2>&1; then
      ok "DRwrap          : installed (converter service enabled)"
    else
      warn "DRwrap          : installed (service disabled)"
    fi
  else
    warn "DRwrap          : absent"
  fi
  local n=0 z
  while IFS= read -r z; do
    [[ -n $z ]] || continue
    n=$((n+1))
    ok "Local installer : $(basename "$z")  [$(edition_label "$(edition_of "$z")")]"
  done < <(davinci_zips)
  (( n )) || davinci_download_links
  hr
}

# ───────────────────────── Selection / installation ─────────────────────────
DAV_ZIPS=()
while IFS= read -r z; do [[ -n "$z" ]] && DAV_ZIPS+=("$z"); done < <(davinci_zips)

select_install_zip(){  # fills SEL_ZIP (edition: Studio takes priority in -y)
  local -a cand=("${DAV_ZIPS[@]}") i=1 z pick
  if [[ -n "$FORCE_ED" ]]; then
    local -a match=()
    for z in "${cand[@]}"; do [[ "$(edition_of "$z")" == "$FORCE_ED" ]] && match+=("$z"); done
    if (( ${#match[@]} == 0 )); then
      err "No \"$FORCE_ED\" zip in $SCRIPT_DIR/ (expected DaVinci_Resolve[_Studio]_*_Linux.zip)."
      return 1
    fi
    cand=("${match[@]}")
  fi
  if (( ${#cand[@]} == 1 )); then SEL_ZIP="${cand[0]}"; return 0; fi
  if (( YES )); then
    for z in "${cand[@]}"; do [[ "$(edition_of "$z")" == studio ]] && { SEL_ZIP="$z"; return 0; }; done
    SEL_ZIP="${cand[0]}"; return 0
  fi
  hr; msg "Several installers found in $SCRIPT_DIR — which one to install?"
  for z in "${cand[@]}"; do
    printf '  %2d) %s   [%s]\n' "$i" "$(basename "$z")" "$(edition_label "$(edition_of "$z")")"
    i=$((i+1))
  done
  read -rp "  Choice [1-$((i-1)), default 1]: " pick; pick="${pick:-1}"
  [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#cand[@]} )) || { err "Invalid choice."; return 1; }
  SEL_ZIP="${cand[$((pick-1))]}"
}

# ───────────────────────── Dependencies ─────────────────────────
DEPS=(gtk3 apr ocl-icd libxcrypt-compat librsvg libgudev glu clinfo unzip curl jq ffmpeg binutils pciutils)

detect_opencl_pkg(){  # OpenCL runtime according to the GPU (nvidia | amd | intel | empty)
  local gpu=""
  gpu="$(lspci -k 2>/dev/null | grep -iE 'vga|3d|display' | grep -ioE 'nvidia|amd|radeon|advanced micro|intel' | tr '[:upper:]' '[:lower:]' | sort -u | head -n1 || true)"
  case "$gpu" in
    nvidia) echo opencl-nvidia ;;
    amd|radeon|"advanced micro") echo rocm-opencl-runtime ;;
    intel) echo intel-compute-runtime ;;
    *) echo "" ;;
  esac
}

install_deps(){
  msg "System dependencies (gtk, OpenCL, extraction tools)"
  local missing=() p
  for p in "${DEPS[@]}"; do pkg_has "$p" || missing+=("$p"); done
  if ((${#missing[@]})); then
    mq_sudo -v || { err "Password required to install: ${missing[*]}"; return 1; }
    mq_sudo pacman -S --needed --noconfirm "${missing[@]}" || { err "Installation failed: ${missing[*]}"; return 1; }
    ok "Installed: ${missing[*]}"
  else
    ok "Already present: ${DEPS[*]}"
  fi

  local opencl opencl_pkg
  opencl="$(detect_opencl_pkg)"
  if [[ -n "$opencl" ]]; then
    if pkg_has "$opencl"; then
      ok "OpenCL runtime already present: $opencl"
    else
      mq_sudo -v || { err "Password required to install $opencl."; return 1; }
      mq_sudo pacman -S --needed --noconfirm "$opencl" || { warn "Failed to install $opencl."; }
      ok "OpenCL runtime: $opencl"
    fi
    if [[ "$opencl" == rocm-opencl-runtime ]] && pkg_has opencl-mesa && (( ! KEEP_MESA )); then
      # Rusticl (= opencl-mesa) sometimes loads instead of ROCm and makes
      # Resolve crash once a project is open: we remove it by default.
      if ((YES)) || ask "Remove opencl-mesa (Rusticl) — causes AMD crashes in Resolve?" y; then
        mq_sudo pacman -Rns --noconfirm opencl-mesa 2>/dev/null || true
        ok "opencl-mesa removed"
      fi
    fi
  else
    warn "GPU not identified (lspci missing or unknown GPU) — pick an OpenCL runtime:"
    warn "  sudo pacman -S opencl-nvidia | rocm-opencl-runtime | intel-compute-runtime"
  fi
}

# ───────────────────────── Binary installation ─────────────────────────
install_resolve(){
  local zip="$1" ed tmp run
  ed="$(edition_of "$zip")"
  msg "Installing DaVinci Resolve $(edition_label "$ed") ($(basename "$zip"))"
  if resolve_installed; then
    warn "An installation already exists in $RESOLVE_DIR."
    if (( YES )) || ask "Replace it (reinstall from $zip)?" n; then
      :
    else
      ok "Existing installation kept."
      return 0
    fi
  fi

  # Drop any extraction dir abandoned by a previous interrupted run first, so
  # the free-space check below sees the real available space.
  davinci_clean_stale
  tmp="$(davinci_tmpdir install)"
  install_tmp="$tmp"
  local free_gb
  free_gb=$(df -Pk -- "$tmp" 2>/dev/null | awk 'NR==2 {print int($4/1024/1024)}')
  if [[ $free_gb =~ ^[0-9]+$ ]] && (( free_gb < 30 )); then
    err "Not enough free space to extract $(basename "$zip") under $(dirname "$tmp") (${free_gb}G free, need ~30G)."
    err "Free some space (or remove stale davinci-* dirs in the work base) and retry."
    return 1
  fi
  msg "Extracting the zip archive into $tmp (free: ${free_gb}G)…"
  unzip -oq "$zip" -d "$tmp" || { err "Cannot extract the zip: $zip"; return 1; }
  run="$(find "$tmp" -maxdepth 2 \( -name '*.run' -o -name 'install*.sh' \) -type f -print -quit 2>/dev/null)"
  if [[ -z "$run" ]]; then
    err "No installer (*.run or install*.sh) found in the zip."
    return 1
  fi
  chmod +x "$run"
  msg "Installer: $(basename "$run")"

  mq_sudo -v || { err "Password required for the installation into /opt."; return 1; }

  # 1) The .run is an AppImage: extract the full payload, copied into /opt.
  # 2) Otherwise (Qt installer): "squashfs-root" = installer to run silently.
  if ( cd "$tmp" && "$run" --appimage-extract >/dev/null 2>&1 ) && [[ -d "$tmp/squashfs-root" ]]; then
    if [[ -x "$tmp/squashfs-root/bin/resolve" ]]; then
      msg "AppImage extraction OK — copying into $RESOLVE_DIR (can take a while)…"
      mq_sudo mkdir -p "$RESOLVE_DIR"
      mq_sudo cp -a "$tmp/squashfs-root/." "$RESOLVE_DIR/"
      ok "Payload copied to $RESOLVE_DIR"
    else
      msg "AppImage extraction = installer — running silently…"
      mq_sudo "$tmp/squashfs-root/AppRun" -i -y 2>/dev/null \
        || { err "Silent installer failed."; warn "Install manually: sh \"$run\""; return 1; }
    fi
  else
    msg "Quiet mode of the installer (-i -y)…"
    mq_sudo "$run" -i -y 2>/dev/null || { err "Silent installer failed."; warn "Install manually: sh \"$run\""; return 1; }
  fi

  if resolve_installed; then
    ok "DaVinci Resolve installed: $RESOLVE_DIR/bin/resolve"
    return 0
  fi
  err "Binary $RESOLVE_DIR/bin/resolve not found after installation."
  warn "Install manually: sh \"$run\" (answer the questions), then run this script again."
  return 1
}

# ───────────────────────── Launcher + shortcut ─────────────────────────
install_launcher(){
  msg "Launcher and menu shortcut"
  mkdir -p "$BIN_DIR" "$APPS_DIR"
  cat > "$LAUNCHER" <<LAUNE
#!/usr/bin/env bash
# DaVinci Resolve — launcher (generated by apps/davinci/setup-davinci.sh)
set -euo pipefail

RESOLVE_DIR="$RESOLVE_DIR"

# Cleans residual instance locks (after a crash) that block relaunching.
if ! pgrep -f "\$RESOLVE_DIR/bin/resolve" >/dev/null 2>&1; then
  rm -f /tmp/qtsingleapp-DaVinc-* /tmp/qtsingleapp-DaVinc-*-lockfile /var/tmp/davinci_socket
fi

# Native UI under Wayland not supported: force XWayland (xcb).
export QT_QPA_PLATFORM=xcb
# ROCm OpenCL (AMD): points the driver if present, otherwise system ICD (GPU detected at install).
resolve_gpu_pick(){
  [[ -r /opt/rocm/lib/libamdocl64.so ]] && export OCL_ICD_FILENAMES=/opt/rocm/lib/libamdocl64.so
}
resolve_gpu_pick
# UI scale is left to Resolve's own preferences (no QT_*/DisplayScale override).
exec "\$RESOLVE_DIR/bin/resolve" "\$@"
LAUNE
  chmod +x "$LAUNCHER"
  ok "Launcher: $LAUNCHER"

  # The payload ships its icon as DV_Resolve.png (128x128) — not the names we
  # used to look for, so the menu entry ended up iconless. Find it, then INSTALL
  # it into the user icon theme so `Icon=davinci-resolve` resolves everywhere.
  local icon="davinci-resolve" iconfull="" src=""
  for c in "$RESOLVE_DIR"/DV_Resolve.png "$RESOLVE_DIR"/graphics/DV_Resolve.png \
           "$RESOLVE_DIR"/DaVinciResolve.png "$RESOLVE_DIR/DaVinci Resolve.png" \
           /usr/share/icons/hicolor/scalable/apps/davinci-resolve.svg; do
    [[ -f "$c" ]] && { src="$c"; break; }
  done
  if [[ -n "$src" ]]; then
    local ext="${src##*.}" idir="$HOME/.local/share/icons/hicolor/256x256/apps"
    [[ "$ext" == "svg" ]] && idir="$HOME/.local/share/icons/hicolor/scalable/apps"
    mkdir -p "$idir"
    cp -f "$src" "$idir/davinci-resolve.$ext"
    iconfull="davinci-resolve"
    command -v gtk-update-icon-cache >/dev/null 2>&1 \
      && gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" >/dev/null 2>&1 || true
    ok "Icon installed: $idir/davinci-resolve.$ext"
  else
    warn "No Resolve icon found in the payload — the menu entry may stay generic."
  fi
  cat > "$DESKTOP" <<DESKE
[Desktop Entry]
Type=Application
Name=DaVinci Resolve
GenericName=DaVinci Resolve
Comment=Video editing, color grading and VFX
Exec=$LAUNCHER %u
Path=$RESOLVE_DIR/
MimeType=application/x-resolveproj;
Icon=${iconfull:-$icon}
StartupNotify=true
StartupWMClass=resolve
Categories=AudioVideo;AudioVideoEditing;
DESKE
  ok "Shortcut: $DESKTOP"
  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$APPS_DIR" 2>/dev/null || true
  fi
}

# Omarchy's default app rule (default/hypr/apps/davinci-resolve.lua) floats
# every Resolve window and fullscreens the project window. Append a user rule
# after the defaults so the main project window tiles; dialogs keep floating.
install_hypr_rule(){
  local hypr="$HOME/.config/hypr/hyprland.lua"
  local start="-- >>> mosquito-davinci-tiling >>>"
  local end="-- <<< mosquito-davinci-tiling <<<"
  if [[ ! -f "$hypr" ]]; then
    warn "Hyprland config not found at $hypr — tiling rule skipped."
    return 0
  fi
  if [[ ! -w "$hypr" ]]; then
    warn "Hyprland config not writable: $hypr — tiling rule skipped."
    return 0
  fi
  sed -i "\|${start#--}|,/${end#--}/d" "$hypr"
  cat >> "$hypr" <<'EOF'
-- >>> mosquito-davinci-tiling >>> Resolve opens tiled, not fullscreen.
-- Omarchy's default app rule floats Resolve and fullscreens the project window
-- (usr/share/omarchy/default/hypr/apps/davinci-resolve.lua). Later rules win:
-- undo both for the main project window only; the Project Manager stays floating.
o.window({ class = ".*[Rr]esolve.*", title = "^DaVinci Resolve( Studio)? - .+$" }, { float = false, fullscreen = false })
-- <<< mosquito-davinci-tiling <<<
EOF
  if command -v hyprctl >/dev/null 2>&1; then
    hyprctl reload >/dev/null 2>&1 || true
    local errs
    errs="$(hyprctl configerrors 2>/dev/null || true)"
    [[ -z "$errs" ]] || warn "Hyprland config errors: $errs"
  fi
  ok "Hyprland tiling rule: $hypr"
}

# Stable system path expected by external tools (notably the nosignal
# omarchy-resolve panel's XWayland check). A symlink to our launcher keeps the
# XWayland environment in one place.
install_wrapper(){
  local w=/usr/local/bin/resolve-omarchy
  if [[ -L "$w" && "$(readlink -f "$w")" == "$(readlink -f "$LAUNCHER")" ]]; then
    ok "System wrapper: $w"
  else
    mq_sudo mkdir -p /usr/local/bin
    mq_sudo ln -sf "$LAUNCHER" "$w"
    ok "System wrapper: $w → $LAUNCHER"
  fi

  # Hidden compatibility entry for external panels (they look for this exact
  # file + Exec). NoDisplay keeps the single visible "DaVinci Resolve" entry.
  local hidden="$APPS_DIR/davinci-resolve-wrapper.desktop"
  mkdir -p "$APPS_DIR"
  cat > "$hidden" <<DESKW
[Desktop Entry]
Type=Application
Name=DaVinci Resolve (wrapper)
Comment=Compatibility entry for external panels; not shown in the menu
Exec=$w
Icon=davinci-resolve
NoDisplay=true
Hidden=true
StartupWMClass=resolve
DESKW
  command -v update-desktop-database >/dev/null 2>&1 \
    && update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true
}

# Resolve defaults its audio backend to DeckLink, which aborts on a machine
# without a Blackmagic card. The setting lives in the user config, so a Resolve
# update does not touch it — but a fresh config can reintroduce it.
fix_audio_backend(){
  local cfg="$HOME/.local/share/DaVinciResolve/configs/config.dat"
  [[ -f "$cfg" ]] || return 0
  grep -q '^Local\.Audio\.Type = DeckLink$' "$cfg" || return 0
  cp -a "$cfg" "$cfg.bak.$(date +%s)"
  sed -i 's|^Local\.Audio\.Type = DeckLink$|Local.Audio.Type = ALSA|' "$cfg"
  ok "Audio backend: DeckLink → ALSA"
}

# ───────────────────────── DRwrap companion ─────────────────────────
# GPL-3.0 external companion (https://github.com/fedsfarm/drwrap). Kept as a
# package, never vendored: it fixes drag/drop, clipboard paste and unsupported
# codec imports. `--no-adopt` is important — our launcher/menu entry stays the
# one the user clicks; drwrap only provides its converter service.
DRWRAP_CONFIG="${DRWRAP_CONFIG:-$HOME/.config/drwrap/config.toml}"

drwrap_silence_notifications(){
  python3 - "$DRWRAP_CONFIG" <<'PYEOF'
import pathlib
import sys

path = pathlib.Path(sys.argv[1]).expanduser()
lines = path.read_text(encoding="utf-8").splitlines() if path.is_file() else []
out = []
skip = False
for line in lines:
    stripped = line.strip()
    if stripped.startswith("[") and stripped.endswith("]"):
        skip = stripped == "[notify]"
        if skip:
            continue
    if skip:
        continue
    out.append(line)
while out and not out[-1].strip():
    out.pop()
out += ["", "[notify]", "enabled = false", "progress = false", ""]
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text("\n".join(out), encoding="utf-8")
PYEOF
}

install_drwrap(){
  msg "DRwrap — drag/drop, clipboard and codec fixes for Resolve"
  if ! command -v drwrap >/dev/null 2>&1; then
    local -a aur=()
    if command -v yay >/dev/null 2>&1; then aur=(yay)
    elif command -v paru >/dev/null 2>&1; then aur=(paru)
    fi
    if (( ${#aur[@]} == 0 )); then
      warn "No AUR helper (yay/paru) — drwrap not installed."
      warn "Install it manually, then run: drwrap setup --no-adopt"
      return 0
    fi
    msg "Installing drwrap from the AUR (one-time)…"
    if ! "${aur[@]}" -S --needed --noconfirm drwrap; then
      warn "drwrap installation failed — Resolve still works without it."
      return 0
    fi
  fi
  command -v drwrap >/dev/null 2>&1 || { warn "drwrap still unavailable — skipped."; return 0; }

  local out
  if out="$(drwrap setup --no-adopt 2>&1)"; then
    ok "drwrap service configured (Resolve launcher left untouched)."
  else
    warn "drwrap setup failed — Resolve still works without it."
    printf '%s\n' "$out" | tail -n 5
    return 0
  fi

  # drwrap ships its own "DaVinci Resolve (wrapped)" menu entry (user or
  # system dir depending on version). Our davinci-resolve.desktop is the
  # complete one (MIME type, icon, path), so remove the duplicate and keep the
  # converter service.
  local removed=0 f
  for f in /usr/share/applications/drwrap.desktop "$HOME/.local/share/applications/drwrap.desktop"; do
    [[ -e "$f" ]] || continue
    if [[ "$f" == /usr/* ]]; then mq_sudo rm -f "$f"; else rm -f "$f"; fi
    removed=1
  done
  if ((removed)); then
    command -v update-desktop-database >/dev/null 2>&1 \
      && update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true
    command -v update-desktop-database >/dev/null 2>&1 \
      && update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
    ok "Removed the duplicate DRwrap menu entry (service kept)."
  fi

  drwrap_silence_notifications || true
  systemctl --user restart drwrap.service >/dev/null 2>&1 || true
  ok "drwrap notifications disabled; converter service enabled."
}

# ───────────────────────── AAC (resolve-aacfix) ─────────────────────────
AACFIX_API="https://api.github.com/repos/josephg/resolve-aacfix/releases/latest"

install_aacfix(){
  # Resolve Linux ships libavcodec with AAC compiled out AND its binary never
  # asks for AAC; resolve-aacfix lifts both gates (Studio 21.x). Reversible:
  # sudo ./aac-fix uninstall. A Resolve update wipes it — re-run this script.
  if [[ -e "$RESOLVE_DIR/bin/resolve.aac-orig" ]]; then
    ok "AAC decode already enabled (resolve-aacfix)."
    return 0
  fi
  if pgrep -f "^$RESOLVE_DIR/bin/resolve" >/dev/null 2>&1; then
    warn "Close DaVinci Resolve before installing the AAC patch."
    return 1
  fi
  command -v jq >/dev/null 2>&1 || { warn "jq is required to find the resolve-aacfix release."; return 1; }

  local url tmp fix
  url="$(curl -fsSL "$AACFIX_API" | jq -r '.assets[] | select(.name|test("tar\\.gz$")) | .browser_download_url' | head -n1)"
  [[ -n "$url" ]] || { warn "Could not find the resolve-aacfix release."; return 1; }

  tmp="$(davinci_tmpdir aacfix)"
  install_tmp="$tmp"
  msg "Downloading resolve-aacfix…"
  curl -fL --max-time 180 -o "$tmp/aacfix.tar.gz" "$url" || { warn "Download failed."; return 1; }
  tar -xzf "$tmp/aacfix.tar.gz" -C "$tmp" || { warn "Cannot extract resolve-aacfix."; return 1; }
  fix="$(find "$tmp" -maxdepth 3 -name aac-fix -type f -print -quit 2>/dev/null)"
  [[ -n "$fix" ]] || { warn "aac-fix not found in the archive."; return 1; }
  chmod +x "$fix"

  if mq_sudo "$fix" install; then
    ok "AAC decode enabled — restart Resolve and re-import the file."
  else
    warn "resolve-aacfix failed — see its output above."
    return 1
  fi
}

step_codecs(){
  local ed="$1"
  if [[ "$ed" == studio ]]; then
    ok "Resolve Studio: H.264 / H.265 native."
    warn "AAC audio is NOT decodable on Linux (both editions) — AAC imports are silent."
    if (( YES )) || ask "Enable AAC decode with resolve-aacfix (Studio 21.x, reversible)?" y; then
      install_aacfix || true
    fi
    if (( YES )) || ask "Also add the FFmpeg encoding plugin (x264/x265/SVT-AV1/VAAPI)?" n; then
      install_ffmpeg_plugin
    fi
  else
    warn "FREE Resolve Linux: no H.264/H.265 (commercial license restriction)."
    warn "AAC audio is NOT decodable on Linux either — resolve-aacfix targets Studio only."
    warn "Reliable path: transcode sources before editing:"
    warn "  ffmpeg -i input.mp4 -c:v dnxhd -profile:v dnxhr_sq -c:a pcm_s16le output.mov"
  fi
}

install_ffmpeg_plugin(){
  local dst="$RESOLVE_DIR/IOPlugins" src="" tmp bund
  [[ -d "$dst/ffmpeg_encoder_plugin.dvcp.bundle" ]] && { ok "FFmpeg encoder plugin already installed."; return 0; }

  # 1) zip dropped in the folder
  for f in "$SCRIPT_DIR"/ffmpeg_encoder_plugin*.zip; do [[ -f "$f" ]] && { src="$f"; break; }; done
  # 2) otherwise download from GitHub (official release)
  if [[ -z "$src" ]] && ( (( YES )) || ask "Download the FFmpeg encoder plugin from GitHub?" y ); then
    if curl -fL --max-time 120 -o "$SCRIPT_DIR/ffmpeg_encoder_plugin.dvcp.bundle.zip" "$FFMPEG_PLUGIN_URL"; then
      src="$SCRIPT_DIR/ffmpeg_encoder_plugin.dvcp.bundle.zip"
      ok "Downloaded: $(basename "$src")"
    else
      rm -f "$SCRIPT_DIR/ffmpeg_encoder_plugin.dvcp.bundle.zip"
      warn "Download failed — manually drop ffmpeg_encoder_plugin.dvcp.bundle.zip in $SCRIPT_DIR/"
      return 0
    fi
  fi
  [[ -n "$src" ]] || { warn "No FFmpeg encoder plugin installed (no source)."; return 0; }

  tmp="$(davinci_tmpdir ffmpeg)"
  install_tmp="$tmp"
  unzip -oq "$src" -d "$tmp" || { err "Cannot extract: $src"; return 1; }
  bund="$(find "$tmp" -maxdepth 3 -type d -name 'ffmpeg_encoder_plugin.dvcp.bundle' -print -quit 2>/dev/null)"
  if [[ -z "$bund" ]]; then
    err "ffmpeg_encoder_plugin.dvcp.bundle not found in $src."
    return 1
  fi
  mq_sudo -v || { err "Password required (writing into $dst)."; return 1; }
  mq_sudo mkdir -p "$dst"
  mq_sudo cp -a "$bund" "$dst/"
  ok "FFmpeg encoder plugin: $dst/ffmpeg_encoder_plugin.dvcp.bundle"
}

# ───────────────────────── SpectraFilm OFX (option) ─────────────────────────
install_spektrafilm(){
  local src="" tmp bund
  if [[ -d "$OFX_PLUGIN_DIR" ]] && find "$OFX_PLUGIN_DIR" -maxdepth 1 -iname '*spektra*' -print -quit 2>/dev/null | grep -q .; then
    ok "SpectraFilm OFX already installed."
    return 0
  fi
  msg "Installing the SpectraFilm OFX (film simulation, free)"
  for f in "$SCRIPT_DIR"/spektrafilm*.zip; do [[ -f "$f" ]] && { src="$f"; break; }; done
  if [[ -z "$src" ]]; then
    if ( (( YES )) || ask "Download SpectraFilm from spektrafilm.114c.de?" y ); then
      if curl -fL --max-time 300 -o "$SCRIPT_DIR/spektrafilm-OFX-linux.zip" "$SPEKTRAFILM_URL"; then
        src="$SCRIPT_DIR/spektrafilm-OFX-linux.zip"
        ok "Downloaded: $(basename "$src")"
      else
        rm -f "$SCRIPT_DIR/spektrafilm-OFX-linux.zip"
        err "Download failed — drop spektrafilm-OFX-linux.zip in $SCRIPT_DIR/" >&2
        return 1
      fi
    else
      warn "SpectraFilm OFX not installed."
      return 0
    fi
  fi
  tmp="$(davinci_tmpdir spektra)"
  install_tmp="$tmp"
  unzip -oq "$src" -d "$tmp" || { err "Cannot extract: $src"; return 1; }
  mapfile -t bund < <(find "$tmp" -maxdepth 4 -type d -name '*.ofx.bundle' | sort)
  if (( ${#bund[@]} == 0 )); then
    err "No *.ofx.bundle folder found in $src."
    return 1
  fi
  mq_sudo -v || { err "Password required (writing into $OFX_PLUGIN_DIR)."; return 1; }
  mq_sudo mkdir -p "$OFX_PLUGIN_DIR"
  local b
  for b in "${bund[@]}"; do
    mq_sudo cp -a "$b" "$OFX_PLUGIN_DIR/"
    ok "OFX installed: $OFX_PLUGIN_DIR/$(basename "$b")"
  done
  warn "Restart DaVinci Resolve then look for \"SpectraFilm\" in Color > Open FX."
}

# ───────────────────────── Recap ─────────────────────────
recap(){
  local ed="${1:-}"
  hr; msg "DaVinci Resolve — ready"
  ok "Launch: davinci-resolve   (or menu Applications > DaVinci Resolve)"
  if [[ "$ed" == studio ]]; then
    if [[ -e "$RESOLVE_DIR/bin/resolve.aac-orig" ]]; then
      echo " • H.264/H.265: native (Studio). AAC: enabled via resolve-aacfix."
      echo "   → re-run this script after every Resolve update (the patch is wiped)."
    else
      echo " • H.264/H.265: native (Studio). AAC: NOT enabled — AAC imports are silent."
    fi
  else
    echo " • H.264/H.265/AAC: not supported by Resolve Linux (free) — transcode to DNxHR/PCM."
  fi
  echo " • First-run config: Preferences > System > Memory & GPU (OpenCL auto-detected)."
  echo " • DRwrap: drag/drop, clipboard paste and codec conversion handled silently."
  echo "   Watch folder: ~/Videos/ResolveDrop · ready files: ~/Videos/ResolveIngest."
  echo " • Project / LUT data: kept in ~/.local/share, ~/.config/Blackmagic Design."
  echo " • Uninstall: ./uninstall-davinci.sh"
  hr
}

# ───────────────────────── Update mode ─────────────────────────
# Called by the mosquitOmarchy update flow (MOSQUITOMARCHY_UPDATE=1) when the
# user updated Resolve themselves. Never needs the Blackmagic zip and never
# reinstalls Resolve: it re-applies what was enabled before (license patch,
# AAC fix, FFmpeg plugin, launcher, wrapper, audio backend).
update_davinci(){
  msg "DaVinci Resolve — update mode"
  if ! resolve_installed; then
    ok "Resolve is not installed — nothing to re-apply."
    return 0
  fi
  YES=1
  local ed aac lic ff cur_ver state_ver
  state_ver="$(state_get version)"
  ed="$(state_get edition)"; [[ -n "$ed" ]] || ed="$(infer_edition)"
  aac="$(state_get aacfix)"; lic="$(state_get license_patch)"; ff="$(state_get ffmpeg_plugin)"
  cur_ver="$(resolve_version)"
  if [[ -z "$state_ver" ]]; then
    # First update after this feature existed: infer from the current install.
    aac=$([[ -e "$RESOLVE_DIR/bin/resolve.aac-orig" ]] && echo 1 || echo 0)
    lic=$(license_patched && echo 1 || echo 0)
    ff=$([[ -d "$RESOLVE_DIR/IOPlugins/ffmpeg_encoder_plugin.dvcp.bundle" ]] && echo 1 || echo 0)
  fi
  if [[ -n "$state_ver" && -n "$cur_ver" && "$state_ver" != "$cur_ver" ]]; then
    msg "Resolve updated: $state_ver → $cur_ver — re-applying the integration."
  fi

  install_launcher
  install_hypr_rule
  install_wrapper
  fix_audio_backend
  install_drwrap

  if [[ "$lic" == 1 ]]; then
    if license_patched; then
      ok "License patch already applied."
    else
      msg "Re-applying the license patch…"
      mq_sudo bash "$SCRIPT_DIR/PATCH/patch-resolve.sh" || warn "License patch failed."
    fi
  fi
  if [[ "$aac" == 1 && "$ed" == studio ]]; then
    install_aacfix || warn "AAC patch failed."
  fi
  if [[ "$ff" == 1 ]]; then
    install_ffmpeg_plugin || warn "FFmpeg encoder plugin failed."
  fi
  save_davinci_state "$ed" "$lic" "$aac" "$ff"
  recap "$ed"
}

# ───────────────────────── Main ─────────────────────────
main(){
  msg "install-davinci — DaVinci Resolve (Studio or free) for Omarchy"
  ((STATUS_ONLY)) && { do_status; exit 0; }
  if [[ "${MOSQUITOMARCHY_UPDATE:-0}" == 1 ]]; then
    update_davinci
    exit $?
  fi

  # Up-front: name the manually-downloaded file if it is missing. In
  # non-interactive runs (the TUI passes -y) abort before touching anything.
  if ! check_manual_installer; then
    if (( YES )) || [[ ! -t 0 ]]; then
      err "Aborting: place the DaVinci Resolve zip in $SCRIPT_DIR/ (see above) and relaunch."
      exit 1
    fi
  fi

  if (( ${#DAV_ZIPS[@]} == 0 )); then
    err "No DaVinci Resolve zip in $SCRIPT_DIR/ (expected DaVinci_Resolve_[Studio_]<version>_Linux.zip — any version)."
    davinci_download_links
    exit 1
  fi

  select_install_zip || exit 1
  local zip="$SEL_ZIP" ed="$(edition_of "$SEL_ZIP")"
  msg "Selected edition: DaVinci Resolve $(edition_label "$ed") ($(basename "$zip"))"
  echo

  install_deps || exit 1
  install_resolve "$zip" || exit 1
  install_launcher
  install_hypr_rule
  install_wrapper
  fix_audio_backend
  ((SKIP_CODECS)) && warn "--no-codecs: codec setup NOT applied." || step_codecs "$ed"
  install_drwrap
  echo

  if ((WITH_SPEKTRA)) || { ((YES == 0)) && ask "Install the free \"SpectraFilm\" OFX (film simulation) into Resolve?" n; }; then
    install_spektrafilm
  fi
  echo
  recap "$ed"


  # ─── Resolution patch (PATCH/patch-resolve.sh) ───
  local patch_script="$SCRIPT_DIR/PATCH/patch-resolve.sh"
  if [[ -x "$patch_script" ]]; then
    echo
    # Already patched? Propose to remove it (restore resolve.orig) instead of
    # silently re-applying it.
    if pcheck="$(bash "$patch_script" --check 2>/dev/null || true)"; grep -q 'binary patched' <<<"$pcheck"; then
      ok "The license patch is already applied."
      if ((YES == 0)) && ask "Remove it (restore the original resolve binary) ?" n; then
        if mq_sudo bash "$patch_script" --revert; then ok "patch removed (original binary restored)"
        else warn "patch-resolve.sh --revert returned an error."; fi
      else
        ok "Patch kept."
      fi
    elif ((YES == 0)) && ask "Patch detected, patch now ?" n; then
      msg "Running patch-resolve.sh…"
      if mq_sudo bash "$patch_script"; then
        ok "patch successful — revert possible via: sudo bash $patch_script --revert"
      else
        warn "patch-resolve.sh returned an error."
        warn "Relaunch: sudo bash $patch_script"
      fi
    else
      warn "patch-resolve.sh detected but not run. You can run it manually:"
      warn "  sudo bash $patch_script  (or --revert to restore the stock binary)"
    fi
  fi
  save_davinci_state "$ed"
}

main "$@"
