#!/usr/bin/env bash
# =============================================================================
# setup-oscmix.sh — build oscmix (huddx01 fork) + its GTK mixer for RME cards
# =============================================================================
# oscmix speaks RME's MIDI SysEx protocol in Class Compliant mode and exposes
# OSC. The huddx01 fork adds the 802/UCX/UCX II/UFX/UFX II/UFX III/UFX+ control
# surfaces and a Qt frontend. Mixbay installs the engine, the GTK mixer and,
# when the nightly release publishes it, the Qt AppImage.
#
# Everything is per-user (~/.local); nothing is written to the interface and
# no service is installed. The mixer is started on demand by
# mixbay-oscmix-gtk / mixbay-oscmix-qt.
#
# Usage:
#   setup-oscmix.sh              install/update the engine + GTK mixer
#   setup-oscmix.sh -y           non-interactive
#   setup-oscmix.sh --qt         download/update only the Qt AppImage
#   setup-oscmix.sh --status     ok | missing: …
#   setup-oscmix.sh --uninstall  remove the per-user install
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

REPO="https://github.com/huddx01/oscmix"
# Pinned dev commit: the fork's device support, not a moving branch.
REF="${OSCMIX_REF:-4ef278368389c1469f950651e19ef66627d634de}"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/mosquitomixbay/oscmix"
BIN_DIR="$HOME/.local/bin"
LIB_DIR="$HOME/.local/lib/oscmix"
QT_APPIMAGE="$LIB_DIR/oscmix-qt.AppImage"
DEPS=(git make gcc pkgconf alsa-lib gtk3 glib2 avahi)
BINS=(oscmix alsaseqio alsarawio oscmix-gtk)

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
    --qt) MODE=qt; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) warn "Unknown option: $1"; exit 2 ;;
  esac
done

ask() {
  local q="$1" r
  ((YES)) && return 0
  if command -v gum >/dev/null 2>&1; then
    gum confirm "$q"
    return
  fi
  read -rp "$q [Y/n] " r
  [[ ${r:-y} =~ ^[oOyY] ]]
}

installed() {
  local b
  for b in "${BINS[@]}"; do
    [[ -x $BIN_DIR/$b ]] || return 1
  done
  [[ -f $LIB_DIR/gtk/gschemas.compiled ]]
}

status() {
  local miss=() b
  for b in "${BINS[@]}"; do
    [[ -x $BIN_DIR/$b ]] || miss+=("$b")
  done
  [[ -f $LIB_DIR/gtk/gschemas.compiled ]] || miss+=("GTK settings schema")
  if ((${#miss[@]})); then
    printf 'missing: %s\n' "${miss[*]}"
    [[ -x $QT_APPIMAGE ]] && echo "qt: ok"
    return 1
  fi
  echo ok
  [[ -x $QT_APPIMAGE ]] && echo "qt: ok" || echo "qt: missing"
}

install_deps() {
  local p miss=()
  command -v pacman >/dev/null 2>&1 || die "pacman not found — install: ${DEPS[*]}"
  for p in "${DEPS[@]}"; do
    pacman -Q "$p" >/dev/null 2>&1 || miss+=("$p")
  done
  ((${#miss[@]})) || return 0
  ask "Install build dependencies with pacman: ${miss[*]}?" \
    || die "Missing build dependencies: ${miss[*]}"
  info "Installing ${miss[*]}"
  mq_sudo pacman -S --needed --noconfirm "${miss[@]}"
}

fetch_source() {
  mkdir -p "$DATA_DIR"
  if [[ ! -d $DATA_DIR/.git ]]; then
    info "Fetching oscmix $REF"
    git -C "$DATA_DIR" init -q
    git -C "$DATA_DIR" remote add origin "$REPO"
  fi
  info "Checking out oscmix $REF"
  git -C "$DATA_DIR" fetch -q --depth 1 origin "$REF"
  git -C "$DATA_DIR" checkout -q --detach FETCH_HEAD
}

build_engine() {
  info "Building oscmix, alsaseqio, alsarawio and oscmix-gtk"
  ( cd "$DATA_DIR" && make oscmix alsaseqio alsarawio gtk )
}

install_engine() {
  local b
  for b in oscmix alsaseqio alsarawio; do
    install -Dm755 "$DATA_DIR/$b" "$BIN_DIR/$b"
  done
  install -Dm755 "$DATA_DIR/gtk/oscmix-gtk" "$BIN_DIR/oscmix-gtk"
  install -Dm644 "$DATA_DIR/gtk/gschemas.compiled" "$LIB_DIR/gtk/gschemas.compiled"
  ok "oscmix installed in $BIN_DIR"
}

fetch_qt() {
  local arch api url
  case "$(uname -m)" in
    x86_64|amd64) arch='(x86_64|amd64)' ;;
    aarch64|arm64) arch='(aarch64|arm64)' ;;
    *) warn "Qt UI: unsupported architecture $(uname -m)"; return 1 ;;
  esac
  command -v curl >/dev/null 2>&1 || { warn "Qt UI: curl not found"; return 1; }
  command -v jq >/dev/null 2>&1 || { warn "Qt UI: jq not found"; return 1; }
  api="https://api.github.com/repos/huddx01/oscmix/releases/tags/nightly"
  url="$(curl -fsSL "$api" 2>/dev/null \
    | jq -r --arg arch "$arch" '.assets[].browser_download_url
        | select(test("(?i)oscmix[-_]?qt.*linux.*" + $arch + ".*\\.AppImage$"))' \
    | head -1)"
  if [[ -z $url ]]; then
    warn "Qt UI: the current nightly release does not publish an AppImage yet."
    warn "The GTK mixer is installed; the Qt option says so when opened."
    return 1
  fi
  info "Downloading the oscmix Qt AppImage"
  mkdir -p "$LIB_DIR"
  curl -fL --progress-bar -o "$QT_APPIMAGE.part" "$url" || { rm -f "$QT_APPIMAGE.part"; return 1; }
  chmod +x "$QT_APPIMAGE.part"
  mv -f "$QT_APPIMAGE.part" "$QT_APPIMAGE"
  ok "Qt UI installed: $QT_APPIMAGE"
}

uninstall() {
  info "Removing the per-user oscmix install"
  local b
  for b in "${BINS[@]}"; do rm -f "$BIN_DIR/$b"; done
  rm -rf "$LIB_DIR" "$DATA_DIR"
  ok "oscmix removed"
}

case $MODE in
  status) status ;;
  uninstall) uninstall ;;
  qt) fetch_qt ;;
  install)
    install_deps
    fetch_source
    build_engine
    install_engine
    fetch_qt || true
    status
    ;;
esac
