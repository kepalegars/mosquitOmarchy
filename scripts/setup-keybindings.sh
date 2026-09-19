#!/usr/bin/env bash
# setup-keybindings.sh — Omarchy keybindings manager for the mosquitOmarchy.
#
# Adds, lists, removes and resets the SUPER keybindings created by this
# package, straight into ~/.config/hypr/bindings.lua. Everything this script
# manages lives in ONE marker block:
#
#   -- >>> Omarchy_Custom_Scripts_Keys
#   ...
#   -- <<< Omarchy_Custom_Scripts_Keys
#
# Reverting is one command:  setup-keybindings.sh --reset
#
# Usage:
#   ./setup-keybindings.sh                 # interactive TUI
#   ./setup-keybindings.sh --status        # read-only report (ours + conflicts + defaults)
#   ./setup-keybindings.sh --list-keys     # suggest free SUPER combos
#   ./setup-keybindings.sh --reset [-y]    # remove the whole block (confirmed / -y)
#   ./setup-keybindings.sh --ensure <combo> <label> <cmd> <type>   # idempotent, non-interactive
#   ./setup-keybindings.sh --remove-key <combo>                    # idempotent, non-interactive
#   # --ensure/--remove-key are used by the setup-customarchy.sh modules (macos-vm, …)
#   ./setup-keybindings.sh -h              # help
set -euo pipefail

CONF="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/bindings.lua"
DEF_DIR="/usr/share/omarchy/default/hypr/bindings"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BEGIN_MARK='-- >>> Omarchy_Custom_Scripts_Keys'
END_MARK='-- <<< Omarchy_Custom_Scripts_Keys'

G='\033[1;32m'; B='\033[1;34m'; Y='\033[1;33m'; R='\033[1;31m'; N='\033[0m'
msg(){ printf "${B}==>${N} %s\n" "$*"; }
ok(){ printf " ${G}✓${N} %s\n" "$*"; }
warn(){ printf " ${Y}!${N} %s\n" "$*"; }
err(){ printf " ${R}✗${N} %s\n" "$*" >&2; }
hr(){ printf '%.0s─' {1..70}; echo; }

YES=0 MODE=tui
SETUP_KEYS_ARGS=()
for a in "$@"; do case "$a" in
  -y|--yes) YES=1 ;;
  --status)  MODE=status ;;
  --list-keys) MODE=keys ;;
  --reset)   MODE=reset ;;
  -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
  --ensure)  MODE=ensure ;;
  --remove-key) MODE=remove-key ;;
  *) SETUP_KEYS_ARGS+=("$a") ;;
esac; done

ask_y(){
  local q="$1" def="${2:-y}" r
  ((YES)) && { ok "(auto) $q -> yes"; return 0; }
  read -rp "$q [$([ "$def" = y ] && echo Y/n || echo y/N)] " r
  r="${r:-$def}"; [[ "$r" =~ ^[oOyY] ]]
}

# ─────────────────────────── State ──────────────────────────────────────────
# combo → "label|cmd|launch"
declare -A OURS=()
OWNS=()          # order of OURS combos, as printed

