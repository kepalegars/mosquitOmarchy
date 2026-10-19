#!/usr/bin/env bash
# =============================================================================
# Omarchy Custom - KeePassXC (password manager + BROWSER INTEGRATION)
# =============================================================================
# This module keeps KeePassXC as your personal password manager and wires the
# KeePassXC-Browser extension to it. It does NOT touch Omarchy's system keyring:
# gnome-keyring keeps serving the freedesktop.org Secret Service
# (org.freedesktop.secrets) for apps (Chromium "Safe Storage", kDrive tokens,
# libsecret/secret-tool, …), exactly as Omarchy ships it.
#
# WHY (history): an earlier version of this module REPLACED gnome-keyring with
# KeePassXC (D-Bus override + gnome-keyring masked + [FdoSecrets] Enabled=true).
# That made KeePassXC answer every "give me my secret" request from Chromium,
# which shows an "app requests access to Chromium Safe Storage" prompt on EVERY
# launch — even after "allow all & future" — and left apps that already had a
# secret in gnome-keyring (kDrive, for example) unable to read it, so they asked
# to log in again on every boot. KeePassXC FdoSecrets cannot import the existing
# gnome-keyring store, so the two simply do not mix for app secrets.
#
# The old takeover is still available (opt-in) with --secret-service for anyone
# who really wants KeePassXC to own org.freedesktop.secrets.
#
# What the DEFAULT apply does (idempotent):
#   1. Ensures the keepassxc package (pacman).
#   2. REVERTS any previous takeover so Omarchy's gnome-keyring serves the
#      Secret Service again (removes the D-Bus override, restores the backup,
#      removes the gnome-keyring autostart shadow, unmasks gnome-keyring-daemon,
#      sets [FdoSecrets] Enabled=false) and starts gnome-keyring.
#   3. Installs the KeePassXC-Browser native-messaging manifests for both
#      Firefox/Zen and Chromium (the Chromium one was missing, which is why the
#      browser link "never worked").
#   4. Enables tray-on-close so KeePassXC survives closing its window.
#   5. Pins the default .kdbx so KeePassXC opens your database instead of
#      offering "create a new database" on every launch.
#
# Usage:
#   ./setup-keepassxc-integration.sh                  # apply (browser integration)
#   ./setup-keepassxc-integration.sh --secret-service # ALSO replace gnome-keyring (old behaviour)
#   ./setup-keepassxc-integration.sh --status         # status
#   ./setup-keepassxc-integration.sh --remove         # undo this module (browser manifests + pin + any takeover)
#   ./setup-keepassxc-integration.sh -y               # non-interactive (nothing asked)
#
# Settings that stay manual BY DESIGN (encrypted in the database, not scriptable):
#   • KeePassXC → Tools → Settings → Browser Integration → tick the browsers you
#     use and "Connect to database on startup"; then, in the browser, click the
#     KeePassXC-Browser icon → Connect and grant access.
#   • When switching to --secret-service: Database → Database Settings → Secret
#     Service Integration → expose a group.
#
# KEEPASSXC module — was in scripts/plugins/, now lives in scripts/apps/
# (the module is an APP manager, no longer a plugin. Done in depth: module
# path, README link, catalog entry and the TUI 'i' info all point here).
#
# Source: keepassxc-browser wiki "Native-messaging-script-files" (the manifest
# templates), keepassxc docs topics/SecretService.adoc (the --secret-service
# opt-in), and issues #6274/#13464 (why masking gnome-keyring breaks apps).
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/gui-run.bash"  # gui-run: reopen in a terminal when launched from a file manager
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/elevate.bash"  # mq_sudo: native pkexec prompt when not root
set -euo pipefail

info() { echo -e "\033[1;34m==>\033[0m $*"; }
ok()   { echo -e "\033[1;32m ✓\033[0m $*"; }
warn() { echo -e "\033[1;33m !\033[0m $*"; }
err()  { echo -e "\033[1;31m ✗\033[0m $*" >&2; }
hr()   { printf '%.0s─' {1..70}; echo; }

