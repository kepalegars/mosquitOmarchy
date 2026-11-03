#!/usr/bin/env bash
# Restore must execute every install.list row and report module failures.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME" "$TMP/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/keepassxc"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/hyprctl"
chmod +x "$TMP/bin/keepassxc" "$TMP/bin/hyprctl"
export PATH="$TMP/bin:$PATH"
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
printf '# plugin folder at backup time: %s/Music/Audio Plugins\n123\t1.0\t%s/Music/Audio Plugins/vst3/Vendor/Example.vst3/Contents/x86_64/Example.vst3\n' \
  "$HOME" "$HOME" > "$TMP/archive/plugins/manifest.txt"
restore_vst_inventory "$TMP/archive" "mosquitomarchy-backup-20261102-013933.tar.gz"
[[ -f $RESTORED_VST_LIST ]]
grep -qi 'inventory only' "$RESTORED_VST_LIST"
grep -q '^## Vendor$' "$RESTORED_VST_LIST"
grep -q 'Example — VST3' "$RESTORED_VST_LIST"
! grep -q 'bytes' "$RESTORED_VST_LIST"

export AUDIOSTACK_VST_ROOT="$TMP/source/Music/Audio Plugins"
mkdir -p "$AUDIOSTACK_VST_ROOT/vst3/example.vst3" "$TMP/full-backup/plugins"
printf 'plugin' > "$AUDIOSTACK_VST_ROOT/vst3/example.vst3/plugin.so"
backup_plugins_inventory "$TMP/full-backup"
grep -q "$AUDIOSTACK_VST_ROOT/vst3/example.vst3/plugin.so" "$TMP/full-backup/plugins/manifest.txt"

mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/mosquito-audio-plugin-manager-actions" <<'FAKE_APM'
#!/usr/bin/env bash
case ${1:-} in
  status-json) printf '{"plugins_root":"%s"}\n' "$AUDIOSTACK_VST_ROOT" ;;
  page) printf '%s\n' '{"kind":"folder","display":"FabFilter"}' \
    '{"kind":"plugin","vendor":"FabFilter","group":"","display":"Pro-Q 4","formats":"vst2,vst3"}' ;;
esac
FAKE_APM
chmod +x "$HOME/.local/bin/mosquito-audio-plugin-manager-actions"
backup_plugins_inventory "$TMP/full-backup"
grep -q $'FabFilter\t-\tPro-Q 4\tvst2,vst3' "$TMP/full-backup/plugins/installed-list.tsv"
printf 'FabFilter\t-\tPro-Q 4\tvst2,vst3\n' > "$TMP/archive/plugins/installed-list.tsv"
restore_vst_inventory "$TMP/archive" "mosquitomarchy-backup-20261102-013933.tar.gz"
canonical="$AUDIOSTACK_VST_ROOT/VST list - 20261102-013933.md"
grep -q '^## FabFilter$' "$canonical"
grep -q 'Pro-Q 4 — VST2, VST3' "$canonical"
! grep -q 'bytes' "$canonical"

mkdir -p "$(dirname "$EXCLUDED_FILE")"
printf 'reaper\nreboot-into-windows\n' > "$EXCLUDED_FILE"
seen=()
category_run(){ seen+=("$1:${CATEGORY_SELECTED[*]}"); }
printf 'apps\tzen\treaper\nplugins\treboot-into-windows\n' > "$LIST"
restore_install_list "$LIST" full
[[ ${seen[0]} == 'apps:zen reaper' ]]
[[ ${seen[1]} == 'plugins:reboot-into-windows' ]]
[[ ! -s $EXCLUDED_FILE ]] || ! grep -qxE 'reaper|reboot-into-windows' "$EXCLUDED_FILE"

mkdir -p "$TMP/restore-input"
printf 'apps\tdouze\textracto\treaper\n' > "$TMP/restore-input/install.list"
mkdir -p "$TMP/reaper-input/.config/REAPER" "$TMP/restore-input/reaper"
printf 'test' > "$TMP/reaper-input/.config/REAPER/reaper.ini"
tar -czf "$TMP/restore-input/reaper/reaper.tar.gz" -C "$TMP/reaper-input" .config/REAPER
tar -czf "$TMP/restore.tar.gz" -C "$TMP/restore-input" install.list reaper/reaper.tar.gz
sudo_primes=0 module_runs=0 reaper_runs=0
mq_sudo_prime(){
  [[ -n ${MQ_SUDO_PRIMED:-} ]] && return 0
  sudo_primes=$((sudo_primes + 1))
  export MQ_SUDO_PRIMED=1
}
module_state(){ printf 'missing\n'; }
run_reaper(){ reaper_runs=$((reaper_runs + 1)); }
restore_sync_pacman_databases(){ mq_sudo_prime; }
category_run(){
  mq_sudo_prime
  module_runs=$((module_runs + 1))
  for k in "${CATEGORY_SELECTED[@]}"; do [[ $k == reaper ]] && run_reaper; done
}
YES=1 RESTORE_DEPLOY_HYPRLAND=no RESTORE_DEPLOY_VST=no RESTORE_DEPLOY_REAPER=yes \
  RESTORE_DEPLOY_ZEN=no RESTORE_DEPLOY_KEEPASS=no RESTORE_DEPLOY_KEEPASS_SETTINGS=no \
  RESTORE_DEPLOY_THEMES=no RESTORE_DEPLOY_OMARCHY_PLUGINS=no RESTORE_KEYBINDINGS=none \
  restore_backup "$TMP/restore.tar.gz"
[[ $sudo_primes == 1 && $module_runs == 1 && $reaper_runs == 1 ]]

# Preinstalls are recorded as the stock packages the user UNchecked; a restore
# removes exactly those, in one call, without a package install or a pacman
# database sync (a removal does not need the sync DB).
dropped=()
run_remove_preinstalls(){ dropped+=("$*"); }
sync_before=$package_sync_calls
printf 'preinstalls\tpreinstall:aether\tpreinstall:obsidian\n' > "$LIST"
restore_install_list "$LIST" full
[[ ${dropped[0]} == 'aether obsidian' ]]
[[ $package_sync_calls == $sync_before ]]
echo 'ok: restore replays every package row and reports failures'
