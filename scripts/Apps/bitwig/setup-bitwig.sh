#!/usr/bin/env bash
# setup-bitwig.sh — Installs Bitwig Studio 6.0 Beta 6 via AUR on Omarchy.
#
# Clones the AUR PKGBUILD bitwig-studio, pins it to version 6.0 Beta 6,
# uses the local .deb provided in the scripts folder as source,
# builds and installs the package, then ASKS whether to apply the custom
# bitwig.jar (PATCH/patch-bitwig.sh, license) to /opt/bitwig-studio/bin.
#
# Usage:
#   ./setup-bitwig.sh            # interactive
#   ./setup-bitwig.sh -y         # everything with the default choices
#   ./setup-bitwig.sh --dry-run  # simulation (no modification)
#
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/gui-run.bash"  # gui-run: reopen in a terminal when launched from a file manager
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/elevate.bash"  # mq_sudo: native pkexec prompt when not root
set -euo pipefail

# ─── Constants ───────────────────────────────────────────────────────────────
BW_VERSION="6.0beta6"
BW_DEB_SLUG="6.0-beta-6"
BW_APP_ID="com.bitwig.BitwigStudio"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ─── CLI parsing ──────────────────────────────────────────────────────────────
YES=0 DRY=0
for a in "$@"; do case "$a" in
  -y|--yes)        YES=1 ;;
  --dry-run)       DRY=1 ;;
  -h|--help)       sed -n '2,16p' "$0"; exit 0 ;;
  *)               echo "Unknown option: $a (supported: -y --dry-run)" >&2; exit 1 ;;
esac; done

# ─── Helpers ──────────────────────────────────────────────────────────────────
G='\033[1;32m'; B='\033[1;34m'; Y='\033[1;33m'; R='\033[1;31m'; N='\033[0m'
msg(){ printf "${B}==>${N} %s\n" "$*"; }
ok(){ printf " ${G}✓${N} %s\n" "$*"; }
warn(){ printf " ${Y}!${N} %s\n" "$*"; }
err(){ printf " ${R}✗${N} %s\n" "$*" >&2; }
hr(){ printf '%.0s─' {1..72}; echo; }

run(){
  if ((DRY)); then printf "     [dry-run] "; printf '%q ' "$@"; echo
  else "$@" || { err "Failed: $*"; return 1; }; fi
}
ask(){
  ((YES)) && { ok "(auto) $1 -> yes"; return 0; }
  ((DRY)) && { msg "[dry-run] question ignored: $1"; return 0; }
  local r; read -rp "$1 [Y/n] " r; [[ ${r:-y} =~ ^[oOyY] ]]
}
pkg_has(){ pacman -Q "$1" &>/dev/null; }