KPXC_DBUS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/dbus-1/services"
KPXC_DBUS_FILE="$KPXC_DBUS_DIR/org.freedesktop.secrets.service"
KPXC_DBUS_BAK="$KPXC_DBUS_DIR/org.freedesktop.secrets.service.pre-keepassxc"
KPXC_AUTOSTART_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"
KPXC_AUTOSTART_SHADE='gnome-keyring-secrets.desktop'
KPXC_INI_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/keepassxc"
KPXC_INI="$KPXC_INI_DIR/keepassxc.ini"
KPXC_INI_BAK="$KPXC_INI.pre-keepassxc"
KPXC_PROXY="/usr/bin/keepassxc-proxy"
# KeePassXC-Browser extension ids (stable store id, and the Edge id).
KPXC_CHROME_ID="oboonakemofpalcgghocfoadofidjkkk"
KPXC_EDGE_ID="pdffhmdngciaglkoonimfcmckehcpafo"

YES=0 WANT_SECRET_SERVICE=0
for a in "$@"; do case "$a" in
  -y|--yes) YES=1 ;;
  --secret-service|--replace-keyring) WANT_SECRET_SERVICE=1 ;;
  --remove-gnome-keyring) export MOSQUITOMARCHY_KEEPASSXC_REMOVE_GNOME_KEYRING=1 ;;
  --keep-gnome-keyring) export MOSQUITOMARCHY_KEEPASSXC_REMOVE_GNOME_KEYRING=0 ;;
  --status) MODE=status ;;
  --remove|--uninstall) MODE=remove ;;
  -h|--help) sed -n '2,58p' "$0"; exit 0 ;;
esac; done
MODE="${MODE:-apply}"

ask_yes(){
  # $1 = question text. 0 = yes. GNOME QML confirm → zenity → tty read.
  # NOTE: with -y we NEVER auto-yes a DESTRUCTIVE question — the caller checks
  # ${YES} itself before asking anything that removes a package.
  local q="$1" r sel done waited=0
  if [[ -t 0 ]] && [[ -n ${TERM:-} ]]; then
    read -r -p "$q [y/N] " r || return 1
    [[ $r =~ ^[yYoO]$ ]]
    return
  fi
  if command -v omarchy-shell >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    sel=$(mktemp); done=$(mktemp); rm -f "$done"
    omarchy-shell shell summon mosquito.confirm "$(jq -cn \
      --arg message "$q" --arg selectionFile "$sel" --arg doneFile "$done" \
      '{message:$message, selectionFile:$selectionFile, doneFile:$done}')" >/dev/null 2>&1 || true
    while [[ ! -e $done ]]; do
      ((waited++ > 300)) && break
      sleep 0.2
    done
    local ret=1
    [[ $(cat "$sel" 2>/dev/null) == yes ]] && ret=0
    rm -f "$sel" "$done"
    return $ret
  fi
  if command -v zenity >/dev/null 2>&1; then
    zenity --question --title="KeePassXC integration" --text="$q" 2>/dev/null && return 0
    return 1
  fi
  warn "No GUI to ask — assuming 'no'."
  return 1
}

# ─── low-level: keepassxc.ini [FdoSecrets] flag ──────────────────────────────
set_fdo_enabled(){
  local enabled="$1"
  [[ -f $KPXC_INI ]] || { mkdir -p "$KPXC_INI_DIR"; printf '\n' > "$KPXC_INI"; }
  if [[ ! -e $KPXC_INI_BAK ]]; then cp -f "$KPXC_INI" "$KPXC_INI_BAK"; fi
  python3 - "$KPXC_INI" "$enabled" <<'PY'
import configparser, pathlib, sys
p = pathlib.Path(sys.argv[1]); val = sys.argv[2]
c = configparser.ConfigParser()
c.optionxform = str
c.read(p)
if not c.has_section("FdoSecrets"):
    c.add_section("FdoSecrets")
c.set("FdoSecrets", "Enabled", val)
with open(p, "w") as fh:
    c.write(fh)
PY
}

fdo_enabled(){
  python3 - "$KPXC_INI" <<'PY' 2>/dev/null || echo no
import configparser, sys
c = configparser.ConfigParser(); c.read(sys.argv[1])
print("yes" if c.getboolean("FdoSecrets", "Enabled", fallback=False) else "no")
PY
}

# ─── low-level: keepassxc.ini [Browser] flag ─────────────────────────────────
set_browser_enabled(){
  [[ -f $KPXC_INI ]] || { mkdir -p "$KPXC_INI_DIR"; printf '\n' > "$KPXC_INI"; }
  if [[ ! -e $KPXC_INI_BAK ]]; then cp -f "$KPXC_INI" "$KPXC_INI_BAK"; fi
  python3 - "$KPXC_INI" <<'PY'
import configparser, pathlib, sys
p = pathlib.Path(sys.argv[1])
c = configparser.ConfigParser(); c.optionxform = str; c.read(p)
if not c.has_section("Browser"):
    c.add_section("Browser")
c.set("Browser", "Enabled", "true")
with open(p, "w") as fh:
    c.write(fh)
PY
}

