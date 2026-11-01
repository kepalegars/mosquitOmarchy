#!/usr/bin/env bash
# desc: tdf — TUI-based PDF viewer
# pkg: tdf-git
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib-tui.sh"
tui_main "tdf-git" "tdf" "$@"
