#!/usr/bin/env bash
# A missing upstream Ableton .run is detectable by the Update flow without
# touching the network or installing the Live edition zip.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" MOSQUITOMARCHY_LIB_ONLY=1 GUI_RUN_EXEC=1
mkdir -p "$HOME" "$TMP/ableton"
source "$ROOT/mosquitomarchy-setup.sh"
ABLETON_DIR="$TMP/ableton"

if ableton_installer_present "$ABLETON_DIR"; then
  echo 'FAIL: empty Ableton module directory reports an installer present' >&2
  exit 1
fi
touch "$ABLETON_DIR/install-ableton-latest.run"
ableton_installer_present "$ABLETON_DIR"

grep -q 'ableton_installer_present "$APPS_DIR/ableton"' "$ROOT/code/main tui/mosquitomarchy-actions"
grep -q 'setup-ableton.sh" -y --check-update' "$ROOT/mosquitomarchy-setup.sh"
export MOSQUITOMARCHY_UPDATE=1
YES=1
bash(){ printf '%s\n' "$*" >> "$TMP/ableton-command"; }
rm -f "$ABLETON_DIR/install-ableton-latest.run"
run_ableton
grep -qF "$ABLETON_DIR/setup-ableton.sh -y --check-update" "$TMP/ableton-command"
# Update must ONLY download: no full install run after the download.
[[ $(wc -l < "$TMP/ableton-command") -eq 1 ]]

# A restore/install with no .run downloads it first, THEN runs the module.
: > "$TMP/ableton-command"
unset MOSQUITOMARCHY_UPDATE
run_ableton
grep -qF "$ABLETON_DIR/setup-ableton.sh -y --check-update" "$TMP/ableton-command"
grep -qF "$ABLETON_DIR/setup-ableton.sh -y" "$TMP/ableton-command"
[[ $(grep -n -- "$ABLETON_DIR/setup-ableton.sh -y --check-update" "$TMP/ableton-command" | cut -d: -f1) \
   -lt $(grep -n -- "$ABLETON_DIR/setup-ableton.sh -y$" "$TMP/ableton-command" | cut -d: -f1) ]]

echo 'ok: Update only downloads the Ableton installer; restore downloads it first, then installs'
