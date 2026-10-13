#!/usr/bin/env bash
# archive-mosquitomarchy.sh — build an archive of the mosquitOmarchy repo.
#
# WHAT THIS PRODUCES
#   One tar.gz in the mosquitomarchy app folder
#   (scripts/apps/mosquitomarchy/), holding the repo under its own
#   `mosquitomarchy/` folder. It is meant to be taken by hand:
#
#       tar xzf mosquitomarchy-<type>-<date>.tar.gz
#       cd mosquitomarchy
#       ./bootstrap.sh              # or ./mosquitomarchy-setup.sh
#
#   With logs asked in, the name reads mosquitomarchy-complete-<date>+logs:
#   the "+logs" is an addition to the full content, not the content itself.
#
#   No mosquitomarchy code is involved in the extraction, and nothing in the
#   archive is a backup: a restore is done by the user, with tar.
#
# TWO ARCHIVE TYPES (the menu below explains each before you pick it)
#   complete   absolutely everything in the working tree — code, untracked
#              files, ignored files; logs are asked about at build time.
#              NEVER any archive (*.tar.gz of any kind, backups included),
#              whatever the type: the archives land inside the repo, so
#              letting one in would swallow all the previous ones.
#   source     the tracked code only: no logs, no install files, no backups
#
# BUILT FROM GIT WHERE IT MATTERS
#   The source list is `git ls-files`, not a `tar --exclude=` guess list:
#   the same commit gives the same content, and leftovers cannot leak in.
#   The complete list is the working tree as it stands (tracked plus
#   everything else on disk), because that type exists to hold it all.
#
# Usage:
#   ./archive-mosquitomarchy.sh              # menu: choose a type, then build
#   ./archive-mosquitomarchy.sh --list       # what would go in (and the sizes)
#   ./archive-mosquitomarchy.sh --out=DIR    # write DIR/ instead of the mosquitomarchy folder
#   ./archive-mosquitomarchy.sh --type=TYPE  # complete | source (skip the menu)
#   ./archive-mosquitomarchy.sh --logs / --no-logs   # complete type: log files in or out
#   ./archive-mosquitomarchy.sh -y           # take the defaults (source type)
#   ./archive-mosquitomarchy.sh -h
#
# Env:
#   OMARCHY_ARCHIVE_OUT   default output directory (default: scripts/apps/mosquitomarchy/)
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/lib/gui-run.bash"  # gui-run: reopen in a terminal when launched from a file manager — the prompt needs one
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
# The archive always lands in the mosquitomarchy app folder, so it is found
# where the manager lives. Archives can never leak INTO an archive (see the
# unconditional *.tar.gz exclusion in both collectors plus the final gate),
# which is what makes an in-repo destination safe.
OUT_DIR="${OMARCHY_ARCHIVE_OUT:-$ROOT/scripts/apps/mosquitomarchy}"

G='\033[1;32m'; B='\033[1;34m'; Y='\033[1;33m'; R='\033[1;31m'; N='\033[0m'
msg(){ printf "${B}==>${N} %s\n" "$*"; }
ok(){ printf " ${G}✓${N} %s\n" "$*"; }
warn(){ printf " ${Y}!${N} %s\n" "$*"; }
err(){ printf " ${R}✗${N} %s\n" "$*" >&2; }
hr(){ printf '%.0s─' {1..72}; echo; }

LIST_ONLY=0 YES=0
# "" = not asked yet. The prompts are the only interactive thing this script has.
LOGS=""
ARCHIVE_TYPE=""
for a in "$@"; do case "$a" in
  -y|--yes) YES=1 ;;                # -y takes the defaults (source type)
  --list|--dry-run) LIST_ONLY=1 ;;
  --out=*) OUT_DIR="${a#*=}" ;;
  --type=*) ARCHIVE_TYPE="${a#*=}" ;;
  --logs) LOGS=1 ;;
  --no-logs) LOGS=0 ;;
  -h|--help) sed -n '2,70p' "$0"; exit 0 ;;
  *) err "Unknown option: $a (supported: -y --list --out=DIR --type=TYPE --logs --no-logs)"; exit 1 ;;
esac; done
case "$ARCHIVE_TYPE" in
  ""|complete|source) ;;
  *) err "Unknown archive type: $ARCHIVE_TYPE (supported: complete, source)"; exit 1 ;;
esac

human(){ numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || printf '%sB' "${1:-0}"; }

# Files that must never appear in an archive, checked on the FINISHED file
# rather than trusted from the exclude list. This is the last gate before
# the file leaves the machine.
FORBIDDEN_PATTERNS=(
  '*/PATCH/*'
  '*/PATCH'
  '*/.local/*'
  '*.log'
  'last_crash.log'
  '*omarchy-backup-*.tar.gz'
  '*Passwords.kdbx'
  'pkglist.txt'
  'aurlist.txt'
  'apps.selected'
  '*.tar.gz'
)

