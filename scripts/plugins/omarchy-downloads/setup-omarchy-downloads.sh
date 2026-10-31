#!/usr/bin/env bash
# Install Omarchy Downloads and manage its SUPER+ALT+D shortcut.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/keybindings.bash"
ok() { echo "✓ $*"; }
err() { echo "✗ $*" >&2; }

id=kirklandgee.downloads
url=https://github.com/KirklandGee/omarchy-downloads.git
if omarchy plugin list --json 2>/dev/null | jq -e --arg id "$id" '.[] | select(.id == $id)' >/dev/null; then
  omarchy plugin enable "$id" >/dev/null
else
  omarchy plugin add "$url" --enable --yes
fi

changed=0
kb_load_ours
if [[ -n ${KB_OURS["SUPER + SHIFT + E"]+x} ]]; then
  kb_remove "SUPER + SHIFT + E"
  changed=1
fi
kb_ensure "SUPER + ALT + D" "Downloads" "omarchy-shell shell toggle $id" cmd
if (( KB_CHANGED )); then changed=1; fi
if (( changed )); then kb_reload; fi
ok "Downloads plugin and SUPER + ALT + D keybinding ready"
