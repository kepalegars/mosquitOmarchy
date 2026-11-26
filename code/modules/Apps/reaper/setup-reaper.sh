#!/usr/bin/env bash
# REAPER, natively on Wayland by default.
#
# Package source: https://archlinux.org/packages/extra/x86_64/reaper/
# UI backend:     https://github.com/GoranKovac/Wayland-Swell
#
# Deliberately NOT done here:
#   - Hyprland window rules (native Wayland windows need none);
#   - backups of the old script / libSwell / hyprland.lua (done by hand once);
#   - reaper-theme-sync (the theme is applied once by setup-reaper-config.sh).
# LSP plugins are optional and asked at the end of a successful install.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../lib/gui-run.bash"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../lib/elevate.bash"  # mq_sudo
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LSP=ask
MODE=wayland
for a in "$@"; do
  case "$a" in
    --lsp) LSP=yes ;;
    --no-lsp) LSP=no ;;
    --x11) MODE=x11 ;;
    --wayland) MODE=wayland ;;
  esac
done
RES="${REAPER_RESOURCE_PATH:-$HOME/.config/REAPER}"
KEEP_X11="$RES/.mosquitomarchy/keep-x11-swell"
if [[ $MODE == x11 ]]; then
  mkdir -p "$(dirname "$KEEP_X11")"
  : > "$KEEP_X11"
elif [[ $MODE == wayland ]]; then
  rm -f -- "$KEEP_X11"
fi

LSP_PKGS=(lsp-plugins lsp-plugins-clap lsp-plugins-vst3 lsp-plugins-vst lsp-plugins-lv2)

echo "== 1/6 REAPER package (extra) =="
# The configured mirror can lag archlinux.org, and pacman -S downgrades when
# the installed version is newer than the local DB. Only install a newer one.
latest=""
if command -v curl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  latest="$(curl -fsSL --max-time 20 https://archlinux.org/packages/extra/x86_64/reaper/json/ \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print("%s-%s" % (d["pkgver"], d["pkgrel"]))' 2>/dev/null || true)"
fi
installed="$(pacman -Q reaper 2>/dev/null | awk '{print $2}' || true)"
if [[ -z $installed ]]; then
  cmp=-1
elif command -v vercmp >/dev/null 2>&1; then
  cmp="$(vercmp "$installed" "$latest" 2>/dev/null || echo 2)"
else
  cmp="$(printf '%s\n%s\n' "$installed" "$latest" | sort -V | head -1)"
  [[ $cmp == "$installed" ]] && cmp=-1 || cmp=1
  [[ $installed == "$latest" ]] && cmp=0
fi

if [[ $cmp == 0 ]]; then
  echo "reaper $installed is the published extra version — nothing to do."
elif [[ $cmp == 1 ]]; then
  echo "reaper $installed is newer than the published ${latest:-unknown}: keeping it."
elif [[ $(uname -m) == x86_64 && -n $latest ]]; then
  pkg="reaper-$latest-x86_64.pkg.tar.zst"
  tmp="$(mktemp -d)"
  if curl -fsSL --max-time 300 -o "$tmp/$pkg" "https://archive.archlinux.org/packages/r/reaper/$pkg" \
     && curl -fsSL --max-time 60 -o "$tmp/$pkg.sig" "https://archive.archlinux.org/packages/r/reaper/$pkg.sig" \
     && [[ -s $tmp/$pkg ]]; then
    echo "Installing the published extra package: $pkg"
    mq_sudo pacman -U --noconfirm "$tmp/$pkg"
  else
    echo "WARNING: $pkg unavailable; leaving reaper ${installed:-not installed} alone." >&2
  fi
  rm -rf "$tmp"
elif [[ -z $installed ]]; then
  mq_sudo pacman -Sy
  mq_sudo pacman -S --needed --noconfirm reaper
else
  echo "WARNING: no published version available for $(uname -m); keeping reaper $installed." >&2
fi

BIN=""
for c in /usr/lib/REAPER/reaper /opt/REAPER/reaper; do
  [ -x "$c" ] && BIN="$c" && break
done
[ -z "$BIN" ] && { echo "REAPER binary not found"; exit 1; }

echo "== 2/6 Native Wayland libSwell + ReaImGui =="
if [[ -f $KEEP_X11 ]]; then
  echo "Keeping the system (X11) libSwell: $KEEP_X11 exists."
  echo "Remove it (or pass --wayland) to try the native Wayland build again."