# ─── low-level: keepassxc.ini tray-on-close ───────────────────────────────────
# Closing the window must hide KeePassXC to the tray, not quit it: the browser
# proxy and any secret-service use survive, and the user stops losing it.
# Three GUI keys, same python pattern as above:
#   ShowTrayIcon   = the tray icon itself (without it the other two do nothing)
#   MinimizeToTray = minimize goes to the tray instead of the taskbar
#   MinimizeOnClose = the X button minimizes instead of quitting
set_tray_on_close(){
  [[ -f $KPXC_INI ]] || { mkdir -p "$KPXC_INI_DIR"; printf '\n' > "$KPXC_INI"; }
  if [[ ! -e $KPXC_INI_BAK ]]; then cp -f "$KPXC_INI" "$KPXC_INI_BAK"; fi
  python3 - "$KPXC_INI" <<'PY'
import configparser, pathlib, sys
p = pathlib.Path(sys.argv[1])
c = configparser.ConfigParser()
c.optionxform = str
c.read(p)
if not c.has_section("GUI"):
    c.add_section("GUI")
for k, v in (("ShowTrayIcon", "true"), ("MinimizeToTray", "true"),
             ("MinimizeOnClose", "true")):
    c.set("GUI", k, v)
with open(p, "w") as fh:
    c.write(fh)
PY
  ok "keepassxc.ini: tray icon on, minimize-to-tray on, minimize-on-close on (backup: $KPXC_INI_BAK)"
}

tray_on_close(){
  python3 - "$KPXC_INI" <<'PY' 2>/dev/null || echo no
import configparser, sys
c = configparser.ConfigParser(); c.read(sys.argv[1])
ok = all(c.getboolean("GUI", k, fallback=False) for k in ("ShowTrayIcon", "MinimizeToTray", "MinimizeOnClose"))
print("yes" if ok else "no")
PY
}

# ─── browser integration (§3) ────────────────────────────────────────────────
# KeePassXC-Browser talks to keepassxc-proxy over the browser's native-messaging
# channel. Each browser reads a JSON manifest from its own directory; KeePassXC
# normally writes these from its Settings UI, but the Chromium one was missing
# here — so the extension could never reach KeePassXC ("le link browser ne
# fonctionne toujours pas"). We write both manifests directly.
install_browser_manifests(){
  if [[ ! -x $KPXC_PROXY ]]; then
    warn "keepassxc-proxy not found ($KPXC_PROXY) — browser integration unavailable."
    return 0
  fi

  # Firefox / Zen (and other Gecko browsers): ~/.mozilla/native-messaging-hosts
  local ff="$HOME/.mozilla/native-messaging-hosts"
  mkdir -p "$ff"
  cat > "$ff/org.keepassxc.keepassxc_browser.json" <<EOF
{
  "allowed_extensions": ["keepassxc-browser@keepassxc.org"],
  "description": "KeePassXC integration with native messaging support",
  "name": "org.keepassxc.keepassxc_browser",
  "path": "$KPXC_PROXY",
  "type": "stdio"
}
EOF
  ok "Firefox/Zen native-messaging manifest: $ff/org.keepassxc.keepassxc_browser.json"

  # Chromium (and Chromium-based: Brave, Vivaldi, …) keep per-browser dirs.
  local nm
  for nm in \
    "${XDG_CONFIG_HOME:-$HOME/.config}/chromium/NativeMessagingHosts" \
    "${XDG_CONFIG_HOME:-$HOME/.config}/BraveSoftware/Brave-Browser/NativeMessagingHosts" \
    "${XDG_CONFIG_HOME:-$HOME/.config}/vivaldi/NativeMessagingHosts"; do
    mkdir -p "$nm"
    cat > "$nm/org.keepassxc.keepassxc_browser.json" <<EOF
{
  "allowed_origins": [
    "chrome-extension://$KPXC_CHROME_ID/",
    "chrome-extension://$KPXC_EDGE_ID/"
  ],
  "description": "KeePassXC integration with native messaging support",
  "name": "org.keepassxc.keepassxc_browser",
  "path": "$KPXC_PROXY",
  "type": "stdio"
}
EOF
  done
  ok "Chromium native-messaging manifest installed (chromium/Brave/Vivaldi)."
  set_browser_enabled
  ok "keepassxc.ini: [Browser] Enabled=true"
}

