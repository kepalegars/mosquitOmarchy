#!/usr/bin/env bash
# Shared indicators clone for mega-caffeine and live-mode.
#
# Omarchy has no extension point for third-party indicators: the widget loads
# every indicator from its own "indicators/" directory, and the plugin id is
# also its IPC target, so the native widget and a second indicators widget
# cannot coexist. The only way to put the Mega caffeine / Live Mode state on
# the stay-awake indicator is therefore one clone of omarchy.indicators with a
# single overlaid file: indicators/StayAwake.qml.
#
# Everything else is re-copied from the installed Omarchy on every run, so
# Omarchy keeps owning Indicators.qml, the indicator list, the settings schema
# and every other indicator. Removing the clone restores omarchy.indicators and
# its bar entry automatically (`omarchy plugin remove mosquito.mega-caffeine`).
#
# Usage: ensure_indicators_clone HOME OVERLAY_DIR
#   OVERLAY_DIR must contain indicators/StayAwake.qml.
# Returns 0 when the clone is installed (or shell.json is absent = not Omarchy).

INDICATORS_CLONE_ID="mosquito.mega-caffeine"
INDICATORS_SOURCE_ID="omarchy.indicators"

# shellcheck source=plugin-clone.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/plugin-clone.bash"

ensure_indicators_clone() {
  local home="$1" overlay="$2"
  local dir="$home/.config/omarchy/plugins/$INDICATORS_CLONE_ID"
  local shell_json="$home/.config/omarchy/shell.json"
  local info src manifest tmp f
  [[ -f $shell_json ]] || return 0
  command -v jq >/dev/null 2>&1 || return 1
  info="$(omarchy-plugin-catalog 2>/dev/null |
    jq -r --arg id "$INDICATORS_SOURCE_ID" '.[] | select(.id == $id) | [.sourceDir, .manifestPath] | @tsv')" || return 1
  [[ -n $info ]] || return 1
  IFS=$'\t' read -r src manifest <<<"$info"
  [[ -f "$src/Indicators.qml" && -f $manifest && -f "$overlay/indicators/StayAwake.qml" \
     && -f "$overlay/Confirm.qml" ]] || return 1

  # widgets/Indicators.qml, not the plugin root: the native file loads its
  # indicators with Qt.resolvedUrl("../indicators/<id>.qml"), so the widget
  # document must stay one level above them. At the root, "../indicators"
  # pointed outside the plugin and every icon failed to load.
  mkdir -p "$dir/widgets" "$dir/indicators"
  cp "$src/Indicators.qml" "$dir/widgets/Indicators.qml"
  rm -f "$dir/Indicators.qml"
  cp "$overlay/Confirm.qml" "$dir/Confirm.qml"
  for f in "$src/../indicators"/*.qml; do
    [[ -f $f ]] && cp "$f" "$dir/indicators/"
  done
  cp "$overlay/indicators/StayAwake.qml" "$dir/indicators/StayAwake.qml"

  # Same shape `omarchy plugin clone` produces, with our id/name. clonedFrom
  # is what makes `omarchy plugin remove` restore omarchy.indicators.
  tmp="$(mktemp)"
  if ! jq --arg id "$INDICATORS_CLONE_ID" --arg name "Mega Caffeine" --arg srcId "$INDICATORS_SOURCE_ID" '
    .id = $id
    | .name = $name
    | .author = "Mosquito"
    | (if (.barWidget | type) == "object" then .barWidget.displayName = $name else . end)
    | .omarchy = ((if (.omarchy | type) == "object" then .omarchy else {} end) + { clonedFrom: $srcId })
    | del(.omarchy.clonePaths)
    | .kinds = (((.kinds // []) + ["overlay"]) | unique)
    | .entryPoints.barWidget = "widgets/Indicators.qml"
    | .entryPoints.overlay = "Confirm.qml"
    | .keepLoaded = true
  ' "$manifest" >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$dir/manifest.json"

  # Places the bar entry, disables the native source and records the restore
  # relationship. Idempotent when the entry is already there.
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
  omarchy plugin enable "$INDICATORS_CLONE_ID" >/dev/null 2>&1 || true
  # Health uses this stamp to tell an Omarchy update from a local edit.
  local up
  up="$(plugin_clone_source_hash "$INDICATORS_SOURCE_ID" 2>/dev/null || true)"
  [[ -n $up ]] && plugin_clone_write_stamp "$dir" "$up" >/dev/null 2>&1 || true
  echo "  ✓ Indicators clone $INDICATORS_CLONE_ID installed/refreshed"
}

# Called by a module uninstall: drop the shared clone only when the other module
# is gone too, so uninstalling one never breaks the other's indicator.
remove_indicators_clone_if_unused() {
  local home="$1" other="$2"
  [[ -e $other ]] && return 0
  omarchy plugin remove "$INDICATORS_CLONE_ID" --yes >/dev/null 2>&1 || {
    rm -rf "$home/.config/omarchy/plugins/$INDICATORS_CLONE_ID"
  }
  echo "  ✓ Indicators clone $INDICATORS_CLONE_ID removed"
}
