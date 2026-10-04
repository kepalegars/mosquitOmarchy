#!/usr/bin/env bash
# bootstrap.sh — One-command bootstrap of mosquitOmarchy.
#
# Downloads (clones) the repo, DEPLOYS the manager (builds the TUI, adds the
# menu entry, the float rule, the post-boot hook) and starts the TUI. The TUI
# is the interface: its Setup screen installs whatever else you want, driving
# the same engine. There is no second, older wizard.
#
# The large installation files (Ableton zips, Guitar Pro installer, Bitwig
# .deb/.jar) are NOT part of the repo: they are downloaded on demand via
# scripts/apps/download-assets.sh (assets.links catalog), optionally, to keep
# the clone lightweight.
#
# Usage:
#   # Repo already cloned → direct execution:
#   ./bootstrap.sh        # interactive: assets, then offer to deploy, then TUI
#   ./bootstrap.sh -y             # no questions: deploy + start the TUI
#   ./bootstrap.sh --zips -y      # same + downloads the assets (zips/exe/deb)
#   ./bootstrap.sh --status       # module status without modifying anything
#   ./bootstrap.sh --init-git     # in an EXTRACTED release archive: attach it to
#                                 #   origin/<branch> so the self-update works
#
#   # Repo NOT yet cloned → a single terminal command (repo is public):
#   curl -fsSL https://raw.githubusercontent.com/kepalegars/mosquitOmarchy/master/bootstrap.sh | bash -s -- --zips -y
#
# Security: asset downloads are verified by sha256 (assets.links);
# the script does nothing unless you explicitly ask it to (no silent sudo:
# each step keeps its own password prompts).
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
DETECTED_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
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

# ───────────────────────── Execution ─────────────────────────
if ((STATUS_ONLY)); then
  bash ./mosquitomarchy-setup.sh --status
  exit $?
fi

if ((ZIPS)); then
  msg "Downloading assets (assets.links catalog)"
  # download-assets.sh refuses the catalog while it still carries the
  # TON_HEBERGEUR placeholder and says exactly what to set. Its non-zero exit is
  # the answer here, not a crash: the bootstrap carries on to deploy the manager
  # either way, since only the big installers are blocked.
  bash ./scripts/apps/download-assets.sh $([[ $YES == 1 ]] && echo -y) \
    || warn "Assets were not downloaded — see the message above."
else
  warn "Assets (zips/exe/deb) NOT downloaded — run ./scripts/apps/download-assets.sh later if needed."
fi

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
  # Checked up front so the failure names the real cause. install-tui.sh would
  # otherwise report "Go is not installed" from inside its own ensure_go, which
  # reads like a broken script rather than a missing dependency.
  if ! command -v go >/dev/null 2>&1; then
    err "Go is required to build the TUI, and it is not installed."
    err "  Arch:   sudo pacman -S go"
    err "  mise:   mise use go@latest"
    return 1
  fi
  bash "./$DEPLOYER" -y
}

if [[ -x $TUI ]]; then
  ok "mosquitOmarchy is already deployed ($TUI) — nothing to deploy."
elif ((YES)) || [[ ! -t 0 ]]; then
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
ok "Deployed. Start the TUI with:  $TUI    (or: omarchy-launch-tui mosquito)"