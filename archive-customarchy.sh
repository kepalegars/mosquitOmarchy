#!/usr/bin/env bash
# archive-customarchy.sh — Archiving of the mosquitOmarchy repo as tar.gz.
#
# On launch you choose among THREE archive types:
#
#   print         → FULL archive, everything except logs (personal backup):
#                   the whole repo + the dated config backups
#                   (~/omarchy-backups/). The bulky app installers
#                   (Ableton/DaVinci/Guitar Pro) are embedded automatically:
#                   it IS the personal backup of them.
#   release       → everything except logs, backup files and the personal
#                   extras kept locally next to the scripts.
#   release+patch → same as release, but including those personal extras
#                   (still no logs and no backup files).
#
# Whatever the type, the following is ALWAYS excluded: logs (*.log,
# last_crash.log), .venv/, any private files kept only on this machine,
# and the previous archives (omarchy-scripts-*.tar.gz).
#
# GitHub only contains the code — the files that live only on this machine
# exist only in the personal archives. "Latest release" = the archive
# produced by THIS script.
#
# The file name embeds the type and is dated:
#   print          → omarchy-scripts-print-<YYYY-MM-DD>.tar.gz        (last backup date)
#   release        → omarchy-scripts-release-<YYYY-MM-DD-HHMMSS>.tar.gz    (today)
#   release+patch  → omarchy-scripts-release-patch-<YYYY-MM-DD-HHMMSS>.tar.gz (today)
#
# The bulky installers (Ableton zips + .run, Guitar Pro .exe, DaVinci zips) are
# embedded automatically by the 'print' type (personal backup — that is the
# point of a print archive). The release types ASK about them (never forced).
# Usage:
#   ./archive-customarchy.sh                     # interactive: type? installers? -> tar.gz
#   ./archive-customarchy.sh -y                  # defaults (type 'print', all installers embedded)
#   ./archive-customarchy.sh --type=release      # non-interactive: clean release (no backups)
#   ./archive-customarchy.sh --type=release+patch# release including the personal extras
#   ./archive-customarchy.sh --with-ableton      # include all Ableton installers (release types)
#   ./archive-customarchy.sh --with-davinci      # include all DaVinci installers (release types)
#   ./archive-customarchy.sh --list-heavy        # list the detected bulky installers
#   ./archive-customarchy.sh --no-backups        # does not embed the backups folder (print only)
#   ./archive-customarchy.sh -h                  # help
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR"                          # repo root (the script lives at the root)
PROJECT_NAME="$(basename "$ROOT")"
BACKUP_DIR="${OMARCHY_BACKUP_DIR:-$HOME/omarchy-backups}"
OUT_DIR="${OMARCHY_ARCHIVE_OUT:-$ROOT}"

G='\033[1;32m'; B='\033[1;34m'; Y='\033[1;33m'; R='\033[1;31m'; D='\033[2m'; N='\033[0m'
msg(){ printf "${B}==>${N} %s\n" "$*"; }
ok(){ printf " ${G}✓${N} %s\n" "$*"; }
warn(){ printf " ${Y}!${N} %s\n" "$*"; }
err(){ printf " ${R}✗${N} %s\n" "$*" >&2; }
hr(){ printf '%.0s─' {1..72}; echo; }

YES=0 WITH_ABLETON=0 WITH_DAVINCI=0 NO_BACKUPS=0 LIST_ONLY=0 ARCHIVE_TYPE=""
FORCE_PRINT_HEAVY=0
for a in "$@"; do case "$a" in
  -y|--yes) YES=1 ;;
  --type=*) ARCHIVE_TYPE="${a#*=}" ;;
  --with-ableton) WITH_ABLETON=1 ;;
  --with-davinci) WITH_DAVINCI=1 ;;
  --no-backups) NO_BACKUPS=1 ;;
  --list-ableton|--list-heavy) LIST_ONLY=1 ;;
  -h|--help) sed -n '2,48p' "$0"; exit 0 ;;
  *) err "Unknown option: $a (see -h)"; exit 1 ;;
esac; done

ask(){
  local q="$1" def="${2:-y}" r
  ((YES)) && { ok "(auto) $q -> yes"; return 0; }
  if command -v gum >/dev/null; then
    gum confirm "$q" --default=$([[ $def == y ]] && echo true || echo false) && return 0 || return 1
  fi
  read -rp "$q [$([ $def = y ] && echo Y/n || echo y/N)] " r
  r="${r:-$def}"; [[ $r =~ ^[oOyY] ]]
}

