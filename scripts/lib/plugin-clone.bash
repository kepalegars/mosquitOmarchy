#!/usr/bin/env bash
# Shared upstream tracking for Omarchy plugins cloned by mosquitOmarchy.
#
# A stamp records two hashes:
#   line 1: the Omarchy source the clone was built from
#   line 2: the installed clone after mosquitOmarchy's own overlays
#
# Reading these two lines separately is what lets Health distinguish an
# upstream change (Omarchy update) from a local edit.

PLUGIN_CLONE_STAMP=".mosquito-upstream"

plugin_clone_stamp_file(){
  printf '%s/%s\n' "${1%/}" "$PLUGIN_CLONE_STAMP"
}

plugin_clone_tree_hash(){
  local dir="$1"
  [[ -d $dir ]] || return 1
  (
    cd "$dir" || return 1
    find . -type f ! -name "$PLUGIN_CLONE_STAMP" -print0 |
      LC_ALL=C sort -z |
      xargs -0 -r sha256sum |
      sha256sum |
      awk '{print $1}'
  )
}

# Hash the files `omarchy plugin clone` would copy, given a source dir and
# manifest. Whole-directory clones use `manifest.json`; split plugins (like
# Indicators) list their files in entryPoints/clonePaths.
plugin_clone_source_hash_at(){
  local source_dir="$1" manifest="$2" rel src f
  [[ -d $source_dir && -f $manifest ]] || return 1
  if [[ ${manifest##*/} == manifest.json ]]; then
    (
      cd "$source_dir" || return 1
      find . -type f -print0 |
        LC_ALL=C sort -z |
        xargs -0 -r sha256sum |
        sha256sum |
        awk '{print $1}'
    )
    return
  fi

  local -a files=("$manifest")
  while IFS= read -r rel; do
    [[ -n $rel ]] || continue
    src="$source_dir/$rel"
    if [[ -d $src ]]; then
      while IFS= read -r -d '' f; do files+=("$f"); done < <(find "$src" -type f -print0)
    elif [[ -f $src ]]; then
      files+=("$src")
    fi
  done < <(jq -r '[.entryPoints[]?, .omarchy.clonePaths[]?.source] | .[]' "$manifest" 2>/dev/null)

  printf '%s\0' "${files[@]}" |
    LC_ALL=C sort -z |
    xargs -0 -r sha256sum |
    sha256sum |
    awk '{print $1}'
}

plugin_clone_source_hash(){
  local id="$1" info source_dir manifest
  command -v omarchy-plugin-catalog >/dev/null 2>&1 || return 1
  info="$(omarchy-plugin-catalog 2>/dev/null |
    jq -r --arg id "$id" '.[] | select(.id == $id) | [.sourceDir, .manifestPath] | @tsv' 2>/dev/null)" || return 1
  [[ -n $info ]] || return 1
  IFS=$'\t' read -r source_dir manifest <<<"$info"
  plugin_clone_source_hash_at "$source_dir" "$manifest"
}

plugin_clone_state(){
  local dir="$1" upstream="$2" stamp old_up old_inst now
  [[ -d $dir ]] || { echo missing; return 0; }
  stamp="$(plugin_clone_stamp_file "$dir")"
  [[ -f $stamp ]] || { echo unstamped; return 0; }
  old_up="$(sed -n '1p' "$stamp" 2>/dev/null)"
  old_inst="$(sed -n '2p' "$stamp" 2>/dev/null)"
  [[ -n $old_up && -n $old_inst ]] || { echo unstamped; return 0; }
  if [[ -n $upstream && $old_up != "$upstream" ]]; then
    echo upstream-changed
    return 0
  fi
  now="$(plugin_clone_tree_hash "$dir")" || { echo missing; return 0; }
  if [[ $old_inst == "$now" ]]; then echo ok; else echo locally-modified; fi
}

plugin_clone_write_stamp(){
  local dir="$1" upstream="$2" stamp installed
  [[ -d $dir && -n $upstream ]] || return 1
  installed="$(plugin_clone_tree_hash "$dir")" || return 1
  stamp="$(plugin_clone_stamp_file "$dir")"
  printf '%s\n%s\n' "$upstream" "$installed" >"$stamp"
}

# Keep the upstream baseline, accept the current files as the new installed
# state (used after a normal mosquitOmarchy overlay run).
plugin_clone_update_stamp(){
  local dir="$1" stamp old_up installed
  stamp="$(plugin_clone_stamp_file "$dir")"
  [[ -f $stamp ]] || return 0
  old_up="$(sed -n '1p' "$stamp" 2>/dev/null)"
  [[ -n $old_up ]] || return 1
  installed="$(plugin_clone_tree_hash "$dir")" || return 1
  printf '%s\n%s\n' "$old_up" "$installed" >"$stamp"
}
