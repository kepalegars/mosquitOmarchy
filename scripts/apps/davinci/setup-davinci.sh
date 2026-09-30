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
# H.264/H.265: NATIVE codecs in Resolve Studio. In the free version, Resolve
# Linux does NOT ship H.264/H.265/AAC (commercial license): the script then
# offers the "libav" patch (symlinks the system libavcodec/libavformat/libavutil
# into /opt/resolve — experimental and reversible) and reminds about DNxHR
# transcoding. For Studio, an FFmpeg encoding plugin (x264/x265/SVT-AV1/VAAPI)
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
#   ./setup-davinci.sh --scale 1.5         # UI zoom (default 1.0)
#   ./setup-davinci.sh --no-codecs         # leave H.264/H.265 codecs alone
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

YES=0 STATUS_ONLY=0 FORCE_ED="" WITH_SPEKTRA=0 SKIP_CODECS=0 KEEP_MESA=0 SCALE=1.0
while (( $# )); do a="$1"; case "$a" in
  -y|--yes) YES=1 ;;
  --status) STATUS_ONLY=1 ;;
  --studio|--free) FORCE_ED="${a#--}" ;;
  --with-spektrafilm) WITH_SPEKTRA=1 ;;
  --no-codecs) SKIP_CODECS=1 ;;
  --keep-mesa) KEEP_MESA=1 ;;
  --scale) SCALE="$2"; shift ;;
  -h|--help) sed -n '2,/^# Launched from a file manager/p' "$0" | head -n -1 || true; exit 0 ;;
  *) echo "Unknown option: $a" >&2; exit 1 ;;
