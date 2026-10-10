#!/usr/bin/env bash
# archive-mosquitomarchy.sh — build an archive of the mosquitOmarchy repo.
#
# WHAT THIS PRODUCES
#   One tar.gz in the directory ABOVE the repo, holding the repo under its own
#   `mosquitomarchy/` folder. It is meant to be taken by hand:
#
#       tar xzf mosquitomarchy-<type>-<date>.tar.gz
#       cd mosquitomarchy
#       ./bootstrap.sh              # or ./mosquitomarchy-setup.sh
#
#   No mosquitomarchy code is involved in the extraction, and nothing in the
#   archive is a backup: a restore is done by the user, with tar.
#
# THREE ARCHIVE TYPES (the menu below explains each before you pick it)
#   complete   absolutely everything in the working tree — code, untracked
#              files, ignored files; logs are asked about at build time
#   release    the tracked code plus the install files you choose, no logs,
#              under the 2 GiB GitHub asset ceiling
#   source     the tracked code only: no logs, no install files
#
# BUILT FROM GIT WHERE IT MATTERS
#   The release and source lists are `git ls-files`, not a `tar --exclude=`
#   guess list: the same commit gives the same content, and leftovers cannot
#   leak in. The complete list is the working tree as it stands (tracked plus
#   everything else on disk), because that type exists to hold it all.
#
# SIZE
#   GitHub accepts a release asset up to 2 GiB (and a file in the REPOSITORY
#   only up to 100 MB — which is why the installers live in a release and not
#   in git). The release build refuses to produce an archive above that limit
#   instead of leaving an upload that GitHub will reject.
#
# THE INSTALL FILES ARE A CHOICE (release type only)
#   The repo alone is ~67 MB. The two install files add ~460 MB, and a release
#   of a version that has nothing new to install does not need them. So it is
#   asked, once, with the sizes in front of you, and the answer is recorded IN
#   THE FILENAME:
#
#     mosquitomarchy-release-2026-09-30-installers.tar.gz   (with them)
#     mosquitomarchy-release-2026-09-30.tar.gz               (code only)
#
#   The suffix is the only record of what a given archive holds, and it is
#   there so nobody has to download 490 MB to find out.
#
# Usage:
#   ./archive-mosquitomarchy.sh              # menu: choose a type, then build
#   ./archive-mosquitomarchy.sh --list       # what would go in (and the sizes)
#   ./archive-mosquitomarchy.sh --out=DIR    # write DIR/ instead of the parent dir
#   ./archive-mosquitomarchy.sh --type=TYPE  # complete | release | source (skip the menu)
#   ./archive-mosquitomarchy.sh --logs / --no-logs   # complete type: log files in or out
#   ./archive-mosquitomarchy.sh -y           # take the defaults (release, install files INCLUDED)
#   ./archive-mosquitomarchy.sh -h
#
# Env:
#   OMARCHY_ARCHIVE_OUT   default output directory (default: the repo's parent dir)
#   OMARCHY_ARCHIVE_MAX   size ceiling in bytes (default: 2 GiB)
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gui-run.bash"  # gui-run: reopen in a terminal when launched from a file manager — the prompt needs one
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The repo ROOT is the parent: this script lives in scripts/, next to the other
# tooling. Resolved from the location rather than assumed, so the archive
# covers the repo whether it is run from scripts/ or by absolute path.
ROOT="$(dirname "$SCRIPT_DIR")"
# The folder name inside the archive is the CANONICAL project name, not the
# name of whoever's checkout produced it: the same commit must give the same
# archive whatever the directory is called locally (here it is 'mosquitOmarchy').
PROJECT_NAME="mosquitomarchy"
# The archive always lands NEXT TO the repo, never inside it: extracting by
# hand yields a single directory, and the repo never collects tarballs.
OUT_DIR="${OMARCHY_ARCHIVE_OUT:-$(dirname "$ROOT")}"
# GitHub release asset limit: 2 GiB.
MAX_BYTES="${OMARCHY_ARCHIVE_MAX:-2147483648}"

