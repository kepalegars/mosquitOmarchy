#!/bin/bash
# fix-bar-center-anchor.sh — give the Omarchy bar's centre section a real anchor.
#
# Symptom: the hidden indicators (night light, stay-awake, DND…) reveal when the
# pointer nears the bar and the clock visibly slides sideways, then snaps back
# when they hide — the bar reads as broken. (The old workaround for this made the
# revealed icons overhang the widget instead; they then hid behind the left
# region and stopped taking clicks.)
#
# Cause: shell.json's `bar.centerAnchor` names a widget that is NOT in
# `bar.layout.center` — usually a leftover from a plugin that was removed or
# renamed (a calendar, say). With no valid anchor the centre section centres the
# WHOLE group and reflows it as one unit, so anything that widens the group (like
# revealing indicators) shoves the clock. A valid anchor (omarchy.clock, the
# default) makes the section measure FROM that widget, so the indicators list
# grows to its left and the clock stays put.
#
# Idempotent and reversible: the previous file is kept next to it as
# shell.json.bak-center-anchor.
set -uo pipefail

info() { echo -e "\033[1;34m==>\033[0m $*"; }
ok()   { echo -e "\033[1;32m ✓\033[0m $*"; }
warn() { echo -e "\033[1;33m !\033[0m $*"; }
err()  { echo -e "\033[1;31m✗\033[0m $*" >&2; }

CONF="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/shell.json"
BAK="$CONF.bak-center-anchor"

# inspect  -> one line on stdout: EMPTY | OK <anchor> | FIXED <old> <new>
# The edit (and the backup) happens here so the shell only has to report it.
inspect(){
python3 - "$CONF" "$BAK" <<'PY'
import json, os, shutil, sys

conf, bak = sys.argv[1], sys.argv[2]
with open(conf, encoding="utf-8") as fh:
    data = json.load(fh)

bar = data.get("bar") or {}
layout = bar.get("layout") or {}
center = layout.get("center") or []

def entry_id(e):
    if isinstance(e, str):
        return e
    if isinstance(e, dict):
        v = e.get("id")
        return str(v) if v not in (None, "") else ""
    return ""

ids = [i for i in (entry_id(e) for e in center) if i]
if not ids:
    print("EMPTY")
    sys.exit(0)

anchor = bar.get("centerAnchor")
if anchor in ids:
    print(f"OK {anchor}")
    sys.exit(0)

chosen = "omarchy.clock" if "omarchy.clock" in ids else ids[0]
if not os.path.exists(bak):
    shutil.copy2(conf, bak)
bar["centerAnchor"] = chosen
data["bar"] = bar
tmp = conf + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
os.replace(tmp, conf)
print(f"FIXED {anchor if anchor not in (None, '') else '(unset)'} {chosen}")
PY
}

apply(){
  [[ -f $CONF ]] || { err "not found: $CONF"; return 1; }
  command -v python3 >/dev/null 2>&1 || { err "python3 is required"; return 1; }

  echo "=== Fix Omarchy bar centre anchor ==="
  local result
  result="$(inspect)" || { err "could not read $CONF"; return 1; }

  case $result in
    EMPTY)
      warn "shell.json has no centre modules — nothing to anchor." ;;
    "OK "*)
      ok "Centre anchor is already valid: ${result#OK }." ;;
    FIXED\ *)
      local old new
      read -r _ old new <<<"$result"
      ok "centerAnchor '${old}' -> '${new}' (previous file kept as $(basename "$BAK"))."
      warn "shell.json hot-reloads on save — if the clock still slides, run: omarchy restart shell" ;;
    *)
      err "unexpected result: $result"; return 1 ;;
  esac
}

revert(){
  [[ -f $BAK ]] || { err "no backup to restore: $BAK"; return 1; }
  cp "$BAK" "$CONF" && rm -f "$BAK"
  ok "restored $(basename "$CONF") — run: omarchy restart shell"
}

status(){
  [[ -f $CONF ]] || { err "not found: $CONF"; return 1; }
  local result
  result="$(python3 - "$CONF" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
bar = data.get("bar") or {}
center = ((bar.get("layout") or {}).get("center")) or []
ids = [e if isinstance(e, str) else (str(e.get("id")) if isinstance(e, dict) and e.get("id") not in (None, "") else "") for e in center]
ids = [i for i in ids if i]
if not ids:
    print("EMPTY")
elif bar.get("centerAnchor") in ids:
    print("OK " + bar.get("centerAnchor"))
else:
    print("STALE " + str(bar.get("centerAnchor")))
PY
)"
  case $result in
    EMPTY) echo "no centre modules — nothing to anchor" ;;
    "OK "*) echo "valid — centre anchor is ${result#OK }" ;;
    "STALE "*) echo "stale — centreAnchor '${result#STALE }' is not in bar.layout.center" ;;
    *) echo "unknown ($result)" ;;
  esac
  if [[ -f $BAK ]]; then echo "a previous version is kept as $(basename "$BAK")"; fi
  return 0
}

main(){
  case "${1:-}" in
    --revert) revert ;;
    --status) status ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//' ;;
    *)        apply ;;
  esac
}

main "$@"
