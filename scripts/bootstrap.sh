#!/usr/bin/env bash
# bootstrap.sh — One-command bootstrap of mosquitOmarchy.
#
# Downloads (clones) the repo, then runs the mosquitomarchy-setup.sh entry point
# with the requested options. The large installation files (Ableton zips,
# Guitar Pro installer, Bitwig .deb/.jar) are NOT part of the repo: they are
# downloaded on demand via scripts/apps/download-assets.sh (assets.links
# catalog), optionally, to keep the clone lightweight.
#
# Usage:
#   # Repo already cloned → direct execution:
#   ./bootstrap.sh        # interactive: setup then, if requested, assets
#   ./bootstrap.sh -y             # everything default (auto setup)
#   ./bootstrap.sh --zips -y      # auto setup + downloads the assets (zips/exe/deb)
#   ./bootstrap.sh --status       # module status without modifying anything
#
#   # Repo NOT yet cloned → a single terminal command (repo is public):
#   curl -fsSL https://raw.githubusercontent.com/kepalegars/mosquitOmarchy/master/scripts/bootstrap.sh | bash -s -- --zips -y
#
# Security: asset downloads are verified by sha256 (assets.links);
# the script does nothing unless you explicitly ask it to (no silent sudo:
# each step keeps its own password prompts).
set -euo pipefail

# ── Repository settings (overridable — package root is github.com/kepalegars/mosquitOmarchy) ──
REPO_URL="${BOOTSTRAP_REPO_URL:-https://github.com/kepalegars/mosquitOmarchy.git}"
RAW_BOOTSTRAP_URL="${BOOTSTRAP_RAW_URL:-https://raw.githubusercontent.com/kepalegars/mosquitOmarchy/master/scripts/bootstrap.sh}"
BRANCH="${BOOTSTRAP_BRANCH:-master}"
INSTALL_DIR="${BOOTSTRAP_INSTALL_DIR:-$HOME/mosquitOmarchy}"

# Options
YES=0 ZIPS=0 STATUS_ONLY=0
for a in "$@"; do case "$a" in
  -y|--yes) YES=1 ;;
  --zips)   ZIPS=1 ;;
  --status) STATUS_ONLY=1 ;;
  --repo=*) REPO_URL="${a#*=}" ;;
  --dir=*)  INSTALL_DIR="${a#*=}" ;;
  -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
  *) echo "Unknown option: $a (supported: -y, --zips, --status, --repo=URL, --dir=PATH)" >&2; exit 1 ;;
esac; done

G='\033[1;32m'; B='\033[1;34m'; Y='\033[1;33m'; R='\033[1;31m'; N='\033[0m'
msg(){ printf "${B}==>${N} %s\n" "$*"; }
ok(){ printf " ${G}✓${N} %s\n" "$*"; }
warn(){ printf " ${Y}!${N} %s\n" "$*"; }
err(){ printf " ${R}✗${N} %s\n" "$*" >&2; }
hr(){ printf '%.0s─' {1..72}; echo; }

# ───────────────────────── Repository location ─────────────────────────
# run from a checkout → the repo root (mosquitomarchy-setup.sh) is found either
# in the script folder itself or one level up (bootstrap.sh lives in scripts/);
# run via `curl | bash` (stdin) → it clones. A checkout without the root
# mosquitomarchy-setup.sh is considered incomplete.
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

# ───────────────────────── Execution ─────────────────────────
if ((STATUS_ONLY)); then
  bash ./mosquitomarchy-setup.sh --status
  exit $?
fi

if ((ZIPS)); then
  msg "Downloading assets (assets.links catalog)"
  bash ./scripts/apps/download-assets.sh $([[ $YES == 1 ]] && echo -y)
else
  warn "Assets (zips/exe/deb) NOT downloaded — run ./scripts/apps/download-assets.sh later if needed."
fi

msg "Running the mosquitomarchy-setup.sh entry point"
bash ./mosquitomarchy-setup.sh $([[ $YES == 1 ]] && echo -y)