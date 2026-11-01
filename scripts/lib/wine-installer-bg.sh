#!/usr/bin/env bash
# wine-installer-bg.sh — hide the blank "Setup" background window Wine/Inno
# Setup maps next to the real "Setup - <product>" wizard.
#
# Started by the APM for the duration of one installer and stopped with its
# stop file. It polls the current Hyprland session (the title is set after the
# window maps, so a window rule cannot catch it) and moves ONLY a window titled
# exactly "Setup" whose class also owns a "Setup - ..." wizard or the
# "Select Setup Language" dialog. The real wizard is never hidden.
set -u
stop_file="${1:?stop file required}"
command -v hyprctl >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0

while [[ ! -e $stop_file ]]; do
  while IFS= read -r addr; do
    [[ -n $addr ]] || continue
    hyprctl eval "hl.dispatch(hl.dsp.window.move({ window = \"address:$addr\", workspace = \"special:wine-bg\", follow = false }))" >/dev/null 2>&1 || true
  done < <(hyprctl clients -j 2>/dev/null | jq -r '
    (map(select((.title // "") | test("^(Setup - |Select Setup Language)"))) | map(.class)) as $titled
    | .[] | select((.title // "") == "Setup"
                   and (.class as $c | $titled | index($c)))
    | .address' 2>/dev/null)
  sleep 0.5
done
