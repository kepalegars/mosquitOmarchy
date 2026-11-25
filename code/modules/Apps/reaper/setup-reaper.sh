#!/usr/bin/env bash
# Omarchy : prepares REAPER for optimal operation under Hyprland/Wayland
# - launches REAPER directly on Hyprland's native Xwayland instead of
#   xwayland-satellite: the class/title properties are then known instantly
#   at window-open, so plain static window rules apply correctly the first
#   time (no more late-arrival glitches on float/opacity/menus). Drag & drop
#   from external apps into REAPER is NOT fixed by this and isn't pursued
#   further -- REAPER's own Linux (SWELL) port has its own unreliable D&D
#   independent of the compositor ; use REAPER's Media Explorer / Insert Media
#   File instead.
# - neutralizes GDK_SCALE (huge UI) and REAPER's own auto DPI (blurry/zoomed) ;
#   Omarchy already forces xwayland.force_zero_scaling globally, so native
#   Xwayland + ui_scale_auto=0 is enough to get a crisp, correctly-sized UI
# - main window tiled ; every other REAPER window (prefs, dialogs, menus,
#   tooltips) floating, fully opaque, no blur, exempt from Omarchy's default
#   window opacity
# Idempotent: may be re-run without risk.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../lib/gui-run.bash"  # gui-run: reopen in a terminal when launched from a file manager
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../lib/elevate.bash"  # mq_sudo: native pkexec prompt when not root
set -euo pipefail

echo "== 1/6 Packages (reaper) =="
# Source of truth: https://archlinux.org/packages/extra/x86_64/reaper/ (Arch's
# official "extra" package, not an AUR build).
#
# Two traps, both seen in the wild:
#  1. the configured Omarchy mirror lags the website (it served 7.82-1 while
#     the page published 7.86-1), so `pacman -Sy && -S --needed` kept finding
#     an "update" that was actually a DOWNGRADE;
#  2. pacman DOES downgrade when the installed version is newer than the one in
#     the synced DB. So never call -S on an already-installed REAPER here.
# Read the published version, compare with pacman's own vercmp, and only ever
# install a NEWER package (from the Arch archive, which has the published one).
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
  echo "reaper $installed is newer than the configured mirror's ${latest:-unknown}: keeping it."
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
  # No published version known: a fresh install from the configured mirror is
  # still safe (there is nothing to downgrade).
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

echo "== 2/6 Launch wrapper =="
mkdir -p "$HOME/.local/bin"
# The wrapper MUST put Ableton's patched wine runtime (d2d1-nspa) first in PATH:
# REAPER resolves `wine` from PATH, and the system wine-staging has no working
# DirectComposition, so a VST3 editor that needs it dies during creation with
# STATUS_STACK_BUFFER_OVERRUN / c0000409 inside dcomp -- the Serum 2 crash.
#
# This was written into ~/.local/bin/reaper, a wrapper nothing launches, while
# the desktop entry execs reaper-launch (below) with the system wine. The
# resolution + the wrapper body now live in one shared place so the two DAW
# launchers cannot drift apart again.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/lib/wine-runtime-daw.bash"
if ! mosquitomarchy_apply_daw_wine_runtime; then
  echo "   WARNING: no wine-d2d1-nspa runtime in ~/.local/opt. REAPER will use the" >&2
  echo "   system wine, and VST3 editors needing DirectComposition (Serum 2) may" >&2
  echo "   crash on open. Run the Ableton setup, or code/lib/daw-wine-runtime-install.sh." >&2
fi

echo "== 3/6 Application shortcut =="
mkdir -p "$HOME/.local/share/applications"
DESK="$HOME/.local/share/applications/cockos-reaper.desktop"
SRC=""
for c in /usr/share/applications/cockos-reaper.desktop /usr/share/applications/reaper.desktop; do
  [ -f "$c" ] && SRC="$c" && break
done
[ -n "$SRC" ] && cp "$SRC" "$DESK" || touch "$DESK"
sed -i -E "s|^Exec=.*|Exec=$HOME/.local/bin/reaper-launch %F|" "$DESK"
update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true

echo "== 4/6 Hyprland rules (float + opaque + no blur, main window tiled) =="
# The REAPER block lives in code/modules/Apps/reaper/reaper-apply-block, NOT inline in
# a heredoc here.
#
# It used to be inline, and that was a trap. Anything that later wanted to
# EXTRACT the block from this file -- to re-apply it after an edit, or to diff it
# -- had to find it by pattern-matching the `-- >>> reaper-setup >>>` /
# `-- <<< reaper-setup <<<` markers. Those same markers also appear in THIS
# file's own `sed -i '/-- >>> reaper-setup >>>/,/-- <<< reaper-setup <<</d'`
# line, so the extraction matched it and `p` printed the surrounding shell,
# ending up with `cat >> "$CONF" <<'EOF'` inside hyprland.lua. That is a Lua
# syntax error near '>>', and it silently killed every rule after it.
#
# reaper-apply-block reads the body by line, refuses a body that still contains
# shell code or is missing its markers, and refuses to write a file that does
# not parse. One command, safe to re-run.
if bash "$(dirname "${BASH_SOURCE[0]}")/reaper-apply-block"; then
  hyprctl reload >/dev/null 2>&1 || true
else
  warn "could not update $HOME/.config/hypr/hyprland.lua — the Hyprland rules for REAPER are unchanged"
fi

echo "== 5/6 reaper-ui-scale (per-monitor UI scale) =="
UI_SCALE_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/reaper-ui-scale"
THEME_SYNC_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/reaper-theme-sync"
mkdir -p "$HOME/.local/bin"
if [[ -f $UI_SCALE_SRC ]]; then
  cp "$UI_SCALE_SRC" "$HOME/.local/bin/reaper-ui-scale"
  chmod +x "$HOME/.local/bin/reaper-ui-scale"
  echo "installed: ~/.local/bin/reaper-ui-scale  (SUPER SHIFT ALT + Y)"
else
  echo "WARNING: reaper-ui-scale not found next to this script; the bind will do nothing."
fi
if [[ -f $THEME_SYNC_SRC ]]; then
  cp "$THEME_SYNC_SRC" "$HOME/.local/bin/reaper-theme-sync"
  chmod +x "$HOME/.local/bin/reaper-theme-sync"
  echo "installed: ~/.local/bin/reaper-theme-sync (accent/font follow Omarchy)"
fi

echo "== 6/6 REAPER settings (initial window size) =="
INI="$HOME/.config/REAPER/reaper.ini"
mkdir -p "$HOME/.config/REAPER"
touch "$INI"
set_key() { # set_key <key> <value>
  grep -q "^$1=" "$INI" && sed -i "s|^$1=.*|$1=$2|" "$INI" || echo "$1=$2" >> "$INI"
}
# ui_scale is deliberately NOT pinned here. It used to be pinned to 1.0 with
# ui_scale_auto 0, on the theory that REAPER's own DPI detection was producing
# "the giant zoom". That detection cannot do per-monitor anything -- it reads one
# system-wide DPI, which X11 only has one of -- so pinning it just meant every
# monitor got the same wrong size. `reaper-ui-scale` now writes this key from the
# focused monitor's Hyprland scale, and says so instead of silently overriding.
set_key wnd_width 1600    # initial main window size ; afterwards REAPER
set_key wnd_height 900    # remembers the last used size itself

echo "Done. Launch REAPER from the launcher (or: ~/.local/bin/reaper-launch)."