G='\033[1;32m'; B='\033[1;34m'; Y='\033[1;33m'; R='\033[1;31m'; N='\033[0m'
msg(){ printf "${B}==>${N} %s\n" "$*"; }
ok(){ printf " ${G}✓${N} %s\n" "$*"; }
warn(){ printf " ${Y}!${N} %s\n" "$*"; }
err(){ printf " ${R}✗${N} %s\n" "$*" >&2; }
hr(){ printf '%.0s─' {1..72}; echo; }

LIST_ONLY=0 YES=0
# "" = not asked yet. The prompts are the only interactive thing this script has.
INSTALLERS=""
LOGS=""
ARCHIVE_TYPE=""
for a in "$@"; do case "$a" in
  -y|--yes) YES=1 ;;                # -y takes the defaults, which is the release
                                    # with the install files INCLUDED
  --list|--dry-run) LIST_ONLY=1 ;;
  --out=*) OUT_DIR="${a#*=}" ;;
  --type=*) ARCHIVE_TYPE="${a#*=}" ;;
  --logs) LOGS=1 ;;
  --no-logs) LOGS=0 ;;
  --installers) INSTALLERS=1 ;;
  --no-installers) INSTALLERS=0 ;;
  -h|--help) sed -n '2,70p' "$0"; exit 0 ;;
  *) err "Unknown option: $a (supported: -y --list --out=DIR --type=TYPE --logs --no-logs --installers --no-installers)"; exit 1 ;;
esac; done
case "$ARCHIVE_TYPE" in
  ""|complete|release|source) ;;
  *) err "Unknown archive type: $ARCHIVE_TYPE (supported: complete, release, source)"; exit 1 ;;
esac

# ───────────────────────── Installation files ─────────────────────────
# The files the release carries on top of the repo. This list IS the spec: it
# matches the "Installation files" table of the main README, and nothing is
# added implicitly. Each is refused outright if it alone would blow the
# ceiling, so a 10 GB DaVinci zip can never turn into a 10 GB upload attempt.
#
#   install-ableton-latest.run   113 MB  the ableton-linux installer, the only
#                                       way to install Ableton from a release
#   bitwig-studio-*.deb          348 MB  the exact build the module pins
#
# NOT carried, on purpose (the README links them instead): the Ableton Live
# zips (account-gated, 3-4 GB each), the DaVinci Resolve zip (10 GB) and the
# Guitar Pro installer (988 MB, freely downloadable).
INSTALL_FILES=(
  scripts/apps/ableton/install-ableton-latest.run
  scripts/apps/bitwig/bitwig-studio-*.deb
)

human(){ numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || printf '%sB' "${1:-0}"; }

# Files that must never appear in a release, checked on the FINISHED archive
# rather than trusted from the exclude list. A release is published, so this
# is the last gate before the file leaves the machine.
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
  # Prints, one per line, the repo-relative paths for the release and source
  # types: every tracked file, minus the ones an archive must not ship.
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
  # deliberately absent), minus the few things that must never ship: nested
  # archives, passwords, machine-generated lists, and the logs unless asked
  # for at build time.
  {
    git -C "$ROOT" ls-files -z | tr '\0' '\n'
    git -C "$ROOT" ls-files --others -z | tr '\0' '\n'
  } | grep -v -E '(^|/)\.git/' \
    | grep -v -E '\.tar\.gz$' \
    | grep -v -E '(^|/)Passwords\.kdbx$' \
    | grep -v -E '(^|/)(pkglist|aurlist)\.txt$' \
    | grep -v -E '(^|/)apps\.selected$' \
    | { if (( ${LOGS:-0} )); then cat; else grep -v -E '(^|/)last_crash\.log$' | grep -v -E '\.log$'; fi; } \
    | awk 'NF && !seen[$0]++'
}