# ───────────────────────── Archive type ─────────────────────────
# Three types:
#   print         full, everything except logs (personal backup: keeps the
#                 personal extras AND the dated config backups).
#   release       everything except logs, backup files and the personal extras.
#   release+patch same as release but including the personal extras.
pick_type(){
  local t
  msg "Choose the archive type:"
  if command -v gum >/dev/null 2>&1; then
    t="$(gum choose "print" "release" "release+patch" \
        --header "Archive type?  print = full personal backup (incl. config backups) / release = clean / release+patch = release incl. personal extras")"
  else
    echo " [1] print          — full: everything except logs (embeds config backups)"
    echo " [2] release        — everything except logs, backups and personal extras"
    echo " [3] release+patch  — release including the personal extras (no logs/backups)"
    local ch
    read -rp "Choice [1-3, default 1] : " ch; ch="${ch:-1}"
    case $ch in
      2) t=release ;;
      3) t=release+patch ;;
      *) t=print ;;
    esac
  fi
  printf '%s\n' "$t"
}

resolve_type(){
  # Sets TYPE + flags (keep_patch / keep_backups).
  if [[ -z $ARCHIVE_TYPE ]]; then
    if ((YES)); then ARCHIVE_TYPE=print; else ARCHIVE_TYPE="$(pick_type)"; fi
  fi
  case "$ARCHIVE_TYPE" in
    print)          TYPE=print;          keep_patch=1; keep_backups=1
                    FORCE_PRINT_HEAVY=1 ;;
    release)        TYPE=release;        keep_patch=0; keep_backups=0 ;;
    release+patch)  TYPE=release+patch;  keep_patch=1; keep_backups=0 ;;
    *) err "Unknown archive type: '$ARCHIVE_TYPE' (see -h)"; exit 1 ;;
  esac
  if ((NO_BACKUPS)) && [[ $TYPE != print ]]; then
    warn "(auto) '--no-backups' is ignored for type '$TYPE' — release archives never embed backups."
  fi
}

