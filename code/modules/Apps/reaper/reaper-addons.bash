#!/usr/bin/env bash
# ReaPack + SWS for the REAPER config action.
#
# On Arch, install the distro packages: the GitHub ReaPack .so needs
# libxml2.so.2, which current Arch no longer ships (it has libxml2.so.16), so
# the upstream binary silently fails to load. The packaged builds link against
# the system libraries and just work. Elsewhere (and as a fallback), the
# release .so is downloaded. A user who wants a specific version can drop any
# compatible file in ~/Downloads: a bare reaper_*-$arch.so, a
# sws-*-Linux-$arch*.tar.xz, or a .reaperpkg/.zip, extracted silently.
# Every candidate is checked with ldd: a binary with missing libraries is
# never installed.
#
# Usage: reaper-addons.bash status
#        reaper-addons.bash install <UserPlugins dir>
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../lib/elevate.bash"  # mq_sudo
set -euo pipefail

ADDONS_ARCH() {
  case "$(uname -m)" in
    x86_64|amd64) echo x86_64 ;;
    aarch64|arm64) echo aarch64 ;;
    armv7l|armhf|armv6l) echo armv7l ;;
    i686|i386) echo i686 ;;
    *) echo "" ;;
  esac
}

addons_url() { # addons_url <reapack|sws> <arch>
  case "$1" in
    reapack) printf 'https://github.com/cfillion/reapack/releases/latest/download/reaper_reapack-%s.so\n' "$2" ;;
    sws) printf 'https://github.com/reaper-oss/sws/releases/latest/download/reaper_sws-%s.so\n' "$2" ;;
  esac
}

addons_want() { # addons_want <reapack|sws> <arch>
  printf 'reaper_%s-%s.so\n' "$1" "$2"
}

addons_distro_pkg() { # Arch package providing the extension
  case "$1" in
    reapack) echo reapack ;;
    sws) echo sws ;;
  esac
}

addons_distro_so() { # addons_distro_so <kind> <arch>: installed packaged .so
  local pkg want
  pkg="$(addons_distro_pkg "$1")"
  want="$(addons_want "$1" "$2")"
  pacman -Ql "$pkg" 2>/dev/null | awk '{print $2}' | grep -E "/${want}$" | head -1
}

addons_usable() { # addons_usable <file>: refuse .so with missing libraries
  [[ -s $1 ]] || return 1
  command -v ldd >/dev/null 2>&1 || return 0
  ! ldd "$1" 2>&1 | grep -q 'not found'
}

# addons_payload <kind> <arch> <tmpdir>: print a usable .so path, or nothing.
# Downloads wins over the network: it is how a user picks a version.
addons_payload() {
  local kind="$1" arch="$2" tmp="$3" want f base name found n=0
  want="$(addons_want "$kind" "$arch")"
  shopt -s nullglob
  for f in "$HOME"/Downloads/*; do
    [[ -f $f ]] || continue
    base="$(basename "$f")"
    if [[ $base == "$want" ]]; then
      addons_usable "$f" && { printf '%s\n' "$f"; return 0; }
      continue
    fi
    case "$base" in
      *.reaperpkg|*.zip)
        name="$(unzip -Z1 "$f" 2>/dev/null | grep -E "(^|/)${want}\$" | head -1 || true)" ;;
      *.tar.xz|*.tar.gz|*.tgz|*.tar.bz2|*.tar)
        name="$(tar -tf "$f" 2>/dev/null | grep -E "(^|/)${want}\$" | head -1 || true)" ;;
      *) continue ;;
    esac
    [[ -n $name ]] || continue
    n=$((n + 1))
    local sub="$tmp/$n"
    mkdir -p "$sub"
    case "$f" in
      *.reaperpkg|*.zip) unzip -q -o "$f" "$name" -d "$sub" 2>/dev/null || continue ;;
      *) tar -xf "$f" -C "$sub" "$name" 2>/dev/null || continue ;;
    esac
    found="$(find "$sub" -type f -name "$want" -print -quit)"
    [[ -n $found ]] && addons_usable "$found" && { printf '%s\n' "$found"; return 0; }
  done
  shopt -u nullglob
  return 1
}

addons_install() { # addons_install <UserPlugins dir>
  local dest="$1" arch missing=0 kind want src url tmp
  arch="$(ADDONS_ARCH)"
  if [[ -z $arch ]]; then
    echo "WARNING: unsupported REAPER architecture ($(uname -m)): no ReaPack/SWS .so" >&2
    return 1
  fi
  tmp="$(mktemp -d)"
  mkdir -p "$dest"
  for kind in reapack sws; do
    want="$(addons_want "$kind" "$arch")"
    src=""

    # 1. Distro package first: its build matches the system's libraries.
    if command -v pacman >/dev/null 2>&1        && pacman -Si "$(addons_distro_pkg "$kind")" >/dev/null 2>&1; then
      if mq_sudo pacman -S --needed --noconfirm "$(addons_distro_pkg "$kind")"; then
        src="$(addons_distro_so "$kind" "$arch" || true)"
        [[ -n $src ]] && echo "Using Arch package $(addons_distro_pkg "$kind"): $src"
      fi
    fi

    # 2. A file the user supplied (any version, right arch, loadable here).
    if [[ -z $src || ! $(addons_usable "$src" && echo yes) ]]; then
      src="$(addons_payload "$kind" "$arch" "$tmp" || true)"
      [[ -n $src ]] && echo "Using $src from ~/Downloads."
    fi

    # 3. Upstream release as a last resort.
    if [[ -z $src || ! $(addons_usable "$src" && echo yes) ]]; then
      url="$(addons_url "$kind" "$arch")"
      if command -v curl >/dev/null 2>&1 \
         && curl -fsSL --max-time 120 -o "$tmp/$want" "$url" \
         && addons_usable "$tmp/$want"; then
        src="$tmp/$want"
        echo "Downloaded $want from GitHub Releases."
      else
        echo "WARNING: no loadable $want (missing libraries?) from GitHub." >&2
      fi
    fi

    if [[ -n $src ]] && addons_usable "$src"; then
      cp -f -- "$src" "$dest/$want"
      chmod 644 "$dest/$want"
      echo "Installed $dest/$want"
    else
      # Never leave a broken .so behind: REAPER would log a load error and the
      # extension would look installed when it is not.
      rm -f -- "$dest/$want"
      echo "WARNING: $want could not be installed; no broken copy was left." >&2
      missing=1
    fi
  done
  rm -rf "$tmp"
  return "$missing"
}

addons_status() {
  local arch kind tmp ok=1
  arch="$(ADDONS_ARCH)"
  [[ -n $arch ]] || { echo missing; return 0; }
  tmp="$(mktemp -d)"
  for kind in reapack sws; do
    addons_payload "$kind" "$arch" "$tmp" >/dev/null && continue
    command -v curl >/dev/null 2>&1 \
      && curl -fsSIL --max-time 6 "$(addons_url "$kind" "$arch")" >/dev/null 2>&1 \
      || ok=0
  done
  rm -rf "$tmp"
  if (( ok )); then echo ok; else echo missing; fi
}

case "${1:-}" in
  status) addons_status ;;
  install) addons_install "${2:?UserPlugins dir required}" ;;
  *) echo "usage: reaper-addons.bash status|install <dir>" >&2; exit 2 ;;
esac
