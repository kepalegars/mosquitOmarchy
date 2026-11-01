#!/usr/bin/env bash
# Self-check for reboot-into-windows. Uses a fake efibootmgr + sudo/pkexec so
# it never touches the real firmware. Run from anywhere:
#   ./test-reboot-into-windows.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$HERE/reboot-into-windows"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok: %s\n' "$*"; }

cat > "$TMP/efibootmgr" <<'EOF'
#!/usr/bin/env bash
STATE="$EFI_STATE"
if [[ ${1:-} == --bootnext ]]; then printf '%s\n' "$2" > "$STATE"; exit 0; fi
if [[ ${1:-} == --delete-bootnext ]]; then rm -f "$STATE"; exit 0; fi
printf 'BootCurrent: 0001\n'
[[ -f $STATE ]] && printf 'BootNext: %s\n' "$(cat "$STATE")"
printf 'BootOrder: 0001,0000\n'
printf 'Boot0001* Omarchy\tHD(1,GPT,abc)/File(\\EFI\\Omarchy\\grubx64.efi)\n'
if [[ ${EFI_NO_WINDOWS:-0} != 1 ]]; then
  printf 'Boot0000* Windows Boot Manager\tHD(1,GPT,abc)/File(\\EFI\\Microsoft\\Boot\\bootmgfw.efi)\n'
fi
EOF
cat > "$TMP/sudo" <<'EOF'
#!/usr/bin/env bash
[[ ${1:-} == -n ]] && shift
[[ ${1:-} == true ]] && exit 0
exec "$@"
EOF
cat > "$TMP/pkexec" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
chmod +x "$TMP/efibootmgr" "$TMP/sudo" "$TMP/pkexec"

export PATH="$TMP:$PATH"
export EFIBOOTMGR="$TMP/efibootmgr"
export EFI_STATE="$TMP/bootnext"

out="$("$HELPER" --list)"
[[ $out == *"Boot0000"* ]] || fail "list did not find the Windows entry"
pass "list finds Windows Boot Manager"

out="$("$HELPER" --dry-run)"
[[ $out == *"--bootnext 0000"* ]] || fail "dry-run did not print the efibootmgr argv"
pass "dry-run prints the write without touching firmware"

REBOOT_INTO_WINDOWS_REBOOT="true" "$HELPER" --yes >/dev/null
[[ "$(cat "$EFI_STATE")" == "0000" ]] || fail "--yes did not arm BootNext"
pass "--yes arms BootNext and verifies it"

"$HELPER" --clear-next >/dev/null
[[ ! -f $EFI_STATE ]] || fail "--clear-next did not remove BootNext"
pass "--clear-next removes BootNext"

if EFI_NO_WINDOWS=1 "$HELPER" --list >/dev/null 2>&1; then
  fail "list succeeded without a Windows entry"
fi
pass "no Windows entry is reported as an error"

printf '\nAll reboot-into-windows checks passed.\n'
