#!/usr/bin/env bash
# setup-basalt-menu.sh — Basalt integration: Omarchy menu entry + launcher.
# =============================================================================
# Basalt (https://github.com/erikjuhani/basalt, AUR package "basalt") is a TUI
# for Obsidian vaults and notes. The package installs /usr/bin/basalt but no
# user-facing launcher, so nothing picks it up in the Omarchy menu.
#
# This script (called by setup-tuis.sh after the AUR install, standalone too):
#   1. Installs/normalizes ~/.local/share/applications/basalt.desktop.
#   2. Adds the "trigger.system.basalt" entry to
#      ~/.config/omarchy/extensions/omarchy-menu.jsonc (independent marked
#      block, JSONC comma repair + validity check — same technique as
#      setup-caligula-menu.sh / setup-septabee-menu.sh).
#
# Usage:
#   ./setup-basalt-menu.sh            # applies (idempotent)
#   ./setup-basalt-menu.sh --remove   # removes the entry + launcher
#
# NOTE: if an Omarchy update overwrites omarchy-menu.jsonc, rerunning this
# script (or setup-tuis.sh) is enough to re-apply the entry.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

info() { echo -e "\033[1;34m==>\033[0m $*"; }
ok()   { echo -e "\033[1;32m ✓\033[0m $*"; }
warn() { echo -e "\033[1;33m !\033[0m $*"; }

BIN=/usr/bin/basalt
DESKTOP_DST="$HOME/.local/share/applications/basalt.desktop"
MENU_DIR="$HOME/.config/omarchy/extensions"
MENU="$MENU_DIR/omarchy-menu.jsonc"
BLOCK_START="// >>> Omarchy_Custom_Scripts - basalt (managed by setup-basalt-menu.sh)"
BLOCK_END="// <<< Omarchy_Custom_Scripts - basalt (managed by setup-basalt-menu.sh)"

REMOVE=false
[[ ${1:-} == "--remove" ]] && REMOVE=true

if [[ $REMOVE == true ]]; then
  rm -f "$DESKTOP_DST"
  ok "Launcher removed (the basalt package itself is untouched)."
else
  mkdir -p "$(dirname "$DESKTOP_DST")"
  cat > "$DESKTOP_DST" <<EOF
[Desktop Entry]
Type=Application
Name=Basalt
Comment=Manage Obsidian vaults and notes (terminal TUI) — installed via mosquitOmarchy
Exec=omarchy-launch-or-focus-tui basalt
Terminal=false
Icon=utilities-terminal
Categories=Utility;Office;
EOF
  ok "Launcher installed ($DESKTOP_DST)"
fi

command -v update-desktop-database >/dev/null 2>&1 \
  && update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true

# -----------------------------------------------------------------------------
# JSONC utility: repairs the commas of omarchy-menu.jsonc (idempotent)
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
        if re.match(r'^[ \t]*\}$', l.rstrip()) and not l.rstrip().endswith(','):
            j = i + 1
            while j < len(lines):
                t = lines[j]
                if not t.strip() or t.lstrip().startswith('//'):
                    j += 1
                    continue
                break
            if j < len(lines) and re.match(r'^[ \t]*"', lines[j]):
                lines[i] = l.rstrip() + ','
        i += 1
    return '\n'.join(lines)

def main():
    mode, path = sys.argv[1], sys.argv[2]
    with open(path) as f:
        text = f.read()

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

    if mode == "write":
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

read_block() {
  cat <<BLOCK_EOF
$BLOCK_START
  "trigger.system.basalt": {
    "icon": "\uf0f6",
    "label": "Basalt — Obsidian notes",
    "description": "Manage Obsidian vaults and notes (terminal TUI)",
    "aliases": ["basalt", "obsidian", "notes", "vault"],
    "when": "test -x $BIN",
    "action": "omarchy-launch-or-focus-tui basalt"
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
      ok "Basalt entry removed from the Omarchy menu"
    else
      warn "Inconsistent markers in $MENU, nothing removed."
    fi
  else
    ok "No Basalt block in the menu, nothing to do."
  fi
  root_line=$(grep -n "^}" "$MENU" 2>/dev/null | cut -d: -f1 | tail -1 || true)
  if [[ -n $root_line ]]; then
    last_close=$(awk -v r="$root_line" 'NR < r && /^[ \t]*\}[ \t]*,?[ \t]*$/ { ln=NR } END { print ln }' "$MENU")
    if [[ -n $last_close ]] && sed -n "${last_close}p" "$MENU" | grep -q ',[[:space:]]*$'; then
      sed -i "${last_close}s/,[[:space:]]*$//" "$MENU"
    fi
  fi
  write_menu >/dev/null || { warn "Could not repair $MENU — fix it manually."; exit 1; }
  exit 0
fi

[[ -x $BIN ]] || warn "Basalt is not installed yet ($BIN) — the entry stays hidden until then."

info "Adding the 'Trigger > System > Basalt' menu entry"
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

if ! write_menu >/dev/null; then
  warn "Could not repair the JSON automatically."
  warn "Fix $MENU manually then rerun this script."
  exit 1
fi

ok "Menu configured: Trigger > System > Basalt"
echo "  (omarchy-menu.jsonc is reloaded automatically; otherwise: omarchy restart shell)"
