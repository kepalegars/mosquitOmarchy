#!/usr/bin/env bash
# patch-move-wires.sh — optional Ableton Move control in Live under wine.
#
# Decision gate (see README, "Move in wine"): the runtime's libusb host bridge
# (0032 + 0106) enumerates every host device and exports exactly what Live and
# the Push helpers import. It is generic, so this patch replaces NO wine file.
# It does the two things wine cannot do for itself:
#
#   1. a udev rule giving the logged-in user access to Ableton's USB devices
#      (/dev/bus/usb/* is root-only otherwise);
#   2. the prefix-wide DllOverride that makes Live load wine's builtin
#      libusb-1.0 (the app folder ships Ableton's native DLL, which Wine would
#      otherwise prefer and which needs a Windows WinUSB driver).
#
# Both are cheap and fully reversible. A runtime update refreshes the prefix
# DLL but keeps user.reg, so --reapply exists for setup-ableton-wires.sh to call
# after every .run install/update.
#
# Usage:
#   patch-move-wires.sh              # apply (default)
#   patch-move-wires.sh --apply
#   patch-move-wires.sh --check      # "move-wine: applied|not applied"
#   patch-move-wires.sh --revert     # restore the previous state
#   patch-move-wires.sh --reapply    # update hook: re-apply if it was applied
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/mosquitomarchy"
MARKER="$STATE_DIR/ableton-move-wine"
_wires_root="${MOSQUITOMARCHY_WIRES_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/mosquitomarchy/runtime/wires}"
DEFAULT_PREFIX="$_wires_root/root/Works/Music-Production/environment"
[[ -d $DEFAULT_PREFIX/drive_c ]] || DEFAULT_PREFIX="$HOME/.wine-ableton"
PREFIX="${ABLETON_PREFIX:-$DEFAULT_PREFIX}"
UDEV="/etc/udev/rules.d/99-ableton-move-live.rules"
UDEV_BODY='# Ableton USB devices (Move, Push, Note): let the logged-in user open the
# display interfaces through libusb (wine'"'"'s host bridge runs as that user).
# Installed by ableton/wires/patch-move-wires.sh.
SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{idVendor}=="2982", MODE="0660", TAG+="uaccess"
'

G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; N='\033[0m'
ok(){ printf " ${G}✓${N} %s\n" "$*"; }
warn(){ printf " ${Y}!${N} %s\n" "$*" >&2; }
err(){ printf " ${R}✗${N} %s\n" "$*" >&2; }

MODE=apply
case "${1:-}" in
  ""|--apply) MODE=apply ;;
  --check)   MODE=check ;;
  --revert)  MODE=revert ;;
  --reapply) MODE=reapply ;;
  -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
  *) err "unknown option: ${1:-} (see --help)"; exit 1 ;;
esac

wine_root(){
  local b
  for b in "$_wires_root"/root/.runtimes/*/bin/wine; do
    [[ -x $b ]] && { dirname "$(dirname "$b")"; return 0; }
  done
  b="$(ls -1d "$HOME"/.local/opt/wine-*/bin/wine 2>/dev/null | sort -V | tail -1 || true)"
  [[ -n $b ]] || return 1
  dirname "$(dirname "$b")"
}

WINE_ROOT="$(wine_root || true)"
WINE="${WINE_ROOT:+$WINE_ROOT/bin/wine}"
WINESERVER="${WINE_ROOT:+$WINE_ROOT/bin/wineserver}"
RUNTIME="$(basename "${WINE_ROOT:-}")"

prefix_ready(){
  [[ -n $WINE && -x $WINE && -d $PREFIX/drive_c ]]
}

wine_up(){
  local p
  for p in $(pgrep -x wineserver 2>/dev/null || true); do
    tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null \
      | grep -qx "WINEPREFIX=$PREFIX" && return 0
  done
  return 1
}

