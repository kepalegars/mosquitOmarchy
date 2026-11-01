#!/usr/bin/env bash
# =============================================================================
# mosquitOmarchy - WhatsApp (Chromium web app + tray supervisor)
# =============================================================================
# The visible app is Chromium in web-app mode (`--app=https://web.whatsapp.com`),
# the same mechanism Omarchy uses for its web apps. There is no Electron window,
# so the old wrapper's blank first paint cannot happen.
#
# A tiny Electron process owns ONLY the tray icon and the lifecycle:
#   * starts Chromium on the hidden special:whatsapp workspace at login;
#   * tray click / menu launch shows and focuses it;
#   * closing the Chromium window relaunches it hidden (close-to-tray);
#   * WhatsApp's audio stream is muted while hidden, so notification chimes are
#     silent; a content-script forces `silent: true` on the notifications too.
#
# The menu entry is created with Omarchy's own `omarchy-webapp-install`, with a
# custom Exec that starts the tray supervisor. No keybinding/shortcut is added.
#
# Usage:
#   ./setup-whatsapp-native.sh          # install
#   ./setup-whatsapp-native.sh -y       # non-interactive install
#   ./setup-whatsapp-native.sh --status # report installed state, change nothing
#   ./setup-whatsapp-native.sh --remove # uninstall (keeps the WhatsApp login)
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../lib/gui-run.bash"  # gui-run: reopen in a terminal when launched from a file manager
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../lib/elevate.bash"  # mq_sudo: native polkit prompt when not root
set -euo pipefail

[[ -d /usr/share/omarchy ]] || { echo "This script is meant for Omarchy." >&2; exit 1; }

info() { echo -e "\033[1;34m==>\033[0m $*"; }
ok()   { echo -e "\033[1;32m ✓\033[0m $*"; }
warn() { echo -e "\033[1;33m !\033[0m $*"; }
err()  { echo -e "\033[1;31m ✗\033[0m $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_HOME="$HOME"
APPS_DIR="$REAL_HOME/.local/share/applications"
DATA="$REAL_HOME/.local/share/whatsapp-web"
TRAY_DIR="$DATA/tray"
EXT_DIR="$DATA/extension"
PROFILE="$DATA/profile"
STATE_DIR="$REAL_HOME/.local/state/whatsapp-web"
LAUNCHER="$REAL_HOME/.local/bin/whatsapp"
OLD_APP_DIR="$REAL_HOME/.local/share/whatsapp-native"
OLD_DESKTOP="$APPS_DIR/whatsapp.desktop"
NEW_DESKTOP="$APPS_DIR/WhatsApp.desktop"
AUTOSTART="$REAL_HOME/.config/hypr/autostart.lua"
# A few seconds after hyprland.start, so the Omarchy shell's StatusNotifier
# host exists (Electron's tray needs it) and the session environment is ready.
# The marker makes the line easy to update/remove.
AUTOSTART_MARK='mosquitOmarchy whatsapp autostart'
AUTOSTART_LINE="o.launch_on_start(\"sh -c 'sleep 5; exec $REAL_HOME/.local/bin/whatsapp --start-in-tray'\") -- $AUTOSTART_MARK"
SRC_ICON="$SCRIPT_DIR/whatsapp-icon.png"

STATUS_ONLY=false REMOVE=false YES=false
for a in "$@"; do case "$a" in
  -y|--yes)    YES=true ;;
  --status)    STATUS_ONLY=true ;;
  --remove)    REMOVE=true ;;
  -h|--help)   sed -n '2,31p' "$0"; exit 0 ;;
  *)           echo "Unknown option: $a (supported: -y --status --remove)" >&2; exit 1 ;;
esac; done

find_electron() {
  local c
  for c in /usr/lib/electron43/electron /usr/lib/electron/electron /usr/bin/electron; do
    [[ -x $c ]] && { echo "$c"; return 0; }
  done
  for c in /usr/lib/electron[0-9]*/electron; do
    [[ -x $c ]] && { echo "$c"; return 0; }
  done
  return 1
}

find_chromium() {
  local c
  for c in /usr/bin/chromium /usr/bin/chromium-browser /usr/bin/google-chrome-stable /usr/bin/brave; do
    [[ -x $c ]] && { echo "$c"; return 0; }
  done
  command -v chromium 2>/dev/null || return 1
}

