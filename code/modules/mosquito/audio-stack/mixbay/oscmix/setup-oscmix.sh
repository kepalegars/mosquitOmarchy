#!/usr/bin/env bash
# =============================================================================
# setup-oscmix.sh — build oscmix + the GTK mixer for the RME Fireface UCX II
# =============================================================================
# oscmix talks to the UCX II over USB MIDI SysEx in Class Compliant mode and
# exposes the mixer over OSC. This installs user-local binaries and never
# writes to the interface: no ALSA control, no card register, no udev rule for
# the card itself.
#
#   oscmix       OSC daemon (raw MIDI <-> OSC)
#   alsarawio    opens the ALSA raw MIDI port for oscmix
#   alsaseqio    ALSA sequencer alternative (installed for convenience)
#   oscmix-gtk   GTK frontend (OSC client)
#
# Usage:
#   setup-oscmix.sh              install/update (interactive)
#   setup-oscmix.sh -y           non-interactive
#   setup-oscmix.sh --status     ok | missing: …
#   setup-oscmix.sh --uninstall  remove the user-local binaries/source only
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

REPO="https://github.com/michaelforney/oscmix"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/mosquitomixbay/oscmix"
BIN_DIR="$HOME/.local/bin"
SCHEMA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/glib-2.0/schemas"
DEPS=(gcc make pkgconf git gtk3 alsa-lib alsa-utils)

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf ' \033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf ' \033[1;33m!\033[0m %s\n' "$*" >&2; }
die()  { warn "$*"; exit 1; }

YES=0 MODE=install
while (($#)); do
  case "$1" in
    -y|--yes) YES=1; shift ;;
    --status) MODE=status; shift ;;
    --uninstall) MODE=uninstall; shift ;;
    --update) MODE=install; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
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
  for b in oscmix alsarawio alsaseqio oscmix-gtk; do
    [[ -x $BIN_DIR/$b ]] || return 1
  done
  [[ -f $SCHEMA_DIR/oscmix.gschema.xml ]]
}

status() {
  local miss=() b
  for b in oscmix alsarawio alsaseqio oscmix-gtk; do
    [[ -x $BIN_DIR/$b ]] || miss+=("$b")
  done
  [[ -f $SCHEMA_DIR/oscmix.gschema.xml ]] || miss+=("oscmix.gschema.xml")
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
    info "Updating oscmix source ($DATA_DIR)"
    git -C "$DATA_DIR" fetch --depth 1 origin
    git -C "$DATA_DIR" reset --hard FETCH_HEAD
  else
    info "Fetching oscmix source"
    git clone --depth 1 "$REPO" "$DATA_DIR"
  fi
}

build_and_install() {
  local jobs
  jobs="$(nproc 2>/dev/null || echo 2)"
  info "Building oscmix + GTK mixer"
  make -C "$DATA_DIR" -j"$jobs"
  make -C "$DATA_DIR/gtk" -j"$jobs"
  [[ -x $DATA_DIR/gtk/oscmix-gtk ]] || die "GTK build did not produce oscmix-gtk"

  install -d "$BIN_DIR" "$SCHEMA_DIR"
  install -m 0755 "$DATA_DIR/oscmix" "$DATA_DIR/alsarawio" "$DATA_DIR/alsaseqio" "$BIN_DIR/"
  install -m 0755 "$DATA_DIR/gtk/oscmix-gtk" "$BIN_DIR/"
  install -m 0644 "$DATA_DIR/gtk/oscmix.gschema.xml" "$SCHEMA_DIR/"
  glib-compile-schemas "$SCHEMA_DIR"
  ok "oscmix installed in $BIN_DIR (GTK schema in $SCHEMA_DIR)"
}

uninstall() {
  info "Removing user-local oscmix"
  rm -f "$BIN_DIR/oscmix" "$BIN_DIR/alsarawio" "$BIN_DIR/alsaseqio" "$BIN_DIR/oscmix-gtk"
  rm -f "$SCHEMA_DIR/oscmix.gschema.xml"
  glib-compile-schemas "$SCHEMA_DIR" 2>/dev/null || true
  rm -rf "$DATA_DIR"
  ok "oscmix removed (pacman build dependencies left in place)"
}

case $MODE in
  status)
    status
    ;;
  uninstall)
    uninstall
    ;;
  install)
    install_deps
    clone_or_update
    build_and_install
    status
    ;;
esac
