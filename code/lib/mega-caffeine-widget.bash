#!/usr/bin/env bash
# Shared Mega Caffeine bar widget for mega-caffeine and live-mode.
#
# Omarchy's indicators widget is first-party and cannot be extended by a
# third-party plugin, so the coffee icon is a widget of its own. The native
# `omarchy.indicators` stays in the bar; this helper keeps it next to the
# coffee widget and removes its own StayAwake entry, so there is exactly one
# stay-awake icon and it knows about coffee mode / live mode.
#
# Usage: ensure_mega_caffeine_widget HOME SOURCE_DIR
#   SOURCE_DIR contains BarWidget.qml, Confirm.qml and manifest.json.
# Returns 0 when installed (or shell.json is absent = not Omarchy).

MEGA_CAFFEINE_PLUGIN_ID="mosquito.mega-caffeine"
NATIVE_INDICATORS_ID="omarchy.indicators"

# shell.json layout: put the native indicators immediately before the coffee
# widget (adopting its entry and settings if it is already elsewhere), drop
# StayAwake from its inline items, and clear the old clone's settings from the
# coffee entry. No-op when the file already has this shape.
_mega_caffeine_layout() {
  local shell_json="$1"
  python3 - "$shell_json" "$MEGA_CAFFEINE_PLUGIN_ID" "$NATIVE_INDICATORS_ID" <<'PY'
import json, os, sys

path, widget_id, native_id = sys.argv[1], sys.argv[2], sys.argv[3]
# shortcut: a fixed list, so an indicator Omarchy adds later stays hidden
# until it is added here too (only the "all indicators" case; a user's own
# selection is preserved).
DEFAULT_ITEMS = ["PasswordlessSudo", "ScreenRecording", "RemoteSession",
                 "Reminder", "NightLight", "Dnd"]

try:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
except (OSError, ValueError):
    sys.exit(1)
layout = data.get("bar", {}).get("layout")
if not isinstance(layout, dict):
    sys.exit(0)
before = json.dumps(data, sort_keys=True)


def entry_id(item):
    if isinstance(item, str):
        return item
    if isinstance(item, dict):
        return item.get("id")
    return None


def find(plugin_id):
    for section, items in layout.items():
        if not isinstance(items, list):
            continue
        for index, item in enumerate(items):
            if entry_id(item) == plugin_id:
                return section, index
    return None


def with_native_items(entry):
    if not isinstance(entry, dict):
        return {"id": native_id, "items": list(DEFAULT_ITEMS)}
    items = entry.get("items")
    if not isinstance(items, list) or not items:
        items = list(DEFAULT_ITEMS)
    else:
        items = [item for item in items if entry_id(item) != "StayAwake"]
        if not items:
            items = list(DEFAULT_ITEMS)
    entry["items"] = items
    return entry


widget_at = find(widget_id)
if widget_at is None:
    # omarchy plugin enable normally places it; if the shell is not running,
    # fall back to the centre so the widget still shows up.
    section = "centerBegin" if isinstance(layout.get("centerBegin"), list) else next(
        (name for name, items in layout.items() if isinstance(items, list)), None)
    if section is None:
        sys.exit(0)
    layout[section].append({"id": widget_id})
    widget_at = (section, len(layout[section]) - 1)

native_at = find(native_id)
native_entry = {"id": native_id}
if native_at is not None:
    section, index = native_at
    native_entry = layout[section].pop(index)
    if section == widget_at[0] and index < widget_at[1]:
        widget_at = (section, widget_at[1] - 1)

layout[widget_at[0]].insert(widget_at[1], with_native_items(native_entry))

for items in layout.values():
    if not isinstance(items, list):
        continue
    for item in items:
        if isinstance(item, dict) and item.get("id") == widget_id:
            for key in ("items", "indicators", "alwaysShow"):
                item.pop(key, None)

if json.dumps(data, sort_keys=True) == before:
    sys.exit(0)

tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
os.replace(tmp, path)
PY
}

ensure_mega_caffeine_widget() {
  local home="$1" src="$2"
  local dir="$home/.config/omarchy/plugins/$MEGA_CAFFEINE_PLUGIN_ID"
  local shell_json="$home/.config/omarchy/shell.json"
  [[ -f $shell_json ]] || return 0
  [[ -f "$src/BarWidget.qml" && -f "$src/Confirm.qml" && -f "$src/manifest.json" ]] || return 1

  mkdir -p "$dir"
  cp "$src/BarWidget.qml" "$src/Confirm.qml" "$src/manifest.json" "$dir/"
  # Files from the old omarchy.indicators clone: the plugin is a plain bar
  # widget now, and a stale widgets/ or indicators/ only produces QML warnings.
  rm -rf "$dir/indicators" "$dir/widgets" "$dir/.mosquito-upstream"

  # Discovery first: enable silently fails for a plugin the shell has not seen.
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
  omarchy plugin enable "$MEGA_CAFFEINE_PLUGIN_ID" >/dev/null 2>&1 || true

  _mega_caffeine_layout "$shell_json" || return 1
  echo "  ✓ Mega Caffeine bar widget installed (native indicators kept)"
}

# Called by a module uninstall: drop the shared widget only when the other
# module is gone too, then give StayAwake back to omarchy.indicators.
remove_mega_caffeine_widget_if_unused() {
  local home="$1" other="$2"
  local shell_json="$home/.config/omarchy/shell.json"
  [[ -e $other ]] && return 0

  omarchy plugin remove "$MEGA_CAFFEINE_PLUGIN_ID" --yes >/dev/null 2>&1 || {
    rm -rf "$home/.config/omarchy/plugins/$MEGA_CAFFEINE_PLUGIN_ID"
  }

  [[ -f $shell_json ]] || return 0
  python3 - "$shell_json" "$NATIVE_INDICATORS_ID" "$MEGA_CAFFEINE_PLUGIN_ID" <<'PY'
import json, os, sys

path, native_id, widget_id = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
except (OSError, ValueError):
    sys.exit(0)
layout = data.get("bar", {}).get("layout")
if not isinstance(layout, dict):
    sys.exit(0)
changed = False
for section, items in layout.items():
    if not isinstance(items, list):
        continue
    kept = [item for item in items
            if not (isinstance(item, dict) and item.get("id") == widget_id)]
    if len(kept) != len(items):
        layout[section] = kept
        changed = True
    for item in kept:
        if isinstance(item, dict) and item.get("id") == native_id and "items" in item:
            del item["items"]
            changed = True
if not changed:
    sys.exit(0)
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
os.replace(tmp, path)
PY
  echo "  ✓ Mega Caffeine bar widget removed (native StayAwake restored)"
}
