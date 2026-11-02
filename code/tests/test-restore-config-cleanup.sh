#!/usr/bin/env bash
# A restore must not plant another machine's dead menu entries or module
# wrappers. Application entries are derived state (packages and modules
# recreate their own); a wrapper is restored only when the backup's own
# install.list selects its module.
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
mq_sudo_prime(){ :; }
restore_sync_pacman_databases(){ :; }
category_run(){ :; }

# The config archive is made from the host machine: it carries an app entry
# and a VM launcher that never belonged to the restored selection.
mkdir -p "$TMP/archive/src/.config/omarchy/extensions" \
         "$TMP/archive/src/.config" "$TMP/archive/src/.local/share/applications" \
         "$TMP/archive/src/.local/share/icons/hicolor/256x256/apps" \
         "$TMP/archive/src/.local/bin"
printf 'keep me\n' > "$TMP/archive/src/.config/test-marker"
printf '{"action":"stale-module"}\n' > "$TMP/archive/src/.config/omarchy/extensions/omarchy-menu.jsonc"
printf '[Desktop Entry]\nName=Dead\nExec=dead-app\n' \
  > "$TMP/archive/src/.local/share/applications/Dead.desktop"
printf 'icon\n' > "$TMP/archive/src/.local/share/icons/hicolor/256x256/apps/Dead.png"
printf '#!/bin/sh\n' > "$TMP/archive/src/.local/bin/omarchy-vm"
printf '#!/bin/sh\n' > "$TMP/archive/src/.local/bin/reaper-launch"
tar -czf "$TMP/archive/config-backup.tar.gz" -C "$TMP/archive/src" .

# No install.list: nothing is selected, so no module wrapper may be restored.
package_archive="$TMP/no-list.tar.gz"
tar -czf "$package_archive" -C "$TMP/archive" config-backup.tar.gz
YES=1 RESTORE_DEPLOY_HYPRLAND=no RESTORE_DEPLOY_VST=no RESTORE_DEPLOY_REAPER=no \
  RESTORE_DEPLOY_ZEN=no RESTORE_DEPLOY_KEEPASS=no RESTORE_DEPLOY_KEEPASS_SETTINGS=no \
  RESTORE_DEPLOY_THEMES=no RESTORE_DEPLOY_OMARCHY_PLUGINS=no RESTORE_KEYBINDINGS=none \
  restore_backup "$package_archive"
[[ -f $HOME/.config/test-marker ]]
[[ ! -e $HOME/.local/share/applications/Dead.desktop ]]
[[ ! -e $HOME/.local/share/icons/hicolor/256x256/apps/Dead.png ]]
[[ ! -e $HOME/.config/omarchy/extensions/omarchy-menu.jsonc ]]
[[ ! -e $HOME/.local/bin/omarchy-vm ]]
[[ ! -e $HOME/.local/bin/reaper-launch ]]

# The same archive with reaper selected: its wrapper comes back, the unselected
# VM launcher and the menu entry still do not.
rm -rf "$HOME" "$TMP/archive"
mkdir -p "$HOME" "$TMP/archive/src/.config/omarchy/extensions" \
         "$TMP/archive/src/.config" "$TMP/archive/src/.local/share/applications" \
         "$TMP/archive/src/.local/share/icons/hicolor/256x256/apps" \
         "$TMP/archive/src/.local/bin"
printf 'keep me\n' > "$TMP/archive/src/.config/test-marker"
printf '{"action":"stale-module"}\n' > "$TMP/archive/src/.config/omarchy/extensions/omarchy-menu.jsonc"
printf '[Desktop Entry]\nName=Dead\nExec=dead-app\n' \
  > "$TMP/archive/src/.local/share/applications/Dead.desktop"
printf 'icon\n' > "$TMP/archive/src/.local/share/icons/hicolor/256x256/apps/Dead.png"
printf '#!/bin/sh\n' > "$TMP/archive/src/.local/bin/omarchy-vm"
printf '#!/bin/sh\n' > "$TMP/archive/src/.local/bin/reaper-launch"
tar -czf "$TMP/archive/config-backup.tar.gz" -C "$TMP/archive/src" .
printf 'apps\treaper\n' > "$TMP/archive/install.list"
package_archive="$TMP/with-list.tar.gz"
tar -czf "$package_archive" -C "$TMP/archive" config-backup.tar.gz install.list

