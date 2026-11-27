#!/usr/bin/env bash
# The native Move helper only installs an udev rule (no Wine DllOverride),
# and must be idempotent/reversible without touching the real /etc.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/code/modules/Apps/ableton/native" "$TMP/code/lib" \
         "$TMP/rules.d" "$TMP/state"
cp "$ROOT/code/modules/Apps/ableton/native/patch-move-native.sh" \
   "$TMP/code/modules/Apps/ableton/native/"
printf 'mq_sudo(){ "$@"; }\n' > "$TMP/code/lib/elevate.bash"
chmod +x "$TMP/code/modules/Apps/ableton/native/patch-move-native.sh"

export MOVE_UDEV_RULE="$TMP/rules.d/99-ableton-move-native.rules"
export XDG_STATE_HOME="$TMP/state"
SCRIPT="$TMP/code/modules/Apps/ableton/native/patch-move-native.sh"

[[ $(bash "$SCRIPT" --check) == 'move-native: not applied' ]]

bash "$SCRIPT" >/dev/null
grep -q 'ATTR{idVendor}=="2982"' "$MOVE_UDEV_RULE"
[[ $(bash "$SCRIPT" --check) == 'move-native: applied' ]]

# Re-applying is a no-op.
bash "$SCRIPT" >/dev/null
[[ $(bash "$SCRIPT" --check) == 'move-native: applied' ]]

bash "$SCRIPT" --revert >/dev/null
[[ ! -f $MOVE_UDEV_RULE ]]
[[ $(bash "$SCRIPT" --check) == 'move-native: not applied' ]]

echo 'ok: native Move udev helper applies, checks and reverts'
