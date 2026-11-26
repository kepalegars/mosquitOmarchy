#!/usr/bin/env bash
# Each row's version comes from VERSIONS, with VERSION only for the manager
# and the default fallback. No script id may be missing from the map.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" GUI_RUN_EXEC=1 MOSQUITOMARCHY_LIB_ONLY=1
mkdir -p "$HOME"

source "$ROOT/mosquitomarchy-setup.sh"

[[ "$(cat "$ROOT/VERSION")" == 2.0.0 ]]
[[ $(module_version mosquitomarchy) == 2.0.0 ]]
[[ $(module_version mixbay) == 1.4.0 ]]
[[ $(module_version touchpad) == 0.0.2 ]]
[[ $(module_version aria2) == 1.0.0 ]]
# Non-script rows and unknown ids fall back to `default`, not the manager.
[[ $(module_version some-stock-theme) == 1.0.0 ]]
module_version_into live-mode; [[ $MV == 0.9.0 ]]

# One entry per exposed id, no duplicates, all values semver.
declare -A seen=()
while IFS='=' read -r id ver || [[ -n $id ]]; do
  [[ $id == \#* || -z $id ]] && continue
  [[ $ver =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "bad version for $id: $ver" >&2; exit 1; }
  [[ -z ${seen[$id]:-} ]] || { echo "duplicate version id: $id" >&2; exit 1; }
  seen[$id]=1
done < "$ROOT/VERSIONS"

for row in "${MODULES[@]:-}" "${FIXES[@]:-}" "${TWEAKS[@]:-}"; do
  id="${row%%:*}"
  [[ -n ${seen[$id]:-} ]] || { echo "no VERSION for $id" >&2; exit 1; }
done

echo 'ok: per-script versions are complete and unique'
