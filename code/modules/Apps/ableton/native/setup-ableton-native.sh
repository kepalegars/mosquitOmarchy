#!/usr/bin/env bash
# setup-ableton-native.sh — native Ableton Live Suite 12.4.7 for Linux.
#
# Wraps the manual steps of https://github.com/velkajelka/linux-native-ableton:
#   1. clone the upstream project into this folder,
#   2. install the tools its installer needs (Arch-first, other distros work),
#   3. make sure the two 12.4.7 archives are next to upstream's install.sh —
#      bootstrap files them here from ~/Downloads, otherwise they are downloaded
#      from the links in the upstream README,
#   4. run upstream install.sh with an explicit version and prefix.
#
# This installs Ableton Live Suite 12.4.7 ONLY. It is independent of the Wine
# module (wine/setup-ableton.sh): different install folder, menu entry and
# uninstaller. Neither is preferred over the other.
#
# Usage:
#   ./setup-ableton-native.sh              # install (prompts kept)
#   ./setup-ableton-native.sh -i           # same, for the TUI's terminal flow
#   ./setup-ableton-native.sh -y           # non-interactive
#   ./setup-ableton-native.sh --status
#   ./setup-ableton-native.sh -u|--uninstall
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/../../../lib/elevate.bash"
if [[ -f $LIB ]]; then
  # shellcheck source=../../../lib/elevate.bash
  source "$LIB"
else
  mq_sudo(){ sudo "$@"; }
fi

PREFIX="${XDG_DATA_HOME:-$HOME/.local/share}/ableton-live-12"
CLONE="$SCRIPT_DIR/linux-native-ableton"
APPS="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
UPSTREAM="https://github.com/velkajelka/linux-native-ableton"
PUSH_ZIP="Push3-RecoveryImage-2.4.7.zip"
SUITE_ZIP="ableton_live_suite_12.4.7_64.zip"
PUSH_URL="https://cdn-downloads.ableton.com/hardware_updates/push3/2.4.7/$PUSH_ZIP"
SUITE_URL="https://cdn-downloads.ableton.com/channels/12.4.7/$SUITE_ZIP"

G=$'\033[1;32m'; Y=$'\033[1;33m'; R=$'\033[1;31m'; N=$'\033[0m'
msg(){ printf '==> %s\n' "$*"; }
ok(){ printf ' %s✓%s %s\n' "$G" "$N" "$*"; }
warn(){ printf ' %s!%s %s\n' "$Y" "$N" "$*"; }
err(){ printf ' %s✗%s %s\n' "$R" "$N" "$*" >&2; }

YES=0 INSTALL=0 UNINSTALL=0 STATUS=0
while (($#)); do
  case $1 in
    -y|--yes) YES=1 ;;
    -i|--install) INSTALL=1 ;;
    -u|--uninstall) UNINSTALL=1 ;;
    --status) STATUS=1 ;;
    -h|--help)
      sed -n '2,22p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) err "Unknown option: $1"; exit 2 ;;
  esac
  shift
done

have(){ command -v "$1" >/dev/null 2>&1; }

# ── system tools ──────────────────────────────────────────────────────────────
ensure_deps(){
  local -a missing=()
  for c in unzip debugfs cabextract python3; do
    if [[ $c == debugfs ]]; then
      have debugfs || [[ -x /usr/sbin/debugfs || -x /sbin/debugfs ]] || missing+=("$c")
    else
      have "$c" || missing+=("$c")
    fi
  done
  # pipewire-alsa is a package, not a command.
  if have pacman; then
    pacman -Q pipewire-alsa >/dev/null 2>&1 || missing+=(pipewire-alsa)
  elif have dpkg-query; then
    [[ $(dpkg-query -W -f='${Status}' pipewire-alsa 2>/dev/null) == *'install ok installed'* ]] \
      || missing+=(pipewire-alsa)
  elif have rpm; then
    rpm -q pipewire-alsa >/dev/null 2>&1 || missing+=(pipewire-alsa)
  fi
  ((${#missing[@]})) || { ok "Required tools present."; return 0; }

  local pm pkgs=""
  if have pacman; then
    pm=pacman; pkgs="unzip e2fsprogs cabextract python pipewire-alsa"
  elif have apt-get; then
    pm=apt-get; pkgs="unzip e2fsprogs cabextract python3 pipewire-alsa"
  elif have dnf; then
    pm=dnf; pkgs="unzip e2fsprogs cabextract python3 pipewire-alsa"
  elif have zypper; then
    pm=zypper; pkgs="unzip e2fsprogs cabextract python3 pipewire-alsa"
  else
    err "Missing tools: ${missing[*]} — install them with your package manager."
    return 1
  fi

  local answer=y
  if (( ! YES )) && [[ -t 0 ]]; then
    read -rp "Install ${missing[*]} with sudo ($pm)? [Y/n] " answer
  fi
  [[ ${answer:-y} =~ ^[yY] ]] || { err "Cannot run the upstream installer without ${missing[*]}."; return 1; }
  msg "Installing: $pkgs"
  case $pm in
    pacman)  mq_sudo pacman -S --needed $pkgs ;;
    apt-get) mq_sudo apt-get install -y $pkgs ;;
    dnf)     mq_sudo dnf install -y $pkgs ;;
    zypper)  mq_sudo zypper install -y $pkgs ;;
  esac
  ok "Required tools installed."
}