st() {
  local missing=0
  [[ -x "$LAUNCHER" ]] || missing=1
  [[ -f "$TRAY_DIR/tray.js" ]] || missing=1
  [[ -f "$EXT_DIR/manifest.json" ]] || missing=1
  [[ -f "$NEW_DESKTOP" ]] || missing=1
  [[ -f "$AUTOSTART" ]] && grep -qF -- "$AUTOSTART_MARK" "$AUTOSTART" || missing=1
  find_chromium >/dev/null || missing=1
  if ((missing)); then echo missing; else echo ok; fi
}

stop_running() {
  local pid i
  if [[ -f "$STATE_DIR/tray.pid" ]]; then
    pid="$(cat "$STATE_DIR/tray.pid" 2>/dev/null || true)"
    [[ -n $pid ]] && kill "$pid" 2>/dev/null || true
  fi
  pkill -f -- '--app=https://web.whatsapp.com/' 2>/dev/null || true
  pkill -f "$OLD_APP_DIR" 2>/dev/null || true
  # Wait for Chromium to flush the profile before a new instance can open it;
  # killing and relaunching immediately can truncate WhatsApp's session.
  for ((i = 0; i < 30; i++)); do
    pgrep -f -- '--app=https://web.whatsapp.com/' >/dev/null 2>&1 || break
    sleep 0.2
  done
  rm -f "$STATE_DIR/tray.pid" "$STATE_DIR/command"
}

if $STATUS_ONLY; then
  st
  exit 0
fi

if $REMOVE; then
  info "Removing WhatsApp (Chromium web app)"
  stop_running
  rm -rf "$TRAY_DIR" "$EXT_DIR"
  rm -f "$LAUNCHER" "$OLD_DESKTOP" "$NEW_DESKTOP" \
        "$REAL_HOME/.local/share/icons/hicolor/256x256/apps/whatsapp.png"
  rm -rf "$OLD_APP_DIR"
  if [[ -f $AUTOSTART ]]; then
    sed -i -e "\|$AUTOSTART_MARK|d" \
           -e '\|^o\.launch_on_start("whatsapp[^"]*")$|d' "$AUTOSTART" 2>/dev/null || true
  fi
  command -v update-desktop-database >/dev/null 2>&1 \
    && update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true
  command -v gtk-update-icon-cache >/dev/null 2>&1 \
    && gtk-update-icon-cache -f -t "$REAL_HOME/.local/share/icons/hicolor" >/dev/null 2>&1 || true
  ok "WhatsApp removed (login data kept in $PROFILE)"
  exit 0
fi

info "1/5 Chromium and Electron runtime"
CHROMIUM_BIN="$(find_chromium || true)"
if [[ -z $CHROMIUM_BIN ]]; then
  info "Installing chromium (pacman, official repo)"
  mq_sudo pacman -S --needed --noconfirm chromium || { err "pacman install failed"; exit 1; }
  CHROMIUM_BIN="$(find_chromium || true)"
  [[ -n $CHROMIUM_BIN ]] || { err "chromium still not found after install"; exit 1; }
fi
ok "chromium: $CHROMIUM_BIN"

ELECTRON_BIN="$(find_electron || true)"
if [[ -z $ELECTRON_BIN ]]; then
  info "Installing electron43 (pacman, official repo)"
  mq_sudo pacman -S --needed --noconfirm electron43 || { err "pacman install failed"; exit 1; }
  ELECTRON_BIN="$(find_electron || true)"
  [[ -n $ELECTRON_BIN ]] || { err "electron still not found after install"; exit 1; }
fi
ok "electron: $ELECTRON_BIN"

# The old wrapper must not keep a second WhatsApp alive.
stop_running
rm -rf "$OLD_APP_DIR"
rm -f "$OLD_DESKTOP"

info "2/5 Tray supervisor + silent-notification extension"
mkdir -p "$TRAY_DIR" "$EXT_DIR" "$PROFILE" "$STATE_DIR"
install -m 644 "$SCRIPT_DIR/tray.js"     "$TRAY_DIR/tray.js"
install -m 644 "$SCRIPT_DIR/package.json" "$TRAY_DIR/package.json"
install -m 644 "$SCRIPT_DIR/extension/manifest.json" "$EXT_DIR/manifest.json"
install -m 644 "$SCRIPT_DIR/extension/silent.js"     "$EXT_DIR/silent.js"
if [[ -f $SRC_ICON ]]; then
  install -m 644 "$SRC_ICON" "$TRAY_DIR/icon.png"
