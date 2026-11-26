#!/usr/bin/env bash
# The native Ableton wrapper must be inspectable and safe without network or
# archives: --status reports the missing files, --help pins the 12.4.7-only
# promise, and --uninstall is a no-op when no upstream install exists.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" XDG_DATA_HOME="$TMP/data"
mkdir -p "$HOME" "$XDG_DATA_HOME"
SCRIPT="$TMP/setup-ableton-native.sh"
cp "$ROOT/code/modules/Apps/ableton/native/setup-ableton-native.sh" "$SCRIPT"

out="$(bash "$SCRIPT" --status)"
grep -q 'Not installed in' <<<"$out"
grep -q 'Push3-RecoveryImage-2.4.7.zip missing' <<<"$out"
grep -q 'ableton_live_suite_12.4.7_64.zip missing' <<<"$out"

: > "$TMP/Push3-RecoveryImage-2.4.7.zip"
: > "$TMP/ableton_live_suite_12.4.7_64.zip"
out="$(bash "$SCRIPT" --status)"
grep -q 'Push3-RecoveryImage-2.4.7.zip present' <<<"$out"
grep -q 'ableton_live_suite_12.4.7_64.zip present' <<<"$out"

# Downloads counts too: the script symlinks those zips instead of downloading.
rm -f "$TMP/Push3-RecoveryImage-2.4.7.zip" "$TMP/ableton_live_suite_12.4.7_64.zip"
mkdir -p "$HOME/Downloads"
: > "$HOME/Downloads/Push3-RecoveryImage-2.4.7.zip"
: > "$HOME/Downloads/ableton_live_suite_12.4.7_64.zip"
out="$(bash "$SCRIPT" --status)"
grep -q 'Push3-RecoveryImage-2.4.7.zip present at' <<<"$out"
grep -q '/Downloads/Push3-RecoveryImage-2.4.7.zip' <<<"$out"

bash "$SCRIPT" --help | grep -q '12.4.7 ONLY'
bash "$SCRIPT" --uninstall | grep -q 'not installed'

echo 'ok: native Ableton wrapper status/help/uninstall are safe without archives'
