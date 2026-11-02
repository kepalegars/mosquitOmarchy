#!/usr/bin/env bash
# Pinning the restored KeePassXC database must close a running instance and
# wait for it to exit before editing its ini, without killing it forcibly.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME/.config/keepassxc" "$HOME/Documents" "$TMP/bin"
DB="$HOME/Documents/Passwords.kdbx"
printf 'db\n' > "$DB"
printf '[General]\n' > "$HOME/.config/keepassxc/keepassxc.ini"
export KP_RUNNING="$TMP/running"
touch "$KP_RUNNING"

cat > "$TMP/bin/pgrep" <<'EOF'
#!/usr/bin/env bash
[[ -e $KP_RUNNING ]]
EOF
cat > "$TMP/bin/pkill" <<'EOF'
#!/usr/bin/env bash
[[ ${*: -1} == keepassxc ]] || exit 2
if [[ ${KP_STUCK:-0} == 0 ]]; then rm -f "$KP_RUNNING"; fi
EOF
cat > "$TMP/bin/sleep" <<'EOF'
#!/usr/bin/env bash
:
EOF
chmod +x "$TMP/bin/pgrep" "$TMP/bin/pkill" "$TMP/bin/sleep"
export PATH="$TMP/bin:$PATH"

# A graceful close completes, then the requested database is pinned.
bash "$ROOT/code/modules/Apps/keepassxc/keepassxc-default-database.sh" "$DB" >/dev/null
grep -qF "LastOpenedDatabases = $DB" "$HOME/.config/keepassxc/keepassxc.ini"

# If the app does not exit, stop without changing the ini; never SIGKILL a
# password manager that may still have unsaved state.
printf '[General]\n' > "$HOME/.config/keepassxc/keepassxc.ini"
touch "$KP_RUNNING"
if KP_STUCK=1 bash "$ROOT/code/modules/Apps/keepassxc/keepassxc-default-database.sh" "$DB" >/dev/null 2>&1; then
  echo 'FAIL: pin helper succeeded while KeePassXC remained open' >&2
  exit 1
fi
! grep -qF 'LastOpenedDatabases' "$HOME/.config/keepassxc/keepassxc.ini"

echo 'ok: KeePassXC pin waits for safe close and does not force-kill'
