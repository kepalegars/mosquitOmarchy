#!/usr/bin/env bash
# desc: caligula — flash ISOs & USB drives (interactive disk imaging, terminal)
# pkg: caligula-git
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib-tui.sh"
tui_main "caligula-git" "caligula" "$@"
