#!/usr/bin/env bash
# =============================================================================
# mosquitOmarchy - Bluetooth: fix MX Master stutter + general BT instability
# =============================================================================
# CAUSE
#   1. BLE connection parameters too lazy:
#        - /var/lib/bluetooth/<adapter>/<mouse>/info had Latency=44 (the device
#          could skip up to ~330 ms of events) and Min/MaxInterval=6/9.
#        - kernel debugfs defaults were 24/40 (30-50 ms) with conn_latency=0.
#      Together they made the MX Master freeze for a few ms roughly once a
#      second.
#   2. BUG IN THE PREVIOUS APPLY ORDER: ConnectionParameters were written to
#      the info files *after* `systemctl restart bluetooth`. bluetoothd only
#      reads those files at startup, so it kept Latency=44 in memory while the
#      on-disk file already said Latency=0 — reconnects still negotiated 44.
#   3. USB autosuspend on the Qualcomm BT controller (btusb
#      enable_autosuspend=Y) and its parent hub (control=auto, delay=0).
#   4. BlueZ auto-reconnected to every paired A2DP sink (many speakers here),
#      spamming avdtp "Host is down" every 5 s and congesting the radio.
#
# WHAT THIS DOES
#   - Stops bluetoothd, rewrites LE HID ConnectionParameters to
#     MinInterval=6 MaxInterval=7 Latency=0 Timeout=216, THEN starts bluetoothd
#     so the daemon actually loads the new values (backed up first).
#   - Forces kernel debugfs defaults to 0/6/7 and installs a udev rule so
#     they are re-applied at every adapter (re)plug.
#   - Disables btusb USB autosuspend (modprobe.d) and sets control=on on the
#     controller *and* its USB parent hub (runtime + udev persistence).
#   - Clears ReconnectUUIDs and sets ReconnectAttempts=0 in main.conf so
#     BlueZ stops polling paired audio devices (backed up first).
#   - Reconnects the MX Master if it was paired.
#
# Usage:
#   ./fix-bluetooth.sh                 # apply (idempotent)
#   ./fix-bluetooth.sh --status        # read-only report
#   ./fix-bluetooth.sh --remove        # revert everything this script changed
#   ./fix-bluetooth.sh -y              # non-interactive
#   ./fix-bluetooth.sh -h
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/gui-run.bash"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/elevate.bash"
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
    -h|--help) sed -n '1,45p' "$0"; exit 0 ;;
    *) err "Unknown option: $1 (supported: -y --status --remove)"; exit 1 ;;
  esac
done

mkdir -p "$BACKUP_DIR/info"

# ── detection ────────────────────────────────────────────────────────────────
# Avoid `ls` — some systems alias it to eza and break parsing.
detect_adapter() {
  local h
  for h in /sys/class/bluetooth/hci[0-9]*; do
    [[ -d $h ]] || continue
    # Skip hci0:N link/channel nodes; only top-level adapters.
    [[ $(basename "$h") == *:* ]] && continue
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
# Parent hub (e.g. 1-3.1 → 1-3). Autosuspend there also stalls the controller.
USB_PARENT=""
if [[ -n $USB_DEV && $USB_DEV == *.* ]]; then
  USB_PARENT="${USB_DEV%.*}"
fi
ADAPTER_DIR="/var/lib/bluetooth/$ADAPTER_MAC"
MX_MAC="$(bluetoothctl devices 2>/dev/null | awk '/MX Master/ {print $2; exit}')"

priv() { mq_sudo "$@"; }

# ── helpers ──────────────────────────────────────────────────────────────────
usb_set_on() {
  local sys="$1"
  [[ -d $sys ]] || return 0
  printf 'on' | priv tee "$sys/power/control" >/dev/null 2>&1 || true
  printf -- '-1' | priv tee "$sys/power/autosuspend_delay_ms" >/dev/null 2>&1 || true
}

usb_runtime() {
  usb_set_on "$USB_SYS"
  [[ -n $USB_PARENT ]] && usb_set_on "/sys/bus/usb/devices/$USB_PARENT"
}

write_debugfs_now() {
  local a
  a="$(detect_adapter || echo "$ADAPTER")"
  [[ -n $a ]] || return 0
  priv bash -c "echo 0 > /sys/kernel/debug/bluetooth/$a/conn_latency 2>/dev/null; echo 6 > /sys/kernel/debug/bluetooth/$a/conn_min_interval 2>/dev/null; echo 7 > /sys/kernel/debug/bluetooth/$a/conn_max_interval 2>/dev/null" 2>/dev/null || true
}

install_persist() {
  priv mkdir -p /usr/local/bin
  # Combined: debugfs LE defaults + USB autosuspend off for the BT controller tree.
  priv tee /usr/local/bin/set_bluetooth_latency.sh >/dev/null <<'EOF'
#!/bin/bash
# Re-apply low-latency BLE defaults + keep the BT USB path awake.
sleep 2
BT_DEBUG_PATH="/sys/kernel/debug/bluetooth/"
if [ -d "$BT_DEBUG_PATH" ]; then
  for HCI_PATH in ${BT_DEBUG_PATH}hci*/ ; do
    [ -d "$HCI_PATH" ] || continue
    case "$(basename "$HCI_PATH")" in *:*) continue ;; esac
    echo 0 > "${HCI_PATH}conn_latency" 2>/dev/null || true
    echo 6 > "${HCI_PATH}conn_min_interval" 2>/dev/null || true
    echo 7 > "${HCI_PATH}conn_max_interval" 2>/dev/null || true
  done
fi
# Walk every hci* → its USB device + parent hub; force runtime PM off.
for hci in /sys/class/bluetooth/hci[0-9]*; do
  [ -d "$hci" ] || continue
  case "$(basename "$hci")" in *:*) continue ;; esac
  iface="$(readlink -f "$hci/device" 2>/dev/null)" || continue
  usbdev="$(dirname "$iface" 2>/dev/null)"
  for node in "$usbdev" "$(dirname "$usbdev" 2>/dev/null)"; do
    [ -d "$node/power" ] || continue
    echo on > "$node/power/control" 2>/dev/null || true
    echo -1 > "$node/power/autosuspend_delay_ms" 2>/dev/null || true
  done
