#!/usr/bin/env bash
# bootstrap.sh — One-command bootstrap of mosquitOmarchy.
#
# Downloads (clones) the repo, DEPLOYS the manager (builds the TUI, adds the
# menu entry, the float rule, the post-boot hook) and starts the TUI. The TUI
# is the interface: its Setup screen installs whatever else you want, driving
# the same engine. There is no second, older wizard.
#
# The large installation files (Ableton zips, Guitar Pro installer, Bitwig
# .deb/.jar, DaVinci zip) are NOT part of the repo and are NOT downloaded: they
# sit behind account logins and a multi-GB zip does not belong in a clone. The
# clean technique is to drop every installer you want into ~/Downloads, then
# run the bootstrap: it moves each recognised file into its module folder
# (never overwriting an existing file) and then names which Setup rows stay
# greyed out for the files still missing.
#
# Usage:
#   # Repo already cloned → direct execution:
#   ./bootstrap.sh        # interactive: collect installers, then offer to deploy, then TUI
#   ./bootstrap.sh -y             # no questions: deploy + start the TUI
#   ./bootstrap.sh --zips         # deprecated no-op, kept so old commands keep
#                                 #   working: the collect phase always runs and
#                                 #   has never downloaded anything
#   ./bootstrap.sh --status       # module status without modifying anything
#   ./bootstrap.sh --init-git     # in an EXTRACTED release archive: attach it to
#                                 #   origin/<branch> so the self-update works
#
#   # Repo NOT yet cloned → a single terminal command (repo is public):
#   curl -fsSL https://raw.githubusercontent.com/kepalegars/mosquitOmarchy/master/bootstrap.sh | bash -s -- -y
#
# Security: the script moves files you already downloaded, nothing more;
# it never overwrites an existing installer, and it does nothing unless you
# explicitly ask it to (no silent sudo: each step keeps its own password
# prompts).
set -euo pipefail

# ── Repository settings (overridable — package root is github.com/kepalegars/mosquitOmarchy) ──
REPO_URL="${BOOTSTRAP_REPO_URL:-https://github.com/kepalegars/mosquitOmarchy.git}"
RAW_BOOTSTRAP_URL="${BOOTSTRAP_RAW_URL:-https://raw.githubusercontent.com/kepalegars/mosquitOmarchy/master/bootstrap.sh}"
BRANCH="${BOOTSTRAP_BRANCH:-master}"
INSTALL_DIR="${BOOTSTRAP_INSTALL_DIR:-$HOME/mosquitOmarchy}"

# Options
YES=0 ZIPS=0 STATUS_ONLY=0 INIT_GIT=0
for a in "$@"; do case "$a" in
  -y|--yes) YES=1 ;;
  --zips)   ZIPS=1 ;;
  --status) STATUS_ONLY=1 ;;
  --init-git) INIT_GIT=1 ;;
  --repo=*) REPO_URL="${a#*=}" ;;
  --dir=*)  INSTALL_DIR="${a#*=}" ;;
  -h|--help) sed -n '2,28 p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "Unknown option: $a (supported: -y, --zips, --status, --init-git, --repo=URL, --dir=PATH)" >&2; exit 1 ;;
esac; done

G='\033[1;32m'; B='\033[1;34m'; Y='\033[1;33m'; R='\033[1;31m'; N='\033[0m'
msg(){ printf "${B}==>${N} %s\n" "$*"; }
ok(){ printf " ${G}✓${N} %s\n" "$*"; }
warn(){ printf " ${Y}!${N} %s\n" "$*"; }
err(){ printf " ${R}✗${N} %s\n" "$*" >&2; }
hr(){ printf '%.0s─' {1..72}; echo; }

