#!/usr/bin/env bash
# setup-flea.sh — install Flea and make it the default file manager.
#
# Part of the GUI apps catalog (guis.catalog). Flea is a file manager, so its
# install is not just the package: `flea --default` also makes it the default
# explorer, the Open/Save file chooser and the Super+Shift+F target.
#
# Package choice: Omarchy's signed `flea` package first, then the AUR
# `flea-bin` tagged release. Never `flea-git` (development build). An existing
# flea command (any of the three packages) is left alone.
#
# The USB-SSD Eject patch (RM=0 drives) is parked for now: the function is
# kept below but not called.
#
# Usage:
#   ./setup-flea.sh           # install (if needed) + set defaults
#   ./setup-flea.sh -y        # non-interactive (same as above)
#   ./setup-flea.sh --remove     # undo the defaults only
#   ./setup-flea.sh --uninstall  # undo defaults + remove the package
#   ./setup-flea.sh --status
#   ./setup-flea.sh -h
for __a in "$@"; do
  case $__a in -y|--yes|--remove|--uninstall|--status|-h|--help) export GUI_RUN_EXEC=1 ;; esac
done
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/gui-run.bash"  # gui-run: reopen in a terminal when launched from a file manager
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/elevate.bash"  # mq_sudo: native pkexec prompt when not root
set -euo pipefail

info() { echo -e "\033[1;34m==>\033[0m $*"; }
ok()   { echo -e "\033[1;32m ✓\033[0m $*"; }
warn() { echo -e "\033[1;33m !\033[0m $*"; }
err()  { echo -e "\033[1;31m ✗\033[0m $*" >&2; }

REMOVE=false UNINSTALL=false STATUS=false
for a in "$@"; do case "$a" in
  -y|--yes)    ;;
  --remove)    REMOVE=true ;;
  --uninstall) UNINSTALL=true ;;
  --status)    STATUS=true ;;
  -h|--help)   sed -n '2,21p' "$0"; exit 0 ;;
  *)           echo "Unknown option: $a (supported: -y --remove --uninstall --status)" >&2; exit 1 ;;
esac; done

default_explorer() {
  xdg-mime query default inode/directory 2>/dev/null || true
}

status() {
  if command -v flea >/dev/null 2>&1; then
    local ver
    ver="$(flea --version 2>/dev/null | head -n1 || true)"
    ok "flea installed${ver:+ ($ver)}"
  else
    warn "flea not installed"
  fi
  printf 'default explorer: %s\n' "$(default_explorer)"
}

install_pkg() {
  if command -v flea >/dev/null 2>&1; then
    ok "flea already installed"
    return 0
  fi
  command -v yay >/dev/null 2>&1 || { err "yay is required to install flea"; return 1; }
  if pacman -Si flea >/dev/null 2>&1; then
    info "Installing flea (Omarchy repository)"
    yay -S --needed --noconfirm flea
  elif yay -Si flea-bin >/dev/null 2>&1; then
    info "Installing flea-bin (AUR, latest tagged release)"
    yay -S --needed --noconfirm flea-bin
  else
    err "flea is in neither the Omarchy repository nor the AUR (flea-bin)"
    return 1
  fi
  ok "flea installed"
}

restart_portal() {
  command -v systemctl >/dev/null 2>&1 || return 0
  if systemctl --user restart xdg-desktop-portal.service 2>/dev/null; then
    ok "File chooser portal restarted (new preference active)"
  else
    warn "Could not restart xdg-desktop-portal; log out and back in"
  fi
}

apply_default() {
  if [[ -z ${WAYLAND_DISPLAY:-} && -z ${DISPLAY:-} ]]; then
    warn "No graphical session: run 'flea --default' from your desktop session"
    return 0
  fi
  if flea --default; then
    ok "Flea is the default explorer, file chooser and Super+Shift+F target"
    restart_portal
  else
    err "flea --default failed; run it manually in your session"
    return 1
  fi
}

