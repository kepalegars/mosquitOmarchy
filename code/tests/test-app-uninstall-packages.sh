#!/usr/bin/env bash
# Explicit module uninstalls remove their packages regardless of the setup -y
# flag, while delegating KeePassXC/Zen integration cleanup and keeping user data.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" MOSQUITOMARCHY_LIB_ONLY=1 GUI_RUN_EXEC=1
mkdir -p "$HOME" "$TMP/bin" "$TMP/modules/Apps/keepassxc" "$TMP/zen"
export UNINSTALL_STUB_LOG="$TMP/stubs"

cat > "$TMP/bin/update-desktop-database" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/bin/update-desktop-database"
export PATH="$TMP/bin:$PATH"

cat > "$TMP/modules/Apps/keepassxc/setup-keepassxc-integration.sh" <<'EOF'
#!/usr/bin/env bash
printf 'keepass %s\n' "$*" >> "$UNINSTALL_STUB_LOG"
EOF
cat > "$TMP/zen/setup-zen.sh" <<'EOF'
#!/usr/bin/env bash
printf 'zen %s\n' "$*" >> "$UNINSTALL_STUB_LOG"
EOF
chmod +x "$TMP/modules/Apps/keepassxc/setup-keepassxc-integration.sh" "$TMP/zen/setup-zen.sh"

source "$ROOT/mosquitomarchy-setup.sh"
SCRIPTS="$TMP/modules"
ZEN_DIR="$TMP/zen"
pkg_has(){ [[ $1 == reaper || $1 == keepassxc || $1 == zen-browser-bin ]]; }
mq_sudo(){ printf '%s\n' "$*" >> "$UNINSTALL_STUB_LOG"; }
YES=0 PURGE=0

un_reaper
un_keepassxc
un_zen

grep -qx 'pacman -Rns --noconfirm reaper' "$UNINSTALL_STUB_LOG"
grep -qx 'pacman -Rns --noconfirm keepassxc' "$UNINSTALL_STUB_LOG"
grep -qx 'pacman -Rns --noconfirm zen-browser-bin' "$UNINSTALL_STUB_LOG"
grep -qx 'keepass --remove' "$UNINSTALL_STUB_LOG"
grep -qx 'zen --remove -y' "$UNINSTALL_STUB_LOG"

echo 'ok: KeePassXC, REAPER, and Zen package uninstalls run without setup -y'
