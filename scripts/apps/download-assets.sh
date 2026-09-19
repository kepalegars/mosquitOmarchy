#!/usr/bin/env bash
# download-assets.sh — Downloads the missing large installation files.
#
# Reads assets.links (repo root): one entry per line ' destination | url | sha256 '.
# For each file: if already present and intact (sha256) → nothing to do; otherwise
# it is downloaded to a temporary file (same destination + '.part'), then
# verified (size + sha256) before being atomically finalized. An interrupted
# download is resumed with curl -C -. Never overwrites an existing file.
#
# Usage :
#   ./download-assets.sh               # interactive: choose the files to download
#   ./download-assets.sh -y            # downloads all missing or corrupt files
#   ./download-assets.sh --status      # state of each file (present / absent / corrupt)
#   ./download-assets.sh --check       # checks the integrity (sha256) of what is present
#   ./download-assets.sh -h            # help
#
# NB: DaVinci Resolve is deliberately NOT in assets.links — its zip (~7 GB)
# is dropped by hand in apps/davinci/ (download outside the script).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"            # repo root (apps/ → repo root)
LINKS="$ROOT/assets.links"

YES=0 STATUS_ONLY=0 CHECK_ONLY=0
for a in "$@"; do case "$a" in
  -y|--yes) YES=1 ;;
  --status) STATUS_ONLY=1 ;;
  --check)  CHECK_ONLY=1 ;;
  -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
  *) echo "Unknown option: $a (see -h)" >&2; exit 1 ;;
esac; done

G='\033[1;32m'; B='\033[1;34m'; Y='\033[1;33m'; R='\033[1;31m'; D='\033[2m'; N='\033[0m'
msg(){ printf "${B}==>${N} %s\n" "$*"; }
ok(){ printf " ${G}✓${N} %s\n" "$*"; }
warn(){ printf " ${Y}!${N} %s\n" "$*"; }
err(){ printf " ${R}✗${N} %s\n" "$*" >&2; }
hr(){ printf '%.0s─' {1..72}; echo; }

