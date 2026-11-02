#!/usr/bin/env bash

# Preserve a VM's configured shared directory before its VM directory is removed.
backup_vm_shared_folder(){
  local vm_dir="$1" backup_dir="$2" shared_dir=""
  if [[ -f "$vm_dir/.vm-config" ]]; then
    shared_dir="$(sed -n 's/^SHARED_DIR="\(.*\)"/\1/p' "$vm_dir/.vm-config" | head -1)"
  fi
  [[ -n $shared_dir ]] || shared_dir="$vm_dir/shared folder"
  [[ -d $shared_dir ]] || return 0
  [[ $shared_dir == "$backup_dir" ]] && return 0
  mkdir -p "$(dirname "$backup_dir")" || return 1

  if [[ -e $backup_dir ]]; then
    # Keep both files when a merge hits a same-name file.
    cp -a --backup=numbered "$shared_dir/." "$backup_dir/"
  else
    mv -- "$shared_dir" "$backup_dir"
  fi
}
