#!/usr/bin/env bash
# desc: basalt — TUI application to manage Obsidian notes
# pkg: basalt
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib-tui.sh"
tui_main "basalt" "basalt" "$@"