YES=1 RESTORE_DEPLOY_HYPRLAND=no RESTORE_DEPLOY_VST=no RESTORE_DEPLOY_REAPER=no \
  RESTORE_DEPLOY_ZEN=no RESTORE_DEPLOY_KEEPASS=no RESTORE_DEPLOY_KEEPASS_SETTINGS=no \
  RESTORE_DEPLOY_THEMES=no RESTORE_DEPLOY_OMARCHY_PLUGINS=no RESTORE_KEYBINDINGS=none \
  restore_backup "$package_archive"
[[ -f $HOME/.config/test-marker ]]
[[ -f $HOME/.local/bin/reaper-launch ]]
[[ ! -e $HOME/.local/bin/omarchy-vm ]]
[[ ! -e $HOME/.local/share/applications/Dead.desktop ]]
[[ ! -e $HOME/.local/share/icons/hicolor/256x256/apps/Dead.png ]]
[[ ! -e $HOME/.config/omarchy/extensions/omarchy-menu.jsonc ]]

# VM wrappers are filed under the vms folder, not apps. Selecting a VM in the
# backup must preserve its wrapper while still skipping application entries.
rm -rf "$HOME" "$TMP/archive"
mkdir -p "$HOME" "$TMP/archive/src/.config/omarchy/extensions" \
         "$TMP/archive/src/.local/share/applications" "$TMP/archive/src/.local/bin"
printf '{"action":"stale-module"}\n' > "$TMP/archive/src/.config/omarchy/extensions/omarchy-menu.jsonc"
printf '[Desktop Entry]\nName=Dead\nExec=dead-app\n' \
  > "$TMP/archive/src/.local/share/applications/Dead.desktop"
printf '#!/bin/sh\n' > "$TMP/archive/src/.local/bin/omarchy-vm"
tar -czf "$TMP/archive/config-backup.tar.gz" -C "$TMP/archive/src" .
printf 'vms\tomarchy-vm\n' > "$TMP/archive/install.list"
package_archive="$TMP/with-vm.tar.gz"
tar -czf "$package_archive" -C "$TMP/archive" config-backup.tar.gz install.list
YES=1 RESTORE_DEPLOY_HYPRLAND=no RESTORE_DEPLOY_VST=no RESTORE_DEPLOY_REAPER=no \
  RESTORE_DEPLOY_ZEN=no RESTORE_DEPLOY_KEEPASS=no RESTORE_DEPLOY_KEEPASS_SETTINGS=no \
  RESTORE_DEPLOY_THEMES=no RESTORE_DEPLOY_OMARCHY_PLUGINS=no RESTORE_KEYBINDINGS=none \
  restore_backup "$package_archive"
[[ -f $HOME/.local/bin/omarchy-vm ]]
[[ ! -e $HOME/.local/share/applications/Dead.desktop ]]
[[ ! -e $HOME/.config/omarchy/extensions/omarchy-menu.jsonc ]]

# Future backups must not archive the derived menu-directory at all.
grep -q '\.local/share/applications' "$ROOT/mosquitomarchy-setup.sh"
grep -q '\.config/omarchy/extensions' "$ROOT/mosquitomarchy-setup.sh"
grep -q '\.local/share/icons/hicolor' "$ROOT/mosquitomarchy-setup.sh"
if sed -n '/cat > "\$tmp\/RESTORE.md"/,/^EOF$/p' "$ROOT/mosquitomarchy-setup.sh" \
     | grep -q 'tar xzf config-backup.tar.gz'; then
  echo 'FAIL: generated restore instructions still recommend raw config extraction' >&2
  exit 1
fi
if sed -n '/--- 1. Core config files/,/--- 2. Plugin folders/p' "$ROOT/mosquitomarchy-setup.sh" \
     | grep -qE '^ *\.local/share/(applications|icons/hicolor)|^ *\.config/omarchy/extensions'; then
  echo 'FAIL: future backups still archive generated app state' >&2
  exit 1
fi

echo 'ok: restore skips dead menu entries and unselected module wrappers'