else
  tmp="$(mktemp -d)"
  release="$tmp/release.json"
  if command -v curl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 && curl -fsSL --max-time 20 -o "$release" https://api.github.com/repos/GoranKovac/Wayland-Swell/releases/latest; then
    tag="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("tag_name",""))' "$release" 2>/dev/null || true)"
    if [[ -n $tag ]]; then
      zipname="libSwell_native_$tag.zip"
      url="https://github.com/GoranKovac/Wayland-Swell/releases/download/$tag/$zipname"
      if curl -fsSL --max-time 180 -o "$tmp/$zipname" "$url" && unzip -q -o "$tmp/$zipname" -d "$tmp/swell" && [[ -s $tmp/swell/libSwell.so ]] && file "$tmp/swell/libSwell.so" 2>/dev/null | grep -q ELF; then
        echo "Installing Wayland libSwell $tag into $(dirname "$BIN")/libSwell.so"
        mq_sudo cp -f -- "$tmp/swell/libSwell.so" "$(dirname "$BIN")/libSwell.so"
      else
        echo "WARNING: could not fetch a valid Wayland libSwell $tag." >&2
      fi
      # The stock ReaImGui is built for the X11/GDK SWELL; use the one from the same release.
      imgui_asset="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(next((a["name"] for a in d.get("assets",[]) if a["name"].startswith("reaper_imgui-") and a["name"].endswith(".zip")), ""))' "$release" 2>/dev/null || true)"
      if [[ -n $imgui_asset ]]; then
        if curl -fsSL --max-time 240 -o "$tmp/$imgui_asset" "https://github.com/GoranKovac/Wayland-Swell/releases/download/$tag/$imgui_asset" && unzip -q -o "$tmp/$imgui_asset" -d "$tmp/imgui"; then
          found="$(find "$tmp/imgui" -type f -name 'reaper_imgui-*.so' -print -quit)"
          if [[ -n $found ]]; then
            mkdir -p "$RES/UserPlugins"
            cp -f -- "$found" "$RES/UserPlugins/$(basename "$found")"
            echo "Installed Wayland ReaImGui: $imgui_asset"
          fi
        else
          echo "WARNING: could not fetch the matching ReaImGui build." >&2
        fi
      fi
    else
      echo "WARNING: Wayland-Swell release lookup failed; keeping the current libSwell.so." >&2
    fi
  else
    echo "WARNING: Wayland-Swell release lookup failed; keeping the current libSwell.so." >&2
  fi
  rm -rf "$tmp"
fi
echo "== 3/6 Launcher + desktop entry =="
mkdir -p "$HOME/.local/bin"
source "$HERE/../../../lib/wine-runtime-daw.bash"
if ! mosquitomarchy_apply_daw_wine_runtime; then
  echo "   WARNING: no wine-d2d1-nspa runtime; VST3 editors needing DirectComposition" >&2
  echo "   (Serum 2) may crash. Run the Ableton setup first." >&2
fi
mkdir -p "$HOME/.local/share/applications"
DESK="$HOME/.local/share/applications/cockos-reaper.desktop"
SRC=""
for c in /usr/share/applications/cockos-reaper.desktop /usr/share/applications/reaper.desktop; do
  [ -f "$c" ] && SRC="$c" && break
done
[ -n "$SRC" ] && cp "$SRC" "$DESK" || touch "$DESK"
sed -i -E "s|^Exec=.*|Exec=$HOME/.local/bin/reaper-launch %F|" "$DESK"
update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true

echo "== 4/6 Stale helpers from the XWayland setup =="
rm -f -- "$HOME/.local/bin/reaper-ui-scale" "$HOME/.local/bin/reaper-theme-sync"

echo "== 5/6 REAPER settings =="
INI="$RES/reaper.ini"
mkdir -p "$RES"
touch "$INI"
set_key() { # set_key <key> <value>
  grep -q "^$1=" "$INI" && sed -i "s|^$1=.*|$1=$2|" "$INI" || echo "$1=$2" >> "$INI"
}
set_key wnd_width 1600
set_key wnd_height 900

echo "== 6/6 Optional LSP plugins =="
install_lsp(){
  echo "Installing LSP plugins (VST2/VST3/CLAP/LV2)…"
  if mq_sudo pacman -S --needed --noconfirm "${LSP_PKGS[@]}"; then
    echo "LSP plugins installed."
  else
    echo "WARNING: LSP plugins could not be installed." >&2
  fi
}
case "$LSP" in
  yes) install_lsp ;;
  no)  echo "LSP plugins skipped (--no-lsp)." ;;
  *)
    if [[ -t 0 && ${YES:-0} != 1 ]]; then
      printf 'Install LSP plugins (VST2/VST3/CLAP/LV2)? [y/N] '
      IFS= read -r answer || answer=""
      case "$answer" in
        y|Y|yes|YES) install_lsp ;;
        *) echo "LSP plugins skipped." ;;
      esac
    else
      echo "LSP plugins: no prompt in a non-interactive run; use --lsp to install them."
    fi
    ;;
esac

echo "Done. Launch REAPER from the launcher (or: ~/.local/bin/reaper-launch)."
