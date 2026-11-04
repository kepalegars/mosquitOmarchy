#!/usr/bin/env bash
# setup-spektrafilm.sh — SpektraFilm OFX + standalone app (AUR git)
#
# Installs BOTH parts of SpektraFilm:
#   1. the AUR package spektrafilm-git — the standalone film-simulation app
#      (installed with yay), and
#   2. the OFX plugins from a local zip (any version).
#
# Put the official SpektraFilm OFX zip in this folder before launching:
#   spektrafilm-OFX-linux.zip   (or any file whose name contains "spektrafilm")
# The script extracts it to a temporary folder, runs the install.sh the archive
# contains (system install into /usr/OFX/Plugins), then deletes the extracted
# files. Only the zip stays on disk, ready to reinstall or update later.
#
# The archive is the one from the official site:
#   https://downloads.spektrafilm.114c.de/latest/spektrafilm-OFX-linux.zip
#
# Usage :
#   ./setup-spektrafilm.sh             # interactive
#   ./setup-spektrafilm.sh -y          # non-interactive (default choices)
#   ./setup-spektrafilm.sh --status    # read-only report
#   ./setup-spektrafilm.sh --remove    # remove the OFX bundles and the app
#   ./setup-spektrafilm.sh -h          # help
#
# After installing, restart DaVinci Resolve (or the other OFX host) and look
# for SpektraFilm in Color > Open FX.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../lib/gui-run.bash"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../lib/elevate.bash"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZIP_DIR="${MQ_SPEKTRAFILM_ZIP_DIR:-$SCRIPT_DIR}"   # test override
OFX_DIR="${MQ_OFX_DIR:-/usr/OFX/Plugins}"         # test / custom-destination override
AUR_PKG="${MQ_SPEKTRAFILM_AUR_PKG:-spektrafilm-git}"  # test override
DOWNLOAD_URL="https://downloads.spektrafilm.114c.de/latest/spektrafilm-OFX-linux.zip"

YES=0 MODE=install
while (( $# )); do a="$1"; case "$a" in
  -y|--yes) YES=1 ;;
  --status) MODE=status ;;
  --remove|--uninstall) MODE=remove ;;
  -h|--help) sed -n '2,/^source /p' "$0" | head -n -1; exit 0 ;;
  *) echo "Unknown option: $a" >&2; exit 1 ;;
esac; shift; done

G='\033[1;32m'; B='\033[1;34m'; Y='\033[1;33m'; R='\033[1;31m'; N='\033[0m'
msg(){ printf "${B}==>${N} %s\n" "$*"; }
ok(){ printf " ${G}✓${N} %s\n" "$*"; }
warn(){ printf " ${Y}!${N} %s\n" "$*"; }
err(){ printf " ${R}✗${N} %s\n" "$*" >&2; }

ask(){
  local q="$1" def="${2:-y}" r
  ((YES)) && { ok "(auto) $q -> yes"; return 0; }
  read -rp "$q [$([ $def = y ] && echo Y/n || echo y/N)] " r
  r="${r:-$def}"; [[ $r =~ ^[oOyY] ]]
}

