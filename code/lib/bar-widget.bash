#!/usr/bin/env bash
# Keep exactly ONE widget from a plugin family in the Omarchy bar layout,
# adopting the original plugin's entry in place so the replacement keeps its
# position and inline settings.
#
# Usage: mq_normalize_bar_widget <shell.json> <user> <suffix> [canonical-id] [extra-id…]
#
# <suffix> matches omarchy.<suffix>, custom.<suffix> and <user>.<suffix>.
# The merged battery widget also adopts the stock battery family, whose bar
# entry lived under a different suffix in older Omarchy releases.

mq_normalize_bar_widget(){
  python3 - "$1" "$2" "$3" "${@:4}" <<'PY'
import json, os, sys, time
path, user, suffix, extra = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
CANON = extra[0] if extra else "mosquito." + suffix
IDS = {"omarchy." + suffix, "custom." + suffix, user + "." + suffix, CANON, *extra}
if CANON == "mosquito.battery":
    IDS |= {"omarchy.battery", "custom.battery", user + ".battery"}
try:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
except (OSError, ValueError):
    sys.exit(0)
layout = data.get("bar", {}).get("layout")
if not isinstance(layout, dict):
    sys.exit(0)
positions = [(sec, i, it.get("id"))
             for sec, items in layout.items() if isinstance(items, list)
             for i, it in enumerate(items)
             if isinstance(it, dict) and it.get("id") in IDS]
if not positions:
    sys.exit(0)
if len(positions) == 1 and positions[0][2] == CANON:
    sys.exit(0)  # already correct: no write, no backup
# Keep the live clone when one is placed (prefer the right cluster, where the
# battery/power widget lives), else adopt the first matching entry.
canon = [p for p in positions if p[2] == CANON]
if canon:
    keep = next((p for p in canon if p[0] == "right"), canon[0])
else:
    keep = positions[0]
    layout[keep[0]][keep[1]]["id"] = CANON
drop = {p[:2] for p in positions} - {keep[:2]}
for section, items in layout.items():
    if isinstance(items, list) and any(s == section for s, _ in drop):
        gone = {i for s, i in drop if s == section}
        layout[section] = [it for i, it in enumerate(items) if i not in gone]
try:
    with open(path, encoding="utf-8") as src:
        backup = path + ".bak.fix-" + suffix + "-" + str(int(time.time()))
        with open(backup, "w", encoding="utf-8") as dst:
            dst.write(src.read())
except OSError:
    pass
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
os.replace(tmp, path)
print("changed")
PY
}
