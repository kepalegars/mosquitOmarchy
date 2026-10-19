#!/usr/bin/env bash
# =============================================================================
# Omarchy Custom - Bluetooth: fix MX Master stutter + general BT instability
# =============================================================================
# CAUSE
#   1. BLE connection parameters too lazy:
#        - /var/lib/bluetooth/<adapter>/<mouse>/info had Latency=44 (the device
#          could skip up to ~330 ms of events) and Min/MaxInterval=6/9.
#        - kernel debugfs defaults were 24/40 (30-50 ms) with conn_latency=0.
#      Together they made the MX Master freeze for a few ms roughly once a
#      second.
#   2. USB autosuspend on the Qualcomm WCN6855 controller (btusb
#      enable_autosuspend=Y, control=auto, 2 s delay) let the adapter sleep
#      between events.
#   3. BlueZ auto-reconnected to every paired A2DP sink (8 speakers here),
#      spamming avdtp "Host is down" every 5 s and congesting the radio, which
#      showed up as intermittent audio glitches on connected speakers.
#
# WHAT THIS DOES
#   - Rewrites the MX Master's (and any other paired LE HID's) ConnectionParameters
#     to MinInterval=6 MaxInterval=7 Latency=0 Timeout=216 (backed up first).
#   - Forces the kernel debugfs defaults to 0/6/7 and installs a udev rule so
#     they are re-applied at every adapter (re)plug.
#   - Disables btusb USB autosuspend (modprobe.d) and switches the controller
#     to control=on at runtime.
#   - Clears ReconnectUUIDs in /etc/bluetooth/main.conf so BlueZ stops polling
#     paired audio devices (backed up first), then restarts bluetooth.
#   - Reconnects the MX Master if it was paired.
#
# Usage:
#   ./fix-bluetooth.sh                 # apply (idempotent)
#   ./fix-bluetooth.sh --status        # read-only report
#   ./fix-bluetooth.sh --remove        # revert everything this script changed
#   ./fix-bluetooth.sh -y              # non-interactive
#   ./fix-bluetooth.sh -h
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/gui-run.bash"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/elevate.bash"
set -uo pipefail

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf ' \033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf ' \033[1;33m!\033[0m %s\n' "$*"; }
err()  { printf ' \033[1;31m✗\033[0m %s\n' "$*" >&2; }

REAL_HOME="${HOME}"
STATE_DIR="$REAL_HOME/.local/state/omarchy-bluetooth"
BACKUP_DIR="$STATE_DIR/backups"
OWNER="$(id -un)"

YES=0
STATUS_ONLY=false
REMOVE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) YES=1; shift ;;
    --status) STATUS_ONLY=true; shift ;;
    --remove|--uninstall) REMOVE=true; shift ;;
    -h|--help) sed -n '1,40p' "$0"; exit 0 ;;
    *) err "Unknown option: $1 (supported: -y --status --remove)"; exit 1 ;;
  esac
done

mkdir -p "$BACKUP_DIR/info"

# ── detection ────────────────────────────────────────────────────────────────
detect_adapter() {
  local h
  for h in /sys/class/bluetooth/hci*; do
    [[ -d $h ]] || continue
    basename "$h"
    return 0
  done
  return 1
}

ADAPTER="$(detect_adapter || true)"
if [[ -z $ADAPTER ]]; then
  err "No Bluetooth adapter (hci*) found."
  exit 1
fi
ADAPTER_MAC="$(bluetoothctl show 2>/dev/null | awk '/^Controller/ {print $2; exit}')"
BT_IFACE="$(readlink -f /sys/class/bluetooth/$ADAPTER/device 2>/dev/null || true)"
USB_DEV="$(basename "$(dirname "$BT_IFACE" 2>/dev/null)" 2>/dev/null || true)"
USB_SYS="/sys/bus/usb/devices/$USB_DEV"
ADAPTER_DIR="/var/lib/bluetooth/$ADAPTER_MAC"
MX_MAC="$(bluetoothctl devices 2>/dev/null | awk '/MX Master/ {print $2; exit}')"

priv() { mq_sudo "$@"; }

# ── helpers ──────────────────────────────────────────────────────────────────
usb_runtime() {
  if [[ -d $USB_SYS ]]; then
    printf 'on' | priv tee "$USB_SYS/power/control" >/dev/null 2>&1 || true
    printf -- '-1' | priv tee "$USB_SYS/power/autosuspend_delay_ms" >/dev/null 2>&1 || true
  fi
}

write_debugfs_now() {
  priv bash -c "echo 0 > /sys/kernel/debug/bluetooth/$ADAPTER/conn_latency 2>/dev/null; echo 6 > /sys/kernel/debug/bluetooth/$ADAPTER/conn_min_interval 2>/dev/null; echo 7 > /sys/kernel/debug/bluetooth/$ADAPTER/conn_max_interval 2>/dev/null" 2>/dev/null || true
}

