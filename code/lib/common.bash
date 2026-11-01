# lib/common.bash — small shared helpers for standalone scripts.
#
# Sourced by Tweaks/tweak-replace-evince-with-papers.sh (the old apps-module
# dispatchers are gone: apps and TUIs are one folder + setup script per entry).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/elevate.bash"  # mq_sudo

G='\033[1;32m'; B='\033[1;34m'; Y='\033[1;33m'; R='\033[1;31m'; D='\033[2m'; N='\033[0m'
msg(){ printf "${B}==>${N} %s\n" "$*"; }
ok(){ printf " ${G}✓${N} %s\n" "$*"; }
warn(){ printf " ${Y}!${N} %s\n" "$*"; }
err(){ printf " ${R}✗${N} %s\n" "$*" >&2; }
hr(){ printf '%.0s─' {1..72}; echo; }

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

require_yay(){
  if ! command -v yay >/dev/null; then
    err "No AUR helper detected (yay missing). Install it:  sudo pacman -S --needed base-devel git && git clone https://aur.archlinux.org/yay.git && cd yay && makepkg -si"
    return 1
  fi
}