# ───────────────────────── Repository location ─────────────────────────
# run from a checkout → the repo root (mosquitomarchy-setup.sh) sits NEXT to
# this script, which is the repo root itself; run via `curl | bash` (stdin) →
# it clones. A checkout without the root mosquitomarchy-setup.sh is considered
# incomplete. The `../` branch is kept only so an older checkout, where this
# script still lived in scripts/, keeps working.
# BASH_SOURCE is empty when this script arrives via `curl | bash` (no file on
# disk); with `set -u` the bare ${BASH_SOURCE[0]} then prints an "unbound
# variable" error at the top of the log. Skip detection entirely in that
# case (a piped install always clones) so the log starts clean.
DETECTED_DIR=""
if [[ -n ${BASH_SOURCE[0]:-} ]]; then
  DETECTED_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
fi
SRC=""
if [[ -n "$DETECTED_DIR" ]] && [[ -f "$DETECTED_DIR/mosquitomarchy-setup.sh" ]]; then
  SRC="$DETECTED_DIR"; msg "Repo found locally: $SRC"
elif [[ -n "$DETECTED_DIR" ]] && [[ -f "$DETECTED_DIR/../mosquitomarchy-setup.sh" ]] && [[ -f "$DETECTED_DIR/lib/gui-run.bash" ]]; then
  SRC="$(cd "$DETECTED_DIR/.." && pwd)"; msg "Repo found locally (bootstrap from scripts/): $SRC"
fi
if [[ -z "$SRC" ]]; then
  SRC="$INSTALL_DIR"
  if [[ -d "$SRC/.git" && -f "$SRC/mosquitomarchy-setup.sh" ]]; then
    msg "Repo already cloned: $SRC"
  else
    msg "Cloning $REPO_URL (branch $BRANCH) → $SRC"
    if [[ -d "$SRC" ]]; then warn "The folder $SRC already exists but is not a working checkout — stopping to avoid overwriting anything."; exit 1; fi
    mkdir -p "$(dirname "$SRC")"
    git clone --depth 1 --branch "$BRANCH" -- "$REPO_URL" "$SRC" || { err "Clone failed."; exit 1; }
    ok "Cloned: $SRC"
  fi
  if [[ -f "$SRC/mosquitomarchy-setup.sh" ]]; then ok "mosquitomarchy-setup.sh present"
  else err "Incomplete checkout — mosquitomarchy-setup.sh not found."; exit 1; fi
fi
cd "$SRC"

# ───────────────────────── Make an extracted release a real checkout ─────────────────────────
# A release archive has no .git, so the self-update zone (--update-repo, the
# boot hook) stays inert. --init-git turns the extracted folder into a genuine
# shallow checkout of the branch, after which the tree behaves exactly like a
# clone: updates work, and nothing is downloaded twice.
if ((INIT_GIT)) && [[ ! -d "$SRC/.git" ]]; then
  msg "Attaching this extracted release to $REPO_URL (branch $BRANCH)"
  command -v git >/dev/null 2>&1 || { err "git is required for --init-git."; exit 1; }
  git -C "$SRC" init -q
  git -C "$SRC" remote add origin "$REPO_URL" 2>/dev/null || git -C "$SRC" remote set-url origin "$REPO_URL"
  # --branch is a `git clone` option, not a `git fetch` one: ask for the refspec
  # explicitly, which is also what puts origin/<branch> where the checkout
  # below expects it.
  if ! git -C "$SRC" fetch -q --depth 1 origin "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH"; then
    err "Could not reach the remote — the tree still works, updates just stay off."
    exit 0
  fi
  # Never throw away edits. A freshly extracted tree has no index yet, so
  # `status` is useless here (everything is untracked): compare the FILES with
  # the branch instead. Empty diff = the extraction matches the repo, so
  # resetting is a no-op on content and only creates the checkout.
  # RELEASE.md is written BY the archive, so it has no counterpart in the repo:
  # it is a build artefact, not a local edit. Excluded, or every release would
  # look "modified" the moment it is extracted.
  drift="$(git -C "$SRC" add -A && git -C "$SRC" -c core.excludesFile=/dev/null \
            diff --cached --stat "origin/$BRANCH" -- . ':(exclude)RELEASE.md' 2>/dev/null)"
  if [[ -n $drift ]]; then
    git -C "$SRC" reset -q
    err "$SRC differs from origin/$BRANCH — refusing to overwrite it:"
    printf '     %s\n' "$drift" >&2
    err "  Keep your changes, or re-extract the archive and retry."
    exit 1
  fi
  if git -C "$SRC" -c advice.detachedHead=false checkout -q -B "$BRANCH" "origin/$BRANCH" 2>/dev/null \
     || git -C "$SRC" reset -q --hard "origin/$BRANCH"; then
    ok "Attached to origin/$BRANCH — ./mosquitomarchy-setup.sh --update-repo now works."
  else
    err "Could not check the branch out — the tree still works, updates just stay off."
  fi