install_files_present(){
  local p out=()
  for p in "${INSTALL_FILES[@]}"; do
    # shellcheck disable=SC2206
    local m=($(cd "$ROOT" && ls -1 $p 2>/dev/null))
    for f in "${m[@]}"; do out+=("$f"); done
  done
  printf '%s\n' "${out[@]:-}"
}

# Sum of the install files that are actually on disk, in bytes.
install_files_bytes(){
  local total=0 f
  while IFS= read -r f; do
    [[ -n $f ]] || continue
    total=$((total + $(stat -c%s "$ROOT/$f" 2>/dev/null || echo 0)))
  done < <(install_files_present | sed '/^$/d')
  printf '%s' "$total"
}

# The one question this script asks. Default is YES: the install files are the
# reason a release archive exists at all (they are what GitHub cannot hold),
# and a release without them is just a tarball of a git clone.
#
# It never blocks: -y and the two explicit flags decide it, and a run with no
# terminal takes the default with a line saying so. A prompt nobody can answer
# would hang the very caller (a cron job, a script) that passed no -y.
ask_installers(){
  [[ -n $INSTALLERS ]] && return 0            # --installers / --no-installers
  local bytes; bytes="$(install_files_bytes)"
  if (( bytes == 0 )); then
    INSTALLERS=0
    warn "No install file on disk (looked for ${INSTALL_FILES[*]}) — code-only release."
    return 0
  fi
  if (( YES )); then
    INSTALLERS=1; ok "(auto) install files included — $(human "$bytes")"
    return 0
  fi
  if [[ ! -t 0 ]]; then
    INSTALLERS=1
    warn "No terminal to ask in — taking the default: install files INCLUDED ($(human "$bytes"))."
    warn "  Use --no-installers (or --installers) to decide without a prompt."
    return 0
  fi
  local f
  printf '\n'
  msg "The install files (GitHub cannot hold these; a release normally carries them):"
  while IFS= read -r f; do
    [[ -n $f ]] || continue
    printf '     %-58s %s\n' "$f" "$(human "$(stat -c%s "$ROOT/$f" 2>/dev/null || echo 0)")"
  done < <(install_files_present | sed '/^$/d')
  printf '     %-58s %s\n' "→ total" "$(human "$bytes")"
  printf '\n'
  local r
  # [o/n] and NOT [Y/n]: a bare "o" is what a French speaker types for NON, and
  # matching ^[oOyY] meant "o" meant OUI. Showing exactly the two letters that
  # are accepted is the only way that prompt cannot be misread.
  read -rp "  Include them ? [o/n] " r
  case "${r:-o}" in
    [oO]) INSTALLERS=1 ;;
    *)    INSTALLERS=0 ;;
  esac
}

# ───────────────────────── Archive type menu ─────────────────────────
type_menu(){
  # Choosing a type answers the question and returns to the main menu on its
  # own; only "back" leaves the choice untouched.
  while true; do
    printf '\n'
    msg "Archive type (current: ${ARCHIVE_TYPE:-release})"
    printf '  The complete archive holds absolutely everything in the working\n'
    printf '  tree — code, untracked files and ignored files; the logs are\n'
    printf '  asked about when it is built.\n'
    printf '  The release archive holds the tracked code plus the install files\n'
    printf '  you choose, without logs, under the 2 GiB GitHub asset ceiling.\n'
    printf '  The source archive holds the tracked code only: no logs and no\n'
    printf '  install files.\n'
    printf '\n'
    printf '    1) complete\n'
    printf '    2) release\n'
    printf '    3) source\n'
    printf '    4) back\n'
    local c
    read -rp "  Choice [1/2/3/4] " c || c=4
    case "${c:-4}" in
      1) ARCHIVE_TYPE=complete; return 0 ;;
      2) ARCHIVE_TYPE=release; return 0 ;;
      3) ARCHIVE_TYPE=source; return 0 ;;
      4) return 0 ;;
      *) warn "Choose 1, 2, 3 or 4." ;;
    esac
  done
}

