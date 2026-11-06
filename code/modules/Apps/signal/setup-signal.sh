#!/usr/bin/env bash
# =============================================================================
# Signal Desktop — install + configure (tray at login, visible when launched
# manually, hide menu bar) + autostart.
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../lib/gui-run.bash"  # gui-run: reopen in a terminal when launched from a file manager
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../lib/elevate.bash"  # mq_sudo: GUI password prompt, never a blind sudo hang
set -uo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SIGNAL_CONFIG_DIR="$HOME/.config/Signal"
readonly SIGNAL_CONFIG_FILE="$SIGNAL_CONFIG_DIR/config.json"
readonly SIGNAL_EPHEMERAL_FILE="$SIGNAL_CONFIG_DIR/ephemeral.json"
readonly AUTOSTART_DIR="$HOME/.config/autostart"
readonly SIGNAL_DESKTOP_FILE="$AUTOSTART_DIR/signal-desktop.desktop"

G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; B='\033[1;34m'; N='\033[0m'
msg(){ printf "${B}==>${N} %s\n" "$*"; }
ok(){ printf " ${G}✓${N} %s\n" "$*"; }
warn(){ printf " ${Y}!${N} %s\n" "$*" >&2; }
err(){ printf " ${R}✗${N} %s\n" "$*" >&2; }

install_signal(){
  if pacman -Q signal-desktop &>/dev/null; then
    ok "Signal Desktop already installed"
    return 0
  fi
  msg "Installing Signal Desktop via pacman"
  mq_sudo pacman -S --needed --noconfirm signal-desktop || {
    err "Failed to install signal-desktop"
    return 1
  }
  ok "Signal Desktop installed"
}

configure_signal(){
  msg "Configuring Signal Desktop (minimize to tray, start in tray, hide menu bar)"
  mkdir -p "$SIGNAL_CONFIG_DIR"

  # Current Signal (8.x) keeps all three switches in ephemeral.json:
  #   system-tray-setting = MinimizeToAndStartInSystemTray
  #     -> the native "Minimize to system tray and start in tray" option
  #   window.autoHideMenuBar = true
  #     -> the native "Hide menu bar" option
  # The old config.json keys (minimizeToTray/startMinimized/hideMenuBar) are
  # from older releases and are ignored by current builds, so only the file
  # Signal actually reads is written.
  local ephemeral="{}"
  if [[ -f $SIGNAL_EPHEMERAL_FILE ]]; then
    if ! jq -e '."system-tray-setting" == "MinimizeToAndStartInSystemTray"
                and (.window.autoHideMenuBar == true)' "$SIGNAL_EPHEMERAL_FILE" >/dev/null 2>&1; then
      cp -n "$SIGNAL_EPHEMERAL_FILE" "$SIGNAL_EPHEMERAL_FILE.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    fi
    ephemeral="$(cat "$SIGNAL_EPHEMERAL_FILE" 2>/dev/null || echo "{}")"
  fi
  ephemeral="$(printf '%s' "$ephemeral" | jq '
    ."system-tray-setting" = "MinimizeToAndStartInSystemTray"
    | .window = ((.window // {}) | .autoHideMenuBar = true)
  ')" || {
    err "Could not update Signal's tray/menu settings in ephemeral.json"
    return 1
  }
  printf '%s\n' "$ephemeral" > "$SIGNAL_EPHEMERAL_FILE"
  ok "Signal: minimize to tray, start in tray, menu bar hidden"

  # Signal writes ephemeral.json on exit. Editing it under a running instance
  # means the running copy wins when it quits, so the settings would silently
  # revert. Say so instead of reporting a configuration that will not stick.
  if pgrep -x signal-desktop >/dev/null 2>&1; then
    warn "Signal is running — quit it completely (tray → Quit) and relaunch so these settings stick."
  fi
}

setup_autostart(){
  msg "Setting up Signal autostart (start in tray)"
  mkdir -p "$AUTOSTART_DIR"

  # The native setting already starts Signal minimized to the tray; the flag
  # also makes the login entry explicit and matches Signal's own --start-in-tray
  # behavior. Manual launches read the persistent setting.
  cat > "$SIGNAL_DESKTOP_FILE" <<'EOF'
[Desktop Entry]
Type=Application
Name=Signal
Exec=signal-desktop --start-in-tray
Icon=signal-desktop
Terminal=false
Categories=Network;InstantMessaging;
StartupNotify=false
StartupWMClass=signal
X-GNOME-Autostart-enabled=true
EOF

  # XDG autostart is consumed by systemd-xdg-autostart-generator, which runs at
  # login. A file created after login therefore has no unit until the next
  # one — the "autostart does nothing" report. Regenerate now, and start the
  # generated unit immediately unless Signal is already running.
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    if ! pgrep -x signal-desktop >/dev/null 2>&1 && command -v systemd-escape >/dev/null 2>&1; then
      systemctl --user start "app-$(systemd-escape 'signal-desktop')@autostart.service" >/dev/null 2>&1 || true
    fi
  fi

  ok "Autostart entry created at $SIGNAL_DESKTOP_FILE"
}

uninstall_signal(){
  if pacman -Q signal-desktop &>/dev/null; then
    msg "Uninstalling Signal Desktop"
    # A stale db.lck (e.g. a previous run was interrupted mid-pacman) makes
    # every transaction fail. Say so instead of claiming the removal worked.
    if [[ -e /var/lib/pacman/db.lck ]]; then
      err "pacman is locked: /var/lib/pacman/db.lck"
      err "Another package manager is running, or a previous run was interrupted."
      err "Close it (or remove the stale lock) and retry. Nothing was removed."
      return 1
    fi
    mq_sudo pacman -R --noconfirm signal-desktop || {
      err "Failed to remove signal-desktop. Nothing was removed."
      return 1
    }
  else
    ok "Signal Desktop is not installed"
  fi

  # Remove config and autostart only once the package is gone.
  rm -f "$SIGNAL_CONFIG_FILE"
  rm -f "$SIGNAL_DESKTOP_FILE"
  # Remove empty config dir if no other files
  rmdir "$SIGNAL_CONFIG_DIR" 2>/dev/null || true

  ok "Signal Desktop uninstalled"
}

main(){
  case "${1:-install}" in
    install|-y|--yes)
      install_signal
      configure_signal
      setup_autostart
      ok "Signal Desktop installed and configured"
      ;;
    uninstall)
      uninstall_signal
      ;;
    *)
      err "Usage: $0 {install|-y|--yes|uninstall}"
      exit 1
      ;;
  esac
}

main "$@"
