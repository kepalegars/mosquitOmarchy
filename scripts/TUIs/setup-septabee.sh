#!/usr/bin/env bash
# desc: SEPTABEE — retro studio DAW & music app (terminal, JIT audio)
# pkg: septabee
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib-tui.sh"
tui_main "septabee" "septabee" "$@"
