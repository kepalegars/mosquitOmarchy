#!/usr/bin/env bash
# desc: aria2 — downloader for HTTP(S), FTP, BitTorrent and Metalink
# pkg: aria2
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib-tui.sh"
tui_main "aria2" "aria2" "$@"
