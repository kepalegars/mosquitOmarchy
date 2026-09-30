#!/usr/bin/env bash
# archive-mosquitomarchy.sh — build the RELEASE archive of the mosquitOmarchy repo.
#
# WHAT THIS PRODUCES
#   One tar.gz, `mosquitomarchy-release-<YYYY-MM-DD>.tar.gz`, holding the repo
#   under its own `mosquitomarchy/` folder plus the installation files that
#   cannot live on GitHub. It is meant to be taken by hand:
#
#       tar xzf mosquitomarchy-release-<date>.tar.gz
#       cd mosquitomarchy
#       ./bootstrap.sh              # or ./mosquitomarchy-setup.sh
#
#   No mosquitomarchy code is involved in the extraction, and nothing in the
#   archive is a backup: a restore is done by the user, with tar.
#
# IT IS A RELEASE, NOT A BACKUP
#   Everything personal is out, silently and by construction:
#
#     * the PATCH/ folders        — private extras (licence workarounds, the
#                                   Guitar Pro patch, …), never published
#     * ~/omarchy-backups/*       — the dated config backups, encrypted or not
#     * *.log, last_crash.log, .local/  — run logs and machine state
#     * any non-tracked file      — see "Built from git" below
#
#   There is no interactive question about any of this: the archive is the
#   release, so the release's rules apply, without asking.
#
# BUILT FROM GIT, NOT FROM THE WORKING TREE
#   The file list is `git ls-files`, not a `tar --exclude=` guess list. Two
#   consequences, both wanted:
#     * an ignored or leftover local file cannot leak in by being un-listed
#       (this machine alone holds a 130 MB extracted Fusion bundle and the
#       compiled TUI leftovers — none of it is tracked, none of it goes out);
#     * the archive is reproducible: the same commit gives the same content.
#   Only the installation files below are added on top, since they are the
#   whole point of a release and are deliberately not on GitHub.
#
# SIZE
#   GitHub accepts a release asset up to 2 GiB (and a file in the REPOSITORY
#   only up to 100 MB — which is why the installers live in a release and not
#   in git). The build refuses to produce an archive above the release limit
#   instead of leaving an upload that GitHub will reject.
#
# Usage:
#   ./archive-mosquitomarchy.sh              # build the release archive
#   ./archive-mosquitomarchy.sh --list       # what would go in (and its size)
#   ./archive-mosquitomarchy.sh --out=DIR    # write DIR/ instead of the repo root
#   ./archive-mosquitomarchy.sh -y           # accepted, nothing is interactive
#   ./archive-mosquitomarchy.sh -h
#
# Env:
#   OMARCHY_ARCHIVE_OUT   default output directory (default: the repo root)
#   OMARCHY_ARCHIVE_MAX   size ceiling in bytes (default: 2 GiB)
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
OUT_DIR="${OMARCHY_ARCHIVE_OUT:-$ROOT}"
# GitHub release asset limit: 2 GiB.
MAX_BYTES="${OMARCHY_ARCHIVE_MAX:-2147483648}"

G='\033[1;32m'; B='\033[1;34m'; Y='\033[1;33m'; R='\033[1;31m'; N='\033[0m'
msg(){ printf "${B}==>${N} %s\n" "$*"; }
ok(){ printf " ${G}✓${N} %s\n" "$*"; }
warn(){ printf " ${Y}!${N} %s\n" "$*"; }
err(){ printf " ${R}✗${N} %s\n" "$*" >&2; }
hr(){ printf '%.0s─' {1..72}; echo; }

LIST_ONLY=0
for a in "$@"; do case "$a" in
  -y|--yes) ;;                      # nothing is interactive: accepted for the
                                    # callers that pass it unconditionally
  --list|--dry-run) LIST_ONLY=1 ;;
  --out=*) OUT_DIR="${a#*=}" ;;
  -h|--help) sed -n '2,52p' "$0"; exit 0 ;;
  *) err "Unknown option: $a (see -h)"; exit 1 ;;
esac; done

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

