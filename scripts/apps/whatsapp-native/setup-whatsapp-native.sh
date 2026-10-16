#!/usr/bin/env bash
# =============================================================================
# Omarchy Custom - WhatsApp (native desktop client, self-contained Electron app)
# =============================================================================
# Installs WhatsApp Web as a real desktop app that actually behaves like one.
# It is a tiny Electron wrapper we fully control (source committed next to this
# script), not a patched AUR build — so all four requirements are guaranteed
# by code we own:
#
#   1. VISUAL notifications that work. WhatsApp Web only shows desktop
#      notifications once Notification.permission is "granted"; otherwise it
#      falls back to its own in-page chime with NO popup (the old symptom:
#      "sonne mais rien n'apparaît"). main.js grants the permission through
#      setPermissionRequestHandler + setPermissionCheckHandler, and preload.js
#      forces Notification.permission to read "granted" in the page so WhatsApp
#      stops showing its "Autoriser les notifications" banner.
#   2. SILENT notifications. Two sound sources exist: the OS notification (the
#      window is muted by nothing) and WhatsApp's own in-page chime, which only
#      fires while the window is NOT focused. main.js mutes the renderer on
#      blur/hide and unmutes on focus — notification pings are silent, voice
#      messages you are actively listening to keep their audio.
#   3. Tray icon + close-to-tray: closing the window hides it to the tray
#      instead of quitting; the tray menu opens it again or really quits.
#   4. No menu bar: Menu.setApplicationMenu(null) + the window's menu removed.
#
# Plus an Omarchy applications-menu entry ("WhatsApp"), its icon in the hicolor
# theme, and login autostart (o.launch_on_start).
#
# Usage:
#   ./setup-whatsapp-native.sh          # install
#   ./setup-whatsapp-native.sh -y       # non-interactive install
#   ./setup-whatsapp-native.sh --status # report installed state, change nothing
#   ./setup-whatsapp-native.sh --remove # uninstall
#
# The `pacman -S` step needs root: mq_sudo handles it with a native polkit
# (pkexec) prompt when not root. Everything else is entirely user-scoped.
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/gui-run.bash"  # gui-run: reopen in a terminal when launched from a file manager
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/elevate.bash"  # mq_sudo: native pkexec prompt when not root
set -euo pipefail

if [[ ! -d /usr/share/omarchy ]]; then
  echo "This script is meant for Omarchy." >&2
  exit 1
fi

info() { echo -e "\033[1;34m==>\033[0m $*"; }
ok()   { echo -e "\033[1;32m ✓\033[0m $*"; }
warn() { echo -e "\033[1;33m !\033[0m $*"; }
err()  { echo -e "\033[1;31m ✗\033[0m $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_HOME="${HOME}"
APPS_DIR="$REAL_HOME/.local/share/applications"

# Source assets committed next to this script.
SRC_MAIN="$SCRIPT_DIR/main.js"
SRC_PRELOAD="$SCRIPT_DIR/preload.js"
SRC_PKG="$SCRIPT_DIR/package.json"
SRC_ICON="$SCRIPT_DIR/whatsapp-icon.png"

# Install locations.
APP_DIR="$REAL_HOME/.local/share/whatsapp-native/app"
ICON_DST="$REAL_HOME/.local/share/icons/hicolor/256x256/apps/whatsapp.png"
DESKTOP="$APPS_DIR/whatsapp.desktop"
LAUNCHER="$REAL_HOME/.local/bin/whatsapp"
AUTOSTART="$REAL_HOME/.config/hypr/autostart.lua"
AUTOSTART_LINE='o.launch_on_start("whatsapp")'

STATUS_ONLY=false REMOVE=false YES=false
for a in "$@"; do case "$a" in
  -y|--yes)    YES=true ;;
  --status)    STATUS_ONLY=true ;;
  --remove)    REMOVE=true ;;
  -h|--help)   sed -n '2,38p' "$0"; exit 0 ;;
  *)           echo "Unknown option: $a (supported: -y --status --remove)" >&2; exit 1 ;;
esac; done

# ── status ───────────────────────────────────────────────────────────────────
st() {
  # ok = app files + launcher + desktop + autostart all present.
  local missing=0
  [[ -x "$LAUNCHER" ]] || missing=1
  [[ -f "$APP_DIR/main.js" ]] || missing=1
  [[ -f "$DESKTOP" ]] || missing=1
  [[ -f "$AUTOSTART" ]] && grep -qxF -- "$AUTOSTART_LINE" "$AUTOSTART" || missing=1
  if ((missing)); then echo missing; else echo ok; fi
}

if $STATUS_ONLY; then
  if [[ -d "$APP_DIR" ]]; then
    echo "installed ($(command -v whatsapp >/dev/null 2>&1 && echo 'whatsapp on PATH' || echo 'launcher present'))"
  else
    echo "not installed"
  fi
  st | sed 's/^/state: /'
  exit 0
fi

