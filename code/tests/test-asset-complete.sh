#!/usr/bin/env bash
# An archive only counts as ready when it stopped being written and its zip
# central directory reads back, so a partial download never un-greys a row.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ACTIONS="$ROOT/code/main tui/mosquitomarchy-actions"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export XDG_CACHE_HOME="$TMP/cache"

# Pull the function out of the backend instead of copying its logic here.
eval "$(sed -n '/^_asset_complete(){/,/^}$/p' "$ACTIONS")"

old="$TMP/old.zip"
python3 - "$old" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("a.txt", "x")
PY
touch -d '1 minute ago' "$old"
_asset_complete "$old" || { echo "complete zip rejected"; exit 1; }

truncated="$TMP/truncated.zip"
head -c 60 "$old" > "$truncated"
touch -d '1 minute ago' "$truncated"
if _asset_complete "$truncated"; then echo "truncated zip accepted"; exit 1; fi

fresh="$TMP/fresh.zip"
cp "$old" "$fresh"
if _asset_complete "$fresh"; then echo "just-written zip accepted"; exit 1; fi

deb="$TMP/old.deb"
printf 'not really a deb' > "$deb"
touch -d '1 minute ago' "$deb"
_asset_complete "$deb" || { echo "old non-zip rejected"; exit 1; }

echo "asset-complete: ok"
