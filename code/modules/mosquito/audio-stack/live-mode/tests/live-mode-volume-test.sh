#!/usr/bin/env bash
# Self-check for live-mode's Mixbay volume takeover: activation flips
# ui.json to "hardware & UI exclusive", deactivation restores exactly what was
# there (true, false, or no key at all), and LOCK_OUTPUT_VOLUME=no touches
# nothing. The two functions are extracted from the real script: sourcing it
# would run its main dispatch and derive the real user's home.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$here/live-mode"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fn="$(sed -n '/^lock_mixbay_volume()/,/^}/p; /^release_mixbay_volume()/,/^}/p' "$script")"
[[ -n $fn ]] || { echo "volume takeover functions not found in live-mode"; exit 1; }
eval "$fn"

MIXBAY_PREFS="$tmp/ui.json"
MIXBAY_VOLUME_PREV="$tmp/before"
LOCK_OUTPUT_VOLUME=yes

value() { jq -r "$1" "$MIXBAY_PREFS"; }

# Pre-existing explicit choice is overridden, then put back untouched.
printf '{"allow_native_volume": true, "keep": 1}\n' >"$MIXBAY_PREFS"
lock_mixbay_volume
[[ $(value .allow_native_volume) == false ]] || { echo "lock did not force exclusive"; exit 1; }
[[ $(cat "$MIXBAY_VOLUME_PREV") == true ]] || { echo "previous value not remembered"; exit 1; }
release_mixbay_volume
[[ $(value .allow_native_volume) == true ]] || { echo "release did not restore true"; exit 1; }
[[ $(value .keep) == 1 ]] || { echo "release dropped unrelated keys"; exit 1; }
[[ ! -e $MIXBAY_VOLUME_PREV ]] || { echo "state file left behind"; exit 1; }

# A missing key comes back missing, so the free default applies again.
printf '{"keep": 1}\n' >"$MIXBAY_PREFS"
lock_mixbay_volume
[[ $(value .allow_native_volume) == false ]] || { echo "absent key was not locked"; exit 1; }
[[ $(cat "$MIXBAY_VOLUME_PREV") == absent ]] || { echo "absent key not recorded"; exit 1; }
release_mixbay_volume
[[ $(value 'has("allow_native_volume")') == false ]] || { echo "absent key was re-created"; exit 1; }

# An explicit false stays false through the round trip.
printf '{"allow_native_volume": false}\n' >"$MIXBAY_PREFS"
lock_mixbay_volume
release_mixbay_volume
[[ $(value .allow_native_volume) == false ]] || { echo "exclusive choice not restored"; exit 1; }

# The lock is opt-out: "no" neither edits the file nor records state.
printf '{"allow_native_volume": true}\n' >"$MIXBAY_PREFS"
LOCK_OUTPUT_VOLUME=no
lock_mixbay_volume
[[ $(value .allow_native_volume) == true ]] || { echo "LOCK_OUTPUT_VOLUME=no still locked"; exit 1; }
[[ ! -e $MIXBAY_VOLUME_PREV ]] || { echo "LOCK_OUTPUT_VOLUME=no recorded state"; exit 1; }

echo ok