else
  warn "icon asset not found ($SRC_ICON) — tray uses a generic icon."
fi
ok "tray supervisor installed ($TRAY_DIR)"

info "3/5 Launcher"
mkdir -p "$(dirname "$LAUNCHER")"
cat > "$LAUNCHER" <<EOF
#!/usr/bin/env bash
# whatsapp — Chromium web app + tray supervisor.
set -euo pipefail
TRAY_DIR="\$HOME/.local/share/whatsapp-web/tray"
STATE="\$HOME/.local/state/whatsapp-web"
PID="\$STATE/tray.pid"
CMD="\$STATE/command"
mkdir -p "\$STATE"
# A PID file survives a reboot/crash, so trust it only while that PID is
# really the tray supervisor (PID reuse otherwise made the launcher exit
# without starting anything at login).
pid="\$(cat "\$PID" 2>/dev/null || true)"
if [[ -n \$pid ]] && kill -0 "\$pid" 2>/dev/null && \\
   grep -qa 'whatsapp-web/tray' "/proc/\$pid/cmdline" 2>/dev/null; then
  if [[ \${1:-} == --start-in-tray ]]; then exit 0; fi
  printf 'show\n' > "\$CMD"
  exit 0
fi
rm -f "\$PID"
if [[ \${1:-} == --start-in-tray ]]; then export WHATSAPP_START_HIDDEN=1; else export WHATSAPP_START_HIDDEN=0; fi
ELECTRON="$ELECTRON_BIN"
if [[ ! -x \$ELECTRON ]]; then
  for c in /usr/lib/electron43/electron /usr/lib/electron[0-9]*/electron /usr/lib/electron/electron /usr/bin/electron; do
    [[ -x \$c ]] && ELECTRON="\$c" && break
  done
fi
exec "\$ELECTRON" "\$TRAY_DIR"
EOF
chmod +x "$LAUNCHER"
ok "launcher ($LAUNCHER)"

info "4/5 Omarchy web-app menu entry (no shortcut)"
rm -f "$OLD_DESKTOP"
if command -v omarchy-webapp-install >/dev/null 2>&1; then
  omarchy-webapp-install "WhatsApp" "https://web.whatsapp.com/" "$SRC_ICON" "$LAUNCHER %U" "x-scheme-handler/whatsapp" \
    || warn "omarchy-webapp-install failed — creating the desktop entry directly"
fi
if [[ ! -f $NEW_DESKTOP ]]; then
  mkdir -p "$APPS_DIR"
  if [[ -f $SRC_ICON ]]; then
    install -Dm644 "$SRC_ICON" "$REAL_HOME/.local/share/icons/hicolor/256x256/apps/whatsapp.png"
    command -v gtk-update-icon-cache >/dev/null 2>&1 \
      && gtk-update-icon-cache -f -t "$REAL_HOME/.local/share/icons/hicolor" >/dev/null 2>&1 || true
  fi
  cat > "$NEW_DESKTOP" <<EOF
[Desktop Entry]
Version=1.0
Name=WhatsApp
Comment=WhatsApp Web (Chromium)
Exec=$LAUNCHER %U
Terminal=false
Type=Application
Icon=whatsapp
StartupNotify=true
MimeType=x-scheme-handler/whatsapp;
EOF
  chmod +x "$NEW_DESKTOP"
fi
command -v update-desktop-database >/dev/null 2>&1 \
  && update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true
ok "menu entry (WhatsApp), no keybinding"

info "5/5 Autostart (directly in the tray)"
mkdir -p "$(dirname "$AUTOSTART")"
touch "$AUTOSTART"
if grep -qxF -- "$AUTOSTART_LINE" "$AUTOSTART"; then
  ok "autostart already present"
else
  sed -i -e "\|$AUTOSTART_MARK|d" \
         -e '\|^o\.launch_on_start("whatsapp[^"]*")$|d' "$AUTOSTART" 2>/dev/null || true
  printf '\n%s\n' "$AUTOSTART_LINE" >> "$AUTOSTART"
  ok "autostart added to ~/.config/hypr/autostart.lua"
fi

echo
ok "WhatsApp installed."
echo "  • Menu launch opens the Chromium window directly."
echo "  • Login starts it hidden on special:whatsapp; the tray icon opens it."
echo "  • Closing the window keeps it in the tray."
echo "  • First launch has to log in to WhatsApp Web once (profile: $PROFILE)."
