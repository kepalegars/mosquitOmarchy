#!/usr/bin/env bash
# download-assets.sh — check the big installation files mosquitOmarchy expects.
#
# What this does now: verifies what is already on disk. That is ALL it does, and
# that is the point.
#
# It used to download. assets.links carried a URL column with a placeholder host,
# and every run walked the catalog and let curl retry DNS on a name that cannot
# resolve. The files themselves cannot be fetched automatically anyway — Ableton
# and Bitwig are behind account logins, and a ~4 GB zip does not belong in a git
# clone — so the URL column was decoration that produced error messages.
#
# So: assets.links is an INVENTORY (path + sha256), this script is a PRESENCE
# CHECK, and a missing file is reported in a neutral tone and named. It is not an
# error, it is a fact about the machine. The module that needs the file greys
# itself out in Setup until the file is there, and nothing else in the install is
# blocked.
#
#   ./scripts/apps/download-assets.sh --status   # one line per file
#   ./scripts/apps/download-assets.sh --check    # sha256 integrity of what is here
#   ./scripts/apps/download-assets.sh --ready scripts/apps/bitwig/bitwig-studio-6.0-beta-6.deb
#                                                    # silent, exit 0 = usable, 1 = not
#
# Supply a file by dropping it in the folder assets.links names for it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# scripts/apps/ → scripts/ → repo root. TWO dirnames: this file lives in
# scripts/apps, so a single dirname lands on scripts/ and every path is then
# relative to the wrong place.
ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
LINKS="$ROOT/assets.links"

G='\033[1;32m'; B='\033[1;34m'; Y='\033[1;33m'; D='\033[2m'; N='\033[0m'
msg(){ printf "${B}==>${N} %s\n" "$*"; }
ok(){  printf " ${G}✓${N} %s\n" "$*"; }
note(){ printf " ${Y}·${N} %s\n" "$*"; }   # a fact, not a failure
err(){ printf "\033[1;31m✗\033[0m %s\n" "$*" >&2; }
hr(){ printf '%.0s─' {1..72}; echo; }

STATUS_ONLY=0
CHECK_ONLY=0
READY_DEST=""
READY_ASKED=0
want_ready=0
for a in "$@"; do
  if ((want_ready)); then READY_DEST="$a"; want_ready=0; continue; fi
  case "$a" in
  -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  --status)  STATUS_ONLY=1 ;;
  --check)   CHECK_ONLY=1 ;;
  --ready)   READY_ASKED=1; want_ready=1 ;;
  *) echo "Unknown option: $a (see --help)" >&2; exit 1 ;;
  esac
done
if ((READY_ASKED)) && [[ -z "$READY_DEST" ]]; then
  echo "--ready needs a path from assets.links" >&2
  exit 2
fi

# Global: MANIFEST (array of "dest|sha")
MANIFEST=()