# External USB SSDs report RM=0, so Flea's stock rule (`rm === true`) hides
# Eject on the exact drive the operator wants to remove. lsblk's TRAN column is
# the marker those partitions inherit from their disk; patch the packaged UI so
# a mounted USB volume offers Eject. Re-applied on every run because a package
# upgrade replaces /usr/share/flea/ui.
fix_usb_eject() {
  local ui=/usr/share/flea/ui
  local dev="$ui/js/Devices.js" qml="$ui/DeviceMounts.qml"
  [[ -f $dev && -f $qml ]] || { warn "Flea UI not found: USB eject fix skipped"; return 0; }
  if grep -q 'usbParent' "$dev" 2>/dev/null && grep -q 'MODEL,TRAN' "$qml" 2>/dev/null; then
    ok "USB eject fix already applied"
    return 0
  fi
  local tmp; tmp="$(mktemp -t flea-usb-eject-XXXXXX.py)" || return 0
  cat > "$tmp" <<'PY'
import sys
from pathlib import Path

dev = Path(sys.argv[1])
qml = Path(sys.argv[2])
changed = 0

s = dev.read_text()
repls = [
    ("function collectVolumes(nodes, model, out) {",
     "function collectVolumes(nodes, model, out, usbParent) {"),
    ("        var own = n.model ? String(n.model) : model",
     "        var own = n.model ? String(n.model) : model\n"
     "        // USB SSDs often report rm=false; the disk's TRAN is inherited by its partitions.\n"
     "        var usb = usbParent === true || String(n.tran || \"\") === \"usb\""),
    ("            out.push(volumeRow(n, own))",
     "            out.push(volumeRow(n, own, usb))"),
    ("        collectVolumes(kids, own, out)",
     "        collectVolumes(kids, own, out, usb)"),
    ("function volumeRow(n, model) {",
     "function volumeRow(n, model, usb) {"),
    ("             removable: n.rm === true, size: deviceBytes(n.size) }",
     "             removable: n.rm === true || usb === true, size: deviceBytes(n.size) }"),
]
for old, new in repls:
    if new in s:
        continue
    if old not in s:
        sys.exit("unexpected Flea UI: " + old)
    s = s.replace(old, new, 1)
    changed += 1
if changed:
    dev.write_text(s)

s = qml.read_text()
old = '"NAME,PATH,LABEL,MOUNTPOINTS,RM,SIZE,TYPE,MODEL"'
new = '"NAME,PATH,LABEL,MOUNTPOINTS,RM,SIZE,TYPE,MODEL,TRAN"'
if new not in s:
    if old not in s:
        sys.exit("unexpected Flea UI: " + old)
    qml.write_text(s.replace(old, new, 1))
    changed += 1
sys.exit(0 if changed else 3)
PY
  if mq_sudo python3 "$tmp" "$dev" "$qml"; then
    ok "USB eject fix applied (external SSDs with RM=0 now offer Eject)"
  else
    warn "could not apply the USB eject fix to /usr/share/flea/ui"
  fi
  rm -f "$tmp"
}

remove_defaults() {
  command -v flea >/dev/null 2>&1 || { ok "flea not installed"; return 0; }
  if flea --default off; then
    ok "Flea defaults undone"
    restart_portal
  else
    err "Flea --default off failed"
    return 1
  fi
}

pkg_has() { pacman -Q "$1" >/dev/null 2>&1; }

remove_package() {
  local p found=0
  for p in flea flea-bin flea-git; do
    pkg_has "$p" || continue
    found=1
    info "Removing $p"
    if mq_sudo pacman -Rns --noconfirm "$p"; then
      ok "$p removed"
    else
      err "$p removal failed"
      return 1
    fi
  done
  ((found)) || ok "flea package not installed"
}

uninstall() {
  remove_defaults || warn "Defaults were not fully undone; removing the package anyway."
  remove_package || return 1
  ok "Flea uninstalled (state ~/.local/state/flea kept)"
}

if $STATUS; then status; exit 0; fi
if $UNINSTALL; then uninstall; exit $?; fi
if $REMOVE; then remove_defaults; exit $?; fi

install_pkg || exit 1
# PARKED: USB-SSD Eject patch (see fix_usb_eject above), re-enable by calling it.
# fix_usb_eject
apply_default
