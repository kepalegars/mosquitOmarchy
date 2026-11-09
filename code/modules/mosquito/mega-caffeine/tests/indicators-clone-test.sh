#!/usr/bin/env bash
# Self-check for code/lib/indicators-clone.bash: the clone is built from the
# installed Omarchy sources, our StayAwake overlay is the only owned file, the
# manifest points back at omarchy.indicators, and a second run is idempotent.
set -euo pipefail

module="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo="$(cd "$module/../../../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/home/.config/omarchy" "$tmp/bin"
printf '{}\n' >"$tmp/home/.config/omarchy/shell.json"
# Stub the shell CLI: the helper must never drive the caller's live shell here.
printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/omarchy"
printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/omarchy-shell"
chmod +x "$tmp/bin/omarchy" "$tmp/bin/omarchy-shell"
export PATH="$tmp/bin:$PATH"

# shellcheck source=../../../../lib/indicators-clone.bash
source "$repo/code/lib/indicators-clone.bash"

ensure_indicators_clone "$tmp/home" "$module/omarchy-plugins/mosquito.mega-caffeine"

dir="$tmp/home/.config/omarchy/plugins/mosquito.mega-caffeine"
fail() { echo "indicators-clone-test: $*" >&2; exit 1; }

[[ -f $dir/manifest.json ]] || fail "manifest missing"
[[ "$(jq -r .id "$dir/manifest.json")" == "mosquito.mega-caffeine" ]] || fail "wrong manifest id"
[[ "$(jq -r .omarchy.clonedFrom "$dir/manifest.json")" == "omarchy.indicators" ]] || fail "clonedFrom missing"
[[ "$(jq -r '.omarchy.clonePaths' "$dir/manifest.json")" == "null" ]] || fail "clonePaths left behind"
cmp -s /usr/share/omarchy/shell/plugins/bar/widgets/Indicators.qml "$dir/widgets/Indicators.qml" \
  || fail "Indicators.qml is not the native copy"
[[ -f $dir/Confirm.qml ]] || fail "Confirm.qml not embedded in the plugin"
[[ "$(jq -r .entryPoints.overlay "$dir/manifest.json")" == "Confirm.qml" ]] || fail "overlay entry point missing"
[[ "$(jq -r .entryPoints.barWidget "$dir/manifest.json")" == "widgets/Indicators.qml" ]] || fail "barWidget entry point wrong"
cmp -s "$module/omarchy-plugins/mosquito.mega-caffeine/indicators/StayAwake.qml" \
  "$dir/indicators/StayAwake.qml" || fail "StayAwake overlay not applied"
[[ $(find "$dir/indicators" -name '*.qml' | wc -l) -ge 7 ]] || fail "native indicators not copied"
[[ -f $dir/.mosquito-upstream ]] || fail "drift stamp missing"

before="$(find "$dir" -type f ! -name .mosquito-upstream -exec sha256sum {} + | sort)"
ensure_indicators_clone "$tmp/home" "$module/omarchy-plugins/mosquito.mega-caffeine"
after="$(find "$dir" -type f ! -name .mosquito-upstream -exec sha256sum {} + | sort)"
[[ $before == "$after" ]] || fail "second run changed the clone"

echo "indicators-clone-test: ok"
