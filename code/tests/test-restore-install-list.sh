#!/usr/bin/env bash
# Restore must execute every install.list row and report module failures.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME"
export MOSQUITOMARCHY_LIB_ONLY=1
export GUI_RUN_EXEC=1
# shellcheck source=../../mosquitomarchy-setup.sh
source "$ROOT/mosquitomarchy-setup.sh"

LIST="$TMP/install.list"
printf 'apps\tdouze\textracto\tkeepassxc\treaper\tzen\nplugins\ttaskq\n' > "$LIST"
seen=()
category_run(){ seen+=("$1:${CATEGORY_SELECTED[*]}"); }
restore_install_list "$LIST" full
[[ ${seen[0]} == 'apps:douze extracto keepassxc reaper zen' ]]
[[ ${seen[1]} == 'plugins:taskq' ]]
! restore_install_has "$LIST" apps ableton
printf 'apps\tdouze\tableton\n' > "$LIST"
restore_install_has "$LIST" apps ableton

category_run(){ MODULE_FAILURES=1; }
if restore_install_list "$LIST" full; then
  echo 'FAIL: restore ignored a failed module' >&2
  exit 1
fi

mkdir -p "$TMP/archive/plugins"
printf '# plugin folder at backup time: %s/Music/Audio Plugins\n123\t1.0\t%s/Music/Audio Plugins/vst3/example.vst3/file.so\n' \
  "$HOME" "$HOME" > "$TMP/archive/plugins/manifest.txt"
restore_vst_inventory "$TMP/archive" "mosquitomarchy-backup-20261102-013933.tar.gz"
[[ -f $RESTORED_VST_LIST ]]
grep -q 'inventory only' "$RESTORED_VST_LIST"
grep -q 'example.vst3/file.so' "$RESTORED_VST_LIST"

export AUDIOSTACK_VST_ROOT="$TMP/source/Music/Audio Plugins"
mkdir -p "$AUDIOSTACK_VST_ROOT/vst3/example.vst3" "$TMP/full-backup/plugins"
printf 'plugin' > "$AUDIOSTACK_VST_ROOT/vst3/example.vst3/plugin.so"
backup_plugins_inventory "$TMP/full-backup"
grep -q "$AUDIOSTACK_VST_ROOT/vst3/example.vst3/plugin.so" "$TMP/full-backup/plugins/manifest.txt"
echo 'ok: restore replays every package row and reports failures'
