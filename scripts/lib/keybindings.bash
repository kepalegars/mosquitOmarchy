# lib/keybindings.bash — mosquitOmarchy-managed SUPER keybindings.
#
# The keybindings manager used to be a standalone interactive script; it is now
# PART of mosquitOmarchy (the TUI's Keybindings screen + these primitives).
# Everything managed lives in ONE marker block of ~/.config/hypr/bindings.lua:
#
#   -- >>> Omarchy_Custom_Scripts_Keys
#   ...
#   -- <<< Omarchy_Custom_Scripts_Keys
#
# Primitives (all non-interactive, reload is the CALLER's decision):
#   kb_load_ours                     parse the marker block into KB_OURS/KB_OWN_ORDER
#   kb_ensure <combo> <label> <cmd> <type>   idempotent add/replace (sets KB_CHANGED)
#   kb_remove <combo>…               remove listed combos (drops empty markers)
#   kb_reset                         remove the WHOLE managed block
#   kb_reload                        hyprctl reload + configerrors report
#   kb_free_keys                     print still-free "SUPER + X" combos
#   kb_count                         number of managed bindings

KB_CONF="${KB_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/hypr/bindings.lua}"
KB_DEF_DIR="/usr/share/omarchy/default/hypr/bindings"
KB_BEGIN='-- >>> Omarchy_Custom_Scripts_Keys'
KB_END='-- <<< Omarchy_Custom_Scripts_Keys'
KB_CHANGED=0
declare -A KB_OURS=()   # combo → "label|cmd|type"
KB_OWN_ORDER=()         # combos in insertion order