remove_browser_manifests(){
  local f
  for f in \
    "$HOME/.mozilla/native-messaging-hosts/org.keepassxc.keepassxc_browser.json" \
    "${XDG_CONFIG_HOME:-$HOME/.config}/chromium/NativeMessagingHosts/org.keepassxc.keepassxc_browser.json" \
    "${XDG_CONFIG_HOME:-$HOME/.config}/BraveSoftware/Brave-Browser/NativeMessagingHosts/org.keepassxc.keepassxc_browser.json" \
    "${XDG_CONFIG_HOME:-$HOME/.config}/vivaldi/NativeMessagingHosts/org.keepassxc.keepassxc_browser.json"; do
    [[ -f $f ]] && rm -f "$f" && ok "removed $f"
  done
}

# ─── keyring (§2): keep Omarchy's gnome-keyring as the Secret Service ─────────
start_gnome_keyring(){
  systemctl --user start gnome-keyring-daemon.socket >/dev/null 2>&1 || true
  systemctl --user start gnome-keyring-daemon.service >/dev/null 2>&1 || true
  if ! pgrep -x gnome-keyring-daemon >/dev/null 2>&1; then
    setsid --fork gnome-keyring-daemon --start --foreground --components=secrets >/dev/null 2>&1 &
    disown
  fi
}

restore_omarchy_keyring(){
  local changed=0
  # D-Bus activation override → KeePassXC. Only remove it if it is OURS
  # (marker) or plainly points at keepassxc, so we never delete a user file.
  if [[ -f $KPXC_DBUS_FILE ]] && grep -qE 'KeePassXCSecretService|Exec=/usr/bin/keepassxc' "$KPXC_DBUS_FILE" 2>/dev/null; then
    rm -f "$KPXC_DBUS_FILE"; changed=1
  fi
  if [[ -f $KPXC_DBUS_BAK ]]; then
    # The "backup" is only the ORIGINAL owner if it does not itself name
    # keepassxc — an earlier run of the old module could have backed up its own
    # override, which would silently re-install the takeover. Discard that case.
    if grep -qE 'KeePassXCSecretService|Exec=/usr/bin/keepassxc' "$KPXC_DBUS_BAK" 2>/dev/null; then
      rm -f "$KPXC_DBUS_BAK"
    else
      mv -f "$KPXC_DBUS_BAK" "$KPXC_DBUS_FILE" 2>/dev/null || true
    fi
    changed=1
  fi
  # gnome-keyring autostart shadow.
  if [[ -f "$KPXC_AUTOSTART_DIR/$KPXC_AUTOSTART_SHADE" ]]; then
    rm -f "$KPXC_AUTOSTART_DIR/$KPXC_AUTOSTART_SHADE"; changed=1
  fi
  # Unmask gnome-keyring so D-Bus activation works again.
  systemctl --user unmask gnome-keyring-daemon.service >/dev/null 2>&1 || true
  systemctl --user unmask gnome-keyring-daemon.socket >/dev/null 2>&1 || true
  # KeePassXC must not claim org.freedesktop.secrets.
  if [[ "$(fdo_enabled)" == yes ]]; then
    set_fdo_enabled false; changed=1
  fi
  if (( changed )); then
    ok "Omarchy's gnome-keyring secret service restored; KeePassXC FdoSecrets disabled."
    warn "Restart KeePassXC once (quit from the tray, then relaunch) so it releases 'org.freedesktop.secrets'."
  else
    ok "Omarchy's gnome-keyring secret service already in place."
  fi
  start_gnome_keyring
}

# ─── takeover (§ --secret-service), kept for opt-in ──────────────────────────
ensure_package(){
  if command -v keepassxc >/dev/null 2>&1; then
    ok "keepassxc package present ($(pacman -Q keepassxc 2>/dev/null | cut -d' ' -f2))"
    return 0
  fi
  mq_sudo -v || { err "Password required to install keepassxc."; return 1; }
  mq_sudo pacman -S --needed --noconfirm keepassxc \
    || { err "pacman failed to install keepassxc."; return 1; }
  ok "keepassxc installed"
}

