#!/usr/bin/env bash
# lib-tui.sh — shared install/remove for the per-TUI entry scripts of code/modules/TUIs.
#
# Each setup-<name>.sh declares its package and optional setup-<stem>-menu.sh
# companion, then calls tui_main. No catalog: the folder is the list.
for __a in "$@"; do
  case $__a in -y|--yes|--status|--uninstall|--remove|-h|--help) export GUI_RUN_EXEC=1 ;; esac
done
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/gui-run.bash"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/elevate.bash"

pkg_has(){ pacman -Q "$1" &>/dev/null; }

# AUR Python packages are built with the system Python, and some of them
# (python-plotext, pulled in by bagels) forget to declare setuptools, which
# Python no longer bundles. Without it the yay build dies with
# "ModuleNotFoundError: No module named 'setuptools'".
aur_build_deps(){
  command -v python >/dev/null 2>&1 || return 0
  python -c 'import setuptools' >/dev/null 2>&1 && return 0
  mq_sudo pacman -S --needed --noconfirm python-setuptools \
    || { echo "python-setuptools: install failed" >&2; return 1; }
}

tui_main(){
  local pkg="$1" stem="$2"; shift 2
  local yes=0 uninstall=0 status=0 menu="$SCRIPT_DIR/setup-$stem-menu.sh"
  for a in "$@"; do case "$a" in
    -y|--yes) yes=1 ;;
    --uninstall|--remove) uninstall=1 ;;
    --status) status=1 ;;
    -h|--help) sed -n '2,12p' "$SCRIPT_DIR/setup-$(basename "$0" .sh | sed 's/^setup-//').sh"; exit 0 ;;
    *) echo "Unknown option: $a" >&2; exit 1 ;;
  esac; done

  if ((status)); then
    pkg_has "$pkg" && echo ok || echo missing
    return 0
  fi

  if ((uninstall)); then
    [[ -x $menu ]] && "$menu" --remove || true
    if pkg_has "$pkg"; then
      mq_sudo pacman -Rns --noconfirm "$pkg" || { echo "$pkg: removal failed" >&2; return 1; }
      echo "$pkg: removed"
    else
      echo "$pkg: not installed"
    fi
    return 0
  fi

  if ! pkg_has "$pkg"; then
    command -v yay >/dev/null 2>&1 || {
      echo "yay is required to install $pkg" >&2
      return 1
    }
    aur_build_deps || return 1
    yay -S --needed --noconfirm "$pkg" || { echo "$pkg: install failed" >&2; return 1; }
  fi
  # The companion owns the launcher/icon/menu finery; re-running it is idempotent.
  [[ -x $menu ]] && "$menu" || true
  echo "$pkg: installed"
}
