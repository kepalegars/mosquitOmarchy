#!/usr/bin/env bash
# setup-strata.sh — install Strata and make it the file manager everywhere.
#
# Strata (https://stratafiles.io, MIT) is a GTK4 file manager, packaged in the
# Omarchy repository. This module installs that package and adds the per-user
# wiring that makes it the default for anything that opens a folder:
#
#   - folder association  (inode/directory, i.e. xdg-open and "Open with")
#   - FileManager1        ("Open file location" from browsers/GTK apps)
#   - file chooser        (portal Open/Save dialogs)
#   - Omarchy keybinds    (SUPER+SHIFT+F and SUPER+ALT+SHIFT+F)
#
# Everything here is reversible: --remove undoes the wiring, --uninstall also
# removes the package.
#
# Usage:
#   ./setup-strata.sh              # install
#   ./setup-strata.sh -y           # non-interactive install
#   ./setup-strata.sh --status
#   ./setup-strata.sh --remove     # undo the wiring, keep the package
#   ./setup-strata.sh --uninstall  # undo the wiring + remove the package
# =============================================================================
for __a in "$@"; do
  case $__a in -y|--yes|--remove|--uninstall|--status|-h|--help) export GUI_RUN_EXEC=1 ;; esac
done
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../lib/gui-run.bash"  # gui-run: reopen in a terminal when launched from a file manager
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../lib/elevate.bash"  # mq_sudo: native pkexec prompt when not root
set -euo pipefail

info() { echo -e "\033[1;34m==>\033[0m $*"; }
ok()   { echo -e "\033[1;32m ✓\033[0m $*"; }
warn() { echo -e "\033[1;33m !\033[0m $*"; }
err()  { echo -e "\033[1;31m ✗\033[0m $*" >&2; }

REMOVE=false UNINSTALL=false STATUS=false
for a in "$@"; do case "$a" in
  -y|--yes)    ;;
  --remove)    REMOVE=true ;;
  --uninstall) UNINSTALL=true ;;
  --status)    STATUS=true ;;
  -h|--help)   sed -n '2,22p' "$0"; exit 0 ;;
  *)           echo "Unknown option: $a (supported: -y --remove --uninstall --status)" >&2; exit 1 ;;
esac; done

APP_ID="io.github.lgse.Strata"
BIN="/usr/bin/strata"
SERVICE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/dbus-1/services"
SERVICE="$SERVICE_DIR/$APP_ID.FileManager1.service"
SERVICE_SRC="/usr/share/strata/$APP_ID.FileManager1.service"
BINDINGS="$HOME/.config/hypr/bindings.lua"
STATE_DIR="$HOME/.config/strata-module"
PREV_MIME="$STATE_DIR/previous-folder-handler"
PREV_FM1="$STATE_DIR/previous-filemanager1"

folder_handler() { xdg-mime query default inode/directory 2>/dev/null || true; }
pkg_has() { pacman -Q strata >/dev/null 2>&1; }

status() {
  if pkg_has; then
    ok "strata installed ($(pacman -Q strata | awk '{print $2}'))"
  elif [[ -x $BIN ]]; then
    warn "strata binary present but not owned by the package"
  else
    warn "strata not installed"
  fi
  printf 'default folder handler: %s\n' "$(folder_handler)"
  [[ -f $SERVICE ]] && echo "FileManager1: installed" || echo "FileManager1: missing"
  if [[ -f $BINDINGS ]]; then
    grep -q 'strata-module: file-manager start' "$BINDINGS" \
      && echo "Omarchy keybinds: Strata" || echo "Omarchy keybinds: not changed"
  fi
}

install_pkg() {
  if pkg_has; then
    ok "strata package already installed"
    return 0
  fi
  info "Installing strata (Omarchy repository)"
  mq_sudo pacman -S --needed --noconfirm strata || { err "strata install failed"; return 1; }
  ok "strata installed"
}

desktop_exists() {
  local n=$1 d
  for d in "${XDG_DATA_HOME:-$HOME/.local/share}" "$HOME/.local/share" /usr/local/share /usr/share; do
    [[ -f $d/applications/$n ]] && return 0
  done
  return 1
}

save_previous_handler() {
  local prev; prev="$(folder_handler)"
  mkdir -p "$STATE_DIR"
  if [[ -n $prev && $prev != "$APP_ID.desktop" ]]; then
    printf '%s\n' "$prev" > "$PREV_MIME"
  fi
}

