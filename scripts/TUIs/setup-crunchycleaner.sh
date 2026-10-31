#!/usr/bin/env bash
# desc: crunchycleaner — lightweight software cache & junk cleaner
# pkg: crunchycleaner-bin
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib-tui.sh"
tui_main "crunchycleaner-bin" "crunchycleaner" "$@"
