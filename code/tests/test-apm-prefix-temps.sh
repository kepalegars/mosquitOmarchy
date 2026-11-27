#!/usr/bin/env bash
# Emptying the wine prefixes' temp folders must remove the CONTENTS of the
# known temp dirs but keep the dirs themselves, and report a JSON summary.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/cfg"
mkdir -p "$HOME" "$XDG_CONFIG_HOME"

prefix="$HOME/.wine-vst"
mkdir -p "$prefix/drive_c/windows/temp/nested" \
         "$prefix/drive_c/windows/system32" \
         "$prefix/drive_c/users/kapeq/AppData/Local/Temp"
printf 'installer junk\n' > "$prefix/drive_c/windows/temp/setup.tmp"
printf 'nested junk\n' > "$prefix/drive_c/windows/temp/nested/inner.tmp"
printf 'updater msi\n' > "$prefix/drive_c/users/kapeq/AppData/Local/Temp/update.msi"
printf 'keep me\n' > "$prefix/drive_c/windows/system32/keep.txt"

# shellcheck source=/dev/null
source "$ROOT/code/modules/mosquito/audio-stack/apm/lib-audio-plugin-manager-core.sh"

report="$(apm_cleanup_prefix_temps_json)"
printf '%s\n' "$report" | jq -e '.count == 3' >/dev/null || { echo "fail: $report" >&2; exit 1; }
[[ -d $prefix/drive_c/windows/temp ]] || { echo "fail: temp dir removed" >&2; exit 1; }
[[ -d $prefix/drive_c/users/kapeq/AppData/Local/Temp ]] || { echo "fail: user temp dir removed" >&2; exit 1; }
[[ -e $prefix/drive_c/windows/temp/setup.tmp || -e $prefix/drive_c/windows/temp/nested || -e $prefix/drive_c/users/kapeq/AppData/Local/Temp/update.msi ]] && {
  echo "fail: temp contents survived" >&2; exit 1; }
[[ -f $prefix/drive_c/windows/system32/keep.txt ]] || { echo "fail: non-temp file removed" >&2; exit 1; }
grep -q '.wine-vst' "$(apm_temp_cleanup_log)" || { echo "fail: cleanup not logged" >&2; exit 1; }