# ── upstream checkout ────────────────────────────────────────────────────────
ensure_clone(){
  if [[ -f "$CLONE/install.sh" ]]; then
    ok "Upstream project already cloned ($CLONE)."
  elif have git; then
    msg "Cloning $UPSTREAM"
    git clone --depth 1 "$UPSTREAM" "$CLONE"
  else
    msg "Downloading the upstream project archive"
    local tmp="$SCRIPT_DIR/.linux-native-ableton.zip"
    have curl && curl -fL --retry 3 -o "$tmp" "$UPSTREAM/archive/refs/heads/main.zip" \
      || have wget && wget -q -O "$tmp" "$UPSTREAM/archive/refs/heads/main.zip" \
      || { err "Need git, curl or wget to fetch the upstream project."; return 1; }
    unzip -q -o "$tmp" -d "$SCRIPT_DIR"
    mv -f "$SCRIPT_DIR/linux-native-ableton-main" "$CLONE"
    rm -f "$tmp"
  fi
  [[ -f "$CLONE/install.sh" && -f "$CLONE/shim/libmenufix.so" \
     && -f "$CLONE/tools/AbletonLive12-launcher" ]] \
    || { err "Incomplete upstream checkout in $CLONE."; return 1; }
  ok "Upstream installer ready."
}

# ── archives ─────────────────────────────────────────────────────────────────
fetch_archive(){ # name url
  local name="$1" url="$2" target="$CLONE/$1" staged="$SCRIPT_DIR/$1" tmp
  [[ -f $target ]] && { ok "$name present in the upstream folder."; return 0; }
  if [[ -f $staged ]]; then
    ln -s -- "$staged" "$target"
    ok "$name linked from this folder."
    return 0
  fi
  msg "Downloading $name (large file — be patient)"
  tmp="$staged.part"
  if have curl; then
    curl -fL --retry 3 -o "$tmp" "$url"
  elif have wget; then
    wget -O "$tmp" "$url"
  else
    err "Need curl or wget to download $name."
    return 1
  fi
  unzip -l "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; err "$url is not a usable zip."; return 1; }
  mv -f "$tmp" "$staged"
  ln -s -- "$staged" "$target"
  ok "$name downloaded."
}

archive_bytes(){ # exact sizes from the CDN links in the upstream README
  case $1 in
    "$PUSH_ZIP")  echo 7498197732 ;;
    "$SUITE_ZIP") echo 4451071191 ;;
  esac
}

disk_preflight(){
  # Upstream install.sh (set_version): 25 GB peak, 13 GB when the program is
  # already in, 1 GB when the content is in. Add the archives only when we
  # still have to download them.
  local kb need=25000000000 f
  [[ -e "$PREFIX/.install-program" ]] && need=13000000000
  [[ -e "$PREFIX/.install-content" ]] && need=1000000000
  for f in "$PUSH_ZIP" "$SUITE_ZIP"; do
    [[ -f "$SCRIPT_DIR/$f" || -f "$CLONE/$f" ]] || need=$((need + $(archive_bytes "$f")))
  done
  kb="$(df -Pk "$SCRIPT_DIR" | awk 'NR == 2 { print $4 }')"
  [[ $kb =~ ^[0-9]+$ ]] || { err "Could not check free disk space."; return 1; }
  (( kb * 1024 >= need )) \
    || { err "Need about $((need / 1000000000)) GB free to install Live and its archives ($((kb / 1024 / 1024)) GB available)."; return 1; }
  ok "Disk space preflight passed ($((need / 1000000000)) GB needed)."
}

tag_desktop_entry(){
  local entry="$APPS/ableton-live-12.desktop"
  [[ -f $entry ]] || return 0
  sed -i 's/^Name=Ableton Live 12$/Name=Ableton Live 12 (Native)/' "$entry"
  have update-desktop-database && update-desktop-database "$APPS" >/dev/null 2>&1 || true
  ok "Menu entry tagged: Ableton Live 12 (Native)."
}

# ── actions ──────────────────────────────────────────────────────────────────
do_status(){
  [[ -f "$PREFIX/.ableton-live-linux" && -f "$PREFIX/uninstall.sh" ]] \
    && ok "Installed: Ableton Live Suite 12.4.7 (Native) in $PREFIX" \
    || warn "Not installed in $PREFIX."
  for z in "$PUSH_ZIP" "$SUITE_ZIP"; do
    [[ -f "$SCRIPT_DIR/$z" || -f "$CLONE/$z" ]] && ok "$z present" || warn "$z missing (download on install)"
  done
}

do_install(){
  ensure_deps
  ensure_clone
  disk_preflight
  fetch_archive "$PUSH_ZIP" "$PUSH_URL"
  fetch_archive "$SUITE_ZIP" "$SUITE_URL"
  msg "Running the upstream installer (Live 12, $PREFIX)"
  if (( YES )); then
    # No controlling terminal: upstream's questions then take their safe
    # defaults (no re-install, no loader link, no udev rule) instead of
    # blocking this non-interactive run.
    if have setsid; then
      ( cd "$CLONE" && setsid --wait bash ./install.sh --version 12 --prefix "$PREFIX" </dev/null )
    else
      warn "setsid missing — the upstream installer may ask a question; use -i."
      ( cd "$CLONE" && bash ./install.sh --version 12 --prefix "$PREFIX" </dev/null )
    fi
  else
    ( cd "$CLONE" && bash ./install.sh --version 12 --prefix "$PREFIX" )
  fi
  tag_desktop_entry
  ok "Native Ableton Live Suite 12.4.7 installed."
}

do_uninstall(){
  [[ -f "$PREFIX/uninstall.sh" ]] || { warn "Native Ableton is not installed in $PREFIX."; return 0; }
  msg "Running the upstream uninstaller"
  local -a args=()
  (( YES )) && args+=(--purge)
  bash "$PREFIX/uninstall.sh" "${args[@]}"
  ok "Native Ableton removed (the downloaded archives are kept)."
}

if (( STATUS )); then do_status
elif (( UNINSTALL )); then do_uninstall
else do_install; fi
