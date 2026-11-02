#!/usr/bin/env bash
# A selected, restored KeePassXC database is launched even when the TUI runner
# has no DISPLAY/WAYLAND_DISPLAY variables; unselected databases are not.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" MOSQUITOMARCHY_LIB_ONLY=1 GUI_RUN_EXEC=1
mkdir -p "$HOME/.config/keepassxc" "$TMP/bin" "$TMP/source/.config/keepassxc" \
  "$TMP/source/Documents" "$TMP/archive"
printf '[General]\n' > "$TMP/source/.config/keepassxc/keepassxc.ini"
printf '[General]\n' > "$HOME/.config/keepassxc/keepassxc.ini"
printf 'test database\n' > "$TMP/source/Documents/Passwords.kdbx"
cat > "$TMP/bin/pgrep" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
cat > "$TMP/bin/keepassxc" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$TMP/bin/uwsm" <<EOF
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> '$TMP/launched'
EOF
cat > "$TMP/bin/hyprctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/bin/pgrep" "$TMP/bin/keepassxc" "$TMP/bin/uwsm" "$TMP/bin/hyprctl"
export PATH="$TMP/bin:$PATH"
tar czf "$TMP/archive/config-backup.tar.gz" -C "$TMP/source" Documents/Passwords.kdbx .config/keepassxc
tar czf "$TMP/restore.tar.gz" -C "$TMP/archive" config-backup.tar.gz

source "$ROOT/mosquitomarchy-setup.sh"
systemctl(){ :; }
omarchy(){ :; }
unset DISPLAY WAYLAND_DISPLAY

YES=1 RESTORE_DEPLOY_HYPRLAND=no RESTORE_DEPLOY_VST=no RESTORE_DEPLOY_REAPER=no \
  RESTORE_DEPLOY_ZEN=no RESTORE_DEPLOY_KEEPASS=yes RESTORE_DEPLOY_KEEPASS_SETTINGS=yes \
  RESTORE_DEPLOY_THEMES=no RESTORE_DEPLOY_OMARCHY_PLUGINS=no RESTORE_KEYBINDINGS=none \
  restore_backup "$TMP/restore.tar.gz" >/dev/null
for _ in {1..50}; do [[ -f $TMP/launched ]] && break; sleep 0.01; done
grep -qF -- "app -- keepassxc $HOME/Documents/Passwords.kdbx" "$TMP/launched"

# Selecting no for the password database must not launch KeePassXC, even when
# a copy of the file happens to remain on disk.
rm -f "$TMP/launched"
YES=1 RESTORE_DEPLOY_HYPRLAND=no RESTORE_DEPLOY_VST=no RESTORE_DEPLOY_REAPER=no \
  RESTORE_DEPLOY_ZEN=no RESTORE_DEPLOY_KEEPASS=no RESTORE_DEPLOY_KEEPASS_SETTINGS=no \
  RESTORE_DEPLOY_THEMES=no RESTORE_DEPLOY_OMARCHY_PLUGINS=no RESTORE_KEYBINDINGS=none \
  restore_backup "$TMP/restore.tar.gz" >/dev/null
[[ ! -e $TMP/launched ]]

echo 'ok: restore launches KeePassXC only when its database is selected'
