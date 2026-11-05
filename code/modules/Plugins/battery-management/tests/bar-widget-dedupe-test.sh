#!/usr/bin/env bash
# Self-check for the bar-layout dedupe in setup-battery-management.sh: exactly
# one power/indicators widget survives, a stock/legacy id is adopted, and a
# lone correct entry is left untouched (no rewrite, no backup).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Extract just the function; sourcing the installer would run the install.
sed -n '/^normalize_bar_widget()/,/^}$/p' "$here/setup-battery-management.sh" >"$tmp/fn.sh"
source "$tmp/fn.sh"

widget_ids() {  # widget_ids FILE SUFFIX
  python3 - "$1" "$2" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
suffix = "." + sys.argv[2]
ids = [it.get("id") for items in d["bar"]["layout"].values() for it in items]
print(",".join(i for i in ids if i and i.endswith(suffix)))
PY
}

check() {  # check NAME SUFFIX JSON WANTED_IDS
  local name="$1" suffix="$2" json="$3" want="$4" got
  printf '%s' "$json" >"$tmp/$name.json"
  normalize_bar_widget "$tmp/$name.json" kapeq_mosquito "$suffix" >/dev/null
  got="$(widget_ids "$tmp/$name.json" "$suffix")"
  [[ $got == "$want" ]] || { echo "$name: ids = '$got', want '$want'"; exit 1; }
}

check power-stale-and-live power '{"bar":{"layout":{"centerEnd":[{"id":"kapeq_mosquito.power"}],"right":[{"id":"mosquito.power"}]}}}' 'mosquito.power'
check power-stale-only     power '{"bar":{"layout":{"centerEnd":[{"id":"kapeq_mosquito.power"}],"right":[]}}}' 'mosquito.power'
check power-stock-and-live power '{"bar":{"layout":{"centerEnd":[{"id":"omarchy.power"}],"right":[{"id":"mosquito.power"}]}}}' 'mosquito.power'
check indicators-twice     indicators '{"bar":{"layout":{"centerBegin":[{"id":"mosquito.indicators"}],"centerEnd":[{"id":"mosquito.indicators"}]}}}' 'mosquito.indicators'
check indicators-stock     indicators '{"bar":{"layout":{"centerBegin":[{"id":"omarchy.indicators"}]}}}' 'mosquito.indicators'

# A single correct entry is a no-op: no rewrite, no backup.
for suffix in power indicators; do
  printf '{"bar":{"layout":{"right":[{"id":"mosquito.%s"}]}}}' "$suffix" >"$tmp/ok-$suffix.json"
  before="$(sha256sum "$tmp/ok-$suffix.json" | cut -d' ' -f1)"
  normalize_bar_widget "$tmp/ok-$suffix.json" kapeq_mosquito "$suffix" >/dev/null
  after="$(sha256sum "$tmp/ok-$suffix.json" | cut -d' ' -f1)"
  [[ $before == $after ]] || { echo "a lone $suffix widget was rewritten"; exit 1; }
  if compgen -G "$tmp/ok-$suffix.json.bak*" >/dev/null; then
    echo "a lone $suffix widget made a backup"; exit 1
  fi
done

echo ok
