#!/bin/bash
# =============================================================================
# Omarchy Custom - Keyboard backlight toggle + "Trigger > Hardware" entry
# =============================================================================
# Adds to the Omarchy menu an entry that toggles (on/off) the keyboard
# backlight, visible under "Trigger > Hardware" (aliases "hardware"/"hw").
#
#   1. Detects the keyboard backlight device (e.g. tpacpi::kbd_backlight)
#   2. Deploys ~/.local/bin/kbd-toggle (on/off toggle, remembers the level)
#   3. Inserts the "trigger.hardware.keyboard-backlight" entry into
#      ~/.config/omarchy/extensions/omarchy-menu.jsonc (independent block)
#
# ROBUSTNESS (what changed vs v1):
#   - After each write, the JSONC validity is checked and misplaced commas
#     between blocks are repaired automatically. This prevents another block
#     (e.g. setup.winvm) inserted after ours from breaking the menu (that was
#     the cause of the entry disappearing).
#   - The deployed binary is named kbd-toggle (aligned with the menu).
#
# Usage:
#   ./fix-keyboard-backlight-menu.sh            # applies (idempotent)
#   ./fix-keyboard-backlight-menu.sh --remove   # removes the entry + helper
#
# NOTE: if an Omarchy update overwrites omarchy-menu.jsonc, rerunning this
# script is enough to re-apply the entry.
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/gui-run.bash"  # gui-run: reopen in a terminal when launched from a file manager
set -euo pipefail

info() { echo -e "\033[1;34m==>\033[0m $*"; }
ok()   { echo -e "\033[1;32m ✓\033[0m $*"; }
warn() { echo -e "\033[1;33m !\033[0m $*"; }

BIN_DIR="$HOME/.local/bin"
MENU_DIR="$HOME/.config/omarchy/extensions"
MENU="$MENU_DIR/omarchy-menu.jsonc"
BLOCK_START="// >>> Omarchy_Custom_Scripts - managed by fix-keyboard-backlight-menu.sh"
BLOCK_END="// <<< Omarchy_Custom_Scripts - managed by fix-keyboard-backlight-menu.sh"

if [[ ! -d /usr/share/omarchy ]]; then
  echo "This script is meant for Omarchy." >&2
  exit 1
fi

REMOVE=false
[[ ${1:-} == "--remove" ]] && REMOVE=true

