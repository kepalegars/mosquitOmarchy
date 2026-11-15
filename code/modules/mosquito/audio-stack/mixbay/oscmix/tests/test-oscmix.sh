#!/usr/bin/env bash
# Self-check for the oscmix module: syntax, install status, launcher handoff
# and uninstall. Runs entirely under a temporary HOME.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAIL=0

check() { # name, condition
  if eval "$2"; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s\n' "$1"; FAIL=1; fi
}

check "setup-oscmix syntax" "bash -n '$HERE/setup-oscmix.sh'"
check "launcher syntax" "bash -n '$HERE/launch-oscmix-gtk'"

mkdir -p "$TMP/bin" "$TMP/home"
out="$(PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP/home" bash "$HERE/setup-oscmix.sh" --status 2>&1)" || true
check "status reports the missing oscmix-desk" "[[ '$out' == missing:*oscmix-session* ]]"

# Fake a complete per-user install.
mkdir -p "$TMP/home/.local/bin" "$TMP/home/.local/lib/oscmix-desk/oscmix_desk"
for b in oscmix alsaseqio oscmix-gtk oscmix-session oscmix-launch; do
  printf '#!/bin/sh\n' > "$TMP/home/.local/bin/$b"
  chmod +x "$TMP/home/.local/bin/$b"
done
touch "$TMP/home/.local/lib/oscmix-desk/oscmix_desk/__init__.py"
out="$(PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP/home" bash "$HERE/setup-oscmix.sh" --status 2>&1)" || true
check "status reports ok" "[[ '$out' == ok ]]"

# The launcher hands off to oscmix-launch.
cat > "$TMP/bin/oscmix-launch" <<EOF
#!/usr/bin/env bash
printf 'launched\n' > "$TMP/launched"
EOF
chmod +x "$TMP/bin/oscmix-launch"
PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP/home" "$HERE/launch-oscmix-gtk" >/dev/null 2>&1 || true
check "launcher runs oscmix-launch" "[[ -f '$TMP/launched' ]]"

# Without oscmix-desk it fails with a setup hint instead of silently doing
# nothing.
out="$(PATH="/usr/bin:/bin" HOME="$TMP/launcherless" "$HERE/launch-oscmix-gtk" 2>&1)" || true
check "launcher explains a missing install" "[[ '$out' == *'oscmix-desk is not installed'* ]]"

HOME="$TMP/home" XDG_DATA_HOME="$TMP/home/.local/share" bash "$HERE/setup-oscmix.sh" --uninstall >/dev/null 2>&1
check "uninstall removes binaries" "[[ ! -e '$TMP/home/.local/bin/oscmix-session' && ! -e '$TMP/home/.local/bin/oscmix-launch' ]]"
check "uninstall removes the runtime package" "[[ ! -d '$TMP/home/.local/lib/oscmix-desk' ]]"

exit "$FAIL"