# ───────────────────────── Collecting the file lists ─────────────────────────
collect_tracked(){
  # Prints, one per line, the repo-relative paths for the source type:
  # every tracked file, minus the ones an archive must not ship.
  git -C "$ROOT" ls-files -z \
    | tr '\0' '\n' \
    | grep -v -E '(^|/)PATCH/' \
    | grep -v -E '(^|/)\.local/' \
    | grep -v -E '(^|/)last_crash\.log$' \
    | grep -v -E '\.log$'
}
collect(){
  collect_tracked
}

collect_complete(){
  # Prints the working tree as it stands: the tracked files plus everything
  # else on disk (untracked AND ignored — the --exclude-standard flag is
  # deliberately absent), minus the things that must never ship: EVERY
  # archive (*.tar.gz anywhere, backups included — the archives land inside
  # the repo, so one nested archive would swallow all the previous ones),
  # passwords, machine-generated lists, and the logs unless asked for.
  {
    git -C "$ROOT" ls-files -z | tr '\0' '\n'
    git -C "$ROOT" ls-files --others -z | tr '\0' '\n'
  } | grep -v -E '(^|/)\.git/' \
    | grep -v -E '\.tar\.gz(\.gpg)?$' \
    | grep -v -E '(^|/)Passwords\.kdbx$' \
    | grep -v -E '(^|/)(pkglist|aurlist)\.txt$' \
    | grep -v -E '(^|/)apps\.selected$' \
    | { if (( ${LOGS:-0} )); then cat; else grep -v -E '(^|/)last_crash\.log$' | grep -v -E '\.log$'; fi; } \
    | awk 'NF && !seen[$0]++'
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
    printf '    • absolutely everything in the working tree\n'
    printf '    • code, untracked files, ignored files\n'
    printf '    • the logs are asked about when it is built\n'
    printf '    • never any archive (*.tar.gz anywhere, backups included)\n'
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
    printf '  1) choose archive type\n'
    printf '  2) start archiving\n'
    printf '  3) quit\n'
    local c
    read -rp "  Choice [1/2/3] " c || c=3
    case "${c:-3}" in
      1) type_menu ;;
      2) return 0 ;;
      3) ok "Nothing written."; exit 0 ;;
      *) warn "Choose 1, 2 or 3." ;;
    esac
  done
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
  read -rp "  Include the log files? [o/n] " r
  case "${r:-n}" in
    [oO]) LOGS=1 ;;
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
    mapfile -t FILES < <(collect_complete)
    local code
    code="$(cd "$ROOT" && printf '%s\n' "${FILES[@]}" | xargs -d '\n' stat -c%s 2>/dev/null | awk '{s+=$1} END {print s+0}')"
    msg "Complete archive contents ( $PROJECT_NAME/ )"
    printf '  %s files from the working tree\n' "${#FILES[@]}"
    printf '  total                : ~%s\n' "$(human "$code")"
    if (( LIST_ONLY )); then return 0; fi
    hr
    return 0
  fi
  mapfile -t TRACKED < <(collect)
  local code
  msg "Source archive contents ( $PROJECT_NAME/ )"
  printf '  %s tracked files from the repo\n' "${#TRACKED[@]}"
  code="$(cd "$ROOT" && printf '%s\n' "${TRACKED[@]}" | xargs -d '\n' stat -c%s 2>/dev/null | awk '{s+=$1} END {print s+0}')"
  printf '  code only          : ~%s\n' "$(human "$code")"
  if (( LIST_ONLY )); then return 0; fi
  hr
}

