#!/usr/bin/env bash
# The reboot-into-Windows entry must install into an empty JSONC menu. The
# generated last entry has a JSONC-valid trailing comma, which jq alone rejects.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[[ -d /usr/share/omarchy && -x /usr/bin/jq ]] || {
  echo 'skip: Omarchy and jq are required for the module integration test'
  exit 0
}
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home/.config/omarchy/extensions" "$TMP/bin"
printf '{\n}\n' > "$TMP/home/.config/omarchy/extensions/omarchy-menu.jsonc"

cat > "$TMP/bin/getent" <<EOF
#!/usr/bin/env bash
[[ \$1 == passwd && \$2 == mq-jsonc-test ]] || exit 1
printf 'mq-jsonc-test:x:1000:1000::%s:/bin/bash\\n' '$TMP/home'
EOF
cat > "$TMP/bin/efibootmgr" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$TMP/bin/getent" "$TMP/bin/efibootmgr"
export USER=mq-jsonc-test SUDO_USER=mq-jsonc-test GUI_RUN_EXEC=1 PATH="$TMP/bin:$PATH"

bash "$ROOT/code/modules/Plugins/reboot-into-windows/setup-reboot-into-windows.sh" >"$TMP/run.log" 2>&1
grep -qF '"system.reboot-windows"' "$TMP/home/.config/omarchy/extensions/omarchy-menu.jsonc"
! grep -qF 'Generated menu is not valid JSONC' "$TMP/run.log"

# The resulting JSONC is parseable after removing its permitted trailing comma.
grep -v '^[[:space:]]*//' "$TMP/home/.config/omarchy/extensions/omarchy-menu.jsonc" \
  | python3 -c 'import re,sys; sys.stdout.write(re.sub(r",(\s*[}\]])", r"\1", sys.stdin.read()))' \
  | /usr/bin/jq empty

# A genuinely malformed existing menu still fails safely and remains intact.
printf '{\n  invalid jsonc\n}\n' > "$TMP/home/.config/omarchy/extensions/omarchy-menu.jsonc"
cp "$TMP/home/.config/omarchy/extensions/omarchy-menu.jsonc" "$TMP/before.jsonc"
if bash "$ROOT/code/modules/Plugins/reboot-into-windows/setup-reboot-into-windows.sh" >"$TMP/invalid.log" 2>&1; then
  echo 'FAIL: module accepted an invalid existing menu' >&2
  exit 1
fi
cmp -s "$TMP/before.jsonc" "$TMP/home/.config/omarchy/extensions/omarchy-menu.jsonc"

echo 'ok: reboot-into-windows handles empty JSONC and preserves invalid existing menus'