esac; shift; done
[[ "$SCALE" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "invalid --scale: $SCALE (expected a number)" >&2; exit 2; }

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
  if [[ -L "$RESOLVE_DIR/libs/libavcodec.so" ]]; then ok "libav patch    : applied (system codecs in /opt/resolve/libs)"
  else warn "libav patch    : not applied"; fi
  if [[ -d "$RESOLVE_DIR/IOPlugins/ffmpeg_encoder_plugin.dvcp.bundle" ]]; then ok "FFmpeg encoder plugin : installed (Studio)"
  else warn "FFmpeg encoder plugin : absent"; fi
  if [[ -d "$OFX_PLUGIN_DIR" ]] && find "$OFX_PLUGIN_DIR" -maxdepth 1 -iname '*spektra*' -print -quit 2>/dev/null | grep -q .; then
    ok "SpectraFilm OFX : installed"
  else
    warn "SpectraFilm OFX : absent"
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
DEPS=(gtk3 apr ocl-icd libxcrypt-compat librsvg libgudev glu clinfo unzip curl pciutils)

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
DEFAULT_SCALE="$SCALE"

# Cleans residual instance locks (after a crash) that block relaunching.
if ! pgrep -f "\$RESOLVE_DIR/bin/resolve" >/dev/null 2>&1; then
  rm -f /tmp/qtsingleapp-DaVinc-* /tmp/qtsingleapp-DaVinc-*-lockfile /var/tmp/davinci_socket
fi

# Native UI under Wayland not supported: force XWayland (xcb).
export QT_QPA_PLATFORM=xcb QT_AUTO_SCREEN_SCALE_FACTOR=1
# ROCm OpenCL (AMD): points the driver if present, otherwise system ICD (GPU detected at install).
[[ -r /opt/rocm/lib/libamdocl64.so ]] && export OCL_ICD_FILENAMES=/opt/rocm/lib/libamdocl64.so
# UI zoom, overridden by DAVINCI_SCALE (e.g. DAVINCI_SCALE=1.25 davinci-resolve).
export QT_SCALE_FACTOR="\${DAVINCI_SCALE:-\$DEFAULT_SCALE}"

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

# ───────────────────────── H.264 / H.265 ─────────────────────────
ensure_ffmpeg(){
  if pkg_has ffmpeg; then ok "ffmpeg already present (system codecs)"; return 0; fi
  mq_sudo -v || { warn "Password required to install ffmpeg."; return 1; }
  mq_sudo pacman -S --needed --noconfirm ffmpeg && ok "ffmpeg installed" || { warn "Failed to install ffmpeg."; return 1; }
}

apply_libav_fix(){
  # Known fix for the FREE version: symlinks the system ffmpeg libs
  # (provided by the ffmpeg package) into /opt/resolve/libs, which re-enables
  # H.264/H.265/AAC. Experimental, fully reversible (stock files are kept as .stock).
  local lib nov s missed=0
  for lib in libavcodec libavformat libavutil; do
    if [[ ! -e "$RESOLVE_DIR/libs/$lib.so" ]]; then
      warn "$lib.so absent from $RESOLVE_DIR/libs — ignored"
      continue
    fi
    s="$(ls /usr/lib/$lib.so.* 2>/dev/null | sort -V | tail -n1)"
    if [[ -z "$s" ]]; then
      warn "System lib $lib not found — install ffmpeg."
      missed=1
      continue
    fi
    if [[ ! -L "$RESOLVE_DIR/libs/$lib.so" ]]; then
      mq_sudo mv -f "$RESOLVE_DIR/libs/$lib.so" "$RESOLVE_DIR/libs/$lib.so.stock" 2>/dev/null \
        || { warn "Not writable: $RESOLVE_DIR/libs/$lib.so"; continue; }
    fi
    mq_sudo ln -sf "$s" "$RESOLVE_DIR/libs/$lib.so"
    ok "$lib.so -> $(basename "$s")"
  done
  (( missed )) && return 1
  ok "libav patch applied — test the H.264 import/export of a clip."
}

step_codecs(){
  local ed="$1"
  if [[ "$ed" == studio ]]; then
    ok "Resolve Studio: H.264 / H.265 / AAC natively supported — nothing to do."
    if (( YES )) || ask "Also add the FFmpeg encoding plugin (x264/x265/SVT-AV1/VAAPI)?" n; then
      install_ffmpeg_plugin
    fi
  else
    warn "FREE Resolve Linux: no H.264/H.265/AAC (commercial license restriction)."
    if (( YES )) || ask "Install ffmpeg + apply the \"libav\" patch (H.264/H.265/AAC)? [experimental, reversible]" y; then
      ensure_ffmpeg || true
      apply_libav_fix
    fi
    echo
    warn "Reliable alternative (no patch): transcode your sources to DNxHR before editing:"
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
    echo " • H.264/H.265/AAC: native (Studio)."
  else
    echo " • H.264/H.265/AAC: libav patch applied (experimental)."
    echo "   → re-test after every Resolve update (re-run this script)."
  fi
  echo " • First-run config: Preferences > System > Memory & GPU (OpenCL auto-detected)."
  echo " • Project / LUT data: kept in ~/.local/share, ~/.config/Blackmagic Design."
  echo " • Uninstall: ./uninstall-davinci.sh"
  hr
}

# ───────────────────────── Main ─────────────────────────
main(){
  msg "install-davinci — DaVinci Resolve (Studio or free) for Omarchy"
  ((STATUS_ONLY)) && { do_status; exit 0; }

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
  ((SKIP_CODECS)) && warn "--no-codecs: H.264/H.265 patches NOT applied." || step_codecs "$ed"
  echo

  if ((WITH_SPEKTRA)) || { ((YES == 0)) && ask "Install the free \"SpectraFilm\" OFX (film simulation) into Resolve?" n; }; then
    install_spektrafilm
  fi
  echo
  recap "$ed"

  # ─── Optional companion tool: omarchy-resolve (28allday) ───
  # Asked here, BEFORE the patch step below, but actually installed AFTER it
  # (at the end of main) — the two are independent decisions and neither
  # should block or reorder the other.
  local want_omarchy_resolve=0
  if ((YES == 0)) && ask "Also install \"omarchy-resolve\" (28allday) — a bundled panel to manage, repair and diagnose this DaVinci install ?" n; then
    want_omarchy_resolve=1
  fi

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

  # ─── omarchy-resolve install (asked above; run after the patch step) ───
  if ((want_omarchy_resolve)); then
    echo
    msg "Installing omarchy-resolve (28allday)…"
    if ! command -v omarchy >/dev/null 2>&1; then
      warn "omarchy CLI not found — cannot install omarchy-resolve as a shell plugin."
    elif omarchy plugin add https://github.com/28allday/omarchy-resolve.git --enable --yes; then
      ok "omarchy-resolve installed."
      command -v omarchy-shell >/dev/null 2>&1 && { omarchy-shell -q nosignal.davinci-resolve show status & disown; }
      if command -v omarchy-notification-send >/dev/null 2>&1; then
        omarchy-notification-send -g "🎬" "DaVinci Resolve installed" \
          "Manage, repair and diagnose it anytime from the bundled panel (omarchy-shell shell toggle nosignal.davinci-resolve)." \
          -t 10000 >/dev/null 2>&1 || true
      else
        notify-send -i video-x-generic "DaVinci Resolve installed" \
          "Manage, repair and diagnose it anytime from the bundled DaVinci panel." 2>/dev/null || true
      fi
    else
      warn "omarchy-resolve install failed. Retry manually:"
      warn "  omarchy plugin add https://github.com/28allday/omarchy-resolve.git --enable"
    fi
  fi
}

main "$@"