write_dbus_override(){
  mkdir -p "$KPXC_DBUS_DIR"
  if [[ ! -e "$KPXC_DBUS_BAK" && -f "$KPXC_DBUS_FILE" ]]; then
    cp -f "$KPXC_DBUS_FILE" "$KPXC_DBUS_BAK"
  fi
  cat > "$KPXC_DBUS_FILE" <<'EOF'
# >>> Omarchy_Custom_Scripts_KeePassXCSecretService
[D-BUS Service]
Name=org.freedesktop.secrets
Exec=/usr/bin/keepassxc
# <<< Omarchy_Custom_Scripts_KeePassXCSecretService
EOF
  ok "DBus Secret Service → keepassxc (the system gnome-keyring file is untouched)"
}

write_autostart_shade(){
  mkdir -p "$KPXC_AUTOSTART_DIR"
  cat > "$KPXC_AUTOSTART_DIR/$KPXC_AUTOSTART_SHADE" <<'EOF'
# >>> Omarchy_Custom_Scripts_KeePassXCSecretService
# ~/.config/autostart wins over /etc/xdg/autostart: the gnome-keyring secrets
# component never starts, so KeePassXC owns the D-Bus name alone.
[Desktop Entry]
Type=Application
Hidden=true
OnlyShowIn=
# <<< Omarchy_Custom_Scripts_KeePassXCSecretService
EOF
  ok "gnome-keyring-secrets autostart shadowed with Hidden=true"
}

mask_daemon_service(){
  systemctl --user mask gnome-keyring-daemon.service > /dev/null 2>&1 \
    || warn "systemctl --user mask gnome-keyring-daemon.service failed."
  ok "gnome-keyring-daemon.service masked (user session)"
}

start_keepassxc(){
  pkill -f 'gnome-keyring-daemon' > /dev/null 2>&1 || true
  sleep 0.3
  if command -v busctl >/dev/null 2>&1; then
    busctl --user stop org.freedesktop.secrets > /dev/null 2>&1 || true
  fi
  setsid --fork /usr/bin/keepassxc >/dev/null 2>&1 &
  disown
  ok "KeePassXC started — it now owns org.freedesktop.secrets."
}

offer_gnome_keyring_removal(){
  # Second, independent prompt (the module replacement prompt lives in the
  # TUI): the PACKAGE removal is optional and does NOT delete the user
  # settings — they remain on the disk, and a plain reinstall recovers them.
  # When the mosquitOmarchy TUI runs the install, the QUESTION IS ASKED THERE
  # (a real confirm prompt) and forwarded via
  # MOSQUITOMARCHY_KEEPASSXC_REMOVE_GNOME_KEYRING=1|0 — so this script never
  # silently skips the question in the TUI's -y flow.
  local mode="${MOSQUITOMARCHY_KEEPASSXC_REMOVE_GNOME_KEYRING:-}"
  if [[ $mode == 1 ]]; then
    mq_sudo -v || { warn "Password required → gnome-keyring package KEPT."; return 0; }
    if mq_sudo pacman -Rns --noconfirm gnome-keyring; then
      ok "gnome-keyring package removed (settings kept on disk)."
    else
      warn "pacman kept gnome-keyring (another package may depend on it)."
    fi
    return 0
  elif [[ $mode == 0 ]]; then
    ok "gnome-keyring package KEPT (decided in the TUI)."
    return 0
  elif (( ${YES:-0} )); then
    ok "(auto-kept) gnome-keyring package not uninstalled in non-interactive mode."
    return 0
  fi
  if ask_yes "Remove the gnome-keyring package itself? (Its settings stay on the disk — reinstalling gnome-keyring recovers them.)"; then
    mq_sudo -v || { warn "Password required → gnome-keyring package KEPT."; return 0; }
    if mq_sudo pacman -Rns --noconfirm gnome-keyring; then
      ok "gnome-keyring package removed (settings kept on disk)."
    else
      warn "pacman kept gnome-keyring (another package may depend on it)."
    fi
  else
    ok "gnome-keyring package KEPT — only its session daemon is shadowed."
  fi
}

takeover_secret_service(){
  info "Opt-in: making KeePassXC the system Secret Service (REPLACES gnome-keyring)."
  info "Existing gnome-keyring secrets must be MIGRATED MANUALLY to KeePassXC."
  write_dbus_override
  set_fdo_enabled true
  ok "keepassxc.ini: [FdoSecrets] Enabled=true (backup: $KPXC_INI_BAK)"
  write_autostart_shade
  mask_daemon_service
  offer_gnome_keyring_removal
  start_keepassxc
  info "Still to do in the KeePassXC UI: Settings → Secret Service Integration →"
  info "confirm enabled; Database → Database Settings → expose a group."
}

