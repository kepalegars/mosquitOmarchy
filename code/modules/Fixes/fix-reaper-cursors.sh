#!/usr/bin/env bash
# =============================================================================
# mosquitOmarchy - REAPER context cursors (trim / grab / resize) never change
# =============================================================================
# libSwell loads REAPER's built-in cursors with gdk_pixbuf_new_from_file() on
# .cur files. Since gdk-pixbuf 2.43 the loader went through glycin, which
# misdetects a .cur as TGA and fails:
#   "The encoder or decoder for Tga does not support the color type Unknown(0)"
# REAPER silently falls back to the system arrow, so trim/grab/fade edges give
# no visual feedback. This affects Arch, Fedora, NixOS, Cinnamon/Hyprland...
#
# What this script does (idempotent):
#   1. Downloads the last gdk-pixbuf 2.42 build (2.42.12-1 from the Arch
#      archive, whose BMP/CUR decoder still reads .cur) and installs ONLY that
#      library under ~/.local/lib/reaper-cursors/. The system library is not
#      touched and no package is downgraded.
#   2. Makes reaper-launch export LD_LIBRARY_PATH for that folder, so the shim
#      is scoped to REAPER (and to processes it starts) and nothing else.
#
# Usage:
#   ./fix-reaper-cursors.sh            # apply (idempotent)
#   ./fix-reaper-cursors.sh --status   # report state
#   ./fix-reaper-cursors.sh --remove   # undo
#   ./fix-reaper-cursors.sh --force    # re-download even if already installed
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../../lib/wine-runtime-daw.bash"  # mosquitomarchy_apply_daw_wine_runtime

LIBDIR="${REAPER_CURSOR_LIBDIR:-$HOME/.local/lib/reaper-cursors}"
LIBNAME="libgdk_pixbuf-2.0.so.0.4200.12"
URL="${REAPER_CURSOR_LIB_URL:-https://archive.archlinux.org/packages/g/gdk-pixbuf2/gdk-pixbuf2-2.42.12-1-x86_64.pkg.tar.zst}"
WRAPPER="$HOME/.local/bin/reaper-launch"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m !\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m ✗\033[0m %s\n' "$*" >&2; }

usable(){ # a library with no unresolved dependencies
  [[ -s $1 ]] || return 1
  command -v ldd >/dev/null 2>&1 || return 0
  ! ldd "$1" 2>&1 | grep -q 'not found'
}

wrapper_has_hook(){
  grep -q 'mosquitomarchy_reaper_cursor_lib' "$WRAPPER" 2>/dev/null
}

regenerate_wrapper(){
  # The launcher is generated; re-running the generator is the only supported
  # way to add the shim without hand-editing a file the next setup rewrites.
  mosquitomarchy_apply_daw_wine_runtime quiet || true
  wrapper_has_hook || warn "$WRAPPER has no cursor shim hook; re-run REAPER setup."
}

do_status(){
  info "REAPER context cursors — status"
  printf '    system : %s\n' "$(pacman -Q gdk-pixbuf2 2>/dev/null || echo 'n/a (not Arch)')"
  if usable "$LIBDIR/$LIBNAME"; then
    printf '    lib    : %s\n' "$LIBDIR/$LIBNAME"
    printf '    state  : applied (gdk-pixbuf 2.42 shim installed)\n'
  else
    printf '    lib    : %s (absent)\n' "$LIBDIR/$LIBNAME"
    printf '    state  : absent\n'
  fi
  printf '    wrapper: %s\n' "$(wrapper_has_hook && echo hooked || echo not hooked)"
}

do_remove(){
  if [[ ! -d $LIBDIR ]]; then
    ok "Nothing to remove — $LIBDIR does not exist."
    return 0
  fi
  rm -rf -- "$LIBDIR"
  regenerate_wrapper
  ok "Cursor shim removed. Restart REAPER to use the system gdk-pixbuf again."
}

do_apply(){
  local force="${1:-}" tmp extracted
  if [[ $force != --force ]] && usable "$LIBDIR/$LIBNAME"; then
    ok "Already applied — $LIBNAME is installed."
    regenerate_wrapper
    return 0
  fi
  command -v curl >/dev/null 2>&1 || { err "curl is required."; return 1; }
  command -v tar >/dev/null 2>&1 || { err "tar (with zstd support) is required."; return 1; }

  info "Downloading gdk-pixbuf 2.42.12 (last release with a working .cur decoder)…"
  tmp="$(mktemp -d)"
  if ! curl -fsSL --max-time 180 -o "$tmp/pkg.tar.zst" "$URL"; then
    err "Download failed: $URL"; rm -rf "$tmp"; return 1
  fi
  mkdir -p "$tmp/pkg"
  if ! tar --zstd -xf "$tmp/pkg.tar.zst" -C "$tmp/pkg" "usr/lib/$LIBNAME" 2>/dev/null; then
    err "Could not extract $LIBNAME from the package."; rm -rf "$tmp"; return 1
  fi
  extracted="$tmp/pkg/usr/lib/$LIBNAME"
  usable "$extracted" || { err "$LIBNAME has missing libraries; not installing it."; rm -rf "$tmp"; return 1; }

  mkdir -p "$LIBDIR"
  cp -f -- "$extracted" "$LIBDIR/$LIBNAME"
  chmod 644 "$LIBDIR/$LIBNAME"
  ln -sfn "$LIBNAME" "$LIBDIR/libgdk_pixbuf-2.0.so.0"
  rm -rf "$tmp"

  regenerate_wrapper
  ok "Installed $LIBDIR/$LIBNAME"
  ok "reaper-launch now loads it for REAPER only. Restart REAPER to get the cursors back."
}

case "${1:-}" in
  --status) do_status ;;
  --remove) do_remove ;;
  --force)  do_apply --force ;;
  -y|--apply|"") do_apply ;;
  *) echo "usage: fix-reaper-cursors.sh [--status|--remove|--force]" >&2; exit 2 ;;
esac