# ───────────────────────── Building ─────────────────────────
build(){
  preflight
  local type="${ARCHIVE_TYPE:-source}"
  if [[ $type == complete ]]; then build_complete; return; fi
  mapfile -t TRACKED < <(collect)

  msg "$type archive of ' $PROJECT_NAME '"
  msg "  Source : $ROOT @ $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo '?')"
  # The FILE LIST comes from git; the CONTENT comes from the working tree (tar
  # reads the disk). So uncommitted work would silently ship. Say so.
  if [[ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]]; then
    warn "Working tree has uncommitted changes — the archive ships the files ON DISK, not the commit."
    warn "  Commit first if the archive must match $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo 'the commit')."
  fi
  printf '  Content: %s tracked files — code only, no install file\n' "${#TRACKED[@]}"
  msg "  Excluded: machine state, logs, backups, every non-tracked file"

  mkdir -p "$OUT_DIR"
  local -a tf=(--transform="s|^|${PROJECT_NAME}/|")
  local stamp out tmp
  stamp="$(date +%Y-%m-%d)"
  out="$OUT_DIR/mosquitomarchy-$type-$stamp.tar.gz"
  tmp="$out.tmp.$$"
  trap 'rm -f "$tmp"' EXIT

  # pigz = parallel gzip (much faster, less memory pressure)
  local -a compress=()
  if command -v pigz >/dev/null 2>&1; then
    compress=("-I" "pigz"); msg "  Compression: pigz (parallel)"
  else
    msg "  Compression: gzip (install pigz to speed it up)"
  fi

  hr; msg "Creating the archive..."
  # ONE tar invocation for everything: appending to a finished .tar.gz would
  # mean decompressing and recompressing the whole thing once per addition.
  # --transform puts all of it under one <project>/ folder: extracting by
  # hand then yields a single directory.
  if ! ( cd "$ROOT" && tar cz "${compress[@]}" -f "$tmp" \
      "${tf[@]}" -- "${TRACKED[@]}" ); then
    err "tar failed — nothing was written."
    exit 1
  fi

  trap - EXIT

  local bytes; bytes="$(stat -c%s "$tmp")"
  mv -f "$tmp" "$out"

  # Final gate: verify what was actually written, not what we intended.
  msg "Verifying the archive..."
  local bad f
  bad=""
  while IFS= read -r f; do
    [[ -z $f ]] && continue
    for pat in "${FORBIDDEN_PATTERNS[@]}"; do
      if [[ $f == $pat ]] || [[ $f == *"$pat" ]]; then bad+="$f"$'\n'; break; fi
    done
  done < <(tar tzf "$out" 2>/dev/null)
  if [[ -n $bad ]]; then
    err "Unexpected content found in the archive — file removed:"
    printf '     %s' "$bad" >&2
    rm -f "$out"
    exit 1
  fi
  ok "verified: no logs, no backups, no passwords, no personal files"

  ok "$type archive: $out ($(human "$bytes"), $(tar tzf "$out" 2>/dev/null | wc -l) entries)"
  echo "  Extract by hand:  tar xzf $(basename "$out") && cd $PROJECT_NAME && ./bootstrap.sh"
  hr
}

build_complete(){
  preflight
  ask_logs
  mapfile -t FILES < <(collect_complete)
  (( ${#FILES[@]} )) || { err "Nothing to archive."; exit 1; }

  msg "complete archive of ' $PROJECT_NAME '"
  msg "  Source : $ROOT @ $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo '?') (plus the working tree as it stands)"
  if (( LOGS )); then
    msg "  Logs   : included (asked for)"
  else
    msg "  Logs   : excluded"
  fi

  mkdir -p "$OUT_DIR"
  local -a tf=(--transform="s|^|${PROJECT_NAME}/|")
  local stamp out tmp suffix=""
  stamp="$(date +%Y-%m-%d)"
  # "+logs" reads as an addition to the full content. The old "-logs" read
  # as if the logs WERE the content.
  (( LOGS )) && suffix="+logs"
  out="$OUT_DIR/mosquitomarchy-complete-$stamp$suffix.tar.gz"
  tmp="$out.tmp.$$"
  trap 'rm -f "$tmp"' EXIT

  local -a compress=()
  if command -v pigz >/dev/null 2>&1; then
    compress=("-I" "pigz"); msg "  Compression: pigz (parallel)"
  else
    msg "  Compression: gzip (install pigz to speed it up)"
  fi

  hr; msg "Creating the archive..."
  if ! ( cd "$ROOT" && tar cz "${compress[@]}" -f "$tmp" \
      "${tf[@]}" -- "${FILES[@]}" ); then
    err "tar failed — nothing was written."
    exit 1
  fi
  trap - EXIT

  local bytes; bytes="$(stat -c%s "$tmp")"
  mv -f "$tmp" "$out"

  msg "Verifying the archive..."
  local bad f
  bad=""
  while IFS= read -r f; do
    [[ -z $f ]] && continue
    # No exception anywhere, backups included: any nested archive or any
    # password fails the build. Entries carry the transformed
    # mosquitomarchy/ prefix here.
    for pat in '*.tar.gz' '*Passwords.kdbx'; do
      if [[ $f == $pat ]] || [[ $f == *"$pat" ]]; then bad+="$f"$'\n'; break; fi
    done
  done < <(tar tzf "$out" 2>/dev/null)
  if [[ -n $bad ]]; then
    err "Unexpected content found in the archive — file removed:"
    printf '     %s' "$bad" >&2
    rm -f "$out"
    exit 1
  fi
  ok "verified: no nested archives of any kind, no passwords"

  ok "complete archive: $out ($(human "$bytes"), $(tar tzf "$out" 2>/dev/null | wc -l) entries)"
  echo "  Extract by hand:  tar xzf $(basename "$out") && cd $PROJECT_NAME && ./bootstrap.sh"
  hr
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