load_ours(){
  OWNS=(); OURS=()
  [[ -f "$CONF" ]] || return 0
  local block st key label body type cmd
  block="$(awk "/$BEGIN_MARK/{f=1;next} /$END_MARK/{f=0} f" "$CONF" 2>/dev/null || true)"
  [[ -z "$block" ]] && return 0
  while IFS= read -r line; do
    st="$(printf '%s' "$line" | sed -n 's/^ *o\.bind("\([^"]*\)", *"\([^"]*\)", *\(.*\)$/\1/;T;p')"
    [[ -z "$st" ]] && continue
    key="$st"
    label="$(printf '%s' "$line" | sed -n 's/^ *o\.bind("\([^"]*\)", *"\([^"]*\)", *\(.*\)$/\2/;T;p')"
    body="$(printf '%s' "$line" | sed -n 's/^ *o\.bind("\([^"]*\)", *"\([^"]*\)", *\(.*\)$/\3/;T;p')"
    type=cmd
    if [[ "$body" == \{*launch*\}* ]]; then type=launch
      cmd="$(printf '%s' "$body" | sed -n 's/.*launch *= *"\([^"]*\)".*/\1/;T;p')"
    else
      cmd="$(printf '%s' "$body" | sed -n 's/^"\([^"]*\)".*/\1/;T;p')"
    fi
    OURS["$key"]="$label|$cmd|$type"
    OWNS+=("$key")
  done <<< "$block"
}

# combos bound anywhere in the user file OUTSIDE our marker block
user_combos_non_ours(){
  [[ -f "$CONF" ]] || return 0
  sed "/$BEGIN_MARK/,/$END_MARK/d" "$CONF" 2>/dev/null \
    | rg -o 'o\.bind\("[^"]+"' -N --no-filename 2>/dev/null \
    | sed 's/o\.bind("//; s/"$//' || true
}

# combos declared in the Omarchy default bindings
default_combos(){
  rg -o 'o\.bind\("[^"]+"' -N --no-filename "$DEF_DIR"/*.lua 2>/dev/null \
    | sed 's/o\.bind("//; s/"$//' || true
}

friendly_default(){ # combo → the default label if it exists
  local combo="$1" res
  res="$(rg -N "o\.bind\(\"$combo\"" "$DEF_DIR"/*.lua 2>/dev/null \
         | sed -n 's/.*o\.bind("[^"]*", *"\([^"]*\)".*/\1/p' | head -1)"
  printf '%s' "$res"
}

normalize_key(){
  # collapse several spaces around ' + ', uppercase the modifiers
  tr 'a-z' 'A-Z' <<< "$1" | sed -E 's/ *\+ */ + /g; s/^ +//; s/ +$//'
}

valid_key(){ [[ "$1" =~ ^([A-Z0-9_]+( +\+ )?)+[A-Z0-9_]+$ ]] && ! [[ "$1" =~ \" ]]; }

# ─────────────────────────── Write ──────────────────────────────────────────
# Emits OUR entries as hl.unbind+o.bind lines, hand-formatted to match the
# style already used in the brightness block.
render_ours(){
  local k label cmd type def lbl
  for k in "${OWNS[@]}"; do
    IFS='|' read -r label cmd type <<<"${OURS[$k]}"
    def="$(friendly_default "$k")"
    if [[ -n "$def" ]]; then
      printf -- '-- %s  (replaces the Omarchy default "%s")\n' "$label" "$def"
    else
      printf -- '-- %s\n' "$label"
    fi
    printf 'hl.unbind("%s")\n' "$k"
    if [[ "$type" == launch ]]; then
      printf 'o.bind("%s", "%s", { launch = "%s" })\n' "$k" "$label" "$cmd"
    else
      printf 'o.bind("%s", "%s", "%s", { locked = true, repeating = true })\n' "$k" "$label" "$cmd"
    fi
  done
}

apply_block(){
  local body
  body="$(render_ours)"
  [[ -d "$(dirname "$CONF")" ]] || return 1
  if [[ ! -f "$CONF" ]]; then
    cat > "$CONF" <<'EOF'
-- Keep only your personal keybinding overrides here. Add new bindings or
-- unbind defaults before replacing them.
--   omarchy menu keybindings --print
EOF
    ok "Created $CONF"
  fi
  if rg -q -e "$BEGIN_MARK" "$CONF" 2>/dev/null; then
    # Replace the existing block (keep the rest of the file).
    awk -v b="$BEGIN_MARK" -v e="$END_MARK" -v body="$body" '
      $0 ~ b { inb=1; print; print body; next }
      $0 ~ e { inb=0; print; next }
      !inb { print }
    ' "$CONF" > "$CONF.tmp"
  else
    # Append the block at the end of the file.
    cp "$CONF" "$CONF.tmp"
    printf '\n%s\n%s\n%s\n' "$BEGIN_MARK" "$body" "$END_MARK" >> "$CONF.tmp"
  fi
  mv "$CONF.tmp" "$CONF"
  msg "Reloading Hyprland..."
  hyprctl reload >/dev/null 2>&1 || true
  local errs
  errs="$(hyprctl configerrors 2>/dev/null | tr -d '[:space:]')"
  if [[ -n "${errs:-}" ]]; then warn "hyprctl configerrors: ${errs}"
  else ok "Hyprland reloaded without configuration errors."; fi
}

# ─────────────────────────── Add ────────────────────────────────────────────
# Wires a new binding after conflict checks.
add_binding(){
  local key="$1" label="$2" cmd="$3" type="$4"
  local def userline n
  if [[ -n "${OURS[$key]+x}" ]]; then
    warn "Already bound to \"${OURS[$key]%%|*}\" in our block — skipping."; return 1
  fi
  def="$(friendly_default "$key")"
  if [[ -n "$def" ]]; then
    msg "Key is an Omarchy DEFAULT: \"$key\" → \"$def\"."
    if ! ask_y "Replace it (default will be unbound)?" y; then warn "Aborted."; return 1; fi
  fi
  userline="$(user_combos_non_ours | rg -x -F "$key" || true)"
  if [[ -n "$userline" ]]; then
    warn "Already bound elsewhere in $CONF: \"$key\" — adding a second binding will duplicate it."
    if ! ask_y "Add anyway?" n; then warn "Aborted."; return 1; fi
  fi
  OURS["$key"]="$label|$cmd|$type"
  OWNS+=("$key")
  apply_block
  # Refuse to leave a binding Hyprland itself rejects: an invalid keysym (e.g.
  # an --ensure typo) still lands in the live config while configerrors flags
  # it. Detect a NEW Unknownkeysym error naming our key and roll the block
  # back so the config stays working instead of "Bound ✓" leaving it broken.
  local errs keytok
  errs="$(hyprctl configerrors 2>/dev/null | tr -d '[:space:]')"
  errs="${errs//\"/}"
  keytok="${key##*+}"
  if [[ -n "$errs" && "$errs" == *"Unknownkeysym:${keytok}"* ]]; then
    unset 'OURS[$key]'
    local kept=() k
    for k in "${OWNS[@]}"; do [[ "$k" != "$key" ]] && kept+=("$k"); done
    OWNS=("${kept[@]}")
    apply_block >/dev/null 2>&1 || true
    err "Rejected $key — Hyprland: $errs (binding rolled back, config restored)."
    return 1
  fi
  ok "Bound: $key → $label"
}

# ─────────────────────────── Catalog ────────────────────────────────────────
CAT_APPS=(
  "Ableton Live|ableton-live"
  "Guitar Pro 8|guitarpro"
  "Bitwig Studio|bitwig-studio"
  "DaVinci Resolve|davinci-resolve"
  "HandBrake|ghb"
  "REAPER|reaper"
)
CAT_FUNCS=(
  "Brightness +5%|$HOME/.local/bin/backlight +5%"
  "Brightness -5%|$HOME/.local/bin/backlight 5%-"
  "Brightness maximum|$HOME/.local/bin/backlight 100%"
  "Brightness minimum|$HOME/.local/bin/backlight 0%"
  "Ultra-save toggle|sudo -n $HOME/.local/bin/ultra-save toggle"
  "Mega-caffeine on|mega-caffeine on"
  "Mega-caffeine off|mega-caffeine off"
  "Mega-caffeine toggle|mega-caffeine toggle"
  "Setup Customarchy|foot -e $SELF_DIR/setup-customarchy.sh"
  "SuperFile|foot -e spf"
)
CAT_MOVE=(
  "Move: main menu|$HOME/.local/bin/mosquito-move-manager|cmd"
  "Move: Move Manager webapp|$HOME/.local/bin/move-manager-webapp|launch"
  "Move: convert a set → MIDI|$HOME/.local/bin/mosquito-move-manager --midi|cmd"
)
CAT_VM=(
  "macOS VM Manager (Super+Alt+A)|omarchy-launch-or-focus-tui macos-vm-tui|launch"
)

pick_free_keys(){
  # Free SUPER combos: letters, digits, F-keys, not used anywhere yet.
  local taken="$( { user_combos_non_ours; default_combos; printf '%s\n' "${OWNS[@]}"; } | sort -u )"
  local cand k
  for c in {A..Z} {0..9} F1 F2 F3 F4 F5 F6 F7 F8 F9 F10 F11 F12; do
    cand="SUPER + $c"
    if ! grep -qx -F "$cand" <<<"$taken" 2>/dev/null; then printf '%s\n' "$cand"; fi
  done
}

menu_add(){
  hr; msg "Add a keybinding — choose a category"
  echo "    1) Launch a package app (menu entry of mosquitOmarchy)"
  echo "    2) Quick function (brightness, ultra-save, mega-caffeine…)"
  echo "    3) mosquito Move Manager (menu / Move Manager webapp / convert to MIDI)"
echo "    4) Custom command"
    echo "    5) macOS VM Manager"
    echo "    r) Return"
    read -rp "  Choice : " c
    local cat=() title="" explicit=0
    case "$c" in
      1) cat=("${CAT_APPS[@]}"); title="package app" ;;
      2) cat=("${CAT_FUNCS[@]}"); title="quick function" ;;
      3) cat=("${CAT_MOVE[@]}"); title="Ableton Move converter"; explicit=1 ;;
      4) menu_add_custom; return ;;
      5) cat=("${CAT_VM[@]}"); title="macOS VM"; explicit=1 ;;
      r|R|q|Q) return ;;
      *) warn "Invalid choice."; return ;;
  esac
  echo
  local i e label val type
  msg "Choose a $title:"
  for i in "${!cat[@]}"; do
    e="${cat[$i]}"; IFS='|' read -r label val type <<<"$e"
    printf '    %2d) %s\n' $((i+1)) "$label"
  done
  echo "     0) Cancel"
  read -rp "  Choice [1-${#cat[@]}] : " c
  [[ "$c" =~ ^[0-9]+$ ]] && (( c >= 1 && c <= ${#cat[@]} )) || { warn "Invalid choice."; return; }
  e="${cat[$((c-1))]}"; IFS='|' read -r label val type <<<"$e"
  menu_pick_key "$label" "$val" "$type"
}

menu_add_custom(){
  hr; msg "Custom command binding"
  read -rp "  Label : " label; [[ -n "$label" ]] || { warn "Empty label."; return; }
  label="${label//\"/}"
  read -rp "  Command : " val; [[ -n "$val" ]] || { warn "Empty command."; return; }
  [[ "$val" == *\"* ]] && { err "Quotes are not allowed in the command."; return; }
  menu_pick_key "$label" "$val" ""
}

menu_pick_key(){ # label cmd type
  local label="$1" val="$2" type="$3" keys k
  keys="$(pick_free_keys)"
  hr; msg "Pick a key for: $label"
  echo "  Free SUPER combos (not used by Omarchy or you):"
  local n=0 arr=()
  while IFS= read -r k; do n=$((n+1)); arr+=("$k"); printf '    %2d) %s\n' "$n" "$k"; done <<<"$keys"
  echo "     0) Type another combo"
  read -rp "  Choice [0-$n] : " c
  if [[ "$c" =~ ^[0-9]+$ ]] && (( c >= 1 && c <= n )); then
    key="${arr[$((c-1))]}"
  elif [[ "$c" == 0 ]]; then
    read -rp "  Combo (e.g. SUPER + SHIFT + K, or XF86… key) : " key
  else
    warn "Invalid choice."; return
  fi
  key="$(normalize_key "$key")"
  valid_key "$key" || { err "Invalid combo format: $key"; return; }
  if [[ -z "$type" ]]; then
    # Catalog app → launch form; otherwise command form.
    if [[ "$val" =~ ^(ableton-live|guitarpro|bitwig-studio|davinci-resolve|ghb|reaper)$ ]]; then
      type=launch
    else
      type=cmd
    fi
  fi
  add_binding "$key" "$label" "$val" "$type"
}

menu_remove(){
  hr; msg "Remove a keybinding"
  if (( ${#OWNS[@]} == 0 )); then warn "No keybindings managed by this script yet."; return; fi
  local i k
  for i in "${!OWNS[@]}"; do
    IFS='|' read -r label _ t <<<"${OURS[${OWNS[$i]}]}"
    printf '    %2d) %-24s (%s)\n' $((i+1)) "$label" "${OWNS[$i]}"
  done
  echo "     0) Cancel"
  read -rp "  Choice : " c
  [[ "$c" =~ ^[0-9]+$ ]] && (( c >= 1 && c <= ${#OWNS[@]} )) || { warn "Invalid choice."; return; }
  k="${OWNS[$((c-1))]}"
  local new=() x
  for x in "${OWNS[@]}"; do [[ "$x" != "$k" ]] && new+=("$x"); done
  OWNS=("${new[@]}")
  unset 'OURS[$k]'
  apply_block
  ok "Removed: $k"
}

# ──────────────────── Non-interactive helpers (used by modules) ──────────────
# add_binding_silent  — idempotent: no-op if combo already in OURS with same cmd.
add_binding_silent(){
  local key="$1" label="$2" cmd="$3" type="$4"
  if [[ -n "${OURS[$key]+x}" ]]; then
    local prev="${OURS[$key]}"; prev="${prev%%|*}"
    if [[ "$prev" == "$label" ]]; then
      ok "Key already bound as requested ($key → $label) — nothing to do."
      return 0
    fi
  fi
  add_binding "$key" "$label" "$cmd" "$type"
}

# remove_binding  — non-interactive: removes a combo from OURS + OWNS.
remove_binding(){
  local key="$1"
  if [[ -z "${OURS[$key]+x}" ]]; then
    warn "Key $key is not managed by this script — nothing to remove."
    return 0
  fi
  local new=() x
  for x in "${OWNS[@]}"; do [[ "$x" != "$key" ]] && new+=("$x"); done
  OWNS=("${new[@]}")
  unset 'OURS[$key]'
  if (( ${#OWNS[@]} == 0 )); then
    # Last one removed → drop the whole block instead of leaving empty markers.
    if rg -q -e "$BEGIN_MARK" "$CONF" 2>/dev/null; then
      awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
        $0 ~ b { inb=1; next }
        $0 ~ e { inb=0; next }
        !inb { print }
      ' "$CONF" > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"
    fi
    ok "Removed: $key (last one — marker block removed)"
    return 0
  fi
  apply_block
  ok "Removed: $key"
}

menu_status(){
  hr; msg "Keybindings status — $CONF"
  local ds="$(default_combos)"
  local nc="$(user_combos_non_ours)"
  printf '  Omarchy defaults found  : %s\n' "$(printf '%s\n' "$ds" | wc -l)"
  printf '  Your other bindings     : %s\n' "$(printf '%s\n' "$nc" | wc -l)"
  printf '  Ours (this block)       : %s\n' "${#OWNS[@]}"
  echo
  msg "Managed by mosquitOmarchy:"
  if (( ${#OWNS[@]} == 0 )); then warn "None."
  else
    local i k label cmd t def
    for i in "${!OWNS[@]}"; do
      k="${OWNS[$i]}"; IFS='|' read -r label cmd t <<<"${OURS[$k]}"
      def="$(friendly_default "$k")"
      if [[ -n "$def" ]]; then
        ok "${k//+ /+/}: $label   (replaces the Omarchy default \"$def\")"
      else
        ok "${k//+ /+/}: $label"
      fi
    done
  fi
  echo
  # Conflicts: OUR combos that also appear in the user file but not by us.
  local ourblock dups=0 k
  ourblock="$(user_combos_non_ours)"
  for k in "${OWNS[@]}"; do
    if grep -qx -F "$k" <<<"$ourblock" 2>/dev/null; then
      warn "Conflict: \"$k\" is also bound outside this block."
      dups=1
    fi
  done
  (( dups )) || ok "No conflict detected with your other bindings."
  echo
  msg "These bindings appear live in Omarchy's keybinds menu:"
  ok "omarchy menu keybindings --print"
  hr
}

menu_reload(){
  hr; msg "Reload Hyprland"
  hyprctl reload >/dev/null 2>&1 || warn "hyprctl reload failed"
  local errs
  errs="$(hyprctl configerrors 2>/dev/null | tr -d '[:space:]')"
  if [[ -n "${errs:-}" ]]; then err "hyprctl configerrors: ${errs}"
  else ok "No configuration errors (empty 'hyprctl configerrors' = all good)."; fi
  hr
}

do_reset(){
  if ! rg -q -e "$BEGIN_MARK" "$CONF" 2>/dev/null; then
    warn "No mosquitOmarchy keybinding block to remove."
    return 0
  fi
  if ! ask_y "Remove ALL keybindings managed by setup-keybindings.sh (marker block)?" y; then ok "Kept."; return 0; fi
  awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    $0 ~ b { inb=1; next }
    $0 ~ e { inb=0; next }
    !inb { print }
  ' "$CONF" > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"
  ok "Marker block removed — Omarchy default bindings are back."
}

# ─────────────────────────── Entry points ───────────────────────────────────
load_ours

case "$MODE" in
  status) menu_status; exit 0 ;;
  keys)
    msg "Free SUPER combos:"
    pick_free_keys | tr '\n' ' '; echo; echo
    exit 0 ;;
  reset)
    do_reset; exit 0 ;;
  ensure)
    (( ${#SETUP_KEYS_ARGS[@]} >= 4 )) || { err "Usage: --ensure <combo> <label> <cmd> <type>"; exit 1; }
    add_binding_silent "${SETUP_KEYS_ARGS[0]}" "${SETUP_KEYS_ARGS[1]}" "${SETUP_KEYS_ARGS[2]}" "${SETUP_KEYS_ARGS[3]}"; exit 0 ;;
  remove-key)
    (( ${#SETUP_KEYS_ARGS[@]} >= 1 )) || { err "Usage: --remove-key <combo>"; exit 1; }
    remove_binding "${SETUP_KEYS_ARGS[0]}"; exit 0 ;;
  tui)
    while :; do
      load_ours
      hr
      msg "setup-keys — mosquitOmarchy keybindings manager"
      printf '  %s bind(s) managed now.\n' "${#OWNS[@]}"
      echo
      echo "    1) Add a keybinding (apps / quick functions / custom command)"
      echo "    2) Remove one of ours"
      echo "    3) Status + conflicts"
      echo "    4) Reload Hyprland (validate config)"
      echo "    5) Reset — remove EVERYTHING managed by this script"
      echo "    q) Quit"
      read -rp "  Choice : " c
      case "$c" in
        1) menu_add ;;
        2) menu_remove ;;
        3) menu_status ;;
        4) menu_reload ;;
        5) do_reset ;;
        q|Q) echo; ok "Bye."; exit 0 ;;
        *) warn "Invalid choice." ;;
      esac
    done ;;
esac