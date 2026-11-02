#!/usr/bin/env bash
# Bootstrap's TUI deployer installs the GTK askpass when package DBs are empty.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home"
ln -s "$(command -v grep)" "$TMP/bin/grep"
ln -s "$(command -v dirname)" "$TMP/bin/dirname"
ln -s "$(command -v readlink)" "$TMP/bin/readlink"
ln -s "$(command -v wc)" "$TMP/bin/wc"
cat > "$TMP/bin/pacman-conf" <<'SH'
#!/bin/bash
case ${1:-} in
  DBPath) printf '%s\n' "$PACMAN_DB" ;;
  --repo-list) printf 'core\n' ;;
esac
SH
cat > "$TMP/bin/pacman" <<'SH'
#!/bin/bash
exit 1
SH
cat > "$TMP/bin/pkexec" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$PACMAN_LOG"
printf '#!/bin/sh\nexit 0\n' > "$ZENITY_FAKE"
/bin/chmod +x "$ZENITY_FAKE"
SH
chmod +x "$TMP/bin/pacman-conf" "$TMP/bin/pacman" "$TMP/bin/pkexec"

(
  export HOME="$TMP/home" XDG_BIN_HOME="$TMP/bin" GUI_RUN_EXEC=1
  export PACMAN_DB="$TMP/pacman" PACMAN_LOG="$TMP/pacman.log" ZENITY_FAKE="$TMP/bin/zenity"
  export PATH="$TMP/bin"
  set --
  # shellcheck source=../main tui/install-tui.sh
  source "$ROOT/code/main tui/install-tui.sh"
  ensure_zenity
  [[ -x $ZENITY_FAKE ]]
  grep -q -- 'pacman -Sy --needed --noconfirm zenity' "$PACMAN_LOG"
  before="$(wc -l < "$PACMAN_LOG")"
  ensure_zenity
  [[ $(wc -l < "$PACMAN_LOG") == "$before" ]]
)
echo 'ok: install-tui installs zenity once and syncs empty package databases'
