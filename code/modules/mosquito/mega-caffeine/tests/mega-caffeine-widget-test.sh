#!/usr/bin/env bash
# Self-check for code/lib/mega-caffeine-widget.bash: the widget files are
# installed, the native indicators sit immediately before it with StayAwake
# removed, a second run changes nothing, and removal restores the native
# indicator only when the other module is gone.
set -euo pipefail

module="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo="$(cd "$module/../../../.." && pwd)"
src="$module/omarchy-plugins/mosquito.mega-caffeine"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/home/.config/omarchy" "$tmp/bin"
printf '{"bar":{"layout":{"centerBegin":[],"right":[]}}}\n' >"$tmp/home/.config/omarchy/shell.json"
# The helper must never drive the caller's live shell here. A failing
# `omarchy plugin remove` exercises the rm -rf fallback.
printf '#!/bin/sh\nexit 1\n' >"$tmp/bin/omarchy"
printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/omarchy-shell"
chmod +x "$tmp/bin/omarchy" "$tmp/bin/omarchy-shell"
export PATH="$tmp/bin:$PATH"

# shellcheck source=../../../lib/mega-caffeine-widget.bash
source "$repo/code/lib/mega-caffeine-widget.bash"

fail() { echo "mega-caffeine-widget-test: $*" >&2; exit 1; }
ids() { jq -r '[.bar.layout[][] | if type == "string" then . else .id end] | join(",")' "$1"; }
plugin="$tmp/home/.config/omarchy/plugins/mosquito.mega-caffeine"

# 1. Install into an empty layout: the widget is placed and the native
#    indicators appear just before it with the native StayAwake removed.
ensure_mega_caffeine_widget "$tmp/home" "$src" >/dev/null
[[ -f $plugin/BarWidget.qml && -f $plugin/Confirm.qml && -f $plugin/manifest.json ]] \
  || fail "plugin files missing"
[[ "$(jq -r .id "$plugin/manifest.json")" == "mosquito.mega-caffeine" ]] || fail "wrong manifest id"
[[ "$(jq -r '.kinds | join(",")' "$plugin/manifest.json")" == "bar-widget,overlay" ]] || fail "wrong kinds"
[[ "$(jq -r .entryPoints.barWidget "$plugin/manifest.json")" == "BarWidget.qml" ]] || fail "wrong barWidget entry point"
[[ "$(jq -r .omarchy.clonedFrom "$plugin/manifest.json")" == "null" ]] || fail "old clone metadata left behind"
layout="$tmp/home/.config/omarchy/shell.json"
[[ "$(ids "$layout")" == "omarchy.indicators,mosquito.mega-caffeine" ]] || fail "native indicators not adjacent before the widget"
[[ "$(jq -r '.bar.layout.centerBegin[0].items | join(",")' "$layout")" \
   == "PasswordlessSudo,ScreenRecording,RemoteSession,Reminder,NightLight,Dnd" ]] \
  || fail "native StayAwake not removed from the default items"
[[ "$(jq -r '.bar.layout.centerBegin[1] | has("alwaysShow")' "$layout")" == "false" ]] \
  || fail "old clone alwaysShow left on the widget"

# 2. Idempotent: a second run leaves shell.json byte for byte alone.
before="$(sha256sum "$layout")"
ensure_mega_caffeine_widget "$tmp/home" "$src" >/dev/null
[[ "$(sha256sum "$layout")" == "$before" ]] || fail "second run rewrote shell.json"

# 3. Native indicators elsewhere with StayAwake selected: moved next to the
#    widget and filtered, keeping the user's other choices.
cat >"$layout" <<'JSON'
{"bar":{"layout":{"centerBegin":[{"id":"mosquito.mega-caffeine","items":["StayAwake"]}],"right":[{"id":"omarchy.indicators","items":["StayAwake","Dnd"],"alwaysShow":true}]}}}
JSON
ensure_mega_caffeine_widget "$tmp/home" "$src" >/dev/null
[[ "$(ids "$layout")" == "omarchy.indicators,mosquito.mega-caffeine" ]] || fail "native indicators not moved before the widget"
[[ "$(jq -r '.bar.layout.centerBegin[0].items | join(",")' "$layout")" == "Dnd" ]] || fail "native items not filtered"
[[ "$(jq -r '.bar.layout.centerBegin[0].alwaysShow' "$layout")" == "true" ]] || fail "native settings not preserved"
[[ "$(jq -r '.bar.layout.centerBegin[1] | has("items")' "$layout")" == "false" ]] || fail "old clone items left on the widget"

# 4. Removal while live-mode is still installed keeps the shared widget.
touch "$tmp/livemode"
remove_mega_caffeine_widget_if_unused "$tmp/home" "$tmp/livemode" >/dev/null
[[ -d $plugin ]] || fail "widget removed while live mode still needs it"

# 5. Removal with no other module drops the widget and gives StayAwake back to
#    the native indicators by dropping the inline items key.
remove_mega_caffeine_widget_if_unused "$tmp/home" "$tmp/nothing" >/dev/null
[[ -d $plugin ]] && fail "widget left behind"
[[ "$(jq -r '.bar.layout.centerBegin[0] | has("items")' "$layout")" == "false" ]] \
  || fail "native StayAwake not restored"
[[ "$(ids "$layout")" == "omarchy.indicators" ]] || fail "native indicators should stay in the bar"

echo "mega-caffeine-widget-test: ok"
