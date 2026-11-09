#!/usr/bin/env bash
# Self-check for the bar-layout dedupe in setup-battery-management.sh: exactly
# one power/indicators widget survives, a stock/legacy id is adopted, and a
# lone correct entry is left untouched (no rewrite, no backup).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Source just the shared bar-layout helper; sourcing the installer would run it.
source "$here/../../../lib/bar-widget.bash"

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
  mq_normalize_bar_widget "$tmp/$name.json" kapeq_mosquito "$suffix" >/dev/null
  got="$(widget_ids "$tmp/$name.json" "$suffix")"
  [[ $got == "$want" ]] || { echo "$name: ids = '$got', want '$want'"; exit 1; }
}

check_canon() {  # check_canon NAME SUFFIX CANON JSON WANTED_IDS
  local name="$1" suffix="$2" canon="$3" json="$4" want="$5" got
  printf '%s' "$json" >"$tmp/$name.json"
  mq_normalize_bar_widget "$tmp/$name.json" kapeq_mosquito "$suffix" "$canon" >/dev/null
  got="$(widget_ids "$tmp/$name.json" "${canon#mosquito.}")"
  [[ $got == "$want" ]] || { echo "$name: ids = '$got', want '$want'"; exit 1; }
}

check power-stale-and-live power '{"bar":{"layout":{"centerEnd":[{"id":"kapeq_mosquito.power"}],"right":[{"id":"mosquito.power"}]}}}' 'mosquito.power'
check power-stale-only     power '{"bar":{"layout":{"centerEnd":[{"id":"kapeq_mosquito.power"}],"right":[]}}}' 'mosquito.power'
check power-stock-and-live power '{"bar":{"layout":{"centerEnd":[{"id":"omarchy.power"}],"right":[{"id":"mosquito.power"}]}}}' 'mosquito.power'
check indicators-twice     indicators '{"bar":{"layout":{"centerBegin":[{"id":"mosquito.indicators"}],"centerEnd":[{"id":"mosquito.indicators"}]}}}' 'mosquito.indicators'
check indicators-stock     indicators '{"bar":{"layout":{"centerBegin":[{"id":"omarchy.indicators"}]}}}' 'mosquito.indicators'

# Merged plugin: every power-family id becomes mosquito.battery, once, in place,
# keeping the entry (and its inline settings) that was already on the right.
check_canon battery-migrate power mosquito.battery \
  '{"bar":{"layout":{"centerEnd":[{"id":"kapeq_mosquito.power"}],"right":[{"id":"mosquito.power","showPercentage":true}]}}}' \
  'mosquito.battery'
check_canon battery-dedupe power mosquito.battery \
  '{"bar":{"layout":{"right":[{"id":"mosquito.battery"},{"id":"mosquito.battery"}]}}}' \
  'mosquito.battery'
check_canon battery-stock-battery power mosquito.battery \
  '{"bar":{"layout":{"right":[{"id":"omarchy.battery","showPercentage":true}]}}}' \
  'mosquito.battery'

# A single correct merged entry is a no-op: no rewrite, no backup.
printf '{"bar":{"layout":{"right":[{"id":"mosquito.battery","showPercentage":true}]}}}' >"$tmp/ok-battery.json"
before="$(sha256sum "$tmp/ok-battery.json" | cut -d' ' -f1)"
mq_normalize_bar_widget "$tmp/ok-battery.json" kapeq_mosquito power mosquito.battery >/dev/null
after="$(sha256sum "$tmp/ok-battery.json" | cut -d' ' -f1)"
[[ $before == $after ]] || { echo "a lone merged battery widget was rewritten"; exit 1; }
compgen -G "$tmp/ok-battery.json.bak*" >/dev/null && { echo "a lone merged battery widget made a backup"; exit 1; }

# A single correct entry is a no-op: no rewrite, no backup.
for suffix in power indicators; do
  printf '{"bar":{"layout":{"right":[{"id":"mosquito.%s"}]}}}' "$suffix" >"$tmp/ok-$suffix.json"
  before="$(sha256sum "$tmp/ok-$suffix.json" | cut -d' ' -f1)"
  mq_normalize_bar_widget "$tmp/ok-$suffix.json" kapeq_mosquito "$suffix" >/dev/null
  after="$(sha256sum "$tmp/ok-$suffix.json" | cut -d' ' -f1)"
  [[ $before == $after ]] || { echo "a lone $suffix widget was rewritten"; exit 1; }
  if compgen -G "$tmp/ok-$suffix.json.bak*" >/dev/null; then
    echo "a lone $suffix widget made a backup"; exit 1
  fi
done

echo ok