# The zip to use: any *.zip whose name mentions spektrafilm, whatever version.
find_zip(){
  local f
  for f in "$ZIP_DIR"/*.zip; do
    [[ -f $f ]] || continue
    [[ ${f,,} == *spektrafilm* ]] || continue
    printf '%s\n' "$f"; return 0
  done
  return 1
}

installed_bundles(){
  local b
  for b in "$OFX_DIR"/spektrafilm*.ofx.bundle; do
    [[ -d $b ]] && printf '%s\n' "$b"
  done
}

installed_version(){
  local cfg="$OFX_DIR/spektrafilm.ofx.bundle/Contents/Resources/update_config.json"
  [[ -r $cfg ]] || return 0
  sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$cfg" | head -n1
}

pkg_installed(){ pacman -Q "$AUR_PKG" &>/dev/null; }

install_aur(){
  if pkg_installed; then ok "$AUR_PKG already installed"; return 0; fi
  command -v yay >/dev/null 2>&1 || {
    err "yay is required to install $AUR_PKG (AUR)."
    return 1
  }
  msg "Installing $AUR_PKG (standalone SpektraFilm app) from the AUR"
  yay -S --needed --noconfirm "$AUR_PKG" || { err "Failed to install $AUR_PKG."; return 1; }
  ok "$AUR_PKG installed"
}

remove_aur(){
  pkg_installed || { ok "$AUR_PKG is not installed — nothing to remove."; return 0; }
  ask "Remove the SpektraFilm app package ($AUR_PKG)?" y || { warn "$AUR_PKG kept."; return 0; }
  mq_sudo pacman -Rns --noconfirm "$AUR_PKG" \
    || { warn "Could not remove $AUR_PKG."; return 1; }
  ok "$AUR_PKG removed."
}

status(){
  local -a found=()
  local b v aur
  while IFS= read -r b; do [[ -n $b ]] && found+=("$b"); done < <(installed_bundles)
  pkg_installed && aur=installed || aur=missing
  if (( ${#found[@]} == 0 )); then
    echo "missing: SpektraFilm OFX not installed in $OFX_DIR (app/$AUR_PKG: $aur)"
    return 0
  fi
  v="$(installed_version)"
  if (( ${#found[@]} >= 4 )) && [[ $aur == installed ]]; then
    echo "ok: SpektraFilm${v:+ $v} OFX in $OFX_DIR + $AUR_PKG app installed"
  else
    echo "partial: ${#found[@]}/4 SpektraFilm OFX bundles in $OFX_DIR (app/$AUR_PKG: $aur)"
  fi
}

remove(){
  local -a found=()
  local b have_aur=0
  while IFS= read -r b; do [[ -n $b ]] && found+=("$b"); done < <(find "$OFX_DIR" -maxdepth 1 -type d -iname 'spektrafilm*.ofx.bundle' 2>/dev/null | sort)
  pkg_installed && have_aur=1 || true
  if (( ${#found[@]} == 0 && have_aur == 0 )); then
    ok "SpektraFilm OFX and app are not installed — nothing to remove."
    return 0
  fi
  ask "Remove SpektraFilm (OFX from $OFX_DIR and the $AUR_PKG app)?" y \
    || { warn "Kept."; return 0; }
  if (( ${#found[@]} )); then
    if [[ -n ${MQ_OFX_DIR:-} ]]; then
      rm -rf -- "${found[@]}"
    else
      mq_sudo rm -rf -- "${found[@]}"
    fi
    ok "SpektraFilm OFX removed (rollback backups in $OFX_DIR are kept)."
  fi
  if ((have_aur)); then
    remove_aur || return 1
  fi
  return 0
}

if [[ $MODE == status ]]; then
  status
  exit 0
fi

if [[ $MODE == remove ]]; then
  remove
  exit 0
fi

zip="$(find_zip)" || {
  err "No SpektraFilm zip in $ZIP_DIR/"
  warn "Download $DOWNLOAD_URL"
  warn "Drop it in $ZIP_DIR/ (or in ~/Downloads, then re-run bootstrap), and retry."
  exit 1
}
command -v unzip >/dev/null 2>&1 || { err "unzip is required to read $(basename "$zip")."; exit 1; }
unzip -tq "$zip" >/dev/null 2>&1 || { err "Corrupt or incomplete zip: $zip"; exit 1; }

msg "Installing SpektraFilm OFX from $(basename "$zip")"
work="$(mktemp -d "${TMPDIR:-/tmp}/spektrafilm.XXXXXX")"
trap 'rm -rf "$work"' EXIT HUP INT TERM
unzip -oq "$zip" -d "$work" || { err "Cannot extract: $zip"; exit 1; }

installer="$(find "$work" -maxdepth 2 -type f -name install.sh -print -quit 2>/dev/null)"
[[ -n $installer ]] || { err "No install.sh inside $(basename "$zip") — not a SpektraFilm archive."; exit 1; }
find "$work" -maxdepth 2 -type d -iname 'spektrafilm*.ofx.bundle' -print -quit 2>/dev/null | grep -q . \
  || { err "No spektrafilm*.ofx.bundle inside $(basename "$zip") — not a SpektraFilm archive."; exit 1; }

install_aur || exit 1

if [[ -n ${MQ_OFX_DIR:-} ]]; then
  bash "$installer" --dest "$OFX_DIR" --no-prewarm
else
  mq_sudo bash "$installer" --system --no-prewarm
fi

ok "SpektraFilm OFX installed in $OFX_DIR."
ok "SpektraFilm standalone app installed ($AUR_PKG)."
warn "Restart DaVinci Resolve (or the other OFX host) so it rescans plugins."
warm="$OFX_DIR/spektrafilm.ofx.bundle/Contents/Resources/Tools/warm_pipeline_cache.sh"
[[ -x $warm ]] && echo " • Optional Vulkan cache prewarm: $warm"
echo " • The extracted archive was deleted; $(basename "$zip") is kept for reinstalling or updating."