install_persist() {
  priv mkdir -p /usr/local/bin
  priv tee /usr/local/bin/set_bluetooth_latency.sh >/dev/null <<'EOF'
#!/bin/bash
sleep 3
BT_DEBUG_PATH="/sys/kernel/debug/bluetooth/"
[ -d "$BT_DEBUG_PATH" ] || exit 0
for HCI_PATH in ${BT_DEBUG_PATH}hci*/ ; do
  [ -d "$HCI_PATH" ] || continue
  echo 0 > "${HCI_PATH}conn_latency" 2>/dev/null || true
  echo 6 > "${HCI_PATH}conn_min_interval" 2>/dev/null || true
  echo 7 > "${HCI_PATH}conn_max_interval" 2>/dev/null || true
done
EOF
  priv chmod +x /usr/local/bin/set_bluetooth_latency.sh
  priv tee /etc/udev/rules.d/99-bluetooth-low-latency.rules >/dev/null <<'EOF'
ACTION=="add", SUBSYSTEM=="bluetooth", KERNEL=="hci[0-9]*", RUN+="/usr/local/bin/set_bluetooth_latency.sh"
EOF
  priv udevadm control --reload-rules 2>/dev/null || true
  priv tee /etc/modprobe.d/btusb-autosuspend.conf >/dev/null <<'EOF'
options btusb enable_autosuspend=0
EOF
}

remove_persist() {
  priv rm -f /usr/local/bin/set_bluetooth_latency.sh /etc/udev/rules.d/99-bluetooth-low-latency.rules /etc/modprobe.d/btusb-autosuspend.conf 2>/dev/null || true
  priv udevadm control --reload-rules 2>/dev/null || true
}

backup_info_files() {
  priv bash -c '
    for info in "'"$ADAPTER_DIR"'"/*/info; do
      [ -f "$info" ] || continue
      if grep -q "\\[ConnectionParameters\\]" "$info" 2>/dev/null; then
        mac=$(basename "$(dirname "$info")")
        if [ ! -f "'"$BACKUP_DIR"'/info/$mac.info" ]; then
          cp "$info" "'"$BACKUP_DIR"'/info/$mac.info"
          chown '"$OWNER"':'"$OWNER"' "'"$BACKUP_DIR"'/info/$mac.info"
        fi
      fi
    done
  ' 2>/dev/null || true
}

apply_info_files() {
  priv bash -c '
    for info in "'"$ADAPTER_DIR"'"/*/info; do
      [ -f "$info" ] || continue
      if grep -q "\\[ConnectionParameters\\]" "$info" 2>/dev/null; then
        sed -i -E \
          -e "s/^(MinInterval=).*/\16/" \
          -e "s/^(MaxInterval=).*/\17/" \
          -e "s/^(Latency=).*/\10/" \
          -e "s/^(Timeout=).*/\1216/" \
          "$info" 2>/dev/null || true
      fi
    done
  ' 2>/dev/null || true
}

restore_info_files() {
  priv bash -c '
    for bak in "'"$BACKUP_DIR"'/info/"*.info; do
      [ -f "$bak" ] || continue
      mac=$(basename "$bak" .info)
      info="'$ADAPTER_DIR'/$mac/info"
      [ -f "$info" ] && cp "$bak" "$info"
    done
  ' 2>/dev/null || true
}

backup_main_conf() {
  if [[ ! -f "$BACKUP_DIR/main.conf.bak" ]]; then
    cp /etc/bluetooth/main.conf "$BACKUP_DIR/main.conf.bak" 2>/dev/null || true
  fi
}

apply_main_conf() {
  backup_main_conf
  if grep -q '^ReconnectUUIDs=' /etc/bluetooth/main.conf; then
    priv sed -i 's/^ReconnectUUIDs=.*/ReconnectUUIDs=/' /etc/bluetooth/main.conf
  else
    # insert under [Policy] if present
    if grep -q '^\[Policy\]' /etc/bluetooth/main.conf; then
      priv sed -i '/^\[Policy\]/a ReconnectUUIDs=' /etc/bluetooth/main.conf
    fi
  fi
}

restore_main_conf() {
  if [[ -f "$BACKUP_DIR/main.conf.bak" ]]; then
    priv cp "$BACKUP_DIR/main.conf.bak" /etc/bluetooth/main.conf
  fi
}