# ─── entry points ─────────────────────────────────────────────────────────────
do_status(){
  echo "package        : $(command -v keepassxc >/dev/null && echo present || echo absent)"
  echo "fdo secrets    : $(fdo_enabled)   (secret service owned by KeePassXC when yes)"
  echo "browser integ. : $(python3 - "$KPXC_INI" <<'PY' 2>/dev/null || echo no
import configparser, sys
c = configparser.ConfigParser(); c.read(sys.argv[1])
print("yes" if c.getboolean("Browser", "Enabled", fallback=False) else "no")
PY
)"
  echo "chromium link  : $([[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/chromium/NativeMessagingHosts/org.keepassxc.keepassxc_browser.json" ]] && echo manifest-present || echo absent)"
  echo "firefox link   : $([[ -f "$HOME/.mozilla/native-messaging-hosts/org.keepassxc.keepassxc_browser.json" ]] && echo manifest-present || echo absent)"
  echo "tray on close  : $(tray_on_close)"
  echo "dbus override  : $([[ -f $KPXC_DBUS_FILE ]] && echo present || echo absent)"
  echo "gnome-keyring  : $(systemctl --user is-enabled gnome-keyring-daemon.service 2>/dev/null || echo n/a)"
  local pin
  pin="$(grep -E '^LastActiveDatabase=' "$KPXC_INI" 2>/dev/null | cut -d= -f2-)"
  echo "pinned DB      : ${pin:-<none — first KeePassXC run chooses it, then it is pinned>}"
}

do_apply(){
  hr
  if (( WANT_SECRET_SERVICE )); then
    info "KeePassXC — password manager + browser integration + SECRET SERVICE takeover."
  else
    info "KeePassXC — password manager + browser integration (Omarchy keyring left intact)."
  fi
  ensure_package

  # Step 1: make sure Omarchy's keyring is the Secret Service (revert any
  # previous takeover) — unless the user explicitly asked for the takeover.
  if (( WANT_SECRET_SERVICE )); then
    takeover_secret_service
  else
    restore_omarchy_keyring
  fi

  # Step 2: browser integration (both manifests) + tray-on-close.
  install_browser_manifests
  set_tray_on_close

  # Step 3: DEFAULT DATABASE — at the KeePassXC FIRST launch the user chooses
  # (creates or opens) the ONE .kdbx that everything else should use; this
  # module records it into keepassxc.ini (pin step) so every FUTURE launch opens
  # THAT database instead of offering "create a new database" every time.
  info "Pin the default database, keyed to the one KeePassXC opens at its first run…"
  if command -v keepassxc >/dev/null 2>&1; then
    "$(dirname "${BASH_SOURCE[0]}")/keepassxc-default-database.sh" >/dev/null 2>&1 \
      && ok "Default database pinned into keepassxc.ini (RememberLast + LastOpened)". \
      || warn "Database pin NOT set — run 'scripts/apps/keepassxc/keepassxc-default-database.sh FILE.kdbx' manually once your DB exists (see the README in this folder)."
  else
    warn "keepassxc missing — skipping the default-database pin."
  fi

  if ! (( WANT_SECRET_SERVICE )); then
    info "Browser link: in KeePassXC → Settings → Browser Integration, tick the"
    info "browsers you use; then in the browser click the KeePassXC-Browser icon"
    info "→ Connect and grant access."
  fi
  hr
}

# Utility for the module info (_i) as well: the .kdbx we pinned, if any.
pin_info(){
  echo -n ""
  local p
  p="$(dirname "${BASH_SOURCE[0]:-$0}")/keepassxc-default-database.sh"
  [[ -f $p ]] && bash "$p" --status 2>/dev/null || true
}

do_remove(){
  info "Undoing the KeePassXC module (Omarchy defaults restored)"
  restore_omarchy_keyring
  remove_browser_manifests
  ok "KeePassXC database and settings were NEVER touched — they stay installed."
  # Un-pin the remembered default database (the user's own). The whole
  # Remember* / LastOpened* block is dropped from keepassxc.ini; the backup
  # .pre-keepassxc stays untouched.
  if [[ -f "$(dirname "${BASH_SOURCE[0]}")/keepassxc-default-database.sh" ]]; then
    "$(dirname "${BASH_SOURCE[0]}")/keepassxc-default-database.sh" --clear \
      && ok "Default-database pin cleared (stock behaviour — no remembered .kdbx)." \
      || warn "database pin could not be cleared."
  fi
}

case $MODE in
  status) do_status ;;
  remove) do_remove ;;
  *)      do_apply ;;
esac
