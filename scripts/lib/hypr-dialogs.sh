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
#   hypr_dialogs_install guitarpro            # dialogs only (caller tiles main)
#   hypr_app_windows_install betterbird '^eu\\.betterbird\\.Betterbird$'  # tile main + float dialogs
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

# Escape a regex so it survives being embedded in a Lua DOUBLE-QUOTED string.
# Lua treats backslash as an escape introducer: `\.` is an "invalid escape
# sequence" (a hard parse error that takes the whole hyprland.lua down, the very
# breakage fix-hyprland-crash.sh repairs), and `\b` silently becomes a backspace
# character instead of the regex word boundary. Doubling every backslash (and
# escaping the quote) makes Lua hand the regex to Hyprland byte-for-byte.
lua_escape(){ printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# The dialog rule itself: float, at the pointer, without stealing focus.
#
# This is the "intelligent" bit borrowed from the Zoom recipe: a menu/dialog
# that opens where the cursor is (instead of glued to the monitor's top-left
# corner) and that does NOT steal the initial focus is what makes the small
# popups of an app stop fighting the user. The Lua expression form is the
# documented equivalent of the old `windowrule = move onscreen cursor`:
#   move = { "cursor_x-(window_w*0.5)", "cursor_y-(window_h*0.5)" }
# centers the window on the pointer; no_initial_focus keeps the main window
# focused. See https://wiki.hypr.land/configuring/core/rules/window-rules/
hypr_dialog_rule(){ # <class-lua-regex> <title-lua-regex> -> one Lua line
  printf 'o.window({ class = "%s", title = "%s" }, { float = true, no_initial_focus = true, move = { "cursor_x-(window_w*0.5)", "cursor_y-(window_h*0.5)" } })' \
    "$(lua_escape "$1")" "$(lua_escape "$2")"
}

# hypr_dialogs_install <app-id>
# Dialog-only variant for callers that own their tiling rule elsewhere (the
# Guitar Pro setup writes its own guitarpro-tiling block). Floats the app's
# dialog-title windows at the pointer, without focus steal, and leaves the
# main window untouched.
hypr_dialogs_install(){
  local app="$1" f rx
  f="$(hypr_dialogs_file)"
  [[ -f $f ]] || { echo "no hyprland config at $f" >&2; return 1; }
  hypr_dialogs_remove "$app" >/dev/null 2>&1 || true
  rx="$(hypr_dialogs_regex)"
  cat >> "$f" <<EOF
-- >>> mosquito-dialogs-$app >>> float $app's dialog windows (titles) at the
-- pointer, no initial focus; the main window is left to its own tiling rule.
-- Matching the known dialog titles is the only signal Hyprland has for an
-- XWayland dialog: it shares its main window's class. See scripts/lib/
-- hypr-dialogs.sh for the full rationale and the word list.
$(hypr_dialog_rule "^(?i)${app}.*\$" "^(?i)(${rx})")
-- <<< mosquito-dialogs-$app <<<
EOF
  command -v hyprctl >/dev/null 2>&1 && hyprctl reload >/dev/null 2>&1 || true
  echo "dialog rules installed for $app"
}

# hypr_app_windows_install <app-id> <class-lua-regex>
# The complete per-app deal: the MAIN window is explicitly tiled (so an app
# whose class ends in .exe, or any generic float rule, cannot leave it
# floating), then its dialogs/menus float at the pointer without focus steal.
# Order matters: later rules win, so the dialog rule comes after the tiling
# one and a title that matches a dialog word overrides the tiling.
hypr_app_windows_install(){
  local app="$1" cls="$2" f rx
  f="$(hypr_dialogs_file)"
  [[ -f $f ]] || { echo "no hyprland config at $f" >&2; return 1; }
  hypr_dialogs_remove "$app" >/dev/null 2>&1 || true
  rx="$(hypr_dialogs_regex)"
  cat >> "$f" <<EOF
-- >>> mosquito-dialogs-$app >>> $app: main window TILED, dialogs/menus float
-- at the pointer without stealing focus (the Zoom-recipe fix, applied to this
-- app alone). See scripts/lib/hypr-dialogs.sh for the rationale + word list.
o.window({ class = "$(lua_escape "$cls")" }, { float = false, tile = true })
$(hypr_dialog_rule "${cls}" "^(?i)(${rx})")
-- <<< mosquito-dialogs-$app <<<
EOF
  command -v hyprctl >/dev/null 2>&1 && hyprctl reload >/dev/null 2>&1 || true
  echo "window rules installed for $app"
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

# CLI: install|remove|status <app> [class-regex]. Lets a setup script call it
# without sourcing (which would run the whole file under `set -e` in its own
# shell). `appwin <app> <class-regex>` installs the full tile+float deal.
case "${1:-}" in
  install|remove|status) "hypr_dialogs_${1}" "${2:?app id required}" ;;
  appwin)               hypr_app_windows_install "${2:?app id required}" "${3:?class regex required}" ;;
esac
