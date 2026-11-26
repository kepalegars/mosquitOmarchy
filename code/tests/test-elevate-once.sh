#!/usr/bin/env bash
# mq_elevate_once primes sudo once: idempotent in-process, and shared by
# concurrent launches (the flock must prevent a second GUI prompt).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export XDG_RUNTIME_DIR="$TMP" HOME="$TMP" MQ_PAM_SUDO="$TMP/no-fprintd"
export MQ_TEST_LOG="$TMP/primes" MQ_TEST_CACHED="$TMP/cached"
printf 'auth sufficient pam_unix.so\n' > "$MQ_PAM_SUDO"

# Fake sudo: -n -v succeeds only once priming has happened; -A -v is the prompt.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/sudo" <<'SH'
#!/usr/bin/env bash
if [[ ${1:-} == -n && ${2:-} == -v ]]; then
  [[ -f ${MQ_TEST_CACHED:-} ]] && exit 0 || exit 1
fi
if [[ ${1:-} == -A && ${2:-} == -v ]]; then
  echo prime >> "$MQ_TEST_LOG"
  sleep 0.3
  : > "$MQ_TEST_CACHED"
  exit 0
fi
exit 1
SH
# An executable named omaskpass makes mq_sudo_askpass prefer it (no zenity).
cat > "$TMP/bin/omaskpass" <<'SH'
#!/usr/bin/env bash
printf 'test-password\n'
SH
chmod +x "$TMP/bin/sudo" "$TMP/bin/omaskpass"
export PATH="$TMP/bin:$PATH" SUDO_ASKPASS="$TMP/bin/omaskpass"

# Four simultaneous launches, each a fresh shell sourcing the helper.
for _ in 1 2 3 4; do
  bash -c 'source "$1/code/lib/elevate.bash"; mq_elevate_once' _ "$ROOT" &
done
wait

n="$(wc -l < "$MQ_TEST_LOG" 2>/dev/null || echo 0)"
[[ $n == 1 ]] || { echo "fail: expected 1 elevation, got $n" >&2; exit 1; }

# A second call in the same shell must not prime again.
source "$ROOT/code/lib/elevate.bash"
mq_elevate_once
n="$(wc -l < "$MQ_TEST_LOG")"
[[ $n == 1 ]] || { echo "fail: in-process re-prime ($n)" >&2; exit 1; }

echo 'ok: one elevation at launch, shared across concurrent launches'
