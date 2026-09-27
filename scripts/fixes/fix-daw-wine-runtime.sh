#!/usr/bin/env bash
# fix-daw-wine-runtime.sh — REAPER + Bitwig use the ableton wine runtime.
#
# ableton-linux's wine fork (wine-d2d1-nspa) implements Windows
# DirectComposition properly. Stock wine-staging crashes VST3 editors whose GUI
# uses DComp (Serum 2 verified: unhandled exception c0000409 inside dcomp during
# editor init → libyabridge throws → REAPER SIGABRT). The same plugins load
# perfectly inside Ableton — which uses THIS runtime.
#
# The fix is two thin wrappers in ~/.local/bin that prepend the runtime's bin to
# PATH, so yabridge's host runs through the patched wine for windows plugins.
# Idempotent; reversible (--remove).
#
# WHICH WRAPPERS MATTER, and this is where the original version failed:
#   * Bitwig is launched as `bitwig-studio`, and ~/.local/bin precedes /usr/bin
#     in PATH, so a wrapper by that name takes effect.
#   * REAPER is NOT: its desktop entry (cockos-reaper.desktop) execs the
#     absolute path ~/.local/bin/reaper-launch, set up by setup-reaper.sh. The
#     first version of this script wrote ~/.local/bin/reaper instead, which
#     nothing launches — so the fix was installed, reported OK, and REAPER kept
#     crashing on the Serum 2 editor. Both are handled now, from one place.
#
# The runtime path is resolved by scripts/lib/wine-runtime-daw.bash, which also
# matches the runtime directory by exact name (a plain glob would let an aborted
# *.transaction-installer.* sibling sort last and win).
#
# Usage:
#   fix-daw-wine-runtime.sh             # install/refresh both wrappers (idempotent)
#   fix-daw-wine-runtime.sh --status    # what each DAW currently launches under
#   fix-daw-wine-runtime.sh --remove    # delete the wrappers (stock wine)
set -euo pipefail

BIN="$HOME/.local/bin"
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
# shellcheck source=../lib/wine-runtime-daw.bash
source "$LIB/wine-runtime-daw.bash"

ok()  { echo -e "\033[32m ●\033[0m $*"; }
warn() { echo -e "\033[1;33m !\033[0m $*"; }

status() {
  local dir
  dir="$(mosquitomarchy_nspa_wine_dir)"
  echo "ableton wine:   $([[ -n $dir ]] && echo "present ($dir)" || echo ABSENT)"
  echo "reaper launcher: $(mosquitomarchy_daw_wrapper_runtime "$BIN/reaper-launch")" \
       "(the path cockos-reaper.desktop execs)"
  echo "bitwig wrapper: $(mosquitomarchy_daw_wrapper_runtime "$BIN/bitwig-studio")"
  [[ -f $BIN/reaper ]] && echo "obsolete:        ~/.local/bin/reaper still exists and is launched by nothing — remove it"
  return 0
}

case "${1:-apply}" in
  --remove)
    rm -f "$BIN/reaper-launch" "$BIN/bitwig-studio" "$BIN/reaper"
    ok "wrappers removed — REAPER/Bitwig use the stock wine again"
    ;;
  --status|status)
    status
    ;;
  apply)
    # The generator no longer produces it, and leaving it around is how the two
    # wrappers drifted apart in the first place.
    if [[ -f $BIN/reaper ]]; then
      rm -f "$BIN/reaper"
      ok "removed the obsolete ~/.local/bin/reaper (nothing launched it)"
    fi
    if mosquitomarchy_apply_daw_wine_runtime; then
      ok "REAPER + Bitwig now launch through the ableton wine runtime (dcomp fix)"
    else
      warn "ableton wine runtime missing under ~/.local/opt — wrappers left alone."
      warn "DComp VST3 editors (Serum 2) will crash on open until it is installed."
      exit 1
    fi
    ;;
  -h|--help) sed -n '2,30p' "$0" ;;
  *) echo "usage: $0 <apply|--status|--remove>"; exit 1 ;;
esac
