#!/usr/bin/env bash
# uninstall-davinci.sh — Removes DaVinci Resolve
#
# Removes /opt/resolve (sudo required), the launcher, the menu shortcut, the
# optional libav patch (back to stock libs) and the SpectraFilm OFX.
# The DATA (projects, LUTs, preferences) in ~/.local/share and
# ~/.config/Blackmagic Design are kept by default.
#
# Usage :
#   ./uninstall-davinci.sh            # interactive
#   ./uninstall-davinci.sh -y         # remove everything without confirmation
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/gui-run.bash"  # gui-run: reopen in a terminal when launched from a file manager
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/elevate.bash"  # mq_sudo: native pkexec prompt when not root
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVE_DIR=/opt/resolve
LAUNCHER="$HOME/.local/bin/davinci-resolve"
OFX_PLUGIN_DIR=/usr/OFX/Plugins

YES=0
while (( $# )); do a="$1"; case "$a" in
  -y|--yes) YES=1 ;;
  -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
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

# restores the stock libs if the libav patch was applied (symlinks)
restore_libav() {
  local lib
  for lib in libavcodec libavformat libavutil; do
    [[ -L "$RESOLVE_DIR/libs/$lib.so" ]] || continue
    if [[ -e "$RESOLVE_DIR/libs/$lib.so.stock" ]]; then
      mq_sudo rm -f "$RESOLVE_DIR/libs/$lib.so"
      mq_sudo mv -f "$RESOLVE_DIR/libs/$lib.so.stock" "$RESOLVE_DIR/libs/$lib.so" 2>/dev/null
      ok "$lib.so restored (stock)"
    else
      mq_sudo rm -f "$RESOLVE_DIR/libs/$lib.so"
      ok "$lib.so removed (symlink)"
    fi
  done
}

hr
msg "Uninstalling DaVinci Resolve"

found=0
[[ -x /opt/resolve/bin/resolve ]] && found=1
[[ -x "$LAUNCHER" ]] && found=1
[[ -L /opt/resolve/libs/libavcodec.so ]] && found=1
[[ -d "$OFX_PLUGIN_DIR" ]] && find "$OFX_PLUGIN_DIR" -maxdepth 1 -iname '*spektra*' | grep -q . && found=1

if (( ! found )); then
  warn "Nothing to remove — DaVinci Resolve is not installed."
  hr; exit 0
fi

# 1) Launcher + menu shortcut
if [[ -x "$LAUNCHER" ]] && ask "Remove the launcher (~/.local/bin/davinci-resolve) and the menu shortcut?" y; then
  rm -f "$LAUNCHER" "$HOME/.local/bin/davinci-resolve-rocm" "$HOME/.local/bin/davinci-resolve-mesa"
  rm -f "$HOME/.local/share/applications/davinci-resolve.desktop" \
        "$HOME/.local/share/applications/DaVinciResolve.desktop"
  command -v update-desktop-database >/dev/null 2>&1 \
    && update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
  ok "Launcher + shortcuts removed"
fi

# 2) System part: libav patch + /opt/resolve (sudo)
system_ok=0
if [[ -d /opt/resolve ]]; then
  if [[ $EUID -eq 0 || -n "${SUDO_USER:-}" ]] || mq_sudo -v 2>/dev/null; then
    system_ok=1
  fi
  if (( system_ok )); then
    if ask "Remove /opt/resolve (the application)?" y; then
      restore_libav
      mq_sudo rm -rf "$RESOLVE_DIR"
      ok "$RESOLVE_DIR removed"
    else
      restore_libav || true
      warn "$RESOLVE_DIR kept (the libav patch has been removed)"
    fi
  else
    warn "System part ($RESOLVE_DIR) not removed: run  sudo bash $0"
  fi
fi

# 3) SpectraFilm OFX
if [[ -d "$OFX_PLUGIN_DIR" ]] && find "$OFX_PLUGIN_DIR" -maxdepth 1 -iname '*spektra*' | grep -q .; then
  if ask "Remove the SpectraFilm OFX ($OFX_PLUGIN_DIR)?" y; then
    if [[ $EUID -eq 0 || -n "${SUDO_USER:-}" ]] || mq_sudo -v 2>/dev/null; then
      mq_sudo bash -c "rm -rf '$OFX_PLUGIN_DIR'/*[Ss]pektra*"
      ok "SpectraFilm OFX removed"
    else
      warn "SpectraFilm OFX not removed: sudo required —  sudo rm -rf '$OFX_PLUGIN_DIR'/*[Ss]pektra*"
    fi
  fi
fi

echo
ok "Done — the data (projects, LUTs, preferences) is kept."
warn "To also wipe everything:  rm -rf ~/.local/share/DaVinciResolve ~/.local/share/BlackmagicDesign ~/.config/Blackmagic\ Design"
hr