# -----------------------------------------------------------------------------
# 0. Detection of the keyboard backlight device
# -----------------------------------------------------------------------------
find_kbd_device() {
  local c
  for c in /sys/class/leds/*kbd_backlight*; do
    [[ -e "$c" ]] && { basename "$c"; return 0; }
  done
  return 1
}

KBD_DEVICE="$(find_kbd_device || true)"

if [[ -z $KBD_DEVICE && $REMOVE != true ]]; then
  warn "No keyboard backlight detected (*kbd_backlight* in /sys/class/leds)."
  warn "The menu entry will be added but hidden until the device exists."
fi

# -----------------------------------------------------------------------------
# 1. Deployment of the toggle
# -----------------------------------------------------------------------------
if [[ $REMOVE == true ]]; then
  rm -f "$BIN_DIR/kbd-toggle"
  ok "Helper $BIN_DIR/kbd-toggle removed"
else
  info "Deploying the toggle $BIN_DIR/kbd-toggle"
  mkdir -p "$BIN_DIR"

  cat > "$BIN_DIR/kbd-toggle" << 'TOGGLE_EOF'
#!/bin/bash
# keyboard backlight toggle (on/off) remembering the last level
set -euo pipefail

STATEFILE="${XDG_RUNTIME_DIR:-/tmp}/kbd-toggle.level"

device=""
for c in /sys/class/leds/*kbd_backlight*; do
  [[ -e "$c" ]] && { device="$(basename "$c")"; break; }
done
[[ -z $device ]] && { echo "No keyboard backlight detected" >&2; exit 1; }

max="$(brightnessctl -d "$device" max)"
cur="$(brightnessctl -d "$device" get)"

if [[ ${1:-toggle} == "off" ]]; then
  echo "$cur" > "$STATEFILE"
  brightnessctl -d "$device" set 0 >/dev/null
  echo "off"
  exit 0
fi
if [[ ${1:-toggle} == "on" ]]; then
  local_level=$(( $(cat "$STATEFILE" 2>/dev/null || echo 0) ))
  (( local_level < 1 || local_level > max )) && local_level=$max
  brightnessctl -d "$device" set "$local_level" >/dev/null
  echo "on"
  exit 0
fi

# toggle by default
if (( cur > 0 )); then
  echo "$cur" > "$STATEFILE"
  brightnessctl -d "$device" set 0 >/dev/null
  echo "off"
else
  local_level=$(( $(cat "$STATEFILE" 2>/dev/null || echo 0) ))
  (( local_level < 1 || local_level > max )) && local_level=$max
  brightnessctl -d "$device" set "$local_level" >/dev/null
  echo "on"
fi
TOGGLE_EOF

  chmod +x "$BIN_DIR/kbd-toggle"
  bash -n "$BIN_DIR/kbd-toggle"
  ok "toggle deployed ($BIN_DIR/kbd-toggle)"
fi

# -----------------------------------------------------------------------------
# 2. Python utility: repairs the commas of a JSONC file (idempotent)
# -----------------------------------------------------------------------------
FIX_JSONC=$(cat << 'PYEOF'
import re, json, sys

def strip_comments(text):
    return '\n'.join(l for l in text.split('\n') if not l.lstrip().startswith('//'))

def fix_commas(text):
    lines = text.split('\n')
    i = 0
    while i < len(lines):
        l = lines[i]
        indent = len(l) - len(l.lstrip())
        if re.match(r'^[ \t]*\}$', l.rstrip()) and not l.rstrip().endswith(','):
            j = i + 1
            while j < len(lines):
                t = lines[j]
                if not t.strip() or t.lstrip().startswith('//'):
                    j += 1
                    continue
                break
            if j < len(lines) and re.match(r'^[ \t]*"', lines[j]) and \
               len(lines[j]) - len(lines[j].lstrip()) == indent:
                lines[i] = l.rstrip() + ','
        i += 1
    return '\n'.join(lines)

def main():
    mode, path = sys.argv[1], sys.argv[2]
    with open(path) as f:
        text = f.read()

    # normalize the commas (idempotent: already well formed -> unchanged)
    new_text = text
    for _ in range(5):
        fixed = fix_commas(new_text)
        if fixed == new_text:
            break
        new_text = fixed

    stripped = strip_comments(new_text)
    try:
        json.loads(stripped)
        valid = True
    except json.JSONDecodeError as e:
        valid = False
        err = "{}: {}".format(e.lineno, e.msg)

    if mode == "validate":
        print("ok" if valid else "INVALID: {}".format(err))
        sys.exit(0 if valid else 1)

    if mode == "write" :
        with open(path, 'w') as f:
            f.write(new_text)
        if not valid:
            print("JSONC INVALID after write: {}".format(err), file=sys.stderr)
            sys.exit(1)
        print("ok")

if __name__ == "__main__":
    main()
PYEOF
)

validate_menu() { python3 -c "$FIX_JSONC" validate "$MENU"; }
write_menu() { python3 -c "$FIX_JSONC" write "$MENU"; }

# -----------------------------------------------------------------------------
# 3. "Trigger > Hardware > Keyboard Backlight" entry in the Omarchy menu
# -----------------------------------------------------------------------------
read_block() {
  cat <<BLOCK_EOF
$BLOCK_START
  "trigger.hardware.keyboard-backlight": {
    "icon": "\uf11c",
    "label": "Keyboard Backlight",
    "description": "Toggles (on/off) the keyboard backlight",
    "aliases": ["kbd-light", "keyboard-light", "kbd-backlight"],
    "when": "ls /sys/class/leds/*kbd_backlight* >/dev/null 2>&1",
    "checked": "[[ \$(cat /sys/class/leds/*kbd_backlight*/brightness) == 0 ]]",
    "action": "kbd-toggle"
  }
