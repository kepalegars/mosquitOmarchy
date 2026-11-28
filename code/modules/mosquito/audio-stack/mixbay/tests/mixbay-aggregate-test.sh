#!/usr/bin/env bash
# Guard smoke test: one pw-mon removal event must trigger exactly one repair.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home/.local/bin" "$TMP/bin"

cat >"$TMP/bin/pw-mon" <<'SH'
#!/usr/bin/env bash
printf 'removed: 42\n'
SH
cat >"$TMP/home/.local/bin/mosquito-mixbay-actions" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GUARD_LOG:?}"
SH
chmod +x "$TMP/bin/pw-mon" "$TMP/home/.local/bin/mosquito-mixbay-actions"

GUARD_LOG="$TMP/log" HOME="$TMP/home" PATH="$TMP/bin:$PATH" \
  bash "$HERE/foundation/mixbay-aggregate-guard"

[[ $(grep -c '^aggregate-repair$' "$TMP/log") -eq 1 ]] \
  || { echo "expected one aggregate-repair call, got: $(cat "$TMP/log")" >&2; exit 1; }
echo "mixbay-aggregate-guard: ok"