# ───────────────────────── Bulky installers ─────────────────────────
# Multi-GB files: Ableton installers (zips + .run) in ableton/,
# Guitar Pro installer (guitar-pro-8-setup.exe) in guitarpro/, and DaVinci Resolve
# installers (zips) in davinci/. They are NEVER embedded without
# validation (size).
HARD=()                 # all the detected "heavy" files
is_ableton(){ [[ "$1" == "$SCRIPT_DIR"/scripts/apps/ableton/* ]]; }
is_davinci(){ [[ "$1" == "$SCRIPT_DIR"/scripts/apps/davinci/* ]]; }
is_guitarpro(){ [[ "$1" == "$SCRIPT_DIR"/scripts/apps/guitarpro/* ]]; }

detect_heavy(){
  HARD=()
  local f
  for f in "$SCRIPT_DIR"/scripts/apps/ableton/*.zip "$SCRIPT_DIR"/scripts/apps/ableton/*.run \
           "$SCRIPT_DIR"/scripts/apps/guitarpro/*.exe \
           "$SCRIPT_DIR"/scripts/apps/davinci/DaVinci_Resolve_*_Linux.zip; do
    if [[ -f $f ]]; then HARD+=("$f"); fi
  done
}
has_heavy(){ ((${#HARD[@]} > 0)); }

select_heavy(){
  # Fills HARD_SELECTED: the heavy files kept for the archive.
  # 'print' (personal backup) auto-selects ALL of them.
  local -a chosen=() picks=() q p
  if (( FORCE_PRINT_HEAVY )); then
    chosen=("${HARD[@]}")
    warn "(print) bulky app installers auto-included (this is the personal backup)."
    HARD_SELECTED=("${chosen[@]}")
    return
  fi
  if (( WITH_ABLETON || WITH_DAVINCI )); then
    for f in "${HARD[@]}"; do
      { (( WITH_ABLETON )) && is_ableton "$f"; } || { (( WITH_DAVINCI )) && is_davinci "$f"; } \
        && chosen+=("$f")
    done
  elif (( YES )); then
    chosen=()
  elif command -v gum >/dev/null 2>&1; then
    local -a labels=()
    for f in "${HARD[@]}"; do
      is_ableton "$f" && labels+=("Ableton  →  $(basename "$f")")
      is_davinci "$f" && labels+=("DaVinci  →  $(basename "$f")")
      is_guitarpro "$f" && labels+=("Guitar Pro  →  $(basename "$f")")
    done
    mapfile -t picks < <(gum choose --no-limit \
        --header "Bulky installers to embed? (none = skip)" \
        --cursor-prefix "[ ] " --selected-prefix "[x] " "${labels[@]}")
    for q in "${picks[@]}"; do
      local shown="${q#*→  }"
      for p in "${HARD[@]}"; do [[ "$(basename "$p")" == "$shown" ]] && chosen+=("$p") && break; done
    done
  else
    local i=1 idx n
    echo "Bulky installers present:"
    for f in "${HARD[@]}"; do
      if is_ableton "$f"; then local tag="Ableton"; elif is_davinci "$f"; then local tag="DaVinci"; else local tag="Guitar Pro"; fi
      printf '  %2d) [%s] %s (%s)\n' "$i" "$tag" "$(basename "$f")" "$(du -h "$f" | cut -f1)"
      i=$((i+1))
    done
    read -rp "  Numbers to embed (e.g.: 2 4) — empty entry = none: " n
    for idx in $n; do
      [[ "$idx" =~ ^[0-9]+$ ]] && ((idx >= 1 && idx <= ${#HARD[@]})) && chosen+=("${HARD[$((idx-1))]}")
    done
  fi
  HARD_SELECTED=("${chosen[@]:-}")
}

# ───────────────────────── Display (--list-heavy) ─────────────────────────
if (( LIST_ONLY )); then
  detect_heavy
  if has_heavy; then
    msg "Bulky installers detected:"
    i=1
    for f in "${HARD[@]}"; do
      if is_ableton "$f"; then tag="Ableton"; elif is_davinci "$f"; then tag="DaVinci"; else tag="Guitar Pro"; fi
      printf '  %2d) [%s] %s  (%s)\n' "$i" "$tag" "$(basename "$f")" "$(du -h "$f" | cut -f1)"
      i=$((i+1))
    done
  else
    warn "No bulky installer (ableton/*.zip|*.run or davinci/DaVinci_Resolve_*.zip)."
  fi
  exit 0
fi

# ───────────────────────── Date: last backup otherwise today ─────────────────────────
last_backup_date(){
  # Most recent omarchy-backup-<YYYYMMDD-HHMMSS>.tar.gz file, gives its timestamp.
  local latest="" f
  for f in "$BACKUP_DIR"/omarchy-backup-*.tar.gz; do
    [[ -f $f ]] && [[ $f -nt $latest ]] && latest="$f"
  done
  [[ -z $latest ]] && { printf '%s' "$(date +%Y-%m-%d-%H%M%S)"; return; }
  local name ts
  name="$(basename "$latest")"
  ts="${name#omarchy-backup-}"; ts="${ts%.tar.gz}"      # YYYYMMDD-HHMMSS
  printf '%s-%s-%s' "${ts:0:4}" "${ts:4:2}" "${ts:6:2}"
}

# ───────────────────────── Building the archive ─────────────────────────
main(){
  detect_heavy
  resolve_type

  hr; msg "Archive of the ' $PROJECT_NAME ' repo — type: $TYPE"
  msg "  Source   : $ROOT"
  # Bulky installers selection: 'print' embeds them automatically (personal
  # backup); the release types offer them (except --with-* flags, or -y skips).
  HARD_SELECTED=()
  if has_heavy && { ((FORCE_PRINT_HEAVY)) || ((!YES)) || ((WITH_ABLETON || WITH_DAVINCI)); }; then
    select_heavy
  elif (( ! FORCE_PRINT_HEAVY )); then
    warn "(auto) bulky installers not embedded (size)."
  fi

  # Backups: dedicated folder included ONLY for the 'print' type (and not
  # with --no-backups). The release types never embed backup files.
  local has_backup=0
  if (( keep_backups )) && (( !NO_BACKUPS )) \
     && compgen -G "$BACKUP_DIR/omarchy-backup-*.tar.gz" >/dev/null 2>&1; then
    has_backup=1
  fi

  # Name: print → dated from the last backup; releases → today's timestamp.
  local stamp fsize
  if [[ $TYPE == print ]]; then
    stamp="$(last_backup_date)"
    OUT="$OUT_DIR/omarchy-scripts-print-$stamp.tar.gz"
  else
    stamp="$(date +%Y-%m-%d-%H%M%S)"
    OUT="$OUT_DIR/omarchy-scripts-release-patch-$stamp.tar.gz"
    [[ $TYPE == release ]] && OUT="$OUT_DIR/omarchy-scripts-release-$stamp.tar.gz"
  fi

  # Small list of what will be embedded, for the report
  msg "Contents:"
  echo "  • Full repo ($PROJECT_NAME/ + README/LICENSE/assets.links, without logs or .venv)"
  ((keep_patch)) && echo "  • Personal extras embedded (release+patch)"
  ((!keep_patch)) && echo "  • Personal extras EXCLUDED (release)"
  ((has_backup)) && echo "  • Config backups: $BACKUP_DIR/"
  ((!keep_backups)) && echo "  • Config backups EXCLUDED (release — rely on a 'print' archive)"
  echo "  • Private local files (kept only on this machine) — never in the archive"
  if ((${#HARD_SELECTED[@]})); then
    local f
    for f in "${HARD_SELECTED[@]}"; do echo "  • Installer  : $(basename "$f")"; done
  fi

  # Base exclusions: temp/logs/.venv + the Git history + private local files
  # (except the personal-extras types, the only archives that carry them) +
  # the previous archives (safety: an archive must never embed another one).
  local -a excludes=(
    --exclude='.git'
    --exclude='*.log'
    --exclude='last_crash.log'
    --exclude='*/PATCH/.venv'
    --exclude='guitar-pro-8-licence.md'
    --exclude='omarchy-scripts-*.tar.gz'
  )
  # 'release' (without patch) → the PATCH/ folders are never embedded.
  if ((!keep_patch)); then
    excludes+=(--exclude='*/PATCH' --exclude='PATCH')
  fi
  # Non-selected bulky installers → also excluded (size).
  local abel sel2 q3
  for abel in "${HARD[@]}"; do
    sel2=0
    for q3 in "${HARD_SELECTED[@]}"; do [[ $q3 == "$abel" ]] && sel2=1 && break; done
    ((sel2)) || excludes+=(--exclude="$(basename "$abel")")
  done

  hr
  msg "Creating the archive (may take a while)..."

  local out_tmp="$OUT.tmp$$"
  trap 'rm -f "$out_tmp"' EXIT

  # The config lives in the dedicated backup (~/omarchy-backups/): it is embedded
  # under the backups/ prefix in the archive (relative $HOME path → the backup
  # stays in the same place on restore).
  local -a btar=() transform=()
  if (( has_backup )); then
    transform=(--transform='s|^'"$(basename "$BACKUP_DIR")"'|backups|')
    btar=(-C "$(dirname "$BACKUP_DIR")" "$(basename "$BACKUP_DIR")")
  fi

  # pigz = parallel gzip (much faster, less memory pressure)
  local -a compress_args=()
  if command -v pigz >/dev/null 2>&1; then
    compress_args=("-I" "pigz")
    msg "  Compression: pigz (parallel)"
  else
    msg "  Compression: gzip (install pigz to speed it up)"
  fi

  # We archive from the repo's parent so the folder appears under its
  # own name (mosquitOmarchy/ in the tar), thus restoring everything in
  # the same place. Files that live on disk outside GitHub (private local
  # extras) are automatically embedded when the type keeps them.
  local parent="$(dirname "$ROOT")"
  if ! ( cd "$parent" && tar cz "${compress_args[@]}" -f "$out_tmp" \
      --warning=no-file-changed "${excludes[@]}" "$PROJECT_NAME" \
      "${transform[@]}" "${btar[@]}" ); then
    err "Failed to create the archive — temporary file kept: $out_tmp"
    trap - EXIT
    return 1
  fi
  trap - EXIT
  mv "$out_tmp" "$OUT"

  fsize="$(du -h "$OUT" | cut -f1)"
  ok "Archive created: $OUT ($fsize)"
  echo "  Contains: $(tar tzf "$OUT" 2>/dev/null | wc -l) entries"
  hr
}

main