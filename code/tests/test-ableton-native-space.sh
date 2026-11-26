#!/usr/bin/env bash
# The Setup confirm must use upstream's real Live 12 figures (same GiB display
# as every other module) and count the two archive downloads only while they
# are absent from both the module folder and ~/Downloads.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home" "$TMP/code/main tui" "$TMP/code/lib" \
         "$TMP/code/modules/Apps/ableton/native"
cp "$ROOT/mosquitomarchy-setup.sh" "$TMP/mosquitomarchy-setup.sh"
cp "$ROOT/code/lib/"*.bash "$TMP/code/lib/"
cp "$ROOT/code/main tui/mosquitomarchy-actions" "$TMP/code/main tui/"
cp "$ROOT/code/main tui/module-sizes.tsv" "$TMP/code/main tui/"

export HOME="$TMP/home" XDG_DATA_HOME="$TMP/data" MOSQUITOMARCHY_LIB_ONLY=1 GUI_RUN_EXEC=1
ACTIONS="$TMP/code/main tui/mosquitomarchy-actions"
NATIVE="$TMP/code/modules/Apps/ableton/native"
needkb(){ python3 -c 'import json,sys; print(json.loads(sys.argv[1])["need_kb"])' "$1"; }

# Neither archive: 25 GB peak + both CDN sizes (7.50 + 4.45 GB) = 34.4 GiB.
out="$(bash "$ACTIONS" space install ableton-native)"
(( $(needkb "$out") > 36000000 && $(needkb "$out") < 37000000 )) || { echo "FAIL: need_kb=$(needkb "$out")" >&2; exit 1; }

# Both archives present: 25 GB = 23.3 GiB, the same 25 GB the README quotes.
: > "$NATIVE/Push3-RecoveryImage-2.4.7.zip"
: > "$NATIVE/ableton_live_suite_12.4.7_64.zip"
out="$(bash "$ACTIONS" space install ableton-native)"
(( $(needkb "$out") > 24000000 && $(needkb "$out") < 25000000 )) || { echo "FAIL: need_kb=$(needkb "$out")" >&2; exit 1; }

# Still not filed in the module folder, but sitting in ~/Downloads.
rm -f "$NATIVE/Push3-RecoveryImage-2.4.7.zip" "$NATIVE/ableton_live_suite_12.4.7_64.zip"
mkdir -p "$HOME/Downloads"
: > "$HOME/Downloads/Push3-RecoveryImage-2.4.7.zip"
: > "$HOME/Downloads/ableton_live_suite_12.4.7_64.zip"
out="$(bash "$ACTIONS" space install ableton-native)"
(( $(needkb "$out") > 24000000 && $(needkb "$out") < 25000000 )) || { echo "FAIL: need_kb=$(needkb "$out")" >&2; exit 1; }

echo 'ok: native Ableton need is 23.3 GiB / 34.4 GiB depending on archive presence'
