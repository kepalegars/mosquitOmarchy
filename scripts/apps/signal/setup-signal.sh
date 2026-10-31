#!/usr/bin/env bash
# =============================================================================
# Signal Desktop — install + configure (tray at login, visible when launched
# manually, hide menu bar) + autostart.
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/gui-run.bash"  # gui-run: reopen in a terminal when launched from a file manager
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/elevate.bash"  # mq_sudo: GUI password prompt, never a blind sudo hang
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
  msg "Configuring Signal Desktop (tray only at login, normal menu launch, hide menu bar)"
  mkdir -p "$SIGNAL_CONFIG_DIR"

  # Signal Desktop stores settings in ~/.config/Signal/config.json (electron-store)
  # Keep close-to-tray off so Quit exits the process and its tray icon; the
  # dedicated autostart flag starts it in the tray without hiding menu launches.
  local json="{}"
  if [[ -f "$SIGNAL_CONFIG_FILE" ]]; then
    json="$(cat "$SIGNAL_CONFIG_FILE" 2>/dev/null || echo "{}")"
  fi

  # Use jq to merge settings, preserving existing keys
  json="$(printf '%s' "$json" | jq '.minimizeToTray = false | .startMinimized = false | .hideMenuBar = true')" || {
    warn "jq not available or config parsing failed; writing minimal config"
    json='{"minimizeToTray":false,"startMinimized":false,"hideMenuBar":true}'
  }

  printf '%s\n' "$json" > "$SIGNAL_CONFIG_FILE"
  ok "Signal configuration written to $SIGNAL_CONFIG_FILE"

  # Signal's actual tray preference lives in ephemeral.json; config.json's
  # startMinimized/minimizeToTray keys alone do not control current releases.
  local ephemeral="{}"
  if [[ -f $SIGNAL_EPHEMERAL_FILE ]]; then
    if ! jq -e '."system-tray-setting" == "DoNotUseSystemTray"' "$SIGNAL_EPHEMERAL_FILE" >/dev/null 2>&1; then
      cp -n "$SIGNAL_EPHEMERAL_FILE" "$SIGNAL_EPHEMERAL_FILE.bak.$(date +%Y%m%d%H%M%S)"
    fi
    ephemeral="$(cat "$SIGNAL_EPHEMERAL_FILE")"
  fi
  ephemeral="$(printf '%s' "$ephemeral" | jq '."system-tray-setting" = "DoNotUseSystemTray"')" || {
    err "Could not update Signal's tray preference in ephemeral.json"
    return 1
  }
  printf '%s\n' "$ephemeral" > "$SIGNAL_EPHEMERAL_FILE"
  ok "Manual launches show the window; the autostart flag still starts in the tray"
}

setup_autostart(){
  msg "Setting up Signal autostart (minimized to tray)"
  mkdir -p "$AUTOSTART_DIR"

  # Only the login launch starts hidden; the Omarchy app-menu launcher stays normal.
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

  ok "Autostart entry created at $SIGNAL_DESKTOP_FILE"
}

uninstall_signal(){
  msg "Uninstalling Signal Desktop"
  mq_sudo pacman -R --noconfirm signal-desktop || true

  # Remove config and autostart
  rm -f "$SIGNAL_CONFIG_FILE"
  rm -f "$SIGNAL_DESKTOP_FILE"
  # Remove empty config dir if no other files
  rmdir "$SIGNAL_CONFIG_DIR" 2>/dev/null || true

  ok "Signal Desktop uninstalled"
}

main(){
  case "${1:-install}" in
    install)
      install_signal
      configure_signal
      setup_autostart
      ok "Signal Desktop installed and configured"
      ;;
    uninstall)
      uninstall_signal
      ;;
    *)
      err "Usage: $0 {install|uninstall}"
      exit 1
      ;;
  esac
}

main "$@"
