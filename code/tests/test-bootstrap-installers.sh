#!/usr/bin/env bash
# Bootstrap must discover all installer files first, then ask once: declining
# (or having no terminal) leaves every file in Downloads; accepting moves them.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home/Downloads" "$TMP/repo/code/modules/Apps/ableton/native" "$TMP/repo/code/modules/Apps/ableton/wires"
ZIP="$TMP/home/Downloads/Push3-RecoveryImage-2.4.7.zip"
: > "$ZIP"
: > "$TMP/home/Downloads/ableton_live_suite_12.4.7_64.zip"

sed -n '/^collect_installers(){/,/^}/p' "$ROOT/bootstrap.sh" > "$TMP/fn.sh"
cat > "$TMP/run.sh" <<EOF
set -euo pipefail
SRC="$TMP/repo"
HOME="$TMP/home"
YES=0
hr(){ :; }; msg(){ printf '%s\\n' "\$*"; }; ok(){ :; }; warn(){ printf '%s\\n' "\$*"; }; err(){ printf '%s\\n' "\$*" >&2; }
xdg-user-dir(){ printf '%s\\n' "$TMP/home/Downloads"; }
source "$TMP/fn.sh"
collect_installers
EOF

# No terminal: nothing moves.
out="$(bash "$TMP/run.sh" 2>&1)"
[[ -f $ZIP ]] || { echo 'FAIL: no-TTY moved a file' >&2; exit 1; }
grep -q 'leaving every file in' <<<"$out"

# Interactive "no": still nothing moves.
out="$(printf 'n\n' | script -q -c "bash '$TMP/run.sh'" /dev/null 2>&1)"
[[ -f $ZIP ]] || { echo 'FAIL: decline moved a file' >&2; exit 1; }
grep -q 'nothing copied, nothing moved' <<<"$out"

# Interactive "yes": both files move to their module folders.
out="$(printf 'y\n' | script -q -c "bash '$TMP/run.sh'" /dev/null 2>&1)"
[[ ! -f $ZIP ]] || { echo 'FAIL: accept left a file in Downloads' >&2; exit 1; }
[[ -f "$TMP/repo/code/modules/Apps/ableton/native/Push3-RecoveryImage-2.4.7.zip" ]]
[[ -f "$TMP/repo/code/modules/Apps/ableton/native/ableton_live_suite_12.4.7_64.zip" ]]

echo 'ok: bootstrap asks once and only moves archives on acceptance'
