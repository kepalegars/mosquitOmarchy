#!/usr/bin/env bash
# patch-move-native.sh — Ableton Move USB access for Live 12 (Native).
#
# Native counterpart of wires/patch-move-wires.sh. Only the udev part is
# portable: the Wine patch's DllOverride of libusb-1.0 has no meaning for a
# Linux ELF, so this script never touches a Wine prefix or a Windows DLL.
# Whether Move itself works depends on the support compiled into this Push 3
# based build; the rule only makes the USB devices accessible to your user.
#
# Usage:
#   patch-move-native.sh              # apply (default)
#   patch-move-native.sh --check      # "move-native: applied|not applied"
#   patch-move-native.sh --revert     # remove only the rule we installed
#   patch-move-native.sh --reapply    # re-apply after an update hook
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/../../../../lib/elevate.bash"
if [[ -f $LIB ]]; then
  # shellcheck source=../../../../lib/elevate.bash
  source "$LIB"
else
  mq_sudo(){ sudo "$@"; }
fi

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/mosquitomarchy"
MARKER="$STATE_DIR/ableton-move-native"
UDEV="${MOVE_UDEV_RULE:-/etc/udev/rules.d/99-ableton-move-native.rules}"
UDEV_BODY='# Ableton USB devices (Move, Push, Note): let the logged-in user open
# the USB interfaces through libusb. Installed by native/patch-move-native.sh.
SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{idVendor}=="2982", MODE="0660", TAG+="uaccess"
'

G=$'\033[1;32m'; Y=$'\033[1;33m'; R=$'\033[1;31m'; N=$'\033[0m'
ok(){ printf ' %s✓%s %s\n' "$G" "$N" "$*"; }
warn(){ printf ' %s!%s %s\n' "$Y" "$N" "$*"; }
err(){ printf ' %s✗%s %s\n' "$R" "$N" "$*" >&2; }

MODE=apply
case ${1:-} in
  ""|--apply) MODE=apply ;;
  --check) MODE=check ;;
  --revert) MODE=revert ;;
  --reapply) MODE=reapply ;;
  -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
  *) err "unknown option: $1 (see --help)"; exit 2 ;;
esac

udev_sha(){ [[ -f $UDEV ]] && sha256sum "$UDEV" | cut -d' ' -f1; }
body_sha(){ printf '%s' "$UDEV_BODY" | sha256sum | cut -d' ' -f1; }
marker_sha(){ [[ -f $MARKER ]] && sed -n 's/^udev_sha=//p' "$MARKER" | head -1; }

applied(){
  local want have
  want="$(body_sha)"
  have="$(udev_sha || true)"
  [[ -n $have && $have == "$want" ]]
}

write_rule(){
  local tmp
  tmp="$(mktemp)"
  printf '%s' "$UDEV_BODY" > "$tmp"
  mq_sudo install -m 0644 "$tmp" "$UDEV" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  mq_sudo udevadm control --reload >/dev/null 2>&1 || true
  mq_sudo udevadm trigger >/dev/null 2>&1 || true
  mkdir -p "$STATE_DIR"
  printf 'udev_sha=%s\n' "$(body_sha)" > "$MARKER"
}

if [[ $MODE == check ]]; then
  if applied; then printf 'move-native: applied\n'; else printf 'move-native: not applied\n'; fi
  exit 0
fi

if [[ $MODE == revert ]]; then
  if [[ -f $MARKER ]]; then
    want="$(marker_sha || true)"; have="$(udev_sha || true)"
    if [[ -n $have && $have == "$want" ]]; then
      mq_sudo rm -f "$UDEV" && ok "removed $UDEV" || err "could not remove $UDEV"
    else
      warn "$UDEV was edited or replaced — left untouched."
    fi
    rm -f "$MARKER"
  else
    printf 'move-native: not applied\n'
  fi
  exit 0
fi

if [[ $MODE == reapply ]]; then
  [[ -f $MARKER ]] || { printf 'move-native: not applied\n'; exit 0; }
fi

if applied; then
  ok "udev rule already in place ($UDEV)."
  exit 0
fi

# ldconfig is not always on PATH inside the TUI runner. Accept the library on
# disk too, otherwise a perfectly good install gets a bogus warning.
libusb_ok=0
if command -v ldconfig >/dev/null 2>&1 \
   && ldconfig -p 2>/dev/null | grep -q 'libusb-1.0.so.0'; then
  libusb_ok=1
fi
for f in /usr/lib/libusb-1.0.so.0 /lib/libusb-1.0.so.0 \
         /usr/lib64/libusb-1.0.so.0 /lib64/libusb-1.0.so.0; do
  [[ -e $f ]] && libusb_ok=1
done
(( libusb_ok )) || warn "libusb-1.0 not found — install it before testing Move."
msg(){ printf '==> %s\n' "$*"; }
msg "Installing the Ableton USB udev rule ($UDEV)"
write_rule || { err "Could not write $UDEV."; exit 1; }
ok "udev rule installed. Unplug/replug the Move, then start Live (Native)."
