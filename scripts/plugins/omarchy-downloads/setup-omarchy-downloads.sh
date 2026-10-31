#!/usr/bin/env bash
# Install Omarchy Downloads and manage its SUPER+ALT+D shortcut.
set -euo pipefail

REMOVE=0
case "${1:-}" in
  "") ;;
  --remove) REMOVE=1 ;;
  *) echo "Usage: $0 [--remove]" >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/keybindings.bash"
ok() { echo "✓ $*"; }
err() { echo "✗ $*" >&2; }

id=kirklandgee.downloads
url=https://github.com/KirklandGee/omarchy-downloads.git
changed=0
kb_load_ours
if (( REMOVE )); then
  for key in "SUPER + ALT + D" "SUPER + SHIFT + E"; do
    if [[ -n ${KB_OURS[$key]+x} ]]; then
      kb_remove "$key"
      changed=1
    fi
  done
  omarchy plugin disable "$id" >/dev/null 2>&1 || true
  omarchy plugin remove "$id" --yes >/dev/null 2>&1 || true
  if (( changed )); then kb_reload; fi
  ok "Downloads plugin and keybinding removed"
  exit 0
fi

if omarchy plugin list --json 2>/dev/null | jq -e --arg id "$id" '.[] | select(.id == $id)' >/dev/null; then
  omarchy plugin enable "$id" >/dev/null
else
  omarchy plugin add "$url" --enable --yes
fi

if [[ -n ${KB_OURS["SUPER + SHIFT + E"]+x} ]]; then
  kb_remove "SUPER + SHIFT + E"
  changed=1
fi
kb_ensure "SUPER + ALT + D" "Downloads" "omarchy-shell shell toggle $id" cmd
if (( KB_CHANGED )); then changed=1; fi
if (( changed )); then kb_reload; fi
ok "Downloads plugin and SUPER + ALT + D keybinding ready"
