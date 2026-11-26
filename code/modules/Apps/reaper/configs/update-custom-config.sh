#!/usr/bin/env bash
# Snapshot the current REAPER config into configs/custom/ for shipping.
#
# setup-reaper-config.sh copies everything under custom/ (except .gitkeep and
# README.md) over the REAPER resource path, so this script writes exactly the
# three .ini files the module already manages:
#   reaper.ini               global REAPER settings
#   reaper-themeconfig.ini   Reapertips / Default Theme Adjuster values
#   reaper-extstate.ini      Theme Adjuster v6/v7 UI state
#
# Two things are deliberately NOT copied from reaper.ini: the [nag] section
# (licence/eval state) and the theme/splash pointers. The config installer
# writes lastthemefn5, splash and splashimage itself with this machine's real
# paths; shipping them would point other users at this machine.
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

cp -f -- "$RES/reaper-themeconfig.ini" "$DEST/reaper-themeconfig.ini"
cp -f -- "$RES/reaper-extstate.ini" "$DEST/reaper-extstate.ini"

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

info "Custom config updated from $RES"
for f in reaper.ini reaper-themeconfig.ini reaper-extstate.ini; do
  printf '    %-26s %s bytes\n' "$f" "$(wc -c < "$DEST/$f")"
done
ok "Review the diff from the repo root, then commit: git diff -- code/modules/Apps/reaper/configs/custom/"
