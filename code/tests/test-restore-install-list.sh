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

PACMAN_TEST_DB="$TMP/pacman"
pacman-conf(){
  case ${1:-} in
    DBPath) printf '%s\n' "$PACMAN_TEST_DB" ;;
    --repo-list) printf 'core\nextra\n' ;;
  esac
}
pacman(){ :; }
sync_calls=0
sync_fails=0
mq_sudo(){
  sync_calls=$((sync_calls + 1))
  ((sync_fails == 0)) || return 1
  mkdir -p "$PACMAN_TEST_DB/sync"
  touch "$PACMAN_TEST_DB/sync/core.db" "$PACMAN_TEST_DB/sync/extra.db"
}
if ! restore_sync_pacman_databases; then
  echo 'FAIL: restore did not initialize missing pacman databases' >&2
  exit 1
fi
restore_sync_pacman_databases
[[ $sync_calls == 1 ]]
rm -f "$PACMAN_TEST_DB/sync/extra.db"
sync_fails=1
if restore_sync_pacman_databases; then
  echo 'FAIL: restore ignored a failed pacman database sync' >&2
  exit 1
fi

package_sync_calls=0
restore_sync_pacman_databases(){ package_sync_calls=$((package_sync_calls + 1)); }

LIST="$TMP/install.list"
printf 'apps\tdouze\textracto\tkeepassxc\treaper\tzen\nplugins\ttaskq\n' > "$LIST"
seen=()
category_run(){ seen+=("$1:${CATEGORY_SELECTED[*]}"); }
restore_install_list "$LIST" full
[[ ${seen[0]} == 'apps:douze extracto keepassxc reaper zen' ]]
[[ ${seen[1]} == 'plugins:taskq' ]]
[[ $package_sync_calls == 1 ]]
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

mkdir -p "$TMP/restore-input"
printf 'apps\tdouze\napps\textracto\n' > "$TMP/restore-input/install.list"
tar -czf "$TMP/restore.tar.gz" -C "$TMP/restore-input" install.list
sudo_primes=0 module_runs=0
mq_sudo_prime(){
  [[ -n ${MQ_SUDO_PRIMED:-} ]] && return 0
  sudo_primes=$((sudo_primes + 1))
  export MQ_SUDO_PRIMED=1
}
restore_sync_pacman_databases(){ mq_sudo_prime; }
category_run(){ mq_sudo_prime; module_runs=$((module_runs + 1)); }
YES=1 RESTORE_DEPLOY_HYPRLAND=no RESTORE_DEPLOY_VST=no RESTORE_DEPLOY_REAPER=no \
  RESTORE_DEPLOY_ZEN=no RESTORE_DEPLOY_KEEPASS=no RESTORE_DEPLOY_KEEPASS_SETTINGS=no \
  RESTORE_DEPLOY_THEMES=no RESTORE_DEPLOY_OMARCHY_PLUGINS=no RESTORE_KEYBINDINGS=none \
  restore_backup "$TMP/restore.tar.gz"
[[ $sudo_primes == 1 && $module_runs == 2 ]]
echo 'ok: restore replays every package row and reports failures'
