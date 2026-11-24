#!/usr/bin/env bash
# Self-check for fix-quickshell-bar.sh. Uses a throwaway HOME, a fake
# `omarchy`/`omarchy-shell` and a synthetic backup archive, so it never
# touches the real bar. Run from anywhere:
#   ./test-fix-quickshell-bar.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIX="$HERE/fix-quickshell-bar.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok: %s\n' "$*"; }

export HOME="$TMP/home"
BACKUPS="$TMP/backups"
BIN="$TMP/bin"
mkdir -p "$HOME/.config/omarchy/plugins/test.live" "$BACKUPS" "$BIN" "$TMP/arc/.config/omarchy"

# This machine "has" test.live; dead.plugin is from another machine.
printf '{"id":"test.live"}' > "$HOME/.config/omarchy/plugins/test.live/manifest.json"

# Backup: one live widget, one plugin this machine does not have.
printf '%s' '{"bar":{"layout":{"left":[{"id":"test.live"}],"center":[{"id":"dead.plugin"}]}}}' \
  > "$TMP/arc/.config/omarchy/shell.json"
tar czf "$TMP/arc/config-backup.tar.gz" -C "$TMP/arc" .config/omarchy/shell.json
tar czf "$BACKUPS/mosquitomarchy-backup-20260101-000000-test.tar.gz" -C "$TMP/arc" config-backup.tar.gz

printf '#!/bin/sh\nexit 0\n' > "$BIN/omarchy"
printf '#!/bin/sh\nexit 0\n' > "$BIN/omarchy-shell"
chmod +x "$BIN/omarchy" "$BIN/omarchy-shell"
export PATH="$BIN:$PATH" OMARCHY_BACKUP_DIR="$BACKUPS"

# 1. Broken (missing) bar -> restored from the archive, dead widget dropped.
"$FIX" >/dev/null 2>&1 || fail "restore exited non-zero"
SHELL_JSON="$HOME/.config/omarchy/shell.json"
jq -e '(.bar.layout.left | map(.id)) == ["test.live"]' "$SHELL_JSON" >/dev/null \
  || fail "restored layout lost test.live"
jq -e '(.bar.layout.center // []) == []' "$SHELL_JSON" >/dev/null \
  || fail "dead.plugin was not dropped"
pass "restores the archive and drops widgets this machine lacks"

# 2. Healthy bar -> nothing overwritten.
before="$(md5sum "$SHELL_JSON")"
out="$("$FIX" 2>&1)" || fail "healthy check exited non-zero"
[[ $out == *"nothing restored"* ]] || fail "healthy bar was not reported as healthy"
[[ "$(md5sum "$SHELL_JSON")" == "$before" ]] || fail "healthy shell.json was rewritten"
pass "a healthy bar is left alone"

# 3. --force -> restores anyway.
"$FIX" --force >/dev/null 2>&1 || fail "--force exited non-zero"
ls "$HOME"/.config/omarchy/shell.json.broken.* >/dev/null 2>&1 \
  || fail "--force did not keep the previous file"
pass "--force restores and keeps the previous file as .broken.<ts>"

printf 'all fix-quickshell-bar checks passed\n'
