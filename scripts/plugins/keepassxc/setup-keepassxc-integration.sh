#!/usr/bin/env bash
# =============================================================================
# Omarchy Custom - KeePassXC secret service (REPLACES gnome-keyring)
# =============================================================================
# Makes KeePassXC the desktop's system-wide Secret Service provider
# (freedesktop.org Secret Service, the D-Bus `org.freedesktop.secrets` name)
# instead of gnome-keyring. Applications talking to the system keyring
# (browsers saving passwords, Seahorse, libsecret, secret-tool, …) then
# store/retrieve their secrets in an UNLOCKED KeePassXC database.
#
# IMPORTANT — this REPLACES gnome-keyring COMPLETELY:
#   • every existing gnome-keyring secret (saved app/Wi-Fi passwords, …) is
#     NOT migrating automatically: they must be ported to KeePassXC MANUALLY.
#     (Migrating the passwords/settings from one to the other is planned
#     later; nothing in this script touches them.)
#   • gnome-keyring is NOT removed automatically: setup ASKS whether to
#     remove the package (option). Its settings stay on the disk either way —
#     a plain reinstall of gnome-keyring recovers them.
#   • KeePassXC is a graphical password manager: the exposed database must be
#     opened/unlocked for apps to store secrets (KeePassXC prompts).
#
# What this script does (idempotent, marker-managed):
#   1. Ensures the keepassxc package (pacman).
#   2. Registers KeePassXC as the DBus default Secret Service provider —
#      the upstream-documented user-level override
#      ~/.local/share/dbus-1/services/org.freedesktop.secrets.service
#      (Exec=/usr/bin/keepassxc). The system gnome-keyring file is untouched.
#   3. Shadows gnome-keyring's session autostart so it never races KeePassXC
#      for the D-Bus name: ~/.config/autostart/gnome-keyring-secrets.desktop
#      (Hidden=true — user file wins over /etc/xdg/autostart) and
#      systemctl --user mask gnome-keyring-daemon.service.
#   4. Writes ~/.config/keepassxc/keepassxc.ini → [FdoSecrets] Enabled=true
#      (the same flag KeePassXC itself sets; a .pre-keepassxc backup of the
#      ini is kept on first write).
#   5. Asks (confirm overlay) whether to also UNINSTALL the gnome-keyring
#      package — its settings stay on the disk, a plain reinstall restores.
#   6. Starts KeePassXC so the D-Bus name is owned immediately.
#
# Generic manual step that stays interactive BY DESIGN (KeePassXC keeps the
# exposure inside the encrypted database):
#   • KeePassXC → Tools → Settings → Secret Service Integration → confirm the
#     enable, then Database → Database Settings → Secret Service Integration
#     → expose a group (apps only read/write inside that group).
#
# Usage:
#   ./setup-keepassxc-integration.sh            # apply (idempotent)
#   ./setup-keepassxc-integration.sh --status   # status
#   ./setup-keepassxc-integration.sh --remove   # restore the omarchy default
#   ./setup-keepassxc-integration.sh -y         # non-interactive (nothing asked)
#
# Source: keepassxc docs topics/SecretService.adoc (the exact upstream
# snippet), issues #6274/#13464 (masking gnome-keyring-daemon.service is the
# documented fallback when the D-Bus override alone is not enough).
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

YES=0
for a in "$@"; do case "$a" in
  -y|--yes) YES=1 ;;
  --remove-gnome-keyring) export MOSQUITOMARCHY_KEEPASSXC_REMOVE_GNOME_KEYRING=1 ;;
  --keep-gnome-keyring) export MOSQUITOMARCHY_KEEPASSXC_REMOVE_GNOME_KEYRING=0 ;;
  --status) MODE=status ;;
  --remove|--uninstall) MODE=remove ;;
  -h|--help) sed -n '2,50p' "$0"; exit 0 ;;
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
    zenity --question --title="KeePassXC secret service" --text="$q" 2>/dev/null && return 0
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

# ─── steps ────────────────────────────────────────────────────────────────────
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

# ─── entry points ─────────────────────────────────────────────────────────────
do_status(){
  echo "package      : $(command -v keepassxc >/dev/null && echo present || echo absent)"
  echo "dbus override: $([[ -f $KPXC_DBUS_FILE ]] && echo present || echo absent)"
  echo "ini flagged  : $(fdo_enabled)"
  echo "autostart    : $([[ -f "$KPXC_AUTOSTART_DIR/$KPXC_AUTOSTART_SHADE" ]] && echo shadowed || echo stock)"
  echo "user masking : $(systemctl --user is-enabled gnome-keyring-daemon.service 2>/dev/null || echo n/a)"
}

do_apply(){
  hr
  info "KeePassXC secret service — REPLACES gnome-keyring completely."
  info "Existing gnome-keyring secrets must be MIGRATED MANUALLY to KeePassXC."
  ensure_package
  write_dbus_override
  set_fdo_enabled true
  ok "keepassxc.ini: [FdoSecrets] Enabled=true (backup: $KPXC_INI_BAK)"
  write_autostart_shade
  mask_daemon_service
  start_keepassxc
  offer_gnome_keyring_removal
  info "Still to do in the KeePassXC UI (encrypted in the database, not scriptable):"
  info "  Tools → Settings → Secret Service Integration → confirm enabled;"
  info "  Database → Database Settings → Secret Service Integration → expose a group."
  hr
}

do_remove(){
  info "Restoring the omarchy default (gnome-keyring secret service)"
  rm -f "$KPXC_DBUS_FILE" && ok "DBus keepassxc override removed."
  if [[ -f $KPXC_DBUS_BAK ]]; then
    mv -f "$KPXC_DBUS_BAK" "$KPXC_DBUS_FILE" 2>/dev/null || true
    ok "previous org.freedesktop.secrets owner restored."
  fi
  rm -f "$KPXC_AUTOSTART_DIR/$KPXC_AUTOSTART_SHADE" \
    && ok "gnome-keyring-secrets autostart restored (shadow removed)."
  systemctl --user unmask gnome-keyring-daemon.service > /dev/null 2>&1 \
    && ok "gnome-keyring-daemon.service unmasked."
  set_fdo_enabled false
  ok "keepassxc.ini: [FdoSecrets] Enabled=false (your KeePassXC settings/database keep everything)."
  setsid --fork gnome-keyring-daemon --start --foreground --components=secrets >/dev/null 2>&1 &
  disown
  ok "gnome-keyring secret service started again."
  ok "KeePassXC database and settings were NEVER touched — they stay installed."
}

case $MODE in
  status) do_status ;;
  remove) do_remove ;;
  *)      do_apply ;;
esac