parse_links(){
  # Global : LINKS_ARR (array of "dest|url|sha")
  LINKS_ARR=()
  [[ -f "$LINKS" ]] || { err "assets.links not found: $LINKS"; return 1; }
  local line dest url sha
  while IFS= read -r line || [[ -n $line ]]; do
    line="${line%%$'\r'}"
    [[ -z $line || $line == \#* ]] && continue
    dest="${line%%|*}"; rest="${line#*|}"
    url="${rest%%|*}";   sha="${rest#*|}"
    # trims the spaces around the fields (format ' dest | url | sha ')
    dest="${dest#"${dest%%[![:space:]]*}"}"; dest="${dest%"${dest##*[![:space:]]}"}"
    url="${url#"${url%%[![:space:]]*}"}";    url="${url%"${url##*[![:space:]]}"}"
    sha="${sha#"${sha%%[![:space:]]*}"}";    sha="${sha%"${sha##*[![:space:]]}"}"
    [[ -z $dest || -z $url ]] && continue
    LINKS_ARR+=("$dest|$url|$sha")
  done < "$LINKS"
  ((${#LINKS_ARR[@]})) || { err "No valid entry in $LINKS."; return 1; }
}

# state of a file: present | absent | corrupt
file_state(){
  local f="$1" sha="$2"
  local fn="$ROOT/$f"
  [[ -f "$fn" ]] || { echo absent; return; }
  # Without sha256 reference: present as-is
  if [[ -z $sha ]]; then echo present; return; fi
  local got
  got="$(sha256sum "$fn" 2>/dev/null | awk '{print $1}')"
  (($(stat -c%s "$fn" 2>/dev/null || echo 0) > 0)) && [[ "$got" == "$sha" ]] \
    && echo present || echo corrupt
}

download_one(){
  local dest="$1" url="$2" sha="$3"
  local fn="$ROOT/$dest"
  local part="$fn.part"
  mkdir -p "$(dirname "$fn")"
  msg "Downloading: ${dest}"
  msg "  $url"
  rm -f -- "$part"
  if ! curl -fL --retry 3 --connect-timeout 20 --max-time 3600 -C - -o "$part" "$url"; then
    rm -f -- "$part"
    err "Download failed: $url"
    return 1
  fi
  # Verification: expected sha256 (or at least a non-empty file)
  if [[ -n $sha ]]; then
    local got
    got="$(sha256sum "$part" | awk '{print $1}')"
    if [[ "$got" != "$sha" ]]; then
      rm -f -- "$part"
      err "Inconsistent checksum for ${dest}"
      err "  expected: $sha"
      err "  got: $got"
      return 1
    fi
  elif [[ ! -s "$part" ]]; then
    rm -f -- "$part"
    err "Downloaded file is empty: ${dest}"
    return 1
  fi
  mv -f -- "$part" "$fn"
  ok "File finalized: ${dest} ($(du -h "$fn" | cut -f1))"
}

do_status(){
  hr; msg "State of downloadable assets (assets.links)"
  local entry st
  for entry in "${LINKS_ARR[@]}"; do
    local dest="${entry%%|*}"
    st="$(file_state "${dest}" "${entry##*|}")"
    case $st in
      present) printf " ${G}✓${N} %-24s %s\n" "$(basename "$dest")" "${dest%/*}/" ;;
      corrupt) printf " ${R}✗${N} %-24s ${D}%s${N} ${Y}(corrupt — re-download)${N}\n" "$(basename "$dest")" "${dest%/*}/" ;;
      *)       printf " ${D}—${N} %-24s %s${D} (absent)${N}\n" "$(basename "$dest")" "${dest%/*}/" ;;
    esac
  done
  hr
}

main(){
  parse_links || exit 1

  if ((STATUS_ONLY)); then do_status; exit 0; fi

  if ((CHECK_ONLY)); then
    hr; msg "Integrity check (assets.links)"
    local st bad=0 entry dest
    for entry in "${LINKS_ARR[@]}"; do
      dest="${entry%%|*}"
      st="$(file_state "$dest" "${entry##*|}")"
      if [[ $st == present ]]; then ok "$dest : intact"
      elif [[ $st == corrupt ]]; then err "$dest : corrupt"; bad=1
      else warn "$dest : absent"; fi
    done
    hr
    ((bad)) && return 1 || return 0
  fi

  # Interactive choice: the missing/corrupt files are proposed ;
  # with -y, all are downloaded automatically.
  local -a todo=() entry dest
  if ((YES)); then
    todo=()
    for entry in "${LINKS_ARR[@]}"; do
      dest="${entry%%|*}"
      [[ "$(file_state "$dest" "${entry##*|}")" == present ]] || todo+=("$entry")
    done
    if ((${#todo[@]} == 0)); then ok "All assets are already present and intact."
    else for entry in "${todo[@]}"; do download_one "${entry%%|*}" "$(echo "$entry" | cut -d'|' -f2)" "${entry##*|}"; done; fi
    return 0
  fi

  # Interactive: propose the missing/corrupt files (gum choose if available)
  todo=()
  local -a labels=()
  local i=0
  for entry in "${LINKS_ARR[@]}"; do
    dest="${entry%%|*}"
    st="$(file_state "$dest" "${entry##*|}")"
    if [[ $st == present ]]; then continue; fi
    todo+=("$entry")
    labels+=("${dest}   $([ $st == corrupt ] && echo '[corrupt]' || echo '[absent]')")
  done
  if ((${#todo[@]} == 0)); then ok "All assets are already present and intact."; exit 0; fi

  local -a picks=()
  if command -v gum >/dev/null; then
    mapfile -t picks < <(gum choose --no-limit "${labels[@]}" \
      --header "Assets to download (missing/corrupt):")
    [[ -n "$(printf '%s' "${picks[@]}")" ]] || { warn "Nothing to download."; exit 0; }
    local p
    for p in "${picks[@]}"; do
      local want="${p%%   *}"
      for entry in "${todo[@]}"; do
        [[ "${entry%%|*}" == "$want" ]] && download_one "${entry%%|*}" "$(echo "$entry" | cut -d'|' -f2)" "${entry##*|}" && break
      done
    done
  else
    echo "Missing/corrupt assets:"
    i=1
    for entry in "${todo[@]}"; do
      st="$(file_state "${entry%%|*}" "${entry##*|}")"
      printf '  %2d) %s  [%s]\n' "$i" "${entry%%|*}" "$st"; i=$((i+1))
    done
    read -rp "Which ones to download? (numbers separated by spaces, Enter = all) " ans
    [[ -n $ans ]] || ans="$(seq 1 ${#todo[@]} | tr '\n' ' ')"
    for n in $ans; do
      (( n >= 1 && n <= ${#todo[@]} )) \
        && download_one "${todo[$((n-1))]%%|*}" "$(echo "${todo[$((n-1))]}" | cut -d'|' -f2)" "${todo[$((n-1))]##*|}"
    done
  fi
}

main "$@"