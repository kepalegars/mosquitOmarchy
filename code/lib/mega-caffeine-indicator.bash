#!/usr/bin/env bash
# Mega Caffeine's coffee indicator.
#
# omarchy.indicators loads every indicator from its own "indicators/" dir, so a
# third-party indicator cannot be a plugin of its own. This helper keeps the
# coffee mug inside that widget: the QML stays in our plugin dir and the
# widget's inline items list names it by a relative path from the native
# indicators dir. The native widget stays enabled and untouched; only its
# StayAwake entry is swapped for the coffee one (same glyph, native tooltips,
# plus the red / blinking state of coffee and Live Mode).
#
# Usage: ensure_mega_caffeine_indicator HOME SOURCE_DIR
#   SOURCE_DIR contains MegaCaffeine.qml, Confirm.qml and manifest.json.
# Returns 0 when installed (or shell.json is absent = not Omarchy).

MEGA_CAFFEINE_PLUGIN_ID="mosquito.mega-caffeine"
NATIVE_INDICATORS_ID="omarchy.indicators"

# The native widget loads "../indicators/<id>.qml". Enough "../" to reach the
# filesystem root from that dir, then the absolute path: extra "../" clamp at
# the root, so the id keeps working if Omarchy moves the widget deeper.
# shortcut: the loader has no extension point; if Omarchy changes that
# resolution, the icon stops loading until this helper is updated.
_mega_caffeine_layout() {
  local shell_json="$1" home="$2"
  python3 - "$shell_json" "$home" "$MEGA_CAFFEINE_PLUGIN_ID" "$NATIVE_INDICATORS_ID" <<'PY'
import json, os, sys

path, home, widget_id, native_id = sys.argv[1:5]
rel_id = ("../../" * 16 + home.strip("/") + "/.config/omarchy/plugins/"
          + widget_id + "/MegaCaffeine")
NATIVE_DEFAULT = ["PasswordlessSudo", "ScreenRecording", "RemoteSession",
                  "Reminder", "NightLight", "Dnd", "StayAwake"]

try:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
except (OSError, ValueError):
    sys.exit(1)
bar = data.get("bar")
layout = bar.get("layout") if isinstance(bar, dict) else None
if not isinstance(layout, dict):
    sys.exit(0)
before = json.dumps(data, sort_keys=True)


def entry_id(item):
    if isinstance(item, str):
        return item
    if isinstance(item, dict):
        return item.get("id")
    return None


# The coffee icon is an indicator now: drop the old separate widget entry.
for section, items in layout.items():
    if isinstance(items, list):
        layout[section] = [item for item in items if entry_id(item) != widget_id]

# Find the native indicators widget, or add it to the centre.
location = None
for section, items in layout.items():
    if not isinstance(items, list):
        continue
    for index, item in enumerate(items):
        if entry_id(item) == native_id:
            location = (section, index)
            break
    if location:
        break

if location is None:
    section = "centerBegin" if isinstance(layout.get("centerBegin"), list) else next(
        (name for name, items in layout.items() if isinstance(items, list)), None)
    if section is None:
        sys.exit(0)
    layout[section].append({"id": native_id})
    location = (section, len(layout[section]) - 1)

section, index = location
entry = layout[section][index]
if isinstance(entry, str):
    entry = {"id": entry}
    layout[section][index] = entry

# StayAwake becomes the coffee indicator in place; the rest of the user's
# selection and the widget settings are preserved.
items = entry.get("items")
if not (isinstance(items, list) and items):
    items = list(NATIVE_DEFAULT)
merged = []
placed = False
for item in items:
    if entry_id(item) in ("StayAwake", rel_id):
        if not placed:
            merged.append(rel_id)
            placed = True
        continue
    merged.append(item)
if not placed:
    merged.append(rel_id)
entry["items"] = merged

# The retired clone switched the native widget off and left clone bookkeeping.
disabled = data.get("disabledPlugins")
if isinstance(disabled, list):
    kept = [entry for entry in disabled if entry not in (native_id, widget_id)]
    if kept:
        data["disabledPlugins"] = kept
    else:
        del data["disabledPlugins"]
restores = data.get("cloneSourceRestores")
if isinstance(restores, list):
    kept = [entry for entry in restores if entry != widget_id]
    if kept:
        data["cloneSourceRestores"] = kept
    else:
        del data["cloneSourceRestores"]

# Enable the overlay plugin by listing it, like `omarchy plugin enable` does:
# the command itself rewrites the bar layout from a stale snapshot.
plugins = data.get("plugins")
if not isinstance(plugins, list):
    plugins = []
if not any(entry_id(entry) == widget_id for entry in plugins):
    plugins.append({"id": widget_id})
data["plugins"] = plugins

if json.dumps(data, sort_keys=True) == before:
    sys.exit(0)

tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
os.replace(tmp, path)
PY
}