kb_load_ours(){
  KB_OWN_ORDER=()
  KB_OURS=()
  KB_CHANGED=0
  [[ -f "$KB_CONF" ]] || return 0
  local block line key label body type cmd
  block="$(awk -v b="$KB_BEGIN" -v e="$KB_END" '$0~b{f=1;next} $0~e{f=0} f' "$KB_CONF" 2>/dev/null || true)"
  [[ -z "$block" ]] && return 0
  while IFS= read -r line; do
    key="$(printf '%s' "$line" | sed -n 's/^ *o\.bind("\([^"]*\)", *"\([^"]*\)", *\(.*\)$/\1/;T;p')"
    [[ -z "$key" ]] && continue
    label="$(printf '%s' "$line" | sed -n 's/^ *o\.bind("\([^"]*\)", *"\([^"]*\)", *\(.*\)$/\2/;T;p')"
    body="$(printf '%s' "$line" | sed -n 's/^ *o\.bind("\([^"]*\)", *"\([^"]*\)", *\(.*\)$/\3/;T;p')"
    type=cmd
    if [[ "$body" == \{*launch*\}* ]]; then
      type=launch
      cmd="$(printf '%s' "$body" | sed -n 's/.*launch *= *"\([^"]*\)".*/\1/;T;p')"
    else
      cmd="$(printf '%s' "$body" | sed -n 's/^"\([^"]*\)".*/\1/;T;p')"
    fi
    KB_OURS["$key"]="$label|$cmd|$type"
    KB_OWN_ORDER+=("$key")
  done <<< "$block"
  return 0
}

kb_friendly_default(){ # combo → the Omarchy default label it would replace, if any
  rg -N "o\.bind\(\"$1\"" "$KB_DEF_DIR"/*.lua 2>/dev/null \
    | sed -n 's/.*o\.bind("[^"]*", *"\([^"]*\)".*/\1/p' | head -1
  return 0
}

kb_render_ours(){
  local k label cmd type def
  for k in "${KB_OWN_ORDER[@]}"; do
    IFS='|' read -r label cmd type <<<"${KB_OURS[$k]}"
    def="$(kb_friendly_default "$k")"
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
  return 0
}

kb_write_block(){
  local body
  body="$(kb_render_ours)"
  [[ -d "$(dirname "$KB_CONF")" ]] || mkdir -p "$(dirname "$KB_CONF")" || return 1
  if [[ ! -f "$KB_CONF" ]]; then
    cat > "$KB_CONF" <<'EOF'
-- Keep only your personal keybinding overrides here. Add new bindings or
-- unbind defaults before replacing them.
--   omarchy menu keybindings --print
EOF
  fi
  if rg -q -e "$KB_BEGIN" "$KB_CONF" 2>/dev/null; then
    awk -v b="$KB_BEGIN" -v e="$KB_END" -v body="$body" '
      $0 ~ b { inb=1; print; print body; next }
      $0 ~ e { inb=0; print; next }
      !inb { print }
    ' "$KB_CONF" > "$KB_CONF.tmp"
  else
    cp "$KB_CONF" "$KB_CONF.tmp"
    printf '\n%s\n%s\n%s\n' "$KB_BEGIN" "$body" "$KB_END" >> "$KB_CONF.tmp"
  fi
  mv "$KB_CONF.tmp" "$KB_CONF"
}

kb_ensure(){ # <combo> <label> <cmd> <type> — idempotent; replaces on label/cmd change
  local key="$1" label="$2" cmd="$3" type="$4" prev found=0 k
  kb_load_ours
  if [[ -n "${KB_OURS[$key]+x}" ]]; then
    prev="${KB_OURS[$key]}"
    if [[ "$prev" == "$label|$cmd|$type" ]]; then
      return 0   # exact match: nothing to do
    fi
  fi
  KB_OURS["$key"]="$label|$cmd|$type"
  for k in "${KB_OWN_ORDER[@]}"; do
    if [[ "$k" == "$key" ]]; then found=1; fi
  done
  if ((found == 0)); then KB_OWN_ORDER+=("$key"); fi
  kb_write_block
  KB_CHANGED=1
}

kb_remove(){ # combo…
  local want=("$@")
  ((${#want[@]})) || return 0
  kb_load_ours
  local k w drop removed=0
  local -a keep=()
  for k in "${KB_OWN_ORDER[@]}"; do
    drop=0
    for w in "${want[@]}"; do
      if [[ "$k" == "$w" ]]; then drop=1; fi
    done
    if ((drop)); then
      unset 'KB_OURS[$k]'
      removed=$((removed + 1))
    else
      keep+=("$k")
    fi
  done
  if ((removed == 0)); then
    warn "None of the given combos are managed — nothing to remove."
    return 0
  fi
  if (( ${#keep[@]} == 0 )); then
    kb_reset
  else
    KB_OWN_ORDER=("${keep[@]}")
    kb_write_block
  fi
  KB_CHANGED=1
}

kb_reset(){
  [[ -f "$KB_CONF" ]] || return 0
  rg -q -e "$KB_BEGIN" "$KB_CONF" 2>/dev/null || return 0
  local tmp
  tmp="$(mktemp)"
  awk -v b="$KB_BEGIN" -v e="$KB_END" '
    $0 ~ b { inb=1; next }
    $0 ~ e { inb=0; next }
    !inb { print }
  ' "$KB_CONF" > "$tmp" && mv "$tmp" "$KB_CONF"
  KB_CHANGED=1
}

kb_reload(){
  hyprctl reload >/dev/null 2>&1 || true
  local errs
  errs="$(hyprctl configerrors 2>/dev/null | tr -d '[:space:]')"
  if [[ -n "${errs:-}" ]]; then
    err "hyprctl configerrors: ${errs}"
    return 1
  fi
  ok "Hyprland reloaded without configuration errors."
}

kb_free_keys(){
  local taken
  taken="$( {
    [[ -f "$KB_CONF" ]] && sed "/$KB_BEGIN/,/$KB_END/d" "$KB_CONF" 2>/dev/null \
      | rg -o 'o\.bind\("[^"]+"' -N --no-filename 2>/dev/null | sed 's/o\.bind("//; s/"$//'
    rg -o 'o\.bind\("[^"]+"' -N --no-filename "$KB_DEF_DIR"/*.lua 2>/dev/null \
      | sed 's/o\.bind("//; s/"$//'
    printf '%s\n' "${KB_OWN_ORDER[@]}"
  } | sort -u )"
  local c cand
  for c in {A..Z} {0..9} F1 F2 F3 F4 F5 F6 F7 F8 F9 F10 F11 F12; do
    cand="SUPER + $c"
    grep -qx -F "$cand" <<<"$taken" 2>/dev/null || printf '%s\n' "$cand"
  done
  return 0
}

kb_count(){
  kb_load_ours
  echo "${#KB_OWN_ORDER[@]}"
}
