#!/usr/bin/env bash
# archive-mosquitomarchy.sh — build an archive of the mosquitOmarchy repo.
#
# WHAT THIS PRODUCES
#   One tar.gz in the user's home folder by default (or the chosen output
#   folder), holding the repo under its own
#   `mosquitomarchy/` folder. It is meant to be taken by hand:
#
#       tar xzf mosquitomarchy-<type>-<timestamp>.tar.gz
#       cd mosquitomarchy
#       ./bootstrap.sh              # or ./mosquitomarchy-setup.sh
#
#   With logs asked in, the name reads mosquitomarchy-complete-<timestamp>+logs:
#   the "+logs" is an addition to the full content, not the content itself.
#
#   No mosquitomarchy code is involved in the extraction, and nothing in the
#   archive is a backup: a restore is done by the user, with tar.
#
# TWO ARCHIVE TYPES (the menu below explains each before you pick it)
#   complete   tracked, untracked and ignored working-tree files; logs are
#              and application installers are asked about after Start. Sensitive
#              machine state, PATCH/.local, passwords and nested archives are excluded.
#   source     the tracked code only: no logs, no install files, no backups
#
# BUILT FROM GIT WHERE IT MATTERS
#   The source list is `git ls-files`, not a `tar --exclude=` guess list:
#   the same commit gives the same content, and leftovers cannot leak in.
#   The complete list is the working tree as it stands (tracked plus
#   untracked/ignored files), except for the safety exclusions above.
#
# Usage:
#   ./archive-mosquitomarchy.sh              # menu: choose a type, then build
#   ./archive-mosquitomarchy.sh --list       # what would go in (and the sizes)
#   ./archive-mosquitomarchy.sh --out=DIR    # write DIR/ instead of the mosquitomarchy folder
#   ./archive-mosquitomarchy.sh --type=TYPE  # complete | source (skip the menu)
#   ./archive-mosquitomarchy.sh --logs / --no-logs   # complete type: log files in or out
#   ./archive-mosquitomarchy.sh --installers / --no-installers # complete: app installers in or out
#   ./archive-mosquitomarchy.sh -y           # take the defaults (source type)
#   ./archive-mosquitomarchy.sh -h
#
# Env:
#   OMARCHY_ARCHIVE_OUT   default output directory (default: $HOME)
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/code/lib/gui-run.bash"  # gui-run: reopen in a terminal when launched from a file manager — the prompt needs one
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The repo ROOT is right here: this script lives next to bootstrap at the
# repo root. Resolved
# from the location rather than assumed, so the archive covers the repo
# whether it is run from its own folder or by absolute path.
# (The script sits AT the root, so its own folder IS the root.)
ROOT="$SCRIPT_DIR"
# The folder name inside the archive is the CANONICAL project name, not the
# name of whoever's checkout produced it: the same commit must give the same
# archive whatever the directory is called locally (here it is 'mosquitOmarchy').
PROJECT_NAME="mosquitomarchy"
# Archives can never leak into a later archive: both collectors and the final
# verification exclude nested tarballs.
OUT_DIR="${OMARCHY_ARCHIVE_OUT:-$HOME}"

G='\033[1;32m'; B='\033[1;34m'; Y='\033[1;33m'; R='\033[1;31m'; N='\033[0m'
msg(){ printf "${B}==>${N} %s\n" "$*"; }
ok(){ printf " ${G}✓${N} %s\n" "$*"; }
warn(){ printf " ${Y}!${N} %s\n" "$*"; }
err(){ printf " ${R}✗${N} %s\n" "$*" >&2; }
hr(){ printf '%.0s─' {1..72}; echo; }

LIST_ONLY=0 YES=0
# "" = not asked yet. The prompts are the only interactive thing this script has.
LOGS=""
ARCHIVE_INSTALLERS=""
ARCHIVE_TYPE=""
for a in "$@"; do case "$a" in
  -y|--yes) YES=1 ;;                # -y takes the defaults (source type)
  --list|--dry-run) LIST_ONLY=1 ;;
  --out=*) OUT_DIR="${a#*=}" ;;
  --type=*) ARCHIVE_TYPE="${a#*=}" ;;
  --logs) LOGS=1 ;;
  --no-logs) LOGS=0 ;;
  --installers) ARCHIVE_INSTALLERS=1 ;;
  --no-installers) ARCHIVE_INSTALLERS=0 ;;
  -h|--help) sed -n '2,70p' "$0"; exit 0 ;;
  *) err "Unknown option: $a (supported: -y --list --out=DIR --type=TYPE --logs --no-logs --installers --no-installers)"; exit 1 ;;