ensure_mega_caffeine_indicator() {
  local home="$1" src="$2"
  local dir="$home/.config/omarchy/plugins/$MEGA_CAFFEINE_PLUGIN_ID"
  local shell_json="$home/.config/omarchy/shell.json"
  [[ -f $shell_json ]] || return 0
  [[ -f "$src/MegaCaffeine.qml" && -f "$src/Confirm.qml" && -f "$src/manifest.json" ]] || return 1

  mkdir -p "$dir"
  cp "$src/MegaCaffeine.qml" "$src/Confirm.qml" "$src/manifest.json" "$dir/"
  # Leftovers from the old clone and the separate bar widget.
  rm -f "$dir/BarWidget.qml"
  rm -rf "$dir/indicators" "$dir/widgets" "$dir/.mosquito-upstream"

  _mega_caffeine_layout "$shell_json" "$home" || return 1
  # Discovery after the write: the registry rescans the plugin dirs.
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
  echo "  ✓ Mega Caffeine indicator installed (inside omarchy.indicators)"
}

# Called by the module uninstall: the coffee entry becomes StayAwake again and
# the overlay plugin goes away. Live mode never installs this; without it live
# mode simply has no coffee icon.
remove_mega_caffeine_indicator() {
  local home="$1"
  local shell_json="$home/.config/omarchy/shell.json"

  # No `omarchy plugin remove`: it rewrites the bar layout from a stale
  # snapshot. Drop the dir and the plugins[] entry, then let the shell rescan.
  rm -rf "$home/.config/omarchy/plugins/$MEGA_CAFFEINE_PLUGIN_ID"

  [[ -f $shell_json ]] || return 0
  python3 - "$shell_json" "$home" "$MEGA_CAFFEINE_PLUGIN_ID" "$NATIVE_INDICATORS_ID" <<'PY'
import json, os, sys

path, home, widget_id, native_id = sys.argv[1:5]
rel_id = ("../../" * 16 + home.strip("/") + "/.config/omarchy/plugins/"
          + widget_id + "/MegaCaffeine")

try:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
except (OSError, ValueError):
    sys.exit(0)
before = json.dumps(data, sort_keys=True)


def entry_id(item):
    if isinstance(item, str):
        return item
    if isinstance(item, dict):
        return item.get("id")
    return None


plugins = data.get("plugins")
if isinstance(plugins, list):
    kept = [entry for entry in plugins if entry_id(entry) != widget_id]
    if kept:
        data["plugins"] = kept
    else:
        del data["plugins"]

bar = data.get("bar")
layout = bar.get("layout") if isinstance(bar, dict) else None
if isinstance(layout, dict):
    for section, items in layout.items():
        if not isinstance(items, list):
            continue
        for item in items:
            if entry_id(item) != native_id or not isinstance(item, dict):
                continue
            entries = item.get("items")
            if not isinstance(entries, list) or rel_id not in entries:
                continue
            restored, kept = False, []
            for entry in entries:
                if entry_id(entry) == rel_id:
                    if not restored:
                        kept.append("StayAwake")
                        restored = True
                else:
                    kept.append(entry)
            item["items"] = kept

if json.dumps(data, sort_keys=True) == before:
    sys.exit(0)

tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
os.replace(tmp, path)
PY
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
  echo "  ✓ Mega Caffeine indicator removed (native StayAwake restored)"
}
