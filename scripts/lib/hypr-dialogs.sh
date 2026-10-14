#!/usr/bin/env bash
# hypr-dialogs.sh — float an app's DIALOG windows while its main window stays
# tiled, for the apps Hyprland cannot tell apart.
#
# WHY THIS EXISTS
#   Hyprland has no WM_TRANSIENT_FOR / _NET_WM_WINDOW_TYPE_DIALOG handling: an
#   XWayland dialog gets the same window class as the main window ("guitarpro.exe",
#   "betterbird") and therefore the same windowrules. Tiling the app tiles its
#   dialogs too; floating the app floats its main window too. There is no rule
#   that says "float only the small windows" — Hyprland cannot match on size.
#
# WHY REAPER DOES NOT NEED IT
#   REAPER's dialogs are native Qt Wayland surfaces with their own class/title,
#   so they match nothing and pick up the stock behaviour. Only the XWayland
#   apps (wine, and the X11 builds of Electron/Qt mail clients) hit this.
#
# THE HEURISTIC, and why it is not a hack
#   Dialog titles are the same words in every app on the desktop, whatever the
#   language of the interface: Save As, Open, Export, Print, Options,
#   Preferences, Settings, Properties, Rename, Choose…, Confirm, Error. Matching
#   those titles is the only signal available, it is entirely READ-ONLY (it
#   never changes how an app behaves, only how its dialogs are placed) and it
#   cannot hit the main window: main windows are named after the PROGRAM, not
#   after a dialog verb. Add words to the list below and every caller takes
#   them in.
#
# Usage (idempotent, one marked block per app):
#   hypr_dialogs_install guitarpro
#   hypr_dialogs_remove guitarpro
#
# The caller owns HYPRLAND_CONFIG (defaults to ~/.config/hypr/hyprland.lua).
set -euo pipefail

HYPR_DIALOG_MARK="-- >>> mosquito-dialogs"

# The known dialog titles, lower-cased. Word-boundary matching, so "save" does
# not float a window called "Savegame Browser". Extend freely.
HYPR_DIALOG_WORDS=(
  save "save as" open import export print options preferences settings
  properties rename confirm
  error warning choose choosefolder browse select "select folder" "select file"
  "select device" "select destination" progress "please wait" "are you sure"
  question information alert dialog
)

hypr_dialogs_file(){ printf '%s' "${HYPRLAND_CONFIG:-$HOME/.config/hypr/hyprland.lua}"; }

# Regex of the words above, OR-ed and case-insensitive. Built once here rather
# than in Lua so the generated rule stays one line.
hypr_dialogs_regex(){
  local w first=1
  for w in "${HYPR_DIALOG_WORDS[@]}"; do
    if ((first)); then printf '^'; first=0; else printf '|^'; fi
    printf '%s\\b' "$w"
  done
}

# hypr_dialogs_install <app-id>
# Writes (or rewrites) the app's marked block: its tiled main window first,
# then the dialog-title float. Order matters — later rules win in Hyprland, so
# the float must come after the caller's own tiling rule.
hypr_dialogs_install(){
  local app="$1" f rx
  f="$(hypr_dialogs_file)"
  [[ -f $f ]] || { echo "no hyprland config at $f" >&2; return 1; }
  hypr_dialogs_remove "$app" >/dev/null 2>&1 || true
  rx="$(hypr_dialogs_regex)"
  cat >> "$f" <<EOF
-- >>> mosquito-dialogs-$app >>> float $app's dialog windows (titles), main window untouched.
-- Matching the known dialog titles is the only signal Hyprland has for an
-- XWayland dialog: it shares its main window's class. See scripts/lib/
-- hypr-dialogs.sh for the full rationale and the word list.
o.window({ class = "^(?i)${app}.*$", title = "^(?i)(${rx})" }, { float = true, center = true })
-- <<< mosquito-dialogs-$app <<<
EOF
  command -v hyprctl >/dev/null 2>&1 && hyprctl reload >/dev/null 2>&1 || true
  echo "dialog rules installed for $app"
}

hypr_dialogs_remove(){
  local app="$1" f
  f="$(hypr_dialogs_file)"
  [[ -f $f ]] || return 0
  sed -i "/^${HYPR_DIALOG_MARK}-${app} >>>/,/^-- <<< mosquito-dialogs-${app} <<</d" "$f"
}

# hypr_dialogs_status <app> — what is actually in the config right now.
hypr_dialogs_status(){
  local app="$1" f
  f="$(hypr_dialogs_file)"
  if [[ -f $f ]] && grep -q "^${HYPR_DIALOG_MARK}-${app} >>>" "$f"; then
    echo "installed"
  else
    echo "missing"
  fi
}

# CLI: install|remove|status <app>. Lets a setup script call it without
# sourcing (which would run the whole file under `set -e` in its own shell).
case "${1:-}" in
  install|remove|status) "hypr_dialogs_${1}" "${2:?app id required}" ;;
esac