if $REMOVE; then
  info "Removing WhatsApp desktop client"
  # Stop a running instance first so files are not busy.
  pkill -f "$APP_DIR" 2>/dev/null || true
  sleep 1
  rm -rf "$REAL_HOME/.local/share/whatsapp-native"
  rm -f "$LAUNCHER" "$DESKTOP" "$ICON_DST"
  if [[ -f "$AUTOSTART" ]]; then
    sed -i "\|^$AUTOSTART_LINE\$|d" "$AUTOSTART" 2>/dev/null || \
      sed -i "\|o.launch_on_start(\"whatsapp\")|d" "$AUTOSTART" 2>/dev/null || true
  fi
  command -v update-desktop-database >/dev/null 2>&1 \
    && update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true
  command -v gtk-update-icon-cache >/dev/null 2>&1 \
    && gtk-update-icon-cache -f -t "$REAL_HOME/.local/share/icons/hicolor" >/dev/null 2>&1 || true
  ok "WhatsApp desktop client removed (WhatsApp Web login data in ~/.config/WhatsApp is kept)"
  exit 0
fi

# ── install ──────────────────────────────────────────────────────────────────
info "1/5 Electron runtime"
find_electron() {
  local c
  for c in /usr/lib/electron43/electron /usr/lib/electron/electron /usr/bin/electron; do
    [[ -x "$c" ]] && { echo "$c"; return 0; }
  done
  # Any electronNN package.
  for c in /usr/lib/electron[0-9]*/electron; do
    [[ -x "$c" ]] && { echo "$c"; return 0; }
  done
  return 1
}
ELECTRON_BIN="$(find_electron || true)"
if [[ -n $ELECTRON_BIN ]]; then
  ok "electron present ($(basename "$(dirname "$ELECTRON_BIN")"))"
else
  info "Installing electron43 (pacman, official repo)"
  mq_sudo pacman -S --needed --noconfirm electron43 || { err "pacman install failed"; exit 1; }
  ELECTRON_BIN="$(find_electron || true)"
  [[ -n $ELECTRON_BIN ]] || { err "electron still not found after install"; exit 1; }
  ok "electron installed"
fi

info "2/5 Application files"
[[ -f $SRC_MAIN && -f $SRC_PRELOAD && -f $SRC_PKG ]] \
  || { err "app source missing in $SCRIPT_DIR (main.js/preload.js/package.json)"; exit 1; }
mkdir -p "$APP_DIR"
install -m 644 "$SRC_MAIN"    "$APP_DIR/main.js"
install -m 644 "$SRC_PRELOAD" "$APP_DIR/preload.js"
install -m 644 "$SRC_PKG"     "$APP_DIR/package.json"
ok "app installed ($APP_DIR)"

info "3/5 Icon"
mkdir -p "$(dirname "$ICON_DST")"
if [[ -f $SRC_ICON ]]; then
  install -m 644 "$SRC_ICON" "$ICON_DST"
  install -m 644 "$SRC_ICON" "$APP_DIR/icon.png"
  ok "icon installed"
else
  warn "icon asset not found ($SRC_ICON) — menu/tray fall back to a generic icon."
fi

info "4/5 Launcher + menu entry"
mkdir -p "$(dirname "$LAUNCHER")"
cat > "$LAUNCHER" <<EOF
#!/usr/bin/env bash
# whatsapp — launcher for the self-contained WhatsApp Web Electron wrapper
# (~/.local/share/whatsapp-native/app). Flags tuned for Wayland/Hyprland.
set -euo pipefail
APP_DIR="\$HOME/.local/share/whatsapp-native/app"
ELECTRON_BIN="\${ELECTRON_BIN:-$ELECTRON_BIN}"
if [[ ! -x "\$ELECTRON_BIN" ]]; then
  for c in /usr/lib/electron43/electron /usr/lib/electron/electron /usr/bin/electron; do
    [[ -x "\$c" ]] && ELECTRON_BIN="\$c" && break
  done
fi
exec "\$ELECTRON_BIN" \\
  --ozone-platform-hint=auto \\
  --enable-features=WaylandWindowDecorations \\
  --enable-wayland-ime \\
  "\$APP_DIR" "\$@"
EOF
chmod +x "$LAUNCHER"
ok "launcher ($LAUNCHER)"

mkdir -p "$APPS_DIR"
cat > "$DESKTOP" <<EOF
[Desktop Entry]
Name=WhatsApp
Comment=WhatsApp Web (tray, notifications visuelles silencieuses, sans barre de menu)
Exec=$LAUNCHER %U
Terminal=false
Type=Application
Icon=$ICON_DST
StartupWMClass=whatsapp
Categories=Network;Chat;InstantMessaging;
MimeType=x-scheme-handler/whatsapp;
StartupNotify=true
EOF
command -v update-desktop-database >/dev/null 2>&1 \
  && update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true
ok "menu entry (WhatsApp)"

info "5/5 Autostart"
mkdir -p "$(dirname "$AUTOSTART")"
if [[ -f $AUTOSTART ]] && grep -qxF -- "$AUTOSTART_LINE" "$AUTOSTART"; then
  ok "autostart already present"
else
  printf '\n%s\n' "$AUTOSTART_LINE" >> "$AUTOSTART"
  ok "autostart added to ~/.config/hypr/autostart.lua"
fi

echo
ok "WhatsApp installed. Launch from the menu (WhatsApp), it starts at login and lives in the tray."
