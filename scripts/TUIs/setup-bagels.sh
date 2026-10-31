#!/usr/bin/env bash
# desc: bagels — terminal expense tracker
# pkg: bagels
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib-tui.sh"
tui_main "bagels" "bagels" "$@"