# "Open file location" has exactly one per-user provider, and two of them
# would fight (the flea module installs its own). Strata being that provider
# is the point of this module, so the old service is set aside here and put
# back by --remove.
clear_other_filemanager1() {
  local f
  mkdir -p "$SERVICE_DIR" "$PREV_FM1"
  for f in "$SERVICE_DIR"/*.service; do
    [[ -f $f ]] || continue
    grep -qx 'Name=org.freedesktop.FileManager1' "$f" || continue
    [[ $(basename "$f") == "$APP_ID.FileManager1.service" ]] && continue
    mv -f "$f" "$PREV_FM1/"
    ok "set aside $(basename "$f") so Strata can handle \"Open file location\""
  done
}

restore_other_filemanager1() {
  local f
  [[ -d $PREV_FM1 ]] || return 0
  for f in "$PREV_FM1"/*.service; do
    [[ -f $f ]] || continue
    install -Dm644 "$f" "$SERVICE_DIR/$(basename "$f")"
    ok "restored $(basename "$f") as the \"Open file location\" provider"
  done
  rm -rf "$PREV_FM1"
}

reload_session_bus() {
  command -v gdbus >/dev/null 2>&1 \
    && timeout 5 gdbus call --session --dest org.freedesktop.DBus \
      --object-path /org/freedesktop/DBus \
      --method org.freedesktop.DBus.ReloadConfig >/dev/null 2>&1 || true
}

install_filemanager1() {
  [[ -f $SERVICE_SRC ]] || { warn "$SERVICE_SRC missing (package too old?)"; return 0; }
  install -Dm644 "$SERVICE_SRC" "$SERVICE"
  reload_session_bus
  ok "Strata handles \"Open file location\""
}

install_folder_handler() {
  xdg-mime default "$APP_ID.desktop" inode/directory
  local cur; cur="$(folder_handler)"
  [[ $cur == "$APP_ID.desktop" ]] \
    && ok "Strata is the default application for folders" \
    || warn "folder handler is '$cur' (expected $APP_ID.desktop)"
}

install_keybinds() {
  [[ -f $BINDINGS ]] || { warn "$BINDINGS not found (Omarchy 3?); keybinds left alone"; return 0; }
  if grep -q 'strata-module: file-manager start' "$BINDINGS"; then
    ok "file-manager keybinds already point to Strata"
    return 0
  fi
  cp -p "$BINDINGS" "$BINDINGS.bak.$(date +%Y%m%d%H%M%S)"
  cat >>"$BINDINGS" <<'EOF'

-- strata-module: file-manager start
hl.unbind("SUPER + SHIFT + F")
hl.unbind("SUPER + ALT + SHIFT + F")
o.bind("SUPER + SHIFT + F", "File manager", { launch = "/usr/bin/strata" })
o.bind("SUPER + ALT + SHIFT + F", "File manager (cwd)",
  "uwsm-app -- /usr/bin/strata \"$(omarchy-cmd-terminal-cwd)\"")
-- strata-module: file-manager end
EOF
  ok "SUPER+SHIFT+F and SUPER+ALT+SHIFT+F open Strata"
  if command -v hyprctl >/dev/null 2>&1 && [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]]; then
    hyprctl reload >/dev/null 2>&1 || true
  fi
}

install_portal() {
  if "$BIN" --install-portal >/dev/null 2>&1; then
    ok "Strata is the file chooser for Open/Save dialogs"
  else
    warn "portal setup failed — set it in Strata: Settings → Desktop integration"
  fi
  restart_portal
}

restart_portal() {
  command -v systemctl >/dev/null 2>&1 || return 0
  if systemctl --user restart xdg-desktop-portal.service 2>/dev/null; then
    ok "file chooser portal restarted"
  else
    warn "could not restart xdg-desktop-portal; log out and back in"
  fi
}

restore_folder_handler() {
  local prev=""
  [[ -s $PREV_MIME ]] && prev="$(head -n1 "$PREV_MIME")"
  rm -f "$PREV_MIME"
  if [[ -n $prev ]] && desktop_exists "$prev"; then
    xdg-mime default "$prev" inode/directory 2>/dev/null \
      && ok "folder handler restored to $prev" \
      || warn "could not restore the folder handler to $prev"
    return 0
  fi
  [[ -n $prev ]] && warn "previous handler $prev is gone — leaving the system default"
  # No usable recorded handler: drop only Strata's association and let the
  # system default apply again.
  local f="$HOME/.config/mimeapps.list"
  [[ -f $f ]] || return 0
  sed -i '/^inode\/directory=.*io\.github\.lgse\.Strata\.desktop/d' "$f" || true
  ok "Strata removed from the folder association"
}

remove_keybinds() {
  [[ -f $BINDINGS ]] || return 0
  grep -q 'strata-module: file-manager start' "$BINDINGS" || return 0
  python3 - "$BINDINGS" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
s = re.sub(r'\n*(?:#|--)\s*strata-module: file-manager start.*?(?:#|--)\s*strata-module: file-manager end\n*',
           '\n', s, flags=re.S)
open(p, 'w').write(s)
PY
  ok "removed Strata's file-manager keybinds"
  if command -v hyprctl >/dev/null 2>&1 && [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]]; then
    hyprctl reload >/dev/null 2>&1 || true
  fi
}

remove_integrations() {
  [[ -x $BIN ]] && "$BIN" --uninstall-portal >/dev/null 2>&1 || true
  rm -f "$SERVICE"
  reload_session_bus
  remove_keybinds
  restore_folder_handler
  restore_other_filemanager1
  restart_portal
  ok "Strata integrations removed"
}

verify() {
  [[ -x $BIN ]] || { err "strata binary not found"; return 1; }
  [[ "$(folder_handler)" == "$APP_ID.desktop" ]] \
    && ok "Strata is the default folder handler" \
    || warn "folder handler is '$(folder_handler)'"
  [[ -f $SERVICE ]] && ok "FileManager1 service installed" || warn "FileManager1 service missing"
  grep -q 'strata-module: file-manager start' "$BINDINGS" 2>/dev/null \
    && ok "file-manager keybinds point to Strata" || warn "file-manager keybinds not set"
}

if $STATUS; then status; exit 0; fi
if $REMOVE; then remove_integrations; exit 0; fi
if $UNINSTALL; then
  remove_integrations
  if pkg_has; then
    info "Removing the strata package"
    mq_sudo pacman -Rns --noconfirm strata || warn "strata package removal failed"
  fi
  ok "Strata uninstalled (settings under ~/.config/strata kept)"
  exit 0
fi

install_pkg || exit 1
save_previous_handler
clear_other_filemanager1
install_filemanager1
install_folder_handler
install_keybinds
install_portal
verify
