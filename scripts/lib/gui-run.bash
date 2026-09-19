#!/usr/bin/env bash
# gui-run.bash — launch an installer from a file manager (Nautilus).
#
# 1. If neither stdin nor stdout is a terminal, the script was started by a
#    GUI (file manager "Run"): reopen it inside a terminal emulator
#    (foot → xterm) so that the output is actually visible.
# 2. In that terminal, once the script finishes — normally OR after a crash —
#    the window stays open with a "press Enter to close" prompt.
#
# Source it near the top of the script, before the first `set -e`:
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gui-run.bash"
if [[ ! -t 0 && ! -t 1 && -z "${GUI_RUN_EXEC:-}" ]]; then
  export GUI_RUN_EXEC=1
  if command -v foot >/dev/null 2>&1; then
    exec foot bash -c 'bash "$1"; ec=$?; printf "\n[%s] finished (exit %d). Press Enter to close this terminal." "$(basename "$1")" "$ec"; read -r _; exit "$ec"' _ "$0"
  elif command -v xterm >/dev/null 2>&1; then
    exec xterm -e bash -c 'bash "$1"; ec=$?; printf "\n[%s] finished (exit %d). Press Enter to close this terminal." "$(basename "$1")" "$ec"; read -r _; exit "$ec"' _ "$0"
  fi
  printf 'gui-run.bash: no terminal emulator found for a file-manager launch — output silenced.\n' >&2
fi