main_menu(){
  ARCHIVE_TYPE="${ARCHIVE_TYPE:-release}"
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
    || { err "Not a git checkout: $ROOT — the release and source types are built from the tracked files."; exit 1; }
}

size_guard(){
  # size_guard <bytes> <what> — refuse rather than produce an unusable upload.
  if (( $1 > MAX_BYTES )); then
    err "$2 is $(human "$1") — over the $(human "$MAX_BYTES") ceiling (a GitHub release asset)."
    err "  Excluded from the release. Nothing was written."
    exit 1
  fi
}

# ───────────────────────── Listing ─────────────────────────
do_list(){
  preflight
  local type="${ARCHIVE_TYPE:-release}"
  if [[ $type == complete ]]; then
    mapfile -t FILES < <(collect_complete)
    local code
    code="$(cd "$ROOT" && printf '%s\n' "${FILES[@]}" | xargs -d '\n' stat -c%s 2>/dev/null | awk '{s+=$1} END {print s+0}')"
    msg "Complete archive contents ( $PROJECT_NAME/ )"
    printf '  %s files from the working tree\n' "${#FILES[@]}"
    printf '  total                : ~%s\n' "$(human "$code")"
    if (( code > MAX_BYTES )); then
      warn "Over the $(human "$MAX_BYTES") GitHub asset ceiling — fine for a local copy, too big to publish."
    fi
    if (( LIST_ONLY )); then return 0; fi
    hr
    return 0
  fi
  mapfile -t TRACKED < <(collect)
  local f s inst=0 code
  if [[ $type == source ]]; then
    msg "Source archive contents ( $PROJECT_NAME/ )"
  else
    msg "Release archive contents ( $PROJECT_NAME/ )"
  fi
  printf '  %s tracked files from the repo\n' "${#TRACKED[@]}"
  if [[ $type == release ]]; then
    while IFS= read -r f; do
      [[ -n $f ]] || continue
      s="$(stat -c%s "$ROOT/$f" 2>/dev/null || echo 0)"
      inst=$((inst + s))
      printf '     %-58s %s\n' "$f" "$(human "$s")"
    done < <(install_files_present | sed '/^$/d')
  fi
  code="$(cd "$ROOT" && printf '%s\n' "${TRACKED[@]}" | xargs -d '\n' stat -c%s 2>/dev/null | awk '{s+=$1} END {print s+0}')"
  printf '  code only          : ~%s\n' "$(human "$code")"
  if [[ $type == release ]] && (( inst )); then
    printf '  + install files    : ~%s\n' "$(human "$inst")"
    printf '  full release       : ~%s\n' "$(human "$((code + inst))")"
  fi
  if (( LIST_ONLY )); then return 0; fi
  hr
}