done
EOF
  priv chmod +x /usr/local/bin/set_bluetooth_latency.sh

  priv tee /etc/udev/rules.d/99-bluetooth-low-latency.rules >/dev/null <<'EOF'
# LE connection defaults after the adapter appears
ACTION=="add", SUBSYSTEM=="bluetooth", KERNEL=="hci[0-9]*", RUN+="/usr/local/bin/set_bluetooth_latency.sh"
# Keep the BT controller USB device awake (btusb)
ACTION=="add", SUBSYSTEM=="usb", DRIVER=="btusb", RUN+="/usr/local/bin/set_bluetooth_latency.sh"
EOF
  priv udevadm control --reload-rules 2>/dev/null || true

  priv tee /etc/modprobe.d/btusb-autosuspend.conf >/dev/null <<'EOF'
options btusb enable_autosuspend=0
EOF
}

remove_persist() {
  priv rm -f /usr/local/bin/set_bluetooth_latency.sh \
    /etc/udev/rules.d/99-bluetooth-low-latency.rules \
    /etc/modprobe.d/btusb-autosuspend.conf 2>/dev/null || true
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

# Ensure a Policy key is set to VALUE (uncommented). Insert under [Policy] if missing.
set_policy_key() {
  local key="$1" value="$2"
  if grep -q "^${key}=" /etc/bluetooth/main.conf; then
    priv sed -i "s/^${key}=.*/${key}=${value}/" /etc/bluetooth/main.conf
  elif grep -q "^#${key}=" /etc/bluetooth/main.conf; then
    priv sed -i "s/^#${key}=.*/${key}=${value}/" /etc/bluetooth/main.conf
  elif grep -q '^\[Policy\]' /etc/bluetooth/main.conf; then
    priv sed -i "/^\[Policy\]/a ${key}=${value}" /etc/bluetooth/main.conf
  fi
}

apply_main_conf() {
  backup_main_conf
  # Empty ReconnectUUIDs alone is not always enough (some BlueZ builds treat an
  # empty list like "unset" and fall back to the built-in A2DP/HFP defaults).
  set_policy_key ReconnectUUIDs ""
  set_policy_key ReconnectAttempts 0
}

restore_main_conf() {
  if [[ -f "$BACKUP_DIR/main.conf.bak" ]]; then
    priv cp "$BACKUP_DIR/main.conf.bak" /etc/bluetooth/main.conf
  fi
}

connect_mx() {
  [[ -n $MX_MAC ]] || return 0
  bluetoothctl power on >/dev/null 2>&1 || true
  # A single hung connect leaves BlueZ in InProgress; give it a few tries.
  local i
  for i in 1 2 3 4 5; do
    if bluetoothctl info "$MX_MAC" 2>/dev/null | grep -q 'Connected: yes'; then
      ok "MX Master already connected ($MX_MAC)"
      return 0
    fi
    timeout 8 bluetoothctl connect "$MX_MAC" >/dev/null 2>&1 || true
    sleep 1
    if bluetoothctl info "$MX_MAC" 2>/dev/null | grep -q 'Connected: yes'; then
      ok "Reconnected MX Master ($MX_MAC)"
      return 0
    fi
  done
  warn "MX Master not connected yet — move the mouse or click a button, then: bluetoothctl connect $MX_MAC"
}

status() {
  info "Bluetooth fix — status"
  printf '    adapter        : %s (%s)\n' "$ADAPTER" "$ADAPTER_MAC"
  printf '    usb device     : %s\n' "$USB_DEV"
  printf '    usb parent     : %s\n' "${USB_PARENT:-none}"
  if [[ -d $USB_SYS ]]; then
    printf '    usb control    : %s\n' "$(cat "$USB_SYS/power/control" 2>/dev/null || echo '?')"
    printf '    usb delay(ms)  : %s\n' "$(cat "$USB_SYS/power/autosuspend_delay_ms" 2>/dev/null || echo '?')"
  fi
  if [[ -n $USB_PARENT && -d /sys/bus/usb/devices/$USB_PARENT ]]; then
    printf '    parent control : %s\n' "$(cat /sys/bus/usb/devices/$USB_PARENT/power/control 2>/dev/null || echo '?')"
  fi
  printf '    debugfs latency: %s\n' "$(priv cat /sys/kernel/debug/bluetooth/$ADAPTER/conn_latency 2>/dev/null || echo '?')"
  printf '    debugfs min/max: %s / %s\n' \
    "$(priv cat /sys/kernel/debug/bluetooth/$ADAPTER/conn_min_interval 2>/dev/null || echo '?')" \
    "$(priv cat /sys/kernel/debug/bluetooth/$ADAPTER/conn_max_interval 2>/dev/null || echo '?')"
  printf '    ReconnectUUIDs  : %s\n' "$(grep '^ReconnectUUIDs=' /etc/bluetooth/main.conf 2>/dev/null || echo '<unset>')"
  printf '    ReconnectAttempts: %s\n' "$(grep '^ReconnectAttempts=' /etc/bluetooth/main.conf 2>/dev/null || echo '<unset>')"
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
        max=$(awk -F= "/^MaxInterval=/{print \$2}" "$info" 2>/dev/null)
        printf "    %-18s Latency=%s MaxInterval=%s\\n" "$mac" "${lat:-?}" "${max:-?}"
      fi
    done
  ' 2>/dev/null || true
}

apply() {
  info "Applying Bluetooth fix"
  backup_info_files
  ok "Backed up ConnectionParameters for paired LE HID devices"

  install_persist
  ok "Persistence installed (udev + modprobe + debugfs/USB script)"

  apply_main_conf
  ok "ReconnectUUIDs cleared + ReconnectAttempts=0 (stops AVDTP polling)"

  # CRITICAL ORDER: bluetoothd only reads ConnectionParameters from the info
  # files at startup. Editing them after a restart leaves Latency=44 in memory
  # while the file on disk already says 0 — which is exactly the stutter bug.
  # Stop → patch files → start, so the daemon loads Latency=0.
  info "Stopping bluetoothd to reload ConnectionParameters"
  if [[ -n $MX_MAC ]]; then
    bluetoothctl disconnect "$MX_MAC" >/dev/null 2>&1 || true
  fi
  # Bounded: a stuck systemd job used to keep the TUI on "applying" with no
  # output for minutes. The job may still finish; the restart below retries.
  priv timeout 20 systemctl stop bluetooth.service >/dev/null 2>&1 || true
  sleep 1

  apply_info_files
  ok "ConnectionParameters updated on disk (Latency=0, MaxInterval=7)"

  priv timeout 20 systemctl start bluetooth.service >/dev/null 2>&1 || true
  ok "bluetooth.service started (loads new LE params)"
  sleep 2

  # Re-detect adapter in case numbering changed after restart.
  ADAPTER="$(detect_adapter || echo "$ADAPTER")"
  write_debugfs_now
  ok "debugfs set to 0/6/7 for $ADAPTER"

  usb_runtime
  ok "USB autosuspend disabled for ${USB_DEV}${USB_PARENT:+ + parent $USB_PARENT}"

  connect_mx
  echo
  ok "Done. Test the mouse for ~1 minute — micro-freezes should be gone."
}

remove() {
  info "Removing Bluetooth fix"
  remove_persist
  # Restore info + main.conf while bluetoothd is stopped so it reloads old values.
  priv timeout 20 systemctl stop bluetooth.service >/dev/null 2>&1 || true
  sleep 1
  restore_info_files
  restore_main_conf
  priv timeout 20 systemctl start bluetooth.service >/dev/null 2>&1 || true
  sleep 2
  # restore USB runtime to auto
  if [[ -d $USB_SYS ]]; then
    printf 'auto' | priv tee "$USB_SYS/power/control" >/dev/null 2>&1 || true
    printf '2000' | priv tee "$USB_SYS/power/autosuspend_delay_ms" >/dev/null 2>&1 || true
  fi
  if [[ -n $USB_PARENT && -d /sys/bus/usb/devices/$USB_PARENT ]]; then
    printf 'auto' | priv tee "/sys/bus/usb/devices/$USB_PARENT/power/control" >/dev/null 2>&1 || true
  fi
  connect_mx
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