status() {
  info "Bluetooth fix — status"
  printf '    adapter        : %s (%s)\n' "$ADAPTER" "$ADAPTER_MAC"
  printf '    usb device     : %s\n' "$USB_DEV"
  if [[ -d $USB_SYS ]]; then
    printf '    usb control    : %s\n' "$(cat "$USB_SYS/power/control" 2>/dev/null || echo '?')"
    printf '    usb delay(ms)  : %s\n' "$(cat "$USB_SYS/power/autosuspend_delay_ms" 2>/dev/null || echo '?')"
  fi
  printf '    debugfs latency: %s\n' "$(priv cat /sys/kernel/debug/bluetooth/$ADAPTER/conn_latency 2>/dev/null || echo '?')"
  printf '    debugfs min/max: %s / %s\n' \
    "$(priv cat /sys/kernel/debug/bluetooth/$ADAPTER/conn_min_interval 2>/dev/null || echo '?')" \
    "$(priv cat /sys/kernel/debug/bluetooth/$ADAPTER/conn_max_interval 2>/dev/null || echo '?')"
  printf '    ReconnectUUIDs  : %s\n' "$(grep '^ReconnectUUIDs=' /etc/bluetooth/main.conf 2>/dev/null || echo '<unset>')"
  printf '    persist files  : %s %s %s\n' \
    "$([[ -f /usr/local/bin/set_bluetooth_latency.sh ]] && echo yes || echo no)" \
    "$([[ -f /etc/udev/rules.d/99-bluetooth-low-latency.rules ]] && echo yes || echo no)" \
    "$([[ -f /etc/modprobe.d/btusb-autosuspend.conf ]] && echo yes || echo no)"
  if [[ -n $MX_MAC ]]; then
    printf '    MX Master      : %s (%s)\n' "$MX_MAC" "$(bluetoothctl info "$MX_MAC" 2>/dev/null | awk -F': ' '/Connected/ {print $2}')"
  else
    printf '    MX Master      : not paired\n'
  fi
  local n
  n=$(bluetoothctl devices 2>/dev/null | wc -l)
  printf '    paired devices : %s\n' "$n"
  priv bash -c '
    for info in "'"$ADAPTER_DIR"'"/*/info; do
      [ -f "$info" ] || continue
      if grep -q "\\[ConnectionParameters\\]" "$info" 2>/dev/null; then
        mac=$(basename "$(dirname "$info")")
        lat=$(awk -F= "/^Latency=/{print \$2}" "$info" 2>/dev/null)
        printf "    %-18s Latency=%s\\n" "$mac" "${lat:-?}"
      fi
    done
  ' 2>/dev/null || true
}

apply() {
  info "Applying Bluetooth fix"
  backup_info_files
  apply_info_files
  ok "ConnectionParameters updated (Latency=0, 6/7) for paired LE HID devices"

  install_persist
  ok "Persistence installed (udev + modprobe + debugfs script)"

  write_debugfs_now
  ok "debugfs set to 0/6/7 for $ADAPTER"

  usb_runtime
  ok "USB autosuspend disabled for $USB_DEV"

  apply_main_conf
  ok "ReconnectUUIDs cleared (stops AVDTP polling of paired speakers)"

  priv systemctl restart bluetooth.service >/dev/null 2>&1 || true
  ok "bluetooth.service restarted"
  sleep 2
  write_debugfs_now

  if [[ -n $MX_MAC ]]; then
    bluetoothctl connect "$MX_MAC" >/dev/null 2>&1 || true
    ok "Reconnected MX Master ($MX_MAC)"
  fi
  echo
  ok "Done. Test the mouse for ~1 minute."
}

remove() {
  info "Removing Bluetooth fix"
  remove_persist
  restore_info_files
  restore_main_conf
  # restore USB runtime to auto
  if [[ -d $USB_SYS ]]; then
    printf 'auto' | priv tee "$USB_SYS/power/control" >/dev/null 2>&1 || true
    printf '2000' | priv tee "$USB_SYS/power/autosuspend_delay_ms" >/dev/null 2>&1 || true
  fi
  priv systemctl restart bluetooth.service >/dev/null 2>&1 || true
  if [[ -n $MX_MAC ]]; then
    bluetoothctl connect "$MX_MAC" >/dev/null 2>&1 || true
  fi
  ok "Reverted. (Backups kept in $BACKUP_DIR)"
}

if $STATUS_ONLY; then
  status
elif $REMOVE; then
  info "Removing the Bluetooth fix"
  remove
else
  info "Applying the Bluetooth fix"
  if (( YES == 0 )); then
    if command -v gum >/dev/null 2>&1; then
      gum confirm "Apply Bluetooth fix (BLE params + USB autosuspend + AVDTP polling)?" --default=true || { info "Aborted."; exit 0; }
    else
      read -rp "Apply Bluetooth fix? [Y/n] " ans
      [[ ${ans:-Y} =~ ^[yYoO]$ ]] || { info "Aborted."; exit 0; }
    fi
  fi
  apply
fi
