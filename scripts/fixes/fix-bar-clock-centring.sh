#!/usr/bin/env bash
# fix-bar-clock-centring.sh — stop the indicator reveal from shoving the clock sideways.
#
# Symptom: moving the pointer near the Omarchy bar reveals the hidden indicators
# (night light, stay-awake, DND…). If the clock visibly slides off centre the
# moment they appear, and snaps back when they go, the bar looks broken.
#
# Cause: mosquito.indicators sits in the bar's CENTRE section, immediately left
# of the clock — and that clock is the section's centreAnchor, the thing the
# centre is measured from. The widget used to grow with its revealed icons:
#
#     implicitWidth: … : activeHorizontalBlock.implicitWidth + inactiveHorizontalArea.implicitWidth
#
# and inactiveHorizontalArea's implicitWidth went 0 → the full width of the
# hidden indicators on hover. So revealing them widened the centre section and
# pushed its own anchor sideways.
#
# This script takes the revealed icons out of the layout entirely: they are
# anchored BESIDE the bar's Row, with their right edge on the active block's
# left edge, so the reveal opens to the LEFT and the Row's width never changes.
#
# Idempotent and reversible. It patches ONE file in the installed plugin and
# keeps a .bak, so the previous version can be restored from the same folder.
set -euo pipefail

G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; B='\033[1;34m'; N='\033[0m'
msg(){ printf "${B}==>${N} %s\n" "$*"; }
ok(){  printf " ${G}✓${N} %s\n" "$*"; }
warn(){ printf " ${Y}!${N} %s\n" "$*"; }
err(){ printf "${R}✗${N} %s\n" "$*" >&2; }

PLUGIN="$HOME/.config/omarchy/plugins/mosquito.indicators/Indicators.qml"
BAK="$PLUGIN.bak-clock-centring"

# The exact symptom, as a precondition rather than an assumption: the widget's
# footprint must currently include the revealed icons. If it does not, the
# upstream or another fix already changed it and this script must not pile a
# second edit on top.
symptom_present(){
  grep -q 'activeHorizontalBlock.implicitWidth + inactiveHorizontalArea.implicitWidth' "$PLUGIN"
}

apply(){
  [[ -f $PLUGIN ]] || { err "not found: $PLUGIN"; err "Is mosquito.indicators installed?"; return 1; }

  if grep -q 'id: inactiveHorizontalArea' "$PLUGIN" \
     && ! symptom_present; then
    ok "already applied — nothing to do"
    return 0
  fi
  symptom_present || { warn "this plugin does not look like the one this fix targets; leaving it alone"; return 1; }

  cp -n "$PLUGIN" "$BAK" 2>/dev/null || true
  msg "Patching $PLUGIN (previous version kept as $(basename "$BAK"))"

  python3 - "$PLUGIN" <<'PY'
import re, sys

path = sys.argv[1]
src = open(path, encoding="utf-8").read()

# 1. the footprint must stop counting the revealed icons
old_width = """    : activeHorizontalBlock.implicitWidth + inactiveHorizontalArea.implicitWidth"""
new_width = """    : activeHorizontalBlock.implicitWidth"""
assert src.count(old_width) == 1, "footprint line not found exactly once"
src = src.replace(old_width, new_width, 1)

# 2. lift the revealed area out of the Row and anchor it beside it
m = re.search(
    r"\n    Item \{\n      id: inactiveHorizontalArea\n.*?\n    \}\n",
    src, re.S)
assert m, "the revealed-area block was not found inside the Row"
src = src[:m.start()] + "\n" + src[m.end():]

anchor_block = """
  // Revealed indicators, deliberately NOT inside horizontalIndicators.
  //
  // In the Row they widened it whenever they appeared, and everything to the right
  // — the clock, which is the centre anchor — moved. Anchored here with their
  // RIGHT edge on the Row's left edge (the active block's left edge), the same
  // reveal opens towards the left instead and the Row never changes width.
  Item {
    id: inactiveHorizontalArea

    visible: !root.vertical
    anchors.right: horizontalIndicators.left
    anchors.verticalCenter: parent.verticalCenter
    width: root.revealInactiveIndicators ? inactiveHorizontalBlock.implicitWidth : 0
    height: Math.max(inactiveHorizontalBlock.implicitHeight, root.barSize)
    clip: true

    IndicatorBlock {
      id: inactiveHorizontalBlock
      anchors.verticalCenter: parent.verticalCenter
      indicatorsModule: root
      indicatorEntries: root.indicatorEntries
      indicatorBlock: "inactive"
      horizontal: true
      reportActiveState: !root.vertical
    }

    HoverHandler {
      onHoveredChanged: root.setIndicatorAreaHovered(hovered)
    }
  }
"""
# just before the vertical Column, which is the other layout's entry point
marker = "\n  Column {\n    id: verticalIndicators"
assert src.count(marker) == 1, "vertical block not found exactly once"
src = src.replace(marker, anchor_block + marker, 1)

open(path, "w", encoding="utf-8").write(src)
print("patched")
PY
  ok "patch applied — restart the shell to see it: omarchy-restart-shell"
}

revert(){
  [[ -f $BAK ]] || { err "no backup to restore: $BAK"; return 1; }
  cp "$BAK" "$PLUGIN"
  rm -f "$BAK"
  ok "restored — restart the shell: omarchy-restart-shell"
}

status(){
  [[ -f $PLUGIN ]] || { err "not found: $PLUGIN"; return 1; }
  if symptom_present; then
    echo "not applied — the revealed indicators still take part in the bar's layout"
  else
    echo "applied — the revealed indicators open to the left without moving the clock"
  fi
  [[ -f $BAK ]] && echo "a previous version is kept as $(basename "$BAK")"
}

main(){
  case "${1:-}" in
    --revert) revert ;;
    --status) status ;;
    -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//' ;;
    *)        apply ;;
  esac
}

main "$@"