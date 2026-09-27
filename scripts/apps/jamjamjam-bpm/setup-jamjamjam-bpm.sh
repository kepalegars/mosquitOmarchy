#!/usr/bin/env bash
# Install or remove jamjamjam-bpm.
#
#   ./setup-jamjamjam-bpm.sh            link into ~/.local/bin
#   ./setup-jamjamjam-bpm.sh remove     unlink
set -euo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SELF")" && pwd)"
BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
TARGET="$BIN_DIR/jamjamjam-bpm"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'missing dependency: %s\n' "$1" >&2
    return 1
  fi
}

if [[ "${1:-}" == "remove" ]]; then
  rm -f "$TARGET"
  printf 'removed %s\n' "$TARGET"
  exit 0
fi

status=0
for tool in python3 ffmpeg pactl pw-cat; do
  need "$tool" || status=1
done
if ! python3 -c 'import numpy' 2>/dev/null; then
  printf 'missing dependency: numpy  (pip install --user numpy)\n' >&2
  status=1
fi
if (( status )); then
  printf '\ninstall the missing pieces and re-run.\n' >&2
  exit 1
fi

mkdir -p "$BIN_DIR"
ln -sf "$SCRIPT_DIR/jamjamjam-bpm" "$TARGET"
printf 'linked %s -> %s\n' "$TARGET" "$SCRIPT_DIR/jamjamjam-bpm"
"$TARGET" doctor
