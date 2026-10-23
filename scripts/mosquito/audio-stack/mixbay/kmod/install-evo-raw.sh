#!/usr/bin/env bash
# kmod/install-evo-raw.sh — installs the evo_raw kernel module that gives
# userspace a USB control handle on Audient EVO interfaces WITHOUT detaching
# snd-usb-audio (binds the unused DFU interface, exposes /dev/evo4 + /dev/evo8).
#
# Upstream: https://github.com/vanzaho/audient-evo-py (public domain, the
# principal reference for mosquitomixbay's EVO protocol). This script does
# NOT vendor the C source: it clones the upstream repo to a cache dir and
# runs its kmod/install.sh (DKMS when available, udev rule, optional
# systemd autoload). Fork it under mosquito/ only if upstream goes stale.
#
# Related (inspiration, other transports — NOT installed here):
#   https://github.com/michaelforney/oscmix        OSC mixer control idiom
#   https://github.com/ismail-bahloul/TuxMix       TUI mixer idiom
#   https://github.com/vijay-prema/audient-evo-linux-tools
#   https://github.com/soerenbnoergaard/evoctl      EVO8 matrix reference
#   https://github.com/subsubl/Evo4mixer
#   https://github.com/hoskere/audient-evo8-rp2350-arduino
#   https://github.com/oudeis01/linux-fireface-mixer  (FireWire/FF400; UCX II
#     over USB is NOT covered by it — mosquitomixbay uses ALSA level 1 there)
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../../lib/elevate.bash"  # mq_sudo

ok()   { echo -e "\033[1;32m ✓\033[0m $*"; }
warn() { echo -e "\033[1;33m !\033[0m $*"; }
die()  { warn "$*"; exit 1; }

UPSTREAM="https://github.com/vanzaho/audient-evo-py"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/mosquitomixbay/audient-evo-py"

if [[ -e /dev/evo8 || -e /dev/evo4 ]]; then
  ok "evo_raw already live ($(ls /dev/evo* 2>/dev/null | tr '\n' ' ')) — nothing to do."
  exit 0
fi

command -v git >/dev/null || die "git required to fetch the kmod sources"
if [[ -d "$CACHE/.git" ]]; then
  git -C "$CACHE" pull --ff-only 2>/dev/null || warn "could not refresh $CACHE — using the cached copy"
else
  mkdir -p "$(dirname "$CACHE")"
  git clone --depth 1 "$UPSTREAM" "$CACHE" || die "clone failed: $UPSTREAM"
fi

[[ -x "$CACHE/kmod/install.sh" ]] || die "upstream layout changed ($CACHE/kmod/install.sh missing) — check $UPSTREAM"
ok "upstream sources ready ($CACHE)"

# The upstream installer asks about DKMS + autoload service itself and needs
# root for depmod/udev. Run it with our sudo primer (one native prompt).
mq_sudo -v || die "sudo required for the kernel module install"
mq_sudo bash "$CACHE/kmod/install.sh"

if [[ -e /dev/evo8 || -e /dev/evo4 ]]; then
  ok "evo_raw live ($(ls /dev/evo* 2>/dev/null | tr '\n' ' '))"
else
  warn "/dev/evo* not present after install — plug the EVO (or reload: sudo modprobe evo_raw) and re-run."
  exit 1
fi
