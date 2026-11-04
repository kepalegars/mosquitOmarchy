#!/usr/bin/env bash
# The AMDGPU compute-watchdog tweak must edit only its own marked block, stay
# idempotent, refuse a foreign amdgpu.lockup_timeout, and restore the previous
# config when limine-update fails.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/code/modules/Tweaks/tweak-amdgpu-compute-timeout.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

CONF="$TMP/limine"
APPLIED="$TMP/applied"
mkdir -p "$TMP/bin"

cat > "$TMP/bin/sudo" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == -n ]]; then shift; fi
if [[ ${1:-} == -v ]]; then exit 0; fi
exec "$@"
EOF

cat > "$TMP/bin/limine-update" <<'EOF'
#!/usr/bin/env bash
[[ ${FAIL_LIMINE:-0} == 1 ]] && exit 1
cp "$MQ_LIMINE_CONF" "$MQ_TEST_APPLIED"
EOF

chmod +x "$TMP/bin/sudo" "$TMP/bin/limine-update"
export PATH="$TMP/bin:$PATH"
export GUI_RUN_EXEC=1
export MQ_LIMINE_CONF="$CONF"
export MQ_TEST_APPLIED="$APPLIED"

reset_conf(){
  cat > "$CONF" <<'EOF'
ESP_PATH="/boot"

KERNEL_CMDLINE[default]+="cryptdevice=UUID=test:omarchy_root root=/dev/mapper/omarchy_root"
EOF
}

fail(){ echo "FAIL: $*" >&2; exit 1; }
has(){ grep -qF -- "$1" "$CONF"; }
count(){ grep -cF -- "$1" "$CONF" || true; }

# ── apply: one block, original content kept, limine-update ran ───────────────
reset_conf
bash "$SCRIPT" >"$TMP/apply.log" 2>&1 || fail "apply exited non-zero"
has 'amdgpu.lockup_timeout=2000,90000,2000,2000' || fail "parameter missing"
[[ $(count 'mosquitOmarchy-amdgpu-compute-timeout') == 1 ]] || fail "marker count != 1"
has 'cryptdevice=UUID=test' || fail "unrelated KERNEL_CMDLINE line was lost"
cmp -s "$CONF" "$APPLIED" || fail "limine-update did not receive the new config"

# ── idempotent: a second apply must not duplicate anything ───────────────────
bash "$SCRIPT" >"$TMP/apply2.log" 2>&1 || fail "second apply exited non-zero"
[[ $(count 'amdgpu.lockup_timeout=') == 1 ]] || fail "duplicate parameter after re-apply"
[[ $(count 'mosquitOmarchy-amdgpu-compute-timeout') == 1 ]] || fail "duplicate marker after re-apply"

# ── status reports the pending reboot, not a false "active" ─────────────────
bash "$SCRIPT" --status >"$TMP/status.log" 2>&1 || fail "status exited non-zero"
grep -q 'pending-reboot' "$TMP/status.log" || fail "status did not say pending-reboot"

# ── remove: block gone, original content kept ───────────────────────────────
bash "$SCRIPT" --remove >"$TMP/remove.log" 2>&1 || fail "remove exited non-zero"
! has 'amdgpu.lockup_timeout=' || fail "parameter still present after remove"
! has 'mosquitOmarchy-amdgpu-compute-timeout' || fail "marker still present after remove"
has 'cryptdevice=UUID=test' || fail "remove lost an unrelated line"

# ── foreign setting: refuse and leave the file untouched ────────────────────
cat > "$CONF" <<'EOF'
KERNEL_CMDLINE[default]+=" amdgpu.lockup_timeout=10000"
EOF
cp -p "$CONF" "$TMP/before-foreign"
if bash "$SCRIPT" >"$TMP/foreign.log" 2>&1; then
  fail "apply accepted a foreign amdgpu.lockup_timeout"
fi
cmp -s "$CONF" "$TMP/before-foreign" || fail "refused apply modified the config"
grep -q 'already set outside this tweak' "$TMP/foreign.log" || fail "missing foreign-setting message"

# ── limine-update failure: restore the previous config ─────────────────────
reset_conf
cp -p "$CONF" "$TMP/before-failure"
if FAIL_LIMINE=1 bash "$SCRIPT" >"$TMP/failure.log" 2>&1; then
  fail "apply accepted a failing limine-update"
fi
cmp -s "$CONF" "$TMP/before-failure" || fail "failed apply did not restore the previous config"
! has 'amdgpu.lockup_timeout=' || fail "failed apply left the parameter behind"

echo 'ok: amdgpu compute-timeout tweak is idempotent, guarded and rolls back'
