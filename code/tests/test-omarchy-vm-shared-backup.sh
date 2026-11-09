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

# Batch purge: every VM's shared files are saved before any VM dir is deleted.
batch="$TMP/batch"
mkdir -p "$batch/vm-a/shared folder" "$batch/vm-b/shared folder" "$batch/not-a-vm"
printf 'a' > "$batch/vm-a/shared folder/a.txt"
printf 'b' > "$batch/vm-b/shared folder/b.txt"
printf 'SHARED_DIR="%s/vm-a/shared folder"\n' "$batch" > "$batch/vm-a/.vm-config"
printf 'SHARED_DIR="%s/vm-b/shared folder"\n' "$batch" > "$batch/vm-b/.vm-config"
backup_all_vm_shared_folders "$batch" "$TMP/batch-backup"
[[ -f "$TMP/batch-backup/a.txt" && -f "$TMP/batch-backup/b.txt" ]]
[[ -d "$batch/not-a-vm" ]]

# A failed batch backup must report failure so the purge can abort.
batch2="$TMP/batch2"
mkdir -p "$batch2/vm-c/shared folder"
printf 'c' > "$batch2/vm-c/shared folder/c.txt"
printf 'SHARED_DIR="%s/vm-c/shared folder"\n' "$batch2" > "$batch2/vm-c/.vm-config"
printf 'not a directory' > "$TMP/batch-blocked"
if backup_all_vm_shared_folders "$batch2" "$TMP/batch-blocked" 2>/dev/null; then
  echo 'FAIL: a failed batch backup must abort the purge' >&2
  exit 1
fi
echo 'ok: VM shared-folder backups merge safely, batch-save every VM, and block deletion on failure'
