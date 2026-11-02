#!/usr/bin/env bash
# The shell restart must happen after restored shell config and theme files are
# in place, not during an earlier module setup.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" MOSQUITOMARCHY_LIB_ONLY=1 GUI_RUN_EXEC=1
mkdir -p "$HOME" "$TMP/config/.config/omarchy" \
  "$TMP/theme/.config/omarchy/themes/restored-theme" "$TMP/archive/themes"
printf '{"restored":true}\n' > "$TMP/config/.config/omarchy/shell.json"
printf 'wallpaper\n' > "$TMP/theme/.config/omarchy/themes/restored-theme/wallpaper"
tar czf "$TMP/archive/config-backup.tar.gz" -C "$TMP/config" .
tar czf "$TMP/archive/themes/themes.tar.gz" -C "$TMP/theme" .config/omarchy/themes/restored-theme
tar czf "$TMP/restore.tar.gz" -C "$TMP/archive" config-backup.tar.gz themes/themes.tar.gz

source "$ROOT/mosquitomarchy-setup.sh"
systemctl(){ :; }
omarchy(){
  [[ ${1:-} == restart && ${2:-} == shell ]] || return 2
  [[ -f "$HOME/.config/omarchy/shell.json" ]] || return 1
  [[ -f "$HOME/.config/omarchy/themes/restored-theme/wallpaper" ]] || return 1
  printf 'shell-and-theme-present\n' >> "$TMP/restarts"
}

YES=1 RESTORE_DEPLOY_HYPRLAND=no RESTORE_DEPLOY_VST=no RESTORE_DEPLOY_REAPER=no \
  RESTORE_DEPLOY_ZEN=no RESTORE_DEPLOY_KEEPASS=no RESTORE_DEPLOY_KEEPASS_SETTINGS=no \
  RESTORE_DEPLOY_OMARCHY_PLUGINS=no RESTORE_DEPLOY_THEMES=yes RESTORE_KEYBINDINGS=none \
  restore_backup "$TMP/restore.tar.gz" >/dev/null

[[ $(cat "$TMP/restarts") == shell-and-theme-present ]]
echo 'ok: restore restarts Omarchy shell after config and theme deployment'