# ───────────────────────── Building ─────────────────────────
build(){
  preflight
  local type="${ARCHIVE_TYPE:-release}"
  if [[ $type == complete ]]; then build_complete; return; fi
  mapfile -t TRACKED < <(collect)
  local -a EXTRA=()
  if [[ $type == release ]]; then
    ask_installers
    mapfile -t EXTRA < <(install_files_present | sed '/^$/d')
    ((INSTALLERS)) || EXTRA=()
  elif (( ${INSTALLERS:-0} )); then
    warn "Install files only apply to the release type — ignored for '$type'."
  fi

  msg "$type archive of ' $PROJECT_NAME '"
  msg "  Source : $ROOT @ $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo '?')"
  # The FILE LIST comes from git; the CONTENT comes from the working tree (tar
  # reads the disk). So uncommitted work would silently ship. Say so.
  if [[ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]]; then
    warn "Working tree has uncommitted changes — the archive ships the files ON DISK, not the commit."
    warn "  Commit first if the archive must match $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo 'the commit')."
  fi
  printf '  Content: %s tracked files' "${#TRACKED[@]}"
  if ((${#EXTRA[@]})); then
    printf ' + %s installation file(s) (%s)' "${#EXTRA[@]}" "$(human "$(install_files_bytes)")"
  else
    printf ' — code only, no install file'
  fi
  printf '\n'
  msg "  Excluded: machine state, logs, backups, every non-tracked file"

  mkdir -p "$OUT_DIR"
  local -a tf=(--transform="s|^|${PROJECT_NAME}/|")
  local stamp out tmp suffix=""
  stamp="$(date +%Y-%m-%d)"
  # The suffix is the only thing telling a reader which kind of archive this
  # is BEFORE spending the download on finding out.
  if [[ $type == release ]]; then
    ((INSTALLERS)) && suffix="-installers"
  fi
  out="$OUT_DIR/mosquitomarchy-$type-$stamp$suffix.tar.gz"
  tmp="$out.tmp.$$"
  trap 'rm -f "$tmp"' EXIT

  # RELEASE.md, written into release archives so whoever opens the tarball
  # knows what it is and how to use it without mosquitomarchy. Its "what is
  # inside" table is built from the actual choice: an archive that claims to
  # carry the installers when it does not is worse than no README at all.
  #
  # The rows go to a file, not a string: the markdown is full of backticks and
  # pipes, and building it by concatenation is a quoting minefield.
  local meta rows f
  meta="$(mktemp -d)"
  rows="$meta/.rows"
  local -a meta_args=()
  if [[ $type == release ]]; then
    if ((INSTALLERS)); then
      {
        printf '| Path | What |\n'
        printf '|---|---:|\n'
        while IFS= read -r f; do
          [[ -n $f ]] || continue
          printf '| `%s` | %s |\n' "$f" "$(human "$(stat -c%s "$ROOT/$f" 2>/dev/null || echo 0)")"
        done < <(install_files_present | sed '/^$/d')
      } > "$rows"
    else
      # Blank line either side, so the markdown table below still starts as a table.
      printf '\n_(no install file - this is a code-only release)_\n\n' > "$rows"
    fi

    cat > "$meta/RELEASE.md" <<'MDEOF'
# mosquitOmarchy — release archive

One tarball with the whole project and the installation files that are too big
for GitHub. **It is not a backup of anyone's machine**: it
holds no personal data, no settings and no logs.

## Use it

```bash
tar xzf mosquitomarchy-release-<date>.tar.gz
cd mosquitomarchy

./bootstrap.sh            # full guided setup
./bootstrap.sh --status    # just show what is missing
./mosquitomarchy-setup.sh # the orchestrator itself, if you prefer
```

A full setup is not required: every module also has its own `setup-*.sh` in
`scripts/apps/<app>/`, each documented in its own README.

## What is inside

@@INSTALL_ROWS@@
| everything else | the repository, as committed |

## What is NOT inside, and where to get it

| Missing | Why | Where |
|---|---|---|
| Ableton Live `.zip` | needs an Ableton account, 3-4 GB | <https://www.ableton.com/en/download/> |
| `DaVinci_Resolve_*_Linux.zip` | 10 GB | <https://www.blackmagicdesign.com/support/family/davinci-resolve-and-fusion> |
| `guitar-pro-8-setup.exe` | 988 MB, freely downloadable | <https://downloads.guitar-pro.com/gp8/stable/guitar-pro-8-setup.exe> |

`bootstrap.sh --zips` downloads the missing installers for you, so a release
archive is only needed to avoid the download step.

## Restore your own settings

This archive has nothing to restore. A machine backup is a different, dated
file in `~/omarchy-backups/`, made by the mosquitomarchy TUI
(**Backup**, optionally AES-256 encrypted) and restored with
`./mosquitomarchy-setup.sh --restore`.
MDEOF

    # Substituting the placeholder: the heredoc stays quoted (its markdown has
    # backticks, which bash would execute), so the rows go in afterwards.
    if ! awk -v rows="$rows" '
          BEGIN { while ((getline l < rows) > 0) buf = buf l "\n" }
          /^@@INSTALL_ROWS@@$/ { printf "%s", buf; next }
          { print }
        ' "$meta/RELEASE.md" > "$meta/RELEASE.md.new"; then
      err "Could not render RELEASE.md — nothing was written."
      exit 1
    fi
    mv -f "$meta/RELEASE.md.new" "$meta/RELEASE.md"
    meta_args=(-C "$meta" RELEASE.md)
  fi

  # pigz = parallel gzip (much faster, less memory pressure)
  local -a compress=()
  if command -v pigz >/dev/null 2>&1; then
    compress=("-I" "pigz"); msg "  Compression: pigz (parallel)"
  else
    msg "  Compression: gzip (install pigz to speed it up)"
  fi

  hr; msg "Creating the archive..."
  # ONE tar invocation for everything (tracked files + installation files +
  # RELEASE.md): appending to a finished .tar.gz would mean decompressing and
  # recompressing the whole 500 MB once per addition. -C switches the source
  # directory mid-command, so RELEASE.md comes from the scratch dir while the
  # rest comes from the repo, and --transform puts all of it under one
  # <project>/ folder: extracting by hand then yields a single directory.
  local -a all=("${TRACKED[@]}")
  ((${#EXTRA[@]})) && all+=("${EXTRA[@]}")
  if ! ( cd "$ROOT" && tar cz "${compress[@]}" -f "$tmp" \
      "${tf[@]}" "${meta_args[@]}" -C "$ROOT" -- "${all[@]}" ); then
    err "tar failed — nothing was written."
    exit 1
  fi

  rm -rf "$meta"
  trap - EXIT

  local bytes; bytes="$(stat -c%s "$tmp")"
  if [[ $type == release ]]; then
    size_guard "$bytes" "$out"
  elif (( bytes > MAX_BYTES )); then
    warn "$type archive is $(human "$bytes") — over the $(human "$MAX_BYTES") GitHub ceiling (fine locally, too big to publish)."
  fi
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
    err "Unexpected content found in the archive — file removed, nothing published:"
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
  (( LOGS )) && suffix="-logs"
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
  if (( bytes > MAX_BYTES )); then
    warn "Complete archive is $(human "$bytes") — over the $(human "$MAX_BYTES") GitHub ceiling (fine locally, too big to publish)."
  fi
  mv -f "$tmp" "$out"

  msg "Verifying the archive..."
  local bad f
  bad=""
  while IFS= read -r f; do
    [[ -z $f ]] && continue
    for pat in '*.tar.gz' '*Passwords.kdbx'; do
      if [[ $f == $pat ]] || [[ $f == *"$pat" ]]; then bad+="$f"$'\n'; break; fi
    done
  done < <(tar tzf "$out" 2>/dev/null)
  if [[ -n $bad ]]; then
    err "Unexpected content found in the archive — file removed, nothing published:"
    printf '     %s' "$bad" >&2
    rm -f "$out"
    exit 1
  fi
  ok "verified: no nested archives, no passwords"

  ok "complete archive: $out ($(human "$bytes"), $(tar tzf "$out" 2>/dev/null | wc -l) entries)"
  echo "  Extract by hand:  tar xzf $(basename "$out") && cd $PROJECT_NAME && ./bootstrap.sh"
  hr
}

# ───────────────────────── Dispatch ─────────────────────────
do_list
if (( LIST_ONLY )); then exit 0; fi
# Interactive without an explicit --type (and without -y): the menu. Anything
# scripted (-y, piped stdin, an explicit --type) builds straight away with the
# release defaults, exactly like before.
if [[ -z $ARCHIVE_TYPE ]] && (( ! YES )) && [[ -t 0 ]]; then
  main_menu
fi
ARCHIVE_TYPE="${ARCHIVE_TYPE:-release}"
build
