#!/usr/bin/env bash
# Exercise do_backup end-to-end: generated app/module state must not enter the
# personal configuration archive, even when present on the source machine.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
export OMARCHY_BACKUP_DIR="$TMP/backups"
export MOSQUITOMARCHY_LIB_ONLY=1 GUI_RUN_EXEC=1
mkdir -p "$HOME/.config/windows" "$HOME/.config/omarchy/extensions" \
  "$HOME/.config/omarchy/plugins/mosquito.better-pip" \
  "$HOME/.config/zen/profile.release/chrome/zen-themes/custom-mod" \
  "$HOME/.config/zen/profile.release/extensions" \
  "$HOME/.config/keepassxc" "$HOME/.config/autostart" \
  "$HOME/.local/share/applications" "$HOME/.local/share/icons/hicolor/256x256/apps" \
  "$HOME/.local/bin" "$HOME/Documents"
printf 'personal setting\n' > "$HOME/.config/windows/user.conf"
printf '[Install42]\nDefault=profile.release\n' > "$HOME/.config/zen/profiles.ini"
printf 'user_pref("zen.restore.test", true);\n' > "$HOME/.config/zen/profile.release/prefs.js"
printf 'custom Zen mod\n' > "$HOME/.config/zen/profile.release/chrome/zen-themes/custom-mod/chrome.css"
printf 'custom extension\n' > "$HOME/.config/zen/profile.release/extensions/custom-addon.xpi"
printf '[GUI]\nLaunchAtStartup=true\n' > "$HOME/.config/keepassxc/keepassxc.ini"
printf '[Desktop Entry]\nName=KeePassXC\nExec=keepassxc\n' \
  > "$HOME/.config/autostart/org.keepassxc.KeePassXC.desktop"
printf '{"name":"stale menu"}\n' > "$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"
printf 'plugin payload\n' > "$HOME/.config/omarchy/plugins/mosquito.better-pip/Service.qml"
printf '[Desktop Entry]\nName=Never selected\n' > "$HOME/.local/share/applications/stale.desktop"
printf 'icon\n' > "$HOME/.local/share/icons/hicolor/256x256/apps/stale.png"
printf '#!/bin/sh\n' > "$HOME/.local/bin/omarchy-vm"
printf '#!/bin/sh\n' > "$HOME/.local/bin/reaper-launch"
chmod +x "$HOME/.local/bin/omarchy-vm" "$HOME/.local/bin/reaper-launch"

cat > "$TMP/selection.tsv" <<'EOF'
apps	reaper
apps	keepassxc
plugins	battery-management	better-pip
EOF
export BACKUP_APPS_SELECTION_FILE="$TMP/selection.tsv"

# Keep the archive-generation test isolated from the host's package manager,
# desktop session, plugins, and keybindings.
source "$ROOT/mosquitomarchy-setup.sh"
YES=1
VST_MODE=none
pkg_has(){ [[ ${1:-} == keepassxc ]]; }
pacman(){ :; }
omarchy(){ printf 'test\n'; }
mosquitomarchy_channel(){ printf 'stable\n'; }
betterbird_active_profile(){ return 1; }
apm_installed(){ return 1; }
apm_installed_plugin_count(){ printf '0\n'; }
mq_vst_init(){ :; }
backup_themes_archive(){ :; }
backup_omarchy_plugins_archive(){ :; }
backup_keybindings_archive(){ :; }
backup_hyprland_archive(){ :; }

do_backup >"$TMP/backup.log" 2>&1
if grep -q 'command not found' "$TMP/backup.log"; then
  cat "$TMP/backup.log" >&2
  echo 'FAIL: backup instructions executed Markdown command substitution' >&2
  exit 1
fi
archive="$(find "$OMARCHY_BACKUP_DIR" -maxdepth 1 -name '*.tar.gz' -print -quit)"
[[ -n $archive ]]
mkdir "$TMP/unpacked"
tar xzf "$archive" -C "$TMP/unpacked"
[[ "$(cat "$TMP/unpacked/install.list")" == $'# install.list — packages selected in the mosquitOmarchy TUI\napps\treaper\napps\tkeepassxc\nplugins\tbattery-management\tbetter-pip' ]]

tar tzf "$TMP/unpacked/config-backup.tar.gz" > "$TMP/config-paths"
grep -q '^\.config/windows/user.conf$' "$TMP/config-paths"
for forbidden in \
  '.config/omarchy/extensions/' \
  '.config/omarchy/plugins/mosquito.better-pip/' \
  '.local/share/applications/' \
  '.local/share/icons/hicolor/' \
  '.local/bin/omarchy-vm' \
  '.local/bin/reaper-launch'; do
  if grep -qF "$forbidden" "$TMP/config-paths"; then
    echo "FAIL: generated/unselected state is in config-backup: $forbidden" >&2
    exit 1
  fi
done
grep -qF '.config/zen/profile.release/chrome/zen-themes/custom-mod/chrome.css' "$TMP/config-paths"
grep -qF '.config/zen/profile.release/extensions/custom-addon.xpi' "$TMP/config-paths"
grep -qF '.config/autostart/org.keepassxc.KeePassXC.desktop' "$TMP/config-paths"

# Restoring those files does not require selecting Zen for module reinstall.
export HOME="$TMP/restore-home"
mkdir -p "$HOME"
mq_sudo_prime(){ :; }
restore_sync_pacman_databases(){ :; }
category_run(){ :; }
systemctl(){ :; }
omarchy(){ :; }
YES=1 RESTORE_DEPLOY_ZEN=yes RESTORE_DEPLOY_KEEPASS=no RESTORE_DEPLOY_KEEPASS_SETTINGS=yes \
  RESTORE_DEPLOY_HYPRLAND=no RESTORE_DEPLOY_VST=no RESTORE_DEPLOY_REAPER=no \
  RESTORE_DEPLOY_THEMES=no RESTORE_DEPLOY_OMARCHY_PLUGINS=no RESTORE_KEYBINDINGS=none \
  restore_backup "$archive" >/dev/null
[[ -f "$HOME/.config/zen/profile.release/chrome/zen-themes/custom-mod/chrome.css" ]]
[[ -f "$HOME/.config/zen/profile.release/extensions/custom-addon.xpi" ]]
[[ -f "$HOME/.config/autostart/org.keepassxc.KeePassXC.desktop" ]]

# The restore now extracts the new config archive directly; no old-archive
# cleanup or compatibility path is needed.
grep -q 'tar xzf "$tmp/config-backup.tar.gz" -C "$HOME" "${tex\[@\]}"' "$ROOT/mosquitomarchy-setup.sh"
if grep -qE 'exclude=.*(applications|icons/hicolor|omarchy/extensions|\.local/bin)' "$ROOT/mosquitomarchy-setup.sh"; then
  echo 'FAIL: restore still contains old-archive cleanup filters' >&2
  exit 1
fi

echo 'ok: new backups exclude unselected app/module-generated state'
