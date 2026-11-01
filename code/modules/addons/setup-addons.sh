#!/usr/bin/env bash
# setup-addons — install the lightweight mosquitOmarchy addons.
#
# An addon is a folder with two files:
#
#   addon.conf   NAME="..."  DESCRIPTION="..."  ENABLED="yes"
#   install.sh   idempotent installer; receives MQ_REPO, MQ_ADDON_DIR,
#                MQ_ADDON_NAME in its environment
#
# That is the whole format. There is no plugin API to learn: an addon is a
# shell script that does one small thing and can be re-run safely. Addons are
# found in the repo (code/modules/addons/) and in the user's own
# ~/.config/mosquitomarchy/addons/ (same format, never committed).
#
# Installed names are recorded so an update can re-apply exactly the addons
# that were present before it, at the end of the update.
#
# Usage:
#   setup-addons.sh              # install every enabled addon (bootstrap)
#   setup-addons.sh --reinstall  # re-apply the recorded addons (update)
#   setup-addons.sh --list       # name<TAB>folder
#   setup-addons.sh --status     # what is recorded / available
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/../../.." && pwd)"
REPO_ADDONS="$SELF_DIR"
USER_ADDONS="${XDG_CONFIG_HOME:-$HOME/.config}/mosquitomarchy/addons"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/mosquitomarchy"
STATE_FILE="$STATE_DIR/addons-installed"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m !\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m ✗\033[0m %s\n' "$*" >&2; }

MODE="--all"
case "${1:-}" in
  --all|"")    MODE="--all" ;;
  --reinstall) MODE="--reinstall" ;;
  --list)      MODE="--list" ;;
  --status)    MODE="--status" ;;
  -h|--help)   sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) err "Unknown option: $1 (supported: --all --reinstall --list --status)"; exit 1 ;;
esac

# Print "name<TAB>folder<TAB>description" for every addon folder on disk.
addon_rows() {
  local dir d name desc enabled
  # User first: a same-named custom addon overrides the shipped one.
  for dir in "$USER_ADDONS" "$REPO_ADDONS"; do
    [[ -d $dir ]] || continue
    for d in "$dir"/*/; do
      [[ -d $d ]] || continue
      [[ -f "$d/addon.conf" && -f "$d/install.sh" ]] || continue
      # shellcheck disable=SC1090
      IFS=$'\t' read -r name desc enabled < <(
        bash -c 'source "$1" 2>/dev/null; printf "%s\t%s\t%s\n" "${NAME:-}" "${DESCRIPTION:-}" "${ENABLED:-yes}"' _ "$d/addon.conf"
      )
      [[ -n $name ]] || continue
      [[ $enabled == no ]] && continue
      printf '%s\t%s\t%s\n' "$name" "${d%/}" "$desc"
    done
  done
}

# A user addon with the same NAME as a repo addon wins (custom override).
dedup_rows() {
  local name folder desc
  declare -A seen=()
  while IFS=$'\t' read -r name folder desc; do
    [[ -n $name ]] || continue
    [[ -n ${seen[$name]:-} ]] && continue
    seen["$name"]="$folder"
    printf '%s\t%s\t%s\n' "$name" "$folder" "$desc"
  done
}

record_installed() {
  local name="$1"
  mkdir -p "$STATE_DIR"
  touch "$STATE_FILE"
  grep -Fxq -- "$name" "$STATE_FILE" || printf '%s\n' "$name" >> "$STATE_FILE"
}

prune_state() {
  # Keep only names that still exist on disk, so a removed addon does not
  # linger forever in the reinstall list.
  local name folder desc available="$STATE_DIR/.addons-available"
  addon_rows | dedup_rows | cut -f1 | sort -u > "$available"
  if [[ -f $STATE_FILE ]]; then
    while IFS= read -r name; do
      [[ -n $name ]] || continue
      grep -Fxq -- "$name" "$available" && printf '%s\n' "$name"
    done < "$STATE_FILE" | sort -u > "$STATE_FILE.tmp"
    mv -f "$STATE_FILE.tmp" "$STATE_FILE"
  fi
  rm -f "$available"
}

run_addon() {
  local name="$1" folder="$2"
  info "Addon: $name"
  if MQ_REPO="$REPO" MQ_ADDON_DIR="$folder" MQ_ADDON_NAME="$name" \
       bash "$folder/install.sh"; then
    record_installed "$name"
    ok "$name installed"
    return 0
  fi
  err "$name failed"
  return 1
}

rows="$(addon_rows | dedup_rows)"
if [[ -z $rows ]]; then
  info "No addons found in $REPO_ADDONS or $USER_ADDONS."
  exit 0
fi

case "$MODE" in
  --list)
    printf '%s\n' "$rows" | cut -f1,2
    exit 0
    ;;
  --status)
    info "Addons available"
    printf '%s\n' "$rows" | while IFS=$'\t' read -r name folder desc; do
      if [[ -f $STATE_FILE ]] && grep -Fxq -- "$name" "$STATE_FILE"; then
        printf '  ✓ %-16s %s\n' "$name" "$desc"
      else
        printf '  · %-16s %s\n' "$name" "$desc"
      fi
    done
    exit 0
    ;;
esac

want=""
if [[ $MODE == --reinstall ]]; then
  want="$(cat "$STATE_FILE" 2>/dev/null || true)"
  [[ -n $want ]] || { info "No addon was installed before this update."; exit 0; }
fi

failed=0
while IFS=$'\t' read -r name folder desc; do
  [[ -n $name ]] || continue
  if [[ $MODE == --reinstall ]] && ! grep -Fxq -- "$name" <<<"$want"; then
    continue
  fi
  run_addon "$name" "$folder" || failed=1
done <<<"$rows"

prune_state
if ((failed)); then
  err "One or more addons failed; the others were kept."
  exit 1
fi
ok "Addons ready."
