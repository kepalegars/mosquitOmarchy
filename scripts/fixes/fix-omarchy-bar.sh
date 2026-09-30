#!/bin/bash
# fix-omarchy-bar.sh — bring back the Omarchy bar when it has been toggled off.
#
# Symptom: the bar is gone. `hyprctl layers` still shows `namespace: omarchy-bar`
# but its box sits just PAST the monitor edge (e.g. y = screen height) and
# `hyprctl monitors` reports reserved [0,0,0,0]: the bar slid off-screen because
# the toggle flag ~/.local/state/omarchy/toggles/bar-off exists (the shell hides
# it by moving it out instead of unmapping it).
#
# Clears the flag and asks the running shell to re-read it (the same nudge
# omarchy-toggle-bar uses; the toggles watch can miss rapid flips).
set -uo pipefail

info() { echo -e "\033[1;34m==>\033[0m $*"; }
ok()   { echo -e "\033[1;32m ✓\033[0m $*"; }
warn() { echo -e "\033[1;33m !\033[0m $*"; }

echo "=== Fix Omarchy bar (hidden / off-screen) ==="

TOGGLE="$HOME/.local/state/omarchy/toggles/bar-off"
if [[ -e "$TOGGLE" ]]; then
  rm -f "$TOGGLE" && ok "Bar was toggled off — flag removed ($TOGGLE)."
else
  ok "Bar was not toggled off (flag absent)."
fi

# Ask the running shell to re-read the toggle immediately.
if command -v omarchy-shell >/dev/null 2>&1; then
  omarchy-shell -q omarchy.bar syncHidden >/dev/null 2>&1 && ok "Bar re-synced." \
    || warn "Could not signal the shell — it will re-read on next restart."
elif command -v omarchy-toggle-bar >/dev/null 2>&1; then
  omarchy-toggle-bar off >/dev/null 2>&1 && ok "Bar re-synced (omarchy-toggle-bar)."
fi

# Report the resulting geometry so the user can confirm.
if command -v hyprctl >/dev/null 2>&1; then
  echo
  hyprctl layers 2>/dev/null | grep -A0 "omarchy-bar" || true
  hyprctl monitors -j 2>/dev/null | python3 -c "import json,sys; [print('  reserved:', m.get('reserved')) for m in json.load(sys.stdin)]" 2>/dev/null || true
fi

ok "Omarchy bar fix done."
