#!/usr/bin/env bash
# Snapshot the current REAPER config into configs/custom/ for shipping.
#
# setup-reaper-config.sh copies everything under custom/ (except .gitkeep and
# README.md) over the REAPER resource path, so this script mirrors the pieces
# that make up a tuned install:
#   reaper.ini               global settings + track/item layout choices
#   reaper-themeconfig.ini   Reapertips / Default Theme Adjuster values/layouts
#   reaper-extstate.ini      Theme Adjuster v6/v7 UI state
#   reaper-kb.ini            custom actions (SCR/KEY entries)
#   reapack.ini              ReaPack repositories and install settings
#   Scripts/                 Lua scripts (+ their images) and __startup.lua
#   Effects/                 JSFX and their .jsfx-inc dependencies
#   FXChains/, TrackTemplates/  exported chains/templates when present
#
# Deliberately NOT copied: UserPlugins/ (binary extensions are installed by
# the module), Data/ (generated), ReaPack/ (package cache, re-downloadable),
# licence/registration files, and machine-bound ini keys.
#
# In reaper.ini the [nag] section and the theme/splash pointers are stripped:
# the config installer writes lastthemefn5, splash and splashimage itself with
# the real paths of the machine it is installed on.
#
# Usage: ./update-custom-config.sh
#        REAPER_RESOURCE_PATH=/path/to/REAPER ./update-custom-config.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RES="${REAPER_RESOURCE_PATH:-$HOME/.config/REAPER}"
DEST="$HERE/custom"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m !\033[0m %s\n' "$*" >&2; }

for f in reaper.ini reaper-themeconfig.ini reaper-extstate.ini; do
  [[ -f "$RES/$f" ]] || { echo "Missing $RES/$f" >&2; exit 1; }
done
mkdir -p "$DEST"

if command -v pgrep >/dev/null 2>&1 && pgrep -x reaper >/dev/null 2>&1; then
  warn "REAPER is running: its ini may be rewritten on exit. Close it for a clean snapshot."
fi

# Plain copies: theme/layouts, custom actions, ReaPack repository list.
for f in reaper-themeconfig.ini reaper-extstate.ini reaper-kb.ini reapack.ini; do
  if [[ -f "$RES/$f" ]]; then
    cp -f -- "$RES/$f" "$DEST/$f"
  elif [[ $f == reaper-kb.ini || $f == reapack.ini ]]; then
    warn "$f not present — no custom actions/repositories were snapshotted."
    rm -f -- "$DEST/$f"
  fi
done

# Sanitised global settings.
python3 - "$RES/reaper.ini" "$DEST/reaper.ini" <<'PY'
import sys

src, dst = sys.argv[1:3]
out, skip = [], False
for line in open(src, encoding="utf-8", errors="replace").read().splitlines():
    if line.strip().startswith("["):
        skip = line.strip() == "[nag]"  # licence/eval state: never shipped
    if skip:
        continue
    if line.startswith(("lastthemefn5=", "splashimage=")):
        continue  # written by the installer with the real paths
    out.append(line)
open(dst, "w", encoding="utf-8").write("\n".join(out).rstrip() + "\n")
PY

# Scripts/JSFX/chains/templates. Replace each tree so removed files do not
# linger in the shipped config.
for d in Scripts Effects FXChains TrackTemplates; do
  if [[ -d "$RES/$d" ]]; then
    rm -rf -- "$DEST/$d"
    mkdir -p -- "$DEST/$d"
    cp -a -- "$RES/$d/." "$DEST/$d/"
  else
    rm -rf -- "$DEST/$d"
  fi
  # Keep empty folders tracked in git; the installer ignores .gitkeep files.
  if [[ -d $DEST/$d ]] && ! find "$DEST/$d" -mindepth 1 -print -quit | grep -q .; then
    : > "$DEST/$d/.gitkeep"
  fi
done

info "Custom config updated from $RES"
for f in reaper.ini reaper-themeconfig.ini reaper-extstate.ini reaper-kb.ini reapack.ini; do
  [[ -f $DEST/$f ]] && printf '    %-26s %s bytes\n' "$f" "$(wc -c < "$DEST/$f")"
done
for d in Scripts Effects FXChains TrackTemplates; do
  [[ -d $DEST/$d ]] && printf '    %-26s %s files\n' "$d/" "$(find "$DEST/$d" -type f | wc -l)"
done
ok "Review the diff from the repo root, then commit: git diff --stat -- code/modules/Apps/reaper/configs/custom/"
