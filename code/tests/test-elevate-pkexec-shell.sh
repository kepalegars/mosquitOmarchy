#!/usr/bin/env bash
# Both pkexec paths must discard a SHELL value not listed in /etc/shells.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/pkexec" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${SHELL:-}" > "$PKEXEC_LOG"
printf '%s\n' "$@" >> "$PKEXEC_LOG"
SH
cat > "$TMP/bin/sudo" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$TMP/bin/pkexec" "$TMP/bin/sudo"
export PATH="$TMP/bin:$PATH" PKEXEC_LOG="$TMP/pkexec.log"
export SHELL="$TMP/not-a-listed-shell"
source "$ROOT/code/lib/elevate.bash"

expected="$(mq_sane_shell)"
mq_pkexec true
[[ $(head -1 "$PKEXEC_LOG") == "$expected" ]]

export DBUS_SESSION_BUS_ADDRESS=unix:path=/tmp/test-session-bus WAYLAND_DISPLAY=wayland-test
mq_enable_sudo_pkexec_shim
sudo pacman -S --needed python-pyusb
[[ $(head -1 "$PKEXEC_LOG") == "$expected" ]]
grep -q '^pacman$' "$PKEXEC_LOG"
rm -rf "$_MQ_SHIM_DIR"
echo 'ok: pkexec receives a shell listed in /etc/shells'
