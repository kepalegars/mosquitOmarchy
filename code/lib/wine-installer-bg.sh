#!/usr/bin/env bash
# wine-installer-bg.sh — hide the blank background window Wine/Inno Setup maps
# next to the real installer wizard.
#
# Started by the APM for the duration of one installer and stopped with its
# stop file. It polls the current Hyprland session (the title is set after the
# window maps, so a window rule cannot catch it).
#
# Matching must not depend on the installer language: the English build shows
# "Setup" next to "Setup - <product>", the Italian one shows "Installazione"
# next to "Installazione di <product>". The reliable signal is the pair: two
# windows of the same Inno Setup temp class where the shorter, generic title is
# a word-prefix of the longer one. A title containing " - " is left alone (that
# is a real wizard/dialog, not the blank background).
set -u
stop_file="${1:?stop file required}"
command -v hyprctl >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0

while [[ ! -e $stop_file ]]; do
  while IFS= read -r addr; do
    [[ -n $addr ]] || continue
    hyprctl eval "hl.dispatch(hl.dsp.window.move({ window = \"address:$addr\", workspace = \"special:wine-bg\", follow = false }))" >/dev/null 2>&1 || true
  done < <(hyprctl clients -j 2>/dev/null | jq -r '
    . as $all
    | .[]
    | . as $w
    | select((.class // "") | test("\\.tmp$"))
    | select(
        ([ $all[]
           | select(.class == $w.class and .address != $w.address)
           | .title // "" ]) as $sibs
        | ($w.title // "") as $t
        | (($t | length) > 2)
          and ($t | contains(" - ") | not)
          and (
            ($sibs | any(. as $s
              | ($s | startswith($t + " "))
                or ($s | startswith($t + " - "))))
            or (($t == "Setup")
                and ($sibs | any(test("^Select Setup Language"))))
          )
      )
    | .address' 2>/dev/null)
  sleep 0.5
done
