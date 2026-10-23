#!/usr/bin/env bash
# Regenerate the reference path sizes in module-sizes.tsv.
#
# cmd_space measures the paths that exist on the machine and uses these
# numbers only when none of a module's install paths exist yet. This script
# keeps that fallback useful (and makes a missing/oversized path visible when
# reviewing a module change).
#
# Usage: ./scripts/dev/gen-module-sizes.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$SCRIPT_DIR/../apps/mosquitomarchy/module-sizes.tsv"
[[ -f $MANIFEST ]] || { echo "Missing $MANIFEST" >&2; exit 1; }

path_kb() {
  local list="$1" total=0 p size
  [[ -n $list ]] || { echo 0; return; }
  while IFS= read -r p; do
    [[ -n $p ]] || continue
    p="${p/#\~/$HOME}"
    [[ -e $p ]] || continue
    size=$(du -sk -- "$p" 2>/dev/null | awk '{print $1}') || continue
    [[ $size =~ ^[0-9]+$ ]] && total=$((total + size))
  done < <(tr ';' '\n' <<< "$list")
  echo "$total"
}

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
while IFS= read -r line; do
  if [[ -z $line || $line == \#* ]]; then
    printf '%s\n' "$line" >> "$tmp"
    continue
  fi
  IFS='|' read -r key install_paths uninstall_paths _ _ note <<< "$line"
  printf '%s|%s|%s|%d|%d|%s\n' \
    "$key" "$install_paths" "$uninstall_paths" \
    "$(path_kb "$install_paths")" "$(path_kb "$uninstall_paths")" "$note" >> "$tmp"
done < "$MANIFEST"
mv "$tmp" "$MANIFEST"
