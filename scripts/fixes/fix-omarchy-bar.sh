#!/bin/bash
# fix-omarchy-bar.sh — bring back the Omarchy bar when it has been toggled off.
#
# Symptom: the bar is gone. `hyprctl layers` still shows `namespace: omarchy-bar`
# but its box sits just PAST the monitor edge (e.g. y = -barSize, or y = screen
# height) and `hyprctl monitors` reports reserved [0,0,0,0]: the bar slid
# off-screen because the toggle flag ~/.local/state/omarchy/toggles/bar-off
# exists (the shell hides it by moving it out instead of unmapping it).
#
# Clears the flag and asks the running shell to re-read it (the same nudge
# omarchy-toggle-bar uses; the toggles watch can miss rapid flips). If the bar
# is STILL parked off-screen after that nudge, the shell's watch/IPC is stuck —
# the documented cure is a full shell restart, so this does that as a last
# resort and re-checks before reporting.
set -uo pipefail

info() { echo -e "\033[1;34m==>\033[0m $*"; }
ok()   { echo -e "\033[1;32m ✓\033[0m $*"; }
warn() { echo -e "\033[1;33m !\033[0m $*"; }
err()  { echo -e "\033[1;31m✗\033[0m $*" >&2; }

# Exit 0 when an omarchy-bar layer sits outside its monitor's bounds, i.e. the
# shell is still hiding it by parking it past the edge (negative x/y, or past
# the far edge). Reads geometry only, so a transparent bar with no reserved
# area is not mistaken for a hidden one.
bar_offscreen(){
  command -v hyprctl >/dev/null 2>&1 || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - <<'PY'
import json, subprocess, sys

def hypr(*args):
    return json.loads(subprocess.check_output(
        ["hyprctl", *args], text=True, stderr=subprocess.DEVNULL))

try:
    layers = hypr("layers", "-j")
    monitors = {m["name"]: m for m in hypr("monitors", "-j")}
except Exception:
    sys.exit(1)  # no compositor / unreadable — treat as on-screen, do nothing

for mon, monitor_layers in layers.items():
    m = monitors.get(mon)
    for level in monitor_layers.get("levels", {}).values():
        for layer in level:
            if layer.get("namespace") != "omarchy-bar":
                continue
            x, y, w, h = layer["x"], layer["y"], layer["w"], layer["h"]
            if m is None:
                if x < 0 or y < 0:
                    sys.exit(0)
                continue
            if x < 0 or y < 0 or x + w > m["width"] or y + h > m["height"]:
                sys.exit(0)
sys.exit(1)
PY
}

# Restart the shell through whatever entry point exists in this environment.
restart_shell(){
  if command -v omarchy-restart-shell >/dev/null 2>&1; then
    omarchy-restart-shell >/dev/null 2>&1
  elif command -v omarchy >/dev/null 2>&1; then
    omarchy restart shell >/dev/null 2>&1
  else
    return 127
  fi
}

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

# Confirm the bar actually came back. The toggles watch can go permanently
# quiet after rapid flips, stranding the bar off screen with the flag already
# gone; only a shell restart clears that state, so fall back to one.
if command -v hyprctl >/dev/null 2>&1; then
  for _ in 1 2 3 4 5; do
    bar_offscreen || break
    sleep 0.4
  done

  if bar_offscreen; then
    warn "Bar is still parked off-screen after the re-sync."
    if restart_shell; then
      for _ in 1 2 3 4 5; do
        bar_offscreen || break
        sleep 0.4
      done
      if bar_offscreen; then
        err "Bar is still off-screen after a shell restart."
      else
        ok "Shell restarted — bar is back on screen."
      fi
    else
      warn "Could not restart the shell automatically — run: omarchy restart shell"
    fi
  fi
fi

# The clock slide belongs to this fix too: revealing the hidden indicators
# used to shove the clock sideways (its own tweak-bar-clock-centring.sh, kept
# standalone as a preference under scripts/tweaks/). Run it here so one bar
# fix covers the bar.
CLOCK_FIX="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/../tweaks/tweak-bar-clock-centring.sh"
if [[ -f $CLOCK_FIX ]]; then
  bash "$CLOCK_FIX" || warn "Clock centring reported an issue (see above)."
else
  warn "tweak-bar-clock-centring.sh not next to this script — clock slide unchecked."
fi

# Report the resulting geometry so the user can confirm.
if command -v hyprctl >/dev/null 2>&1; then
  echo
  hyprctl layers 2>/dev/null | grep -A0 "omarchy-bar" || true
  hyprctl monitors -j 2>/dev/null | python3 -c "import json,sys; [print('  reserved:', m.get('reserved')) for m in json.load(sys.stdin)]" 2>/dev/null || true
fi

ok "Omarchy bar fix done."