fi

# ───────────────────────── Collect the large installers ─────────────────────────
# Clean technique: drop every installer you want into ~/Downloads, then run
# the bootstrap — this moves each recognised file into its module folder.
# An existing file at the destination always wins: the move is skipped, never
# an overwrite. Anything still missing greys its Setup row out; the report at
# the end names exactly those rows.
collect_installers(){
  local dl="$HOME/Downloads"
  if command -v xdg-user-dir >/dev/null 2>&1; then
    dl="$(xdg-user-dir DOWNLOAD 2>/dev/null || echo "$HOME/Downloads")"
  fi
  hr
  msg "Checking $dl for installer files"
  [[ -d "$dl" ]] || { warn "No Downloads folder at $dl — nothing to collect."; return 0; }

  # glob-pattern → destination dir (relative to the repo root, which is $SRC
  # by the time this runs). Mirrors the presence globs the Setup greying uses,
  # so a moved file lights its row back up on the next render.
  local -a map=(
    'Ableton*.zip|scripts/apps/ableton'
    'ableton*.zip|scripts/apps/ableton'
    'install-ableton-*.run|scripts/apps/ableton'
    'guitar-pro-8-setup.exe|scripts/apps/guitarpro'
    'bitwig-studio-*.deb|scripts/apps/bitwig'
    'bitwig.jar|scripts/apps/bitwig/PATCH'
    '*[Rr]esolve*.zip|scripts/apps/davinci'
    '[Dd]a[Vv]inci*.zip|scripts/apps/davinci'
  )
  local moved=0 skipped=0 entry pat dest f base target
  shopt -s nullglob
  for entry in "${map[@]}"; do
    pat="${entry%%|*}"; dest="${entry##*|}"
    mkdir -p "$SRC/$dest"
    for f in "$dl"/$pat; do
      [[ -f $f ]] || continue
      base="$(basename "$f")"; target="$SRC/$dest/$base"
      if [[ -e "$target" ]]; then
        warn "• $base — already in $dest/, move skipped (existing file kept)"
        skipped=$((skipped+1))
      elif mv -- "$f" "$target"; then
        ok "• $base → $dest/"
        moved=$((moved+1))
      else
        warn "• $base — could not move to $dest/ (left in Downloads)"
      fi
    done
  done
  shopt -u nullglob
  (( moved == 0 && skipped == 0 )) && warn "No installer files found in $dl."

  # Which Setup rows stay greyed out for a still-missing installer.
  local -a greyed=()
  compgen -G "$SRC/scripts/apps/ableton/Ableton*.zip" >/dev/null \
    || compgen -G "$SRC/scripts/apps/ableton/ableton*.zip" >/dev/null \
    || greyed+=("ableton")
  compgen -G "$SRC/scripts/apps/bitwig/bitwig*.deb" >/dev/null \
    || greyed+=("bitwig")
  [[ -f "$SRC/scripts/apps/guitarpro/guitar-pro-8-setup.exe" ]] \
    || greyed+=("guitarpro")
  compgen -G "$SRC/scripts/apps/davinci/*[Rr]esolve*.zip" >/dev/null \
    || compgen -G "$SRC/scripts/apps/davinci/[Dd]a[Vv]inci*.zip" >/dev/null \
    || greyed+=("davinci-resolve")
  hr
  if ((${#greyed[@]})); then
    warn "Setup rows staying greyed out (installer still missing): ${greyed[*]}"
    warn "Drop the file in ~/Downloads and re-run bootstrap — it files it away."
  else
    ok "No greyed-out installer rows — every gated module has its file."
  fi
  hr
  return 0
}

# ───────────────────────── Execution ─────────────────────────
if ((STATUS_ONLY)); then
  bash ./mosquitomarchy-setup.sh --status
  exit $?
fi

# Unconditional, and that is the point: the answer to "which of the big
# installers do I still owe this machine" belongs BEFORE the deploy, not as a
# surprise halfway through Setup. Collecting only moves files you already
# downloaded, so it cannot fail the run — a missing multi-GB zip is a fact
# about the machine, not a broken bootstrap, and the modules that want one
# grey themselves out in Setup.
((ZIPS)) && warn "--zips does nothing now (nothing has been downloaded for a while). Kept so existing commands still run."
collect_installers || warn "Could not scan ~/Downloads — continuing; Setup will report per module."


# ───────────────────────── Deploy ─────────────────────────
# Bootstrap's job is to get to a WORKING mosquitOmarchy, not to install every
# app on the machine: deploying the manager builds the TUI and drops the
# dispatcher, the menu entry, the float rule and the post-boot hook, after
# which the TUI's Setup screen drives the very same engine to install whatever
# else is wanted. Handing the machine to a bare terminal wizard instead was
# the thing this replaces.
#
# The deployer is scripts/apps/mosquitomarchy/install-tui.sh — the same script
# the `mosquitomarchy` module runs ("mosquitomarchy-deployer" in the module
# list). It is idempotent, so re-running is free.
TUI="$HOME/.local/bin/mosquitomarchy-tui"
DEPLOYER="scripts/apps/mosquitomarchy/install-tui.sh"

deploy(){
  msg "Deploying mosquitOmarchy — builds the TUI, adds the menu entry, the float rule and the post-boot hook"
  # No go pre-check here on purpose. install-tui.sh's ensure_go installs Go
  # (mise, then pacman) and names both paths if neither works, so a second copy
  # of the check here could only ever be a worse, earlier version of the same
  # error.
  bash "./$DEPLOYER" -y
  # The backups folder lives next to the repo from day one, so Backup and
  # Restore agree on where to look even before the first backup exists.
  mkdir -p "$SRC/mosquitomarchy-backups" 2>/dev/null \
    && ok "Backups folder ready: $SRC/mosquitomarchy-backups" || true
}

# No "already deployed" shortcut: the TUI is rebuilt on EVERY bootstrap run,
# even when a binary is already there. A skipped rebuild is how machines end
# up running a stale manager while the repo moved on.
if ((YES)) || [[ ! -t 0 ]]; then
  deploy || true
else
  hr
  printf 'Deploy mosquitOmarchy now? (builds the TUI, adds the menu entry,\n'
  printf 'the float rule and the post-boot hook) [Y/n] '
  read -r reply || reply=y
  if [[ ${reply:-y} != [nN]* ]]; then
    deploy || true
  else
    warn "Skipped — run ./$DEPLOYER -y whenever you want it."
  fi
fi

# ───────────────────────── Hand over to the TUI ─────────────────────────
# The TUI is the interface; there is no second wizard to fall back to. If it
# cannot be started the bootstrap says so plainly instead of dropping the user
# into an obsolete prompt sequence.
if [[ ! -x $TUI ]]; then
  err "The mosquitOmarchy TUI is not available, so there is nothing to start."
  err "Build it with:  ./$DEPLOYER -y"
  exit 1
fi

msg "Starting the mosquitOmarchy TUI"
if [[ -t 0 && -t 1 ]]; then
  exec "$TUI"
fi
ok "Deployed. Start the TUI with:  $TUI    (or just: mosquitomarchy)"