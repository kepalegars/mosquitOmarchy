#!/usr/bin/env bash
# Install Pocket (jrmmhm.pocket): hides rarely-used bar widgets behind one mark
# and reveals them on hover. Widgets stay in the bar; only their visible flag
# changes, so their settings and slots are preserved.
set -euo pipefail

REMOVE=0
case "${1:-}" in
  "") ;;
  --remove) REMOVE=1 ;;
  *) echo "Usage: $0 [--remove]" >&2; exit 2 ;;
esac

id=jrmmhm.pocket
url=https://github.com/jrmmhm/omarchy-pocket.git
ok() { echo "✓ $*"; }

if ((REMOVE)); then
  omarchy plugin disable "$id" >/dev/null 2>&1 || true
  omarchy plugin remove "$id" --yes >/dev/null 2>&1 || true
  ok "Pocket plugin removed (hidden widgets are back on the bar)"
  exit 0
fi

if omarchy plugin list --json 2>/dev/null | jq -e --arg id "$id" '.[] | select(.id == $id)' >/dev/null; then
  omarchy plugin enable "$id" >/dev/null
else
  omarchy plugin add "$url" --enable --yes
fi
ok "Pocket ready — drag widgets onto the mark to tuck them away"
