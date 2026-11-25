#!/usr/bin/env bash
# ReaPack + SWS for the REAPER config action.
#
# Both ship a Linux .so per architecture on GitHub Releases, so the config
# action downloads them itself. A user who wants a specific version can drop
# any compatible file in ~/Downloads instead: a bare reaper_*-$arch.so, a
# sws-*-Linux-$arch*.tar.xz, or a .reaperpkg/.zip. The archive is unpacked
# silently and only the .so matching THIS system's arch is used.
#
# Usage: reaper-addons.bash status
#        reaper-addons.bash install <UserPlugins dir>
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

# addons_payload <kind> <arch> <tmpdir>: print a usable .so path, or nothing.
# Downloads wins over the network: it is how a user picks a version.
addons_payload() {
  local kind="$1" arch="$2" tmp="$3" want f base name found n=0
  want="$(addons_want "$kind" "$arch")"
  shopt -s nullglob
  for f in "$HOME"/Downloads/*; do
    [[ -f $f ]] || continue
    base="$(basename "$f")"
    if [[ $base == "$want" ]]; then printf '%s\n' "$f"; return 0; fi
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
    [[ -n $found ]] && { printf '%s\n' "$found"; return 0; }
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
    src="$(addons_payload "$kind" "$arch" "$tmp" || true)"
    if [[ -z $src ]]; then
      url="$(addons_url "$kind" "$arch")"
      if command -v curl >/dev/null 2>&1 \
         && curl -fsSL --max-time 120 -o "$tmp/$want" "$url" && [[ -s $tmp/$want ]]; then
        src="$tmp/$want"
        echo "Downloaded $want from GitHub Releases."
      fi
    fi
    if [[ -n $src && -s $src ]]; then
      cp -f -- "$src" "$dest/$want"
      echo "Installed $dest/$want"
    else
      echo "WARNING: $want not found in ~/Downloads and download failed." >&2
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
