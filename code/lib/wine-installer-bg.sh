#!/usr/bin/env bash
# wine-installer-bg.sh — hide the blank background windows Wine/Inno Setup maps
# next to the real installer wizard.
#
# Started by the APM for the duration of one installer and stopped with its
# stop file. It polls the current Hyprland session (the title is set after the
# window maps, so a window rule cannot catch it).
#
# Inno Setup extracts itself to an executable whose WM_CLASS ends in ".tmp" and
# maps a plain background window ("Setup", "Installazione", "Installation"…)
# beside the real wizard ("Setup - <product>", "Installazione di <product>"…).
# Some builds also leave an empty-titled window. Those blanks are the immovable
# black rectangles; the wizard, the language picker and error dialogs must stay
# visible.
#
# The rule is per class: a blank/generic window is hidden only when the same
# class owns a non-generic window, so an installer whose only window is titled
# "Setup" is never hidden. An unrelated app's window is never touched: its class
# does not look like an installer.
set -u
stop_file="${1:?stop file required}"
command -v hyprctl >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0

while [[ ! -e $stop_file ]]; do
  while IFS= read -r addr; do
    [[ -n $addr ]] || continue
    hyprctl eval "hl.dispatch(hl.dsp.window.move({ window = \"address:$addr\", workspace = \"special:wine-bg\", follow = false }))" >/dev/null 2>&1 || true
  done < <(hyprctl clients -j 2>/dev/null | jq -r '
    def generic:
      ascii_downcase | gsub("^\\s+|\\s+$"; "")
      | test("^(|setup|setup wizard|install|installer|installation|installation wizard|installazione|installazione guidata|installateur|assistant|assistant d\u0027installation|instalación|instalador|wine)$");
    . as $all
    | .[]
    | . as $w
    | (.class // "" | ascii_downcase) as $c
    | select($c | test("\\.tmp$|setup|install"))
    | select(($w.title // "") | generic)
    | select(
        [ $all[]
          | select((.class // "" | ascii_downcase) == $c and .address != $w.address)
          | (.title // "")
          | select(generic | not)
        ] | length > 0
      )
    | .address' 2>/dev/null)
  sleep 0.1
done
