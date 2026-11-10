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
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../../../lib/elevate.bash"  # mq_sudo

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

# The upstream installer only builds when DKMS is present; without it it
# stops on an interactive prompt, builds nothing, and the bay stays in DEMO.
# Install it first so a -y/onboarding run has everything it needs.
if ! command -v dkms >/dev/null 2>&1; then
  command -v pacman >/dev/null 2>&1 \
    || die "dkms required to build evo_raw — install it, or build evo_raw.c by hand."
  mq_sudo pacman -S --needed --noconfirm dkms || die "could not install dkms"
fi

# install.sh is interactive (device menu, dialout, autoload). Answer it here or
# a non-interactive run stops at the first prompt with nothing built: pick the
# connected EVO (rules are listed evo4, evo8), decline dialout (70-mixbay-evo
# already grants uaccess) and autoload (evoctl is not installed by Mixbay).
mq_sudo -v || die "sudo required for the kernel module install"
_choice=1
for _f in /sys/bus/usb/devices/*/idVendor; do
  [[ "$(cat "$_f" 2>/dev/null)" == 2708 ]] || continue
  [[ "$(cat "${_f%idVendor}idProduct" 2>/dev/null)" == 0007 ]] && _choice=2
done
printf '%s\nn\nn\n' "$_choice" | mq_sudo bash "$CACHE/kmod/install.sh"

# The upstream installer builds DKMS only for the kernel it runs under. With
# both linux and linux-omarchy installed, booting the other kernel left
# /dev/evo8 missing and Mixbay silently fell back to DEMO. Build for every
# installed kernel and load the module at boot so a kernel switch cannot
# break the bay again.
if command -v dkms >/dev/null 2>&1; then
  mq_sudo dkms autoinstall \
    || warn "dkms autoinstall failed — build the running kernel with: sudo dkms install evo_raw/0.1 -k $(uname -r)"
fi
mq_sudo bash -c 'printf "%s\n" evo_raw > /etc/modules-load.d/evo_raw.conf; modprobe evo_raw' \
  || warn "could not load evo_raw now — run: sudo modprobe evo_raw"

if [[ -e /dev/evo8 || -e /dev/evo4 ]]; then
  ok "evo_raw live ($(ls /dev/evo* 2>/dev/null | tr '\n' ' '))"
else
  warn "/dev/evo* not present after install — plug the EVO (or reload: sudo modprobe evo_raw) and re-run."
  exit 1
fi