parse_links(){
  [[ -f "$LINKS" ]] || { err "assets.links not found: $LINKS"; return 1; }
  local line dest sha
  while IFS= read -r line || [[ -n $line ]]; do
    line="${line%%$'\r'}"
    [[ -z $line || $line == \#* ]] && continue
    dest="${line%%|*}"; sha="${line#*|}"
    # trims the spaces around the fields (format ' dest | sha ')
    dest="${dest#"${dest%%[![:space:]]*}"}"; dest="${dest%"${dest##*[![:space:]]}"}"
    sha="${sha#"${sha%%[![:space:]]*}"}";    sha="${sha%"${sha##*[![:space:]]}"}"
    # Only the path is required: a file with no recorded checksum is still
    # inventoried, and reported as present if it exists.
    [[ -z $dest || $dest == *' '* ]] && continue
    MANIFEST+=("$dest|$sha")
  done < "$LINKS"
  ((${#MANIFEST[@]})) || { err "No valid entry in $LINKS."; return 1; }
}

# present | absent | corrupt
file_state(){
  # Split, not one `local a=… b=$a`: this file runs under `set -u`, and a name
  # referenced in the same declaration that introduces it is not reliably bound
  # yet — it died with "f: unbound variable" on the first call.
  local f="$1" sha="$2" got
  local fn="$ROOT/$f"
  [[ -f "$fn" ]] || { echo absent; return; }
  [[ -z $sha ]] && { echo present; return; }
  got="$(sha256sum "$fn" 2>/dev/null | awk '{print $1}')"
  [[ -n $got && $got == "$sha" ]] && echo present || echo corrupt
}

# One printf per row, and %b rather than %s for every field.
#
# %s prints a backslash sequence literally: the colour codes arrived as
# arguments and came out on screen as the text "\033[1;32m" beside each line.
# %b interprets escapes in its arguments, which is what a variable full of them
# needs. Plain %s stays for the file names, which have no escapes to interpret.
row(){
  local mark="$1" colour="$2" name="$3" path="$4" tail="${5:-}"
  # Assembled first, printed once through %b: one specifier, one argument, and
  # %b interprets the escapes in it. Spreading the fields across the format
  # meant one more %s than argument, which shifted the lot by one.
  printf '%b\n' " ${colour}${mark}${N} ${name} ${D}${ROOT}/${path}/${N}${tail}"
}

do_status(){
  local entry dest st n_present=0 n_missing=0
  for entry in "${MANIFEST[@]}"; do
    dest="${entry%%|*}"
    st="$(file_state "$dest" "${entry##*|}")"
    case $st in
      present) row "✓" "$G" "$(basename "$dest")" "${dest%/*}" ""; n_present=$((n_present+1)) ;;
      corrupt) row "·" "$Y" "$(basename "$dest")" "${dest%/*}" " — here, but its checksum does not match"
                n_missing=$((n_missing+1)) ;;
      *)       row "·" "$Y" "$(basename "$dest")" "${dest%/*}" " — not here yet"; n_missing=$((n_missing+1)) ;;
    esac
  done
  hr
  printf " ${D}%d of %d present · %d to supply by hand${N}\n" \
    "$n_present" "${#MANIFEST[@]}" "$n_missing"
}

do_check(){
  local entry dest st bad=0
  for entry in "${MANIFEST[@]}"; do
    dest="${entry%%|*}"
    st="$(file_state "$dest" "${entry##*|}")"
    case $st in
      present) ok "$dest : intact" ;;
      corrupt) err "$dest : present but its checksum does NOT match assets.links"; bad=1 ;;
      *)       note "$dest : not here yet (supply it by hand)" ;;
    esac
  done
  hr
  return $bad
}

# Look a destination's recorded checksum up in the catalog.
sha_for(){
  local want="$1" entry
  for entry in "${MANIFEST[@]}"; do
    [[ "${entry%%|*}" == "$want" ]] && { echo "${entry##*|}"; return; }
  done
  echo ""
}

# The predicate Setup greys a module out on. Silent, and it says nothing about
# WHY: callers that want a reason run --status and read it.
ready(){
  local dest="$1" st
  # A destination that is not in the catalog at all cannot be judged, so it is
  # not ready — a module asking about an untracked file must not light up green.
  local known=0 entry
  for entry in "${MANIFEST[@]}"; do [[ "${entry%%|*}" == "$dest" ]] && { known=1; break; }; done
  ((known)) || return 1
  st="$(file_state "$dest" "$(sha_for "$dest")")"
  [[ $st == present ]]
}

# Names what is missing and where to put it. Called from the bootstrap so the
# absence is announced BEFORE the install rather than as a wall of red crosses
# halfway through it.
explain_missing(){
  local entry dest st any=0
  hr
  msg "Large installers — supplied by hand"
  for entry in "${MANIFEST[@]}"; do
    dest="${entry%%|*}"
    st="$(file_state "$dest" "${entry##*|}")"
    [[ $st == present ]] && continue
    any=1
    printf "  ${D}·${N} %s\n" "$(basename "$dest")"
    printf "      ${D}put it in  %s/%s/${N}\n" "$ROOT" "${dest%/*}"
  done
  if ((any)); then
    hr
    note "None of this blocks the install."
    note "Ableton, Bitwig and Guitar Pro simply stay GREYED OUT in Setup"
    note "until their file is in place — they grey back in on their own."
    hr
  fi
}

main(){
  parse_links || exit 1
  if ((STATUS_ONLY)); then do_status; exit 0; fi
  # `do_check || exit 1` rather than `do_check; exit $?`: under `set -e` a failing
  # do_check aborts the shell before `exit $?` is ever reached, so the explicit
  # || is what actually carries the 1 across.
  if ((CHECK_ONLY)); then do_check || exit 1; exit 0; fi
  # --ready is the predicate Setup greys a module out on: silent, exit 0 only
  # when the file is there AND its checksum holds.
  if [[ -n "$READY_DEST" ]]; then ready "$READY_DEST" || exit 1; exit 0; fi
  do_status
  explain_missing
}

main "$@"