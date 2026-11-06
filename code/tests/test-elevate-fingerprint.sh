#!/usr/bin/env bash
# pam_fprintd in sudo's stack must be detected, so mq_sudo_prime skips the
# askpass (which `sudo -A` never calls while PAM waits on the reader).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
source "$ROOT/code/lib/elevate.bash"

printf 'auth sufficient pam_fprintd.so\n' > "$TMP/with"
printf 'auth sufficient pam_unix.so\n' > "$TMP/without"

if ! MQ_PAM_SUDO="$TMP/with" mq_sudo_has_fingerprint; then
  echo "fail: pam_fprintd stack not detected" >&2
  exit 1
fi
if MQ_PAM_SUDO="$TMP/without" mq_sudo_has_fingerprint; then
  echo "fail: pam_unix-only stack reported as fingerprint" >&2
  exit 1
fi
if MQ_PAM_SUDO="$TMP/missing" mq_sudo_has_fingerprint; then
  echo "fail: missing PAM file reported as fingerprint" >&2
  exit 1
fi
echo 'ok: pam_fprintd detection gates the askpass priming'