# Registry reads go through user.reg, not `wine reg query`: a query would start
# wineserver on every --check (the TUI asks often) and update hooks must never
# leave a wine process behind. Apply flushes with `wineserver -w` before this
# is trusted.
reg_value(){
  [[ -f $PREFIX/user.reg ]] || return 0
  awk '
    /^\[Software\\\\Wine\\\\DllOverrides\]/ { f=1; next }
    /^\[/ { f=0 }
    f && /^"libusb-1\.0"=/ { sub(/^"libusb-1\.0"="/, ""); sub(/"$/, ""); print; exit }
  ' "$PREFIX/user.reg"
}

reg_flush(){
  [[ -x $WINESERVER ]] || return 0
  WINEPREFIX="$PREFIX" "$WINESERVER" -w >/dev/null 2>&1 || true
}

reg_set(){
  WINEPREFIX="$PREFIX" WINEDEBUG=-all "$WINE" reg add \
    'HKCU\Software\Wine\DllOverrides' /v libusb-1.0 /t REG_SZ /d "$1" /f \
    >/dev/null 2>&1 || return 1
  reg_flush
  [[ "$(reg_value)" == "$1" ]]
}

reg_del(){
  WINEPREFIX="$PREFIX" WINEDEBUG=-all "$WINE" reg delete \
    'HKCU\Software\Wine\DllOverrides' /v libusb-1.0 /f >/dev/null 2>&1 || true
  reg_flush
  [[ -z "$(reg_value)" ]]
}

udev_sha(){ [[ -f $UDEV ]] && sha256sum "$UDEV" | cut -d' ' -f1; }

marker_get(){ # key
  [[ -f $MARKER ]] || return 0
  sed -n "s/^$1=//p" "$MARKER" | head -1
}

# Marker + the state it claims: the udev file hash catches a stale or edited
# rule, and the registry value catches an override lost to a prefix rebuild.
applied(){
  [[ -f $MARKER ]] || return 1
  [[ "$(marker_get runtime)" == "$RUNTIME" ]] || return 1
  [[ -n $RUNTIME ]] || return 1
  [[ "$(marker_get udev_sha)" == "$(udev_sha)" ]] || return 1
  [[ "$(reg_value)" == builtin ]]
}

write_marker(){
  local prev="$1" sha
  sha="$(udev_sha || true)"
  mkdir -p "$STATE_DIR"
  {
    printf 'runtime=%s\n' "$RUNTIME"
    printf 'udev_sha=%s\n' "$sha"
    printf 'override_prev=%s\n' "$prev"
  } > "$MARKER"
}

run_root(){ # one elevation for the whole udev step
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then "$@"; return $?; fi
  if [[ -n ${MQ_ELEVATE_SOURCED:-} ]]; then mq_sudo "$@"; return $?; fi
  local lib="$SCRIPT_DIR/../../../../../../lib/elevate.bash"
  if [[ -f $lib ]]; then
    # shellcheck source=/dev/null
    source "$lib"
    mq_sudo "$@"
    return $?
  fi
  sudo "$@"
}

install_udev(){
  local tmp
  tmp="$(mktemp)"
  printf '%s' "$UDEV_BODY" > "$tmp"
  if [[ -f $UDEV ]] && cmp -s "$tmp" "$UDEV"; then
    rm -f "$tmp"
    ok "udev access rule already current: $UDEV"
    return 0
  fi
  if run_root install -m 0644 "$tmp" "$UDEV"; then
    rm -f "$tmp"
    ok "udev access rule installed: $UDEV"
  else
    rm -f "$tmp"
    err "could not install $UDEV (root required)"
    return 1
  fi
  run_root udevadm control --reload-rules >/dev/null 2>&1 || true
  run_root udevadm trigger --subsystem-match=usb >/dev/null 2>&1 || true
}

remove_udev(){
  [[ -e $UDEV ]] || return 0
  run_root rm -f "$UDEV" || return 1
  run_root udevadm control --reload-rules >/dev/null 2>&1 || true
  ok "udev access rule removed: $UDEV"
}

do_apply(){
  prefix_ready || { err "no wine runtime or prefix ($PREFIX) — install Ableton first"; return 1; }
  [[ -f $PREFIX/drive_c/windows/system32/libusb-1.0.dll ]] \
    || { err "prefix has no libusb-1.0.dll — run the prefix update first"; return 1; }
  if wine_up; then
    err "wine is still running for $PREFIX — close Live and try again"
    return 1
  fi
  local prev
  # Keep the value the FIRST apply recorded: a re-apply sees our own "builtin"
  # and must not mistake it for the state to restore on --revert.
  prev="$(marker_get override_prev)"
  if [[ -z $prev ]]; then
    prev="$(reg_value)"
    [[ -n $prev ]] || prev=__unset__
  fi

  install_udev || return 1
  reg_set builtin || { err "could not set the libusb-1.0 override in $PREFIX"; return 1; }
  ok "Live now loads wine's libusb-1.0 bridge"
  write_marker "$prev"
  ok "move-wine: applied (replug the Move, then start Live)"
}

do_revert(){
  if [[ ! -f $MARKER ]]; then
    printf 'move-wine: not applied\n'
    return 0
  fi
  if wine_up; then
    err "wine is still running for $PREFIX — close Live and try again"
    return 1
  fi
  local prev
  prev="$(marker_get override_prev)"
  # The module uninstall can remove the prefix before this patch row runs;
  # a `wine reg` call would then recreate an empty ~/.wine-ableton.
  if [[ -f $PREFIX/user.reg ]]; then
    if [[ $prev == __unset__ || -z $prev ]]; then
      reg_del || { err "could not remove the libusb-1.0 override"; return 1; }
    else
      reg_set "$prev" || { err "could not restore the previous libusb-1.0 override"; return 1; }
    fi
  else
    warn "prefix absent — no registry value to restore"
  fi
  remove_udev || { err "could not remove the udev rule"; return 1; }
  rm -f "$MARKER"
  ok "move-wine: reverted"
}

do_check(){
  if applied; then
    printf 'move-wine: applied\n'
  else
    printf 'move-wine: not applied\n'
    return 1
  fi
}

case "$MODE" in
  apply)   do_apply ;;
  revert)  do_revert ;;
  reapply)
    if [[ ! -f $MARKER ]]; then
      printf 'move-wine: not applied (nothing to re-apply)\n'
      exit 0
    fi
    if applied; then
      printf 'move-wine: applied (runtime %s unchanged)\n' "$RUNTIME"
      exit 0
    fi
    do_apply
    ;;
  check)   do_check ;;
esac
