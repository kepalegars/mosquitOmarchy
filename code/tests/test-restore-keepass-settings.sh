#!/usr/bin/env bash
# Safe restore replaces module-created KeePassXC defaults with the archived
# settings on a fresh target, preserves pre-existing settings, and reapplies
# the float rule after the archived Hyprland config is extracted last.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" MOSQUITOMARCHY_LIB_ONLY=1 GUI_RUN_EXEC=1 RESTORE_MODE=safe
mkdir -p "$HOME" "$TMP/source/.config/keepassxc" "$TMP/source-hypr/.config/hypr" \
  "$TMP/archive/hyprland" "$TMP/bin"
cat > "$TMP/source/.config/keepassxc/keepassxc.ini" <<'EOF'
[GUI]
RestorePreference=from-backup
EOF
printf '{"browser":"restored"}\n' > "$TMP/source/.config/keepassxc/custom-settings.json"
cat > "$TMP/source-hypr/.config/hypr/hyprland.lua" <<'EOF'
-- >>> keepassxc-window-setup >>> legacy host block
o.window("org.keepassxc.KeePassXC", { tag = "+floating-window" })
-- <<< keepassxc-window-setup <<<
EOF
tar czf "$TMP/archive/config-backup.tar.gz" -C "$TMP/source" .config/keepassxc
tar czf "$TMP/archive/hyprland/hyprland.tar.gz" -C "$TMP/source-hypr" .config/hypr
printf 'apps\tkeepassxc\n' > "$TMP/archive/install.list"
tar czf "$TMP/restore.tar.gz" -C "$TMP/archive" config-backup.tar.gz hyprland/hyprland.tar.gz install.list

cat > "$TMP/bin/keepassxc" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$TMP/bin/hyprctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/bin/keepassxc" "$TMP/bin/hyprctl"
export PATH="$TMP/bin:$PATH"

source "$ROOT/mosquitomarchy-setup.sh"
mq_sudo_prime(){ :; }
restore_sync_pacman_databases(){ :; }
systemctl(){ :; }
omarchy(){ :; }
module_runs=0
module_state(){ echo ok; }
category_run(){
  module_runs=$((module_runs + 1))
  mkdir -p "$HOME/.config/keepassxc"
  [[ -f "$HOME/.config/keepassxc/keepassxc.ini" ]] \
    || printf '[GUI]\nModuleDefault=true\n' > "$HOME/.config/keepassxc/keepassxc.ini"
}

# Fresh target: module setup creates defaults first, but safe restore must still
# install the selected backup settings and module-owned float rule.
YES=1 RESTORE_DEPLOY_HYPRLAND=yes RESTORE_DEPLOY_VST=no RESTORE_DEPLOY_REAPER=no \
  RESTORE_DEPLOY_ZEN=no RESTORE_DEPLOY_KEEPASS=no RESTORE_DEPLOY_KEEPASS_SETTINGS=yes \
  RESTORE_DEPLOY_THEMES=no RESTORE_DEPLOY_OMARCHY_PLUGINS=no RESTORE_KEYBINDINGS=none \
  restore_backup "$TMP/restore.tar.gz" >/dev/null
grep -q '^RestorePreference=from-backup$' "$HOME/.config/keepassxc/keepassxc.ini"
[[ -f "$HOME/.config/keepassxc/custom-settings.json" ]]
grep -q 'float = true, center = true, size = { "monitor_w\*0.65"' "$HOME/.config/hypr/hyprland.lua"
grep -qF 'class = "(?i)^keepassxc$"' "$HOME/.config/hypr/hyprland.lua"
! grep -q 'tag = "+floating-window"' "$HOME/.config/hypr/hyprland.lua"
[[ $module_runs == 1 ]]

# Existing settings on a safe restore are user data and stay untouched.
printf '[GUI]\nRestorePreference=keep-target\n' > "$HOME/.config/keepassxc/keepassxc.ini"
YES=1 RESTORE_DEPLOY_HYPRLAND=yes RESTORE_DEPLOY_VST=no RESTORE_DEPLOY_REAPER=no \
  RESTORE_DEPLOY_ZEN=no RESTORE_DEPLOY_KEEPASS=no RESTORE_DEPLOY_KEEPASS_SETTINGS=yes \
  RESTORE_DEPLOY_THEMES=no RESTORE_DEPLOY_OMARCHY_PLUGINS=no RESTORE_KEYBINDINGS=none \
  restore_backup "$TMP/restore.tar.gz" >/dev/null
grep -q '^RestorePreference=keep-target$' "$HOME/.config/keepassxc/keepassxc.ini"
[[ $module_runs == 2 ]]

echo 'ok: safe restore restores fresh KeePassXC settings and reapplies its float rule'