# ─── Detection of the existing installation ──────────────────────────────────
detect_installed(){
  INSTALLED_AUR=()
  INSTALLED_FLATPAK=0
  INSTALLED_DEB=0

  for p in bitwig-studio bitwig-studio-beta bitwig-studio-legacy; do
    pacman -Q "$p" &>/dev/null && INSTALLED_AUR+=("$p")
  done
  if flatpak list 2>/dev/null | grep -q "$BW_APP_ID"; then
    INSTALLED_FLATPAK=1
  fi
  if command -v dpkg &>/dev/null && dpkg -l bitwig-studio 2>/dev/null | grep -q "^ii"; then
    INSTALLED_DEB=1
  fi
  ((${#INSTALLED_AUR[@]} > 0)) || ((INSTALLED_FLATPAK)) || ((INSTALLED_DEB))
}

# ─── Cleanup of the old installations ────────────────────────────────────────
ORPHAN_FILES=(
  /usr/share/metainfo/com.bitwig.BitwigStudio.appdata.xml
  /usr/share/mime/packages/com.bitwig.BitwigStudio.xml
  /usr/share/applications/com.bitwig.BitwigStudio.desktop
  /usr/bin/bitwig-studio
  /usr/share/icons/hicolor/*/apps/com.bitwig.BitwigStudio.*
  /usr/share/icons/hicolor/scalable/mimetypes/com.bitwig.BitwigStudio.*
  /usr/share/icons/hicolor/scalable/mimetypes/*dawproject.svg
  /opt/bitwig-studio
)

detect_orphans(){
  ORPHANS=()
  local f
  for pat in "${ORPHAN_FILES[@]}"; do
    # expand the glob (the icons have wildcards)
    for f in $pat; do
      # -e: exists ; -L: link (even broken)
      [[ -e "$f" || -L "$f" ]] && ORPHANS+=("$f")
    done
  done
  ((${#ORPHANS[@]} > 0))
}

cleanup_old(){
  # Check whether a real installation is present
  detect_installed || true
  # Check whether orphan files remain (even without an installed package)
  detect_orphans || true

  if (( ${#INSTALLED_AUR[@]} == 0 )) && (( ! INSTALLED_FLATPAK )) \
     && (( ! INSTALLED_DEB )) && (( ${#ORPHANS[@]} == 0 )); then
    return 0
  fi

  warn "Detected Bitwig presences:"
  ((${#INSTALLED_AUR[@]}))  && echo "   - AUR  : ${INSTALLED_AUR[*]}"
  ((INSTALLED_FLATPAK))     && echo "   - Flatpak : $BW_APP_ID"
  ((INSTALLED_DEB))         && echo "   - .deb (dpkg) : bitwig-studio"
  ((${#ORPHANS[@]}))        && { echo "   - Orphan files:"; for f in "${ORPHANS[@]}"; do echo "       $f"; done; }

  if ! ask "Delete everything and install Bitwig $BW_VERSION ?" y; then
    warn "Aborted."; exit 0
  fi

  for p in "${INSTALLED_AUR[@]}"; do
    msg "AUR uninstall: $p"
    run mq_sudo pacman -R --noconfirm "$p"
  done
  if ((INSTALLED_FLATPAK)); then
    msg "Flatpak uninstall: $BW_APP_ID"
    run flatpak uninstall --user --assumeyes "$BW_APP_ID" 2>/dev/null || true
  fi
  if ((INSTALLED_DEB)); then
    msg ".deb uninstall: bitwig-studio"
    run mq_sudo dpkg -r bitwig-studio
  fi

  # Clean up the orphan files (leftovers from previous installations)
  if ((${#ORPHANS[@]})); then
    msg "Removing orphan files..."
    local f
    for f in "${ORPHANS[@]}"; do
      run mq_sudo rm -rf "$f"
    done
  fi
}

# ─── Installation via AUR ─────────────────────────────────────────────────────
install_aur(){
  command -v makepkg >/dev/null || { err "makepkg not found (base-devel required)."; return 1; }

  # Look for the local .deb
  local deb_file=""
  local f
  while IFS= read -r -d '' f; do
    deb_file="$f"; break
  done < <(find "$SCRIPT_DIR" -maxdepth 1 -type f -iname "bitwig*${BW_DEB_SLUG}*.deb" -print0 2>/dev/null)

  if [[ -z "$deb_file" ]] || [[ ! -f "$deb_file" ]]; then
    # Search more broadly
    while IFS= read -r -d '' f; do
      deb_file="$f"; break
    done < <(find "$SCRIPT_DIR" -maxdepth 1 -type f -iname 'bitwig*.deb' -print0 2>/dev/null)
  fi

  if [[ -z "$deb_file" ]] || [[ ! -f "$deb_file" ]]; then
    err "No bitwig .deb found in $SCRIPT_DIR"
    return 1
  fi

  ok "Using the .deb: $(basename "$deb_file") ($(du -h "$deb_file" | cut -f1))"

  # Build (in a stable folder, not the cleaned temp)
  local build_dir="$SCRIPT_DIR/.bitwig-build"
  rm -rf "$build_dir"
  git clone -q https://aur.archlinux.org/bitwig-studio.git "$build_dir" \
    || { err "AUR clone failed"; return 1; }

  # Pin to the requested version
  sed -i "s/^pkgver=.*/pkgver='$BW_VERSION'/" "$build_dir/PKGBUILD"
  sed -i "s/^_pkgver=.*/_pkgver='$BW_DEB_SLUG'/" "$build_dir/PKGBUILD"
  sed -i 's#^source=.*#source=("bitwig-studio-${_pkgver}.deb")#' "$build_dir/PKGBUILD"

  # Copy the .deb into the build folder
  local dest_deb="$build_dir/bitwig-studio-${BW_DEB_SLUG}.deb"
  cp -f "$deb_file" "$dest_deb"

  # Recompute the sha256sums
  if command -v updpkgsums &>/dev/null; then
    msg "Recomputing the sha256sums..."
    ( cd "$build_dir" && updpkgsums )
  else
    warn "updpkgsums missing — checksum left as is."
  fi

  # Build and install
  msg "Building and installing (let it run)..."
  local pkg_file
  ( cd "$build_dir" && makepkg --noconfirm --skipchecksums --skippgpcheck 2>&1 ) \
    || { err "AUR build failed"; return 1; }
  pkg_file="$(find "$build_dir" -name '*.pkg.tar.zst' | head -1)"

  if [[ -z "$pkg_file" ]] || [[ ! -f "$pkg_file" ]]; then
    err "AUR build failed"
    return 1
  fi
  ok "Package built: $(basename "$pkg_file")"

  # Install the built package via sudo pacman -U (more reliable than yay/paru
  # for a local package; asks for the sudo password)
  msg "Installing via pacman -U..."
  mq_sudo pacman -U "$pkg_file" --noconfirm 2>&1 || { err "Installation failed (sudo password required ?)"; return 1; }

  # Clean up the build folder once installed
  rm -rf "$build_dir"

  pkg_has bitwig-studio || { err "bitwig-studio absent from pacman after the build."; return 1; }
  ok "Bitwig $(pacman -Q bitwig-studio | awk '{print $2}') installed via AUR"
}

# ─── Custom bitwig.jar (PATCH/patch-bitwig.sh) ───────────────────────
# The custom jar ships in PATCH/. The standalone patch-bitwig.sh copies it
# to /opt/bitwig-studio/bin/bitwig.jar, keeping the original as .stock.
# Asked at the END of the installation.
apply_custom_jar(){
  local patch_script="$SCRIPT_DIR/PATCH/patch-bitwig.sh"
  if [[ ! -x "$patch_script" ]]; then
    warn "Custom jar not found — original bitwig.jar kept."
    return 0
  fi
  if ((DRY)); then
    msg "[dry-run] would run: sudo bash \"$patch_script\""
    return 0
  fi
  # Driven by the mosquitOmarchy TUI: never auto-apply here. The TUI proposes the
  # patch (only when the script is present) after the install.
  if [[ -n ${MOSQUITOMARCHY_TUI:-} ]]; then
    ok "Custom jar available — the TUI proposes the patch after the install."
    return 0
  fi
  # Already applied? Propose to revert to the stock jar instead of silently
  # re-applying it.
  if bash "$patch_script" --check 2>/dev/null | grep -q 'already in place'; then
    ok "The custom bitwig.jar is already applied."
    if ((YES == 0)) && ask "Remove the custom jar (restore the stock bitwig.jar) ?" n; then
      mq_sudo bash "$patch_script" --revert || warn "The stock jar was not restored."
    else
      ok "Patch kept."
    fi
    return 0
  fi
  if ((YES)) || ask "Patch detected, patch now ?" y; then
    mq_sudo bash "$patch_script" || warn "The custom jar was not applied."
  else
    warn "Patch not run — apply it manually:  sudo bash \"$patch_script\""
  fi
}

# ─── Blocking the updates (IgnorePkg) ────────────────────────────────────────
block_updates(){
  msg "Blocking the bitwig-studio updates (IgnorePkg)"
  local conf="/etc/pacman.conf"
  local bound
  bound="$(grep -n "^\[" "$conf" | sed -n '2p' | cut -d: -f1)"
  [[ -z "$bound" ]] && bound="$(grep -n "^\[" "$conf" | head -1 | cut -d: -f1)"
  if awk -v n="$bound" 'NR<n && /^IgnorePkg/ {found=1} END{exit !found}' "$conf"; then
    ok "bitwig-studio already in IgnorePkg"
    return 0
  fi
  if ((DRY)); then ok "(dry-run) IgnorePkg would be added"; return 0; fi
  mq_sudo sed -i '/^IgnorePkg/d' "$conf"
  mq_sudo sed -i "/^\[options\]/a IgnorePkg = bitwig-studio" "$conf"
  ok "Bitwig updates blocked"
}

# ─── Manual installer check (at opening) ─────────────────────────────────────
# Bitwig Studio is not public: download the .deb from your Bitwig account and
# drop it here (any version: the script finds bitwig*.deb). Warn up front and
# name the expected file when it is missing.
check_manual_installer(){
  local found="" f
  while IFS= read -r -d '' f; do found="$f"; break; done \
    < <(find "$SCRIPT_DIR" -maxdepth 1 -type f -iname 'bitwig*.deb' -print0 2>/dev/null)
  if [[ -n $found ]]; then
    ok "Bitwig installer present: $(basename "$found")"
    return 0
  fi
  hr
  warn "Missing manual download — no Bitwig Studio .deb in $SCRIPT_DIR/"
  warn "  Expected file: bitwig-studio-*.deb (any version)"
  warn "  → download it from your Bitwig account and drop the .deb here:"
  warn "    https://www.bitwig.com/download/"
  warn "    $SCRIPT_DIR/"
  hr
  return 1
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main(){
  hr
  msg "Installing Bitwig Studio $BW_VERSION (AUR)"
  hr

  # Up-front: name the manually-downloaded .deb if it is missing. In
  # non-interactive runs (the TUI passes -y) abort before touching anything.
  if ! check_manual_installer; then
    if (( YES )) || [[ ! -t 0 ]]; then
      err "Aborting: place the Bitwig .deb in $SCRIPT_DIR/ (see above) and relaunch."
      exit 1
    fi
  fi

  cleanup_old
  install_aur
  apply_custom_jar
  block_updates

  hr
  ok "Bitwig Studio $BW_VERSION installed"
  echo ""
  echo "  Launch: bitwig-studio"
  echo ""
  warn "Remember to disable the updates in Bitwig:"
  echo "     Dashboard > Settings > Misc > uncheck auto-update"
  hr
}

main "$@"
