#!/usr/bin/env bash
# Deleting a VM must preserve its configured shared files, including conflicts.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/code/modules/VMs/omarchy-vm/backup-vm-shared.bash"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

vm="$TMP/vm-one"
mkdir -p "$vm/custom share"
printf 'SHARED_DIR="%s/custom share"\n' "$vm" > "$vm/.vm-config"
printf 'hidden' > "$vm/custom share/.hidden"
backup="$TMP/VMs/shared folder backup"
backup_vm_shared_folder "$vm" "$backup"
[[ -f "$backup/.hidden" && ! -e "$vm/custom share" ]]

vm="$TMP/vm-two"
mkdir -p "$vm/shared folder" "$backup"
printf 'new' > "$vm/shared folder/collision.txt"
printf 'unique' > "$vm/shared folder/unique.txt"
printf 'old' > "$backup/collision.txt"
backup_vm_shared_folder "$vm" "$backup"
[[ $(cat "$backup/collision.txt") == new ]]
[[ $(cat "$backup/collision.txt.~1~") == old ]]
[[ $(cat "$backup/unique.txt") == unique ]]
[[ -d "$vm/shared folder" ]]

vm="$TMP/vm-three"
mkdir -p "$vm/shared folder"
printf 'safe' > "$vm/shared folder/keep.txt"
printf 'not a directory' > "$TMP/not-a-directory"
if backup_vm_shared_folder "$vm" "$TMP/not-a-directory" 2>/dev/null; then
  echo 'FAIL: a failed backup must block deletion' >&2
  exit 1
fi
[[ -f "$vm/shared folder/keep.txt" ]]
echo 'ok: VM shared-folder backups merge safely and block deletion on failure'