esac; done
case "$ARCHIVE_TYPE" in
  ""|complete|source) ;;
  *) err "Unknown archive type: $ARCHIVE_TYPE (supported: complete, source)"; exit 1 ;;
esac

human(){ numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || printf '%sB' "${1:-0}"; }

file_bytes(){
  (( $# )) || { echo 0; return; }
  printf '%s\0' "$@" | xargs -0 -r stat -c%s -- | awk '{s+=$1} END {print s+0}'
}

space_available(){
  local target="$OUT_DIR"
  while [[ ! -d $target && $target != / ]]; do target="$(dirname "$target")"; done
  df -Pk -- "$target" | awk 'NR==2 {print $4 * 1024}'
}

# Stream the uncompressed tar through a tiny stdlib progress renderer before
# gzip/pigz. This works without an extra `pv` dependency and reports real bytes.
progress_stream(){
  python3 -c '
import sys
total = int(sys.argv[1])
done = 0
tty = sys.stderr.isatty()
width = 32
def draw(pct):
    filled = width * pct // 100
    sys.stderr.write("\rArchive: [%s%s] %3d%%" % ("#" * filled, "-" * (width - filled), pct))
    sys.stderr.flush()
try:
    while True:
        chunk = sys.stdin.buffer.read(1024 * 1024)
        if not chunk:
            break
        sys.stdout.buffer.write(chunk)
        done += len(chunk)
        if tty:
            draw(min(99, done * 100 // max(total, 1)))
    sys.stdout.buffer.flush()
except BrokenPipeError:
    sys.exit(1)
if tty:
    draw(100)
    sys.stderr.write("\n")
' "$1"
}

# Sensitive or recursive content is excluded in both modes and checked again
# in the finished archive. Logs are added to this list unless explicitly kept.
FORBIDDEN_PATTERNS=(
  '*/PATCH/*'
  '*/PATCH'
  '*/.local/*'
  '*/.local'
  '*Passwords.kdbx'
  '*/pkglist.txt'
  '*/aurlist.txt'
  '*/apps.selected'
  '*.tar.gz'
  '*.tar.gz.gpg'
)

# ───────────────────────── Collecting the file lists ─────────────────────────
collect_tracked(){
  # Prints NUL-separated repo-relative paths for the source type:
  # every tracked file, minus the ones an archive must not ship.
  git -C "$ROOT" ls-files -z \
     | grep -zvE '(^|/)PATCH(/|$)|(^|/)\.local(/|$)|(^|/)(Passwords\.kdbx|pkglist\.txt|aurlist\.txt|apps\.selected)$|\.tar\.gz(\.gpg)?$|\.log$'
}
collect(){
  collect_tracked
}

collect_complete(){
  # Includes ignored files too, except sensitive machine state, PATCH/.local,
  # passwords, generated lists, nested archives and (unless requested) logs.
  local exclude='(^|/)\.git(/|$)|(^|/)PATCH(/|$)|(^|/)\.local(/|$)|(^|/)(Passwords\.kdbx|pkglist\.txt|aurlist\.txt|apps\.selected)$|\.tar\.gz(\.gpg)?$'
  (( ${LOGS:-0} )) || exclude+='|\.log$'
  (( ${ARCHIVE_INSTALLERS:-0} )) || exclude+='|^code/modules/Apps/(ableton/[^/]+\.(run|zip)|bitwig/[^/]+\.deb|davinci/[^/]+\.zip|spektrafilm/[^/]+\.zip|guitarpro/[^/]+\.exe)$'
  {
    git -C "$ROOT" ls-files -z
    git -C "$ROOT" ls-files --others -z
  } | grep -zvE "$exclude"
}

installer_files(){
  local f
  for f in "$ROOT"/code/modules/Apps/ableton/*.{run,zip} \
           "$ROOT"/code/modules/Apps/bitwig/*.deb \
           "$ROOT"/code/modules/Apps/davinci/*.zip \
           "$ROOT"/code/modules/Apps/spektrafilm/*.zip \
           "$ROOT"/code/modules/Apps/guitarpro/*.exe; do
    [[ -f $f ]] && printf '%s\0' "${f#"$ROOT"/}"
  done
}

installer_names(){
  local f first=1
  (( $# )) || { printf 'none found'; return; }
  for f in "$@"; do
    (( first )) || printf ', '
    printf '%s' "$f"
    first=0
  done
}

# ───────────────────────── Archive type menu ─────────────────────────
type_menu(){
  # Choosing a type answers the question and returns to the main menu on its
  # own; only "back" leaves the choice untouched.
  while true; do
    printf '\n'
    msg "Archive type (current: ${ARCHIVE_TYPE:-source})"
    printf '\n'
    printf '  complete:\n'
    printf '    • tracked, untracked and ignored files (except sensitive state)\n'
    printf '    • after Start, choose whether installers and logs are included\n'
    printf '    • excludes .local, PATCH, passwords, generated lists and nested archives\n'
    printf '\n'
    printf '  source:\n'
    printf '    • the tracked code only\n'
    printf '    • no logs, no install files, no backups\n'
    printf '\n'
    printf '    1) complete\n'
    printf '    2) source\n'
    printf '    3) back\n'
    local c
    read -rp "  Choice [1/2/3] " c || c=3
    case "${c:-3}" in
      1) ARCHIVE_TYPE=complete; return 0 ;;
      2) ARCHIVE_TYPE=source; return 0 ;;
      3) return 0 ;;
      *) warn "Choose 1, 2 or 3." ;;
    esac
  done
}

main_menu(){
  ARCHIVE_TYPE="${ARCHIVE_TYPE:-source}"
  while true; do
    hr
    msg "mosquitOmarchy archive (type: $ARCHIVE_TYPE, out: $OUT_DIR)"
    printf '  1) set archive destination folder\n'
    printf '  2) choose archive type\n'
    printf '  3) start archiving\n'
    printf '  4) quit\n'
    local c
    read -rp "  Choice [1/2/3/4] " c || c=4
    case "${c:-3}" in
      1) output_folder_menu ;;
      2) type_menu ;;
      3) return 0 ;;
      4) ok "Nothing written."; exit 0 ;;
      *) warn "Choose 1, 2, 3 or 4." ;;
    esac
  done
}

output_folder_menu(){
  local dest
  printf '\nCurrent archive folder: %s\n' "$OUT_DIR"
  read -r -p 'Enter a folder path (Enter keeps the current folder): ' dest || return 0
  [[ -n $dest ]] || return 0
  case "$dest" in
    '~') dest="$HOME" ;;
    '~/'*) dest="$HOME/${dest#\~/}" ;;
  esac
  [[ $dest == /* ]] || dest="$ROOT/$dest"
  OUT_DIR="${dest%/}"
  [[ -n $OUT_DIR ]] || OUT_DIR=/
  ok "Archive folder set to: $OUT_DIR"
}

ask_installers(){
  [[ ${ARCHIVE_TYPE:-source} == complete ]] || return 0
  local -a files=()
  mapfile -d '' -t files < <(installer_files)
  if (( ${#files[@]} == 0 )); then
    ARCHIVE_INSTALLERS=0
    msg 'No Ableton, Bitwig, DaVinci or Guitar Pro installer files found.'
    return 0
  fi
  local names answer
  names="$(installer_names "${files[@]}")"
  if [[ -n $ARCHIVE_INSTALLERS ]]; then
    if (( ARCHIVE_INSTALLERS )); then ok "Installers included: ($names)"; else msg "Installers excluded: ($names)"; fi
    return 0
  fi
  if (( YES )) || [[ ! -t 0 ]]; then
    ARCHIVE_INSTALLERS=0
    msg "Installers excluded by default: ($names)"
    return 0
  fi
  printf '\nInstaller files (Ableton, Bitwig, DaVinci, Guitar Pro): (%s)\n' "$names"
  read -r -p 'Include these files in the archive? [y/N] ' answer || answer=n
  case "${answer:-n}" in
    [yY]) ARCHIVE_INSTALLERS=1; ok "Installers included: ($names)" ;;
    *) ARCHIVE_INSTALLERS=0; msg "Installers excluded: ($names)" ;;
  esac
}

# The one question the complete type asks. Default keeps the logs OUT: they
# are machine state, and an archive that holds everything already holds a lot.
ask_logs(){
  [[ $ARCHIVE_TYPE == complete ]] || return 0
  [[ -n $LOGS ]] && return 0
  if (( YES )) || [[ ! -t 0 ]]; then
    LOGS=0
    (( YES )) && ok "(auto) logs excluded"
    return 0
  fi
  local r
  read -rp "  Include the log files? [y/n] " r
  case "${r:-n}" in
    [yY]) LOGS=1 ;;
    *)    LOGS=0 ;;
  esac
}

preflight(){
  cd "$ROOT" || { err "Not a directory: $ROOT"; exit 1; }
  git rev-parse --git-dir >/dev/null 2>&1 \
    || { err "Not a git checkout: $ROOT — the source type is built from the tracked files."; exit 1; }
}

# ───────────────────────── Listing ─────────────────────────
do_list(){
  preflight
  local type="${ARCHIVE_TYPE:-source}"
  if [[ $type == complete ]]; then
    mapfile -d '' -t FILES < <(collect_complete)
    local code
    code="$(file_bytes "${FILES[@]}")"
    msg "Complete archive contents ( $PROJECT_NAME/ )"
    printf '  %s files from the working tree\n' "${#FILES[@]}"
    printf '  total                : ~%s\n' "$(human "$code")"
    printf '  free at destination : %s\n' "$(human "$(space_available)")"
    if (( LOGS )); then printf '  logs                 : included\n'; else printf '  logs                 : excluded (default)\n'; fi
    local -a installers=()
    mapfile -d '' -t installers < <(installer_files)
    if (( ARCHIVE_INSTALLERS )); then
      printf '  app installers       : included (%s)\n' "$(installer_names "${installers[@]}")"
    else
      printf '  app installers       : excluded by default (%s)\n' "$(installer_names "${installers[@]}")"
    fi
    if (( LIST_ONLY )); then return 0; fi
    hr
    return 0
  fi
  mapfile -d '' -t TRACKED < <(collect)
  local code
  msg "Source archive contents ( $PROJECT_NAME/ )"
  printf '  %s tracked files from the repo\n' "${#TRACKED[@]}"
  code="$(file_bytes "${TRACKED[@]}")"
  printf '  code only          : ~%s\n' "$(human "$code")"
  printf '  free at destination : %s\n' "$(human "$(space_available)")"
  if (( LIST_ONLY )); then return 0; fi
  hr
}

# ───────────────────────── Building ─────────────────────────
verify_archive(){
  local archive="$1" allow_logs="$2" listing="$3" f bad="" pat
  local -a forbidden=("${FORBIDDEN_PATTERNS[@]}")
  (( allow_logs )) || forbidden+=( '*.log' )
  tar tzf "$archive" > "$listing" 2>/dev/null \
    || { err "Archive verification failed (truncated or corrupt)."; return 1; }
  while IFS= read -r f; do
    [[ -z $f ]] && continue
    for pat in "${forbidden[@]}"; do
      if [[ $f == $pat ]]; then bad+="$f"$'\n'; break; fi
    done
  done < "$listing"
  if [[ -n $bad ]]; then
    err "Forbidden content found in the archive:"
    printf '     %s' "$bad" >&2
    return 1
  fi
}

check_space(){
  local input_bytes="$1" available required
  mkdir -p "$OUT_DIR"
  available="$(space_available)"
  required=$((input_bytes + 128 * 1024 * 1024))
  printf '  Input size          : ~%s\n' "$(human "$input_bytes")"
  printf '  Free at destination : %s\n' "$(human "$available")"
  (( available >= required )) || {
    err "Not enough space; need at least $(human "$required") including a 128 MB safety margin."
    return 1
  }
}

create_archive(){
  local tmp="$1" input_bytes="$2" listing="$3" out="$4"; shift 4
  local -a tf=(--transform="s|^|${PROJECT_NAME}/|") compressor=(gzip -c)
  command -v python3 >/dev/null 2>&1 || { err "python3 is required for the progress bar."; return 1; }
  if command -v pigz >/dev/null 2>&1; then
    compressor=(pigz -c)
    msg "  Compression: pigz (parallel)"
  else
    msg "  Compression: gzip"
  fi
  trap 'rm -f -- "$tmp" "$listing"' EXIT
  hr; msg "Creating archive..."
  if ! (cd "$ROOT" && tar -c "${tf[@]}" -- "$@") \
      | progress_stream "$input_bytes" \
      | "${compressor[@]}" > "$tmp"; then
    err "Archive creation failed; the incomplete file was discarded."
    return 1
  fi
  msg "Verifying archive contents and compression..."
  verify_archive "$tmp" "${LOGS:-0}" "$listing" || return 1
  local bytes entries
  bytes="$(stat -c%s "$tmp")"
  entries="$(wc -l < "$listing")"
  mv -- "$tmp" "$out"
  rm -f -- "$listing"
  trap - EXIT
  ok "verified archive: $out ($(human "$bytes"), $entries entries)"
  echo "  Extract by hand:  tar xzf $(basename "$out") && cd $PROJECT_NAME && ./bootstrap.sh"
  hr
}

archive_path(){
  local type="$1" logs="$2" stamp suffix=""
  stamp="$(date +%Y-%m-%d-%H%M%S-%N)"
  (( logs )) && suffix="+logs"
  printf '%s/mosquitomarchy-%s-%s%s.tar.gz' "$OUT_DIR" "$type" "$stamp" "$suffix"
}

build(){
  preflight
  local type="${ARCHIVE_TYPE:-source}"
  [[ $type == complete ]] && { build_complete; return; }
  mapfile -d '' -t TRACKED < <(collect)
  msg "source archive of ' $PROJECT_NAME '"
  msg "  Source : $ROOT @ $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo '?')"
  if [[ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]]; then
    warn "Working tree has uncommitted changes — the archive uses files on disk, not the commit."
  fi
  printf '  Content: %s tracked source files\n' "${#TRACKED[@]}"
  msg "  Excluded: machine state, logs, backups, passwords and non-tracked files"
  local input_bytes out tmp listing
  input_bytes="$(file_bytes "${TRACKED[@]}")"
  check_space "$input_bytes" || exit 1
  out="$(archive_path source 0)"
  tmp="$out.tmp.$$"; listing="$tmp.list"
  create_archive "$tmp" "$input_bytes" "$listing" "$out" "${TRACKED[@]}"
}

build_complete(){
  preflight
  ask_installers
  ask_logs
  mapfile -d '' -t FILES < <(collect_complete)
  (( ${#FILES[@]} )) || { err "Nothing to archive."; exit 1; }
  msg "complete archive of ' $PROJECT_NAME '"
  msg "  Source : $ROOT @ $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo '?') plus working-tree files"
  if (( LOGS )); then msg "  Logs   : included (as requested)"; else msg "  Logs   : excluded"; fi
  printf '  Content: %s files, ~%s uncompressed\n' "${#FILES[@]}" "$(human "$(file_bytes "${FILES[@]}")")"
  msg "  Safety exclusions: .local, PATCH, passwords, generated lists and nested archives"
  local input_bytes out tmp listing
  input_bytes="$(file_bytes "${FILES[@]}")"
  check_space "$input_bytes" || exit 1
  out="$(archive_path complete "$LOGS")"
  tmp="$out.tmp.$$"; listing="$tmp.list"
  create_archive "$tmp" "$input_bytes" "$listing" "$out" "${FILES[@]}"
}

# ───────────────────────── Dispatch ─────────────────────────
do_list
if (( LIST_ONLY )); then exit 0; fi
# Interactive without an explicit --type (and without -y): the menu. Anything
# scripted (-y, piped stdin, an explicit --type) builds straight away with the
# source defaults, exactly like before.
if [[ -z $ARCHIVE_TYPE ]] && (( ! YES )) && [[ -t 0 ]]; then
  main_menu
fi
ARCHIVE_TYPE="${ARCHIVE_TYPE:-source}"
build
# The classic finish: without it the terminal closes the instant the archive
# is done and the result is never seen. Only when interactive — a scripted
# run (-y, pipes) must never block on a prompt.
if [[ -t 0 && -t 1 ]]; then
  hr
  read -rp "Done — press Enter to quit. " _ || true
fi