# ───────────────────────── Collecting the file list ─────────────────────────
collect(){
  # Prints, one per line, the repo-relative paths that go into the archive:
  # every tracked file, minus the ones git tracks but a release must not ship.
  git -C "$ROOT" ls-files -z \
    | tr '\0' '\n' \
    | grep -v -E '(^|/)PATCH/' \
    | grep -v -E '(^|/)\.local/' \
    | grep -v -E '(^|/)last_crash\.log$' \
    | grep -v -E '\.log$'
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

preflight(){
  cd "$ROOT" || { err "Not a directory: $ROOT"; exit 1; }
  git rev-parse --git-dir >/dev/null 2>&1 \
    || { err "Not a git checkout: $ROOT — the release is built from the tracked files."; exit 1; }
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
  mapfile -t TRACKED < <(collect)
  mapfile -t EXTRA < <(install_files_present | sed '/^$/d')
  local total=0 f
  msg "Release archive contents ( $PROJECT_NAME/ )"
  printf '  %s tracked files from the repo\n' "${#TRACKED[@]}"
  if ((${#EXTRA[@]})); then
    for f in "${EXTRA[@]}"; do
      local s; s="$(stat -c%s "$ROOT/$f" 2>/dev/null || echo 0)"
      total=$((total + s))
      printf '  + %s (%s)\n' "$f" "$(human "$s")"
      size_guard "$s" "$f"
    done
  fi
  local code; code="$(cd "$ROOT" && printf '%s\n' "${TRACKED[@]}" | xargs -d '\n' stat -c%s 2>/dev/null | awk '{s+=$1} END {print s+0}')"
  total=$((total + code))
  printf '  = ~%s before compression\n' "$(human "$total")"
  printf '  PATCH/ folders, .local/, *.log, backups: excluded (not tracked / never listed)\n'
  if (( LIST_ONLY )); then return 0; fi
  hr
}

# ───────────────────────── Building ─────────────────────────
build(){
  preflight
  mapfile -t TRACKED < <(collect)
  mapfile -t EXTRA < <(install_files_present | sed '/^$/d')

  msg "Release archive of ' $PROJECT_NAME '"
  msg "  Source : $ROOT @ $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo '?')"
  # The FILE LIST comes from git; the CONTENT comes from the working tree (tar
  # reads the disk). So uncommitted work would silently ship. Say so.
  if [[ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]]; then
    warn "Working tree has uncommitted changes — the archive ships the files ON DISK, not the commit."
    warn "  Commit first if the release must match $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo 'the commit')."
  fi
  printf '  Content: %s tracked files' "${#TRACKED[@]}"
  ((${#EXTRA[@]})) && printf ' + %s installation file(s)' "${#EXTRA[@]}"
  printf '\n'
  msg "  Excluded: PATCH/ · .local/ · *.log · backups · every non-tracked file"

  mkdir -p "$OUT_DIR"
  local -a tf=(--transform="s|^|${PROJECT_NAME}/|")
  local stamp out tmp
  stamp="$(date +%Y-%m-%d)"
  out="$OUT_DIR/mosquitomarchy-release-$stamp.tar.gz"
  tmp="$out.tmp.$$"
  trap 'rm -f "$tmp"' EXIT

  # RELEASE.md, written into the archive so whoever opens the tarball knows
  # what it is and how to use it without mosquitomarchy.
  local meta; meta="$(mktemp -d)"
  cat > "$meta/RELEASE.md" <<'MDEOF'
# mosquitOmarchy — release archive

One tarball with the whole project and the installation files that are too big
(or too private) for GitHub. **It is not a backup of anyone's machine**: it
holds no personal data, no settings, no logs, no licence workarounds.

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

| Path | What |
|---|---|
| `scripts/apps/ableton/install-ableton-latest.run` | the Ableton installer (113 MB) |
| `scripts/apps/bitwig/bitwig-studio-*.deb` | the Bitwig build the module pins (348 MB) |
| everything else | the repository, as committed |

## What is NOT inside, and where to get it

| Missing | Why | Where |
|---|---|---|
| `scripts/apps/*/PATCH/` | private extras (licence workarounds, the Guitar Pro patch) | kept out of every release, on purpose |
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
      "${tf[@]}" -C "$meta" RELEASE.md -C "$ROOT" -- "${all[@]}" ); then
    err "tar failed — nothing was written."
    exit 1
  fi
  rm -rf "$meta"
  trap - EXIT

  local bytes; bytes="$(stat -c%s "$tmp")"
  size_guard "$bytes" "$out"
  mv -f "$tmp" "$out"

  # Final gate: verify what was actually written, not what we intended.
  msg "Verifying the archive carries nothing personal..."
  local bad f
  bad=""
  while IFS= read -r f; do
    [[ -z $f ]] && continue
    for pat in "${FORBIDDEN_PATTERNS[@]}"; do
      if [[ $f == $pat ]] || [[ $f == *"$pat" ]]; then bad+="$f"$'\n'; break; fi
    done
  done < <(tar tzf "$out" 2>/dev/null)
  if [[ -n $bad ]]; then
    err "Personal content found in the archive — file removed, nothing published:"
    printf '     %s' "$bad" >&2
    rm -f "$out"
    exit 1
  fi
  ok "verified: no PATCH, no logs, no backups, no passwords, no personal files"

  ok "Release archive: $out ($(human "$bytes"), $(tar tzf "$out" 2>/dev/null | wc -l) entries)"
  echo "  Extract by hand:  tar xzf $(basename "$out") && cd $PROJECT_NAME && ./bootstrap.sh"
  hr
}

do_list
(( LIST_ONLY )) && exit 0
build
