#!/usr/bin/env bash
# Self-check for code/lib/mega-caffeine-indicator.bash: the coffee indicator is
# installed inside omarchy.indicators (StayAwake swapped in place), the native
# widget stays enabled, a second run changes nothing, and removal gives the
# native StayAwake entry back.
set -euo pipefail

module="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo="$(cd "$module/../../../.." && pwd)"
src="$module/omarchy-plugins/mosquito.mega-caffeine"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/home/.config/omarchy" "$tmp/bin"
# A machine coming from the retired indicators clone and the separate widget:
# the native widget is switched off, clone bookkeeping is stale, and the old
# widget still has a bar entry.
printf '{"bar":{"layout":{"centerBegin":[{"id":"mosquito.mega-caffeine"}],"right":[{"id":"omarchy.indicators","items":["StayAwake","Dnd"],"alwaysShow":true}]}},"disabledPlugins":["omarchy.indicators","omarchy.battery"],"cloneSourceRestores":["mosquito.mega-caffeine","mosquito.battery"]}\n' >"$tmp/home/.config/omarchy/shell.json"
# The helper must never drive the caller's live shell here.
printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/omarchy-shell"
chmod +x "$tmp/bin/omarchy-shell"
export PATH="$tmp/bin:$PATH"

# shellcheck source=../../../lib/mega-caffeine-indicator.bash
source "$repo/code/lib/mega-caffeine-indicator.bash"

fail() { echo "mega-caffeine-indicator-test: $*" >&2; exit 1; }
layout="$tmp/home/.config/omarchy/shell.json"
plugin="$tmp/home/.config/omarchy/plugins/mosquito.mega-caffeine"
rel_id="$(python3 -c 'import sys; print("../../" * 16 + sys.argv[1].strip("/") + "/.config/omarchy/plugins/mosquito.mega-caffeine/MegaCaffeine")' "$tmp/home")"

# 1. Install onto the clone-era state: the old widget entry is dropped, the
#    native widget keeps its place and settings, and StayAwake becomes the
#    coffee indicator in the same position.
ensure_mega_caffeine_indicator "$tmp/home" "$src" >/dev/null
[[ -f $plugin/MegaCaffeine.qml && -f $plugin/Confirm.qml && -f $plugin/manifest.json ]] \
  || fail "plugin files missing"
[[ -e $plugin/BarWidget.qml ]] && fail "old bar widget left behind"
[[ "$(jq -r .id "$plugin/manifest.json")" == "mosquito.mega-caffeine" ]] || fail "wrong manifest id"
[[ "$(jq -r '.kinds | join(",")' "$plugin/manifest.json")" == "overlay" ]] || fail "wrong kinds"
[[ "$(jq -r .entryPoints.overlay "$plugin/manifest.json")" == "Confirm.qml" ]] || fail "wrong overlay entry point"
[[ "$(jq -r '.bar.layout.centerBegin | length' "$layout")" == "0" ]] || fail "old widget entry kept"
[[ "$(jq -r '.bar.layout.right[0].id' "$layout")" == "omarchy.indicators" ]] || fail "native indicators moved"
[[ "$(jq -r --arg id "$rel_id" '.bar.layout.right[0].items[0] == $id and .bar.layout.right[0].items[1] == "Dnd"' "$layout")" == "true" ]] \
  || fail "StayAwake not swapped for the coffee indicator"
[[ "$(jq -r '.bar.layout.right[0].alwaysShow' "$layout")" == "true" ]] || fail "native settings not preserved"
[[ "$(jq -r '.disabledPlugins | join(",")' "$layout")" == "omarchy.battery" ]] \
  || fail "native indicators left disabled"
[[ "$(jq -r '.cloneSourceRestores | join(",")' "$layout")" == "mosquito.battery" ]] \
  || fail "stale clone source restore left behind"
[[ "$(jq -r --arg id mosquito.mega-caffeine '.plugins[] | select(.id == $id) | .id' "$layout")" == "mosquito.mega-caffeine" ]] \
  || fail "overlay plugin not enabled"

# 2. Idempotent: a second run leaves shell.json byte for byte alone.
before="$(sha256sum "$layout")"
ensure_mega_caffeine_indicator "$tmp/home" "$src" >/dev/null
[[ "$(sha256sum "$layout")" == "$before" ]] || fail "second run rewrote shell.json"

# 3. Removal drops the overlay and gives StayAwake its place back, without
#    touching the native widget itself.
remove_mega_caffeine_indicator "$tmp/home" >/dev/null
[[ -d $plugin ]] && fail "plugin left behind"
[[ "$(jq -r '.bar.layout.right[0].items | join(",")' "$layout")" == "StayAwake,Dnd" ]] \
  || fail "native StayAwake not restored"
[[ "$(jq -r '.bar.layout.right[0].id' "$layout")" == "omarchy.indicators" ]] \
  || fail "native indicators should stay in the bar"
[[ "$(jq -r '[.plugins // [] | .[] | select(.id == "mosquito.mega-caffeine")] | length' "$layout")" == "0" ]] \
  || fail "overlay plugin still enabled"

# 4. A layout without the indicators widget: it is added with the default
#    selection and the coffee indicator at the end, then removal restores the
#    default StayAwake list.
printf '{"bar":{"layout":{"centerBegin":[],"right":[]}}}\n' >"$layout"
ensure_mega_caffeine_indicator "$tmp/home" "$src" >/dev/null
[[ "$(jq -r '.bar.layout.centerBegin[0].id' "$layout")" == "omarchy.indicators" ]] \
  || fail "indicators widget not added"
[[ "$(jq -r --arg id "$rel_id" '.bar.layout.centerBegin[0].items[-1] == $id' "$layout")" == "true" ]] \
  || fail "coffee indicator not last in the default list"
remove_mega_caffeine_indicator "$tmp/home" >/dev/null
[[ "$(jq -r '.bar.layout.centerBegin[0].items | join(",")' "$layout")" \
   == "PasswordlessSudo,ScreenRecording,RemoteSession,Reminder,NightLight,Dnd,StayAwake" ]] \
  || fail "default StayAwake list not restored"

echo "mega-caffeine-indicator-test: ok"
