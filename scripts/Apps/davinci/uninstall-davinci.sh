#!/usr/bin/env bash
# uninstall-davinci.sh — Removes DaVinci Resolve
#
# Removes /opt/resolve (sudo required), the launcher, the menu shortcut, the
# Hyprland tiling rule, the optional AAC patch (back to the stock binary/libs)
# and the SpectraFilm OFX.
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
HYPR="$HOME/.config/hypr/hyprland.lua"
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

# restores the stock binary and libav libs if resolve-aacfix was applied
restore_aacfix() {
  [[ -e "$RESOLVE_DIR/bin/resolve.aac-orig" ]] || return 0
  mq_sudo mv -f "$RESOLVE_DIR/bin/resolve.aac-orig" "$RESOLVE_DIR/bin/resolve" \
    && ok "resolve binary restored (AAC patch removed)"
  if [[ -d "$RESOLVE_DIR/libs/_bmd_orig" ]]; then
    mq_sudo cp -a "$RESOLVE_DIR/libs/_bmd_orig/." "$RESOLVE_DIR/libs/" \
      && ok "stock libav libs restored"
  fi
}

hr
msg "Uninstalling DaVinci Resolve"

found=0
[[ -x /opt/resolve/bin/resolve ]] && found=1
[[ -x "$LAUNCHER" ]] && found=1
[[ -e "$HOME/.local/share/applications/davinci-resolve-wrapper.desktop" ]] && found=1
[[ -f "$HYPR" ]] && grep -qF -- '-- >>> mosquito-davinci-tiling >>>' "$HYPR" && found=1
[[ -e "${XDG_STATE_HOME:-$HOME/.local/state}/mosquitomarchy/davinci-state" ]] && found=1
[[ -e /opt/resolve/bin/resolve.aac-orig ]] && found=1
[[ -d "$OFX_PLUGIN_DIR" ]] && find "$OFX_PLUGIN_DIR" -maxdepth 1 -iname '*spektra*' | grep -q . && found=1

if (( ! found )); then
  warn "Nothing to remove — DaVinci Resolve is not installed."
  hr; exit 0
fi

# 1) Launcher + menu shortcut
rm -f "$HOME/.local/share/applications/davinci-resolve-wrapper.desktop"
rm -f "${XDG_STATE_HOME:-$HOME/.local/state}/mosquitomarchy/davinci-state"
if { [[ -x "$LAUNCHER" ]] || grep -qF -- '-- >>> mosquito-davinci-tiling >>>' "$HYPR" 2>/dev/null; } \
   && ask "Remove the launcher (~/.local/bin/davinci-resolve), the menu shortcut and the Hyprland tiling rule?" y; then
  rm -f "$LAUNCHER" "$HOME/.local/bin/davinci-resolve-rocm" "$HOME/.local/bin/davinci-resolve-mesa"
  rm -f "$HOME/.local/share/applications/davinci-resolve.desktop" \
        "$HOME/.local/share/applications/DaVinciResolve.desktop"
  if [[ -L /usr/local/bin/resolve-omarchy ]]; then
    mq_sudo rm -f /usr/local/bin/resolve-omarchy && ok "System wrapper removed"
  fi
  command -v update-desktop-database >/dev/null 2>&1 \
    && update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
  ok "Launcher + shortcuts removed"
  if [[ -f "$HYPR" ]] && grep -qF -- '-- >>> mosquito-davinci-tiling >>>' "$HYPR"; then
    sed -i '/-- >>> mosquito-davinci-tiling >>>/,/-- <<< mosquito-davinci-tiling <<</d' "$HYPR"
    hyprctl reload >/dev/null 2>&1 || true
    ok "Hyprland tiling rule removed"
  fi
fi

# 2) System part: AAC patch + /opt/resolve (sudo)
system_ok=0
if [[ -d /opt/resolve ]]; then
  if [[ $EUID -eq 0 || -n "${SUDO_USER:-}" ]] || mq_sudo -v 2>/dev/null; then
    system_ok=1
  fi
  if (( system_ok )); then
    if ask "Remove /opt/resolve (the application)?" y; then
      restore_aacfix
      mq_sudo rm -rf "$RESOLVE_DIR"
      ok "$RESOLVE_DIR removed"
    else
      restore_aacfix || true
      warn "$RESOLVE_DIR kept (the AAC patch has been removed)"
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

# 4) DRwrap integration (service + generated launcher; package and converted files kept)
if command -v drwrap >/dev/null 2>&1; then
  if ask "Remove the DRwrap service/launcher integration (package and converted files kept)?" y; then
    drwrap setup --remove >/dev/null 2>&1 && ok "DRwrap integration removed" || warn "drwrap setup --remove failed"
  fi
fi

echo
ok "Done — the data (projects, LUTs, preferences) is kept."
warn "To also wipe everything:  rm -rf ~/.local/share/DaVinciResolve ~/.local/share/BlackmagicDesign ~/.config/Blackmagic\ Design"
hr
