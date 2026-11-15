#!/usr/bin/env bash
# =============================================================================
# setup-oscmix.sh — install oscmix-desk for the RME Fireface UCX II
# =============================================================================
# oscmix-desk (https://github.com/relative23/oscmix-desk) builds the upstream
# oscmix backend plus its GTK mixer and adds the declarative desk, the user
# service and the launcher. It talks to the UCX II in Class Compliant mode
# over ALSA sequencer SysEx; it only writes to the interface when a desk is
# applied (routing.conf, at start and on reload).
#
# Everything is per-user (~/.local). The root steps are skipped deliberately:
# no udev hotplug rule, no resume hook, no shared /run lock. A login start
# and the mixer launcher both work without them.
#
# Usage:
#   setup-oscmix.sh              install/update, automatic desk left off
#   setup-oscmix.sh -y           non-interactive
#   setup-oscmix.sh -y --enable  install and enable the automatic desk
#   setup-oscmix.sh --disable    stop and disable the automatic desk
#   setup-oscmix.sh --status     ok | missing: …
#   setup-oscmix.sh --uninstall  remove the per-user install (config kept)
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ELEVATE="$(cd "$ROOT_DIR/../../../.." 2>/dev/null && pwd)/lib/elevate.bash"
if [[ -f $ELEVATE ]]; then
  # shellcheck source=/dev/null
  source "$ELEVATE"
else
  mq_sudo() { sudo "$@"; }
fi

REPO="https://github.com/relative23/oscmix-desk"
# Pinned release. oscmix-desk builds the matching upstream oscmix commit and
# verifies it, so a future upstream change cannot silently alter the backend.
REF="${OSCMIX_DESK_REF:-v0.10.0}"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/mosquitomixbay/oscmix-desk"
LEGACY_DATA="${XDG_DATA_HOME:-$HOME/.local/share}/mosquitomixbay/oscmix"
BIN_DIR="$HOME/.local/bin"
LIB_DIR="$HOME/.local/lib/oscmix-desk"
DEPS=(git make gcc pkgconf alsa-lib gtk3 glib2 python)
BINS=(oscmix alsaseqio oscmix-gtk oscmix-session oscmix-launch)

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf ' \033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf ' \033[1;33m!\033[0m %s\n' "$*" >&2; }
die()  { warn "$*"; exit 1; }

YES=0 MODE=install ENABLE=0
while (($#)); do
  case "$1" in
    -y|--yes) YES=1; shift ;;
    --status) MODE=status; shift ;;
    --uninstall) MODE=uninstall; shift ;;
    --update) MODE=install; shift ;;
    --enable) ENABLE=1; shift ;;
    --disable) MODE=disable; shift ;;
    -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
    *) warn "Unknown option: $1"; exit 2 ;;
  esac
done

ask() {
  local q="$1" def="${2:-y}" r
  ((YES)) && return 0
  if command -v gum >/dev/null 2>&1; then
    gum confirm "$q" --default=$([[ $def == y ]] && echo true || echo false)
    return
  fi
  read -rp "$q [$([ "$def" = y ] && echo Y/n || echo y/N)] " r
  r="${r:-$def}"
  [[ $r =~ ^[oOyY] ]]
}

installed() {
  local b
  for b in "${BINS[@]}"; do
    [[ -x $BIN_DIR/$b ]] || return 1
  done
  [[ -f "$LIB_DIR/oscmix_desk/__init__.py" ]]
}

status() {
  local miss=() b
  for b in "${BINS[@]}"; do
    [[ -x $BIN_DIR/$b ]] || miss+=("$b")
  done
  [[ -f "$LIB_DIR/oscmix_desk/__init__.py" ]] || miss+=("runtime package")
  if ((${#miss[@]})); then
    printf 'missing: %s\n' "${miss[*]}"
    return 1
  fi
  echo ok
}

install_deps() {
  local p miss=()
  command -v pacman >/dev/null 2>&1 || die "pacman not found — install: ${DEPS[*]}"
  for p in "${DEPS[@]}"; do
    pacman -Q "$p" >/dev/null 2>&1 || miss+=("$p")
  done
  ((${#miss[@]})) || return 0
  if ! ask "Install build dependencies with pacman: ${miss[*]}?" y; then
    die "Missing build dependencies: ${miss[*]}"
  fi
  info "Installing ${miss[*]}"
  mq_sudo pacman -S --needed --noconfirm "${miss[@]}"
}

clone_or_update() {
  mkdir -p "$(dirname "$DATA_DIR")"
  if [[ -d $DATA_DIR/.git ]]; then
    info "Updating oscmix-desk source to $REF ($DATA_DIR)"
    git -C "$DATA_DIR" fetch --depth 1 origin "refs/tags/$REF:refs/tags/$REF" 2>/dev/null \
      || git -C "$DATA_DIR" fetch --depth 1 origin
    git -C "$DATA_DIR" checkout -q --detach "$REF"
  else
    info "Fetching oscmix-desk $REF"
    git clone --depth 1 --branch "$REF" "$REPO" "$DATA_DIR"
  fi
}

install_desk() {
  [[ -x $DATA_DIR/install.sh ]] || die "installer missing in $DATA_DIR"
  local flags=(--no-udev)
  if ((ENABLE)); then
    flags+=(--enable)
    info "Installing oscmix-desk and enabling the automatic desk"
  else
    info "Installing oscmix-desk (automatic desk left off)"
  fi
  ( cd "$DATA_DIR" && ./install.sh "${flags[@]}" )
  # The previous upstream-only build left an alsarawio binary and a source
  # checkout behind; oscmix-desk replaces the rest of the same binaries.
  rm -f "$BIN_DIR/alsarawio"
  rm -rf "$LEGACY_DATA"
  ok "oscmix-desk installed in $BIN_DIR"
}

disable_desk() {
  installed || die "oscmix-desk is not installed"
  info "Disabling the automatic desk"
  ( cd "$DATA_DIR" && ./install.sh --disable )
  ok "automatic desk disabled (files and routing.conf kept)"
}

uninstall() {
  info "Removing the per-user oscmix-desk install"
  if [[ -x $DATA_DIR/uninstall.sh ]]; then
    bash "$DATA_DIR/uninstall.sh" || warn "uninstall.sh reported a problem"
  else
    local b
    for b in "${BINS[@]}"; do rm -f "$BIN_DIR/$b"; done
    rm -rf "$LIB_DIR"
  fi
  rm -f "$BIN_DIR/alsarawio"
  rm -rf "$DATA_DIR" "$LEGACY_DATA"
  ok "oscmix-desk removed (routing config kept in ~/.config/oscmix)"
}

case $MODE in
  status)
    status
    ;;
  uninstall)
    uninstall
    ;;
  disable)
    disable_desk
    ;;
  install)
    install_deps
    clone_or_update
    install_desk
    status
    ;;
esac