$BLOCK_END
BLOCK_EOF
}

if [[ $REMOVE == true ]]; then
  if [[ -f $MENU ]] && grep -qF "$BLOCK_START" "$MENU"; then
    start_line=$(grep -nF "$BLOCK_START" "$MENU" | cut -d: -f1 | head -1)
    end_line=$(grep -nF "$BLOCK_END" "$MENU" | cut -d: -f1 | head -1)
    if [[ -n $start_line && -n $end_line && $end_line -gt $start_line ]]; then
      tmp=$(mktemp)
      head -n $((start_line - 1)) "$MENU" > "$tmp"
      tail -n +$((end_line + 1)) "$MENU" >> "$tmp"
      mv "$tmp" "$MENU"
      write_menu >/dev/null
      ok "Keyboard Backlight entry removed from the menu"
    else
      warn "Inconsistent markers in $MENU, nothing removed."
    fi
  else
    ok "No Keyboard Backlight block in the menu, nothing to do."
  fi
  exit 0
fi

info "Adding the 'Trigger > Hardware > Keyboard Backlight' entry"
mkdir -p "$MENU_DIR"

BLOCK_TMP=$(mktemp)
read_block > "$BLOCK_TMP"

if [[ ! -f $MENU ]]; then
  {
    echo "{"
    cat "$BLOCK_TMP"
    echo "}"
  } > "$MENU"
elif grep -qF "$BLOCK_START" "$MENU"; then
  start_line=$(grep -nF "$BLOCK_START" "$MENU" | cut -d: -f1 | head -1)
  end_line=$(grep -nF "$BLOCK_END" "$MENU" | cut -d: -f1 | head -1)
  if [[ -z $start_line || -z $end_line || $end_line -le $start_line ]]; then
    rm -f "$BLOCK_TMP"
    warn "Inconsistent markers in $MENU, manual correction needed."
    exit 1
  fi
  tmp=$(mktemp)
  head -n $((start_line - 1)) "$MENU" > "$tmp"
  cat "$BLOCK_TMP" >> "$tmp"
  tail -n +$((end_line + 1)) "$MENU" >> "$tmp"
  mv "$tmp" "$MENU"
else
  close_line=$(grep -n "^}" "$MENU" | cut -d: -f1 | tail -1 || true)
  tmp=$(mktemp)
  if [[ -n ${close_line:-} ]]; then
    head -n $((close_line - 1)) "$MENU" > "$tmp"
    cat "$BLOCK_TMP" >> "$tmp"
    tail -n +${close_line} "$MENU" >> "$tmp"
  else
    cp "$MENU" "$tmp"
    cat "$BLOCK_TMP" >> "$tmp"
    echo "}" >> "$tmp"
  fi
  mv "$tmp" "$MENU"
fi
rm -f "$BLOCK_TMP"

# Automatic comma repair + validity check
if ! write_menu >/dev/null; then
  warn "Could not repair the JSON automatically."
  warn "Fix $MENU manually then rerun this script."
  exit 1
fi

ok "Menu configured: Trigger > Hardware > Keyboard Backlight"
echo "  (omarchy-menu.jsonc is reloaded automatically; otherwise: omarchy restart shell)"

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
info "Setup complete. Summary:"
echo "  • Omarchy menu  -> Trigger > Hardware > Keyboard Backlight (on/off toggle)"
echo "  • Terminal      -> kbd-toggle [on|off]"
echo "  • Remove        -> ./fix-keyboard-backlight-menu.sh --remove"
