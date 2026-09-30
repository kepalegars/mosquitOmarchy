#!/usr/bin/env bash
# setup-septabee-menu.sh — Septabee integration: Omarchy menu entry + icon.
# =============================================================================
# Septabee is a retro studio DAW / music app (AUR package "septabee",
# upstream prebuilt binaries from https://septabee.nekoweb.org). Its package
# ships a binary and a system .desktop but no icon.
#
# This script (called by setup-tuis.sh after the AUR install, standalone too):
#   1. Installs the icon       ~/.local/share/icons/hicolor/256x256/apps/septabee.png
#      (repo asset scripts/apps/tui-tools/septabee-logo.png -> splash the icon).
#   2. Installs a user-level .desktop override (~/.local/share/applications/)
#      that keeps the packaged Exec but adds the Icon (user entries take
#      precedence over /usr/share ones — idempotent, faithful to upstream).
#   3. Adds the "trigger.music.septabee" entry to
#      ~/.config/omarchy/extensions/omarchy-menu.jsonc (independent marked
#      block, under the existing "trigger.music" group), with JSONC comma
#      repair + validity check (same technique as
#      setup-keyboard-backlight-menu.sh).
#
# Usage:
#   ./setup-septabee-menu.sh            # applies (idempotent)
#   ./setup-septabee-menu.sh --remove   # removes the entry + icon + launcher
#
# NOTE: if an Omarchy update overwrites omarchy-menu.jsonc, rerunning this
# script (or setup-tuis.sh) is enough to re-apply the entry.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

info() { echo -e "\033[1;34m==>\033[0m $*"; }
ok()   { echo -e "\033[1;32m ✓\033[0m $*"; }
warn() { echo -e "\033[1;33m !\033[0m $*"; }

BIN=/usr/bin/septabee
ICON_SRC="$SCRIPT_DIR/septabee-logo.png"
ICON_DST="$HOME/.local/share/icons/hicolor/256x256/apps/septabee.png"
DESKTOP_DST="$HOME/.local/share/applications/septabee.desktop"
MENU_DIR="$HOME/.config/omarchy/extensions"
MENU="$MENU_DIR/omarchy-menu.jsonc"
BLOCK_START="// >>> Omarchy_Custom_Scripts - septabee (managed by setup-septabee-menu.sh)"
BLOCK_END="// <<< Omarchy_Custom_Scripts - septabee (managed by setup-septabee-menu.sh)"

REMOVE=false
[[ ${1:-} == "--remove" ]] && REMOVE=true

# -----------------------------------------------------------------------------
# 1. Icon
# -----------------------------------------------------------------------------
if [[ $REMOVE == true ]]; then
  rm -f "$ICON_DST"
  if [[ -f "$DESKTOP_DST" ]]; then
    rm -f "$DESKTOP_DST"
    ok "Launcher $DESKTOP_DST removed (system .desktop keeps working)"
  fi
  ok "Icon removed ($ICON_DST)"
else
  if [[ -f $ICON_SRC ]]; then
    mkdir -p "$(dirname "$ICON_DST")"
    if [[ ! -f $ICON_DST ]] || ! cmp -s "$ICON_SRC" "$ICON_DST"; then
      cp "$ICON_SRC" "$ICON_DST"
      ok "Icon installed ($ICON_DST)"
    else
      ok "Icon already in place ($ICON_DST)"
    fi
  else
    warn "No repo icon asset ($ICON_SRC) — the menu keeps its glyph only."
  fi

  if [[ -f $DESKTOP_DST ]] && ! grep -q "^Icon=septabee$" "$DESKTOP_DST"; then
    warn "Replacing the existing $DESKTOP_DST (no 'Icon=septabee'); system .desktop keeps working"
    rm -f "$DESKTOP_DST"
  fi
  if [[ ! -f $DESKTOP_DST ]] || ! grep -q "^Name=SEPTABEE$" "$DESKTOP_DST"; then
    mkdir -p "$(dirname "$DESKTOP_DST")"
    cat > "$DESKTOP_DST" <<EOF
[Desktop Entry]
Type=Application
Name=SEPTABEE
Comment=Retro studio DAW (terminal, JIT audio) — installed via mosquitOmarchy
Exec=$BIN
Terminal=false
Icon=septabee
Categories=AudioVideo;Audio;
EOF
    ok "Launcher installed ($DESKTOP_DST)"
  else
    ok "Launcher already in place ($DESKTOP_DST)"
  fi
fi

command -v gtk-update-icon-cache >/dev/null 2>&1 \
  && gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" >/dev/null 2>&1 || true

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
# 3. "Trigger > Music > SEPTABEE" entry in the Omarchy menu
# -----------------------------------------------------------------------------
read_block() {
  cat <<BLOCK_EOF
$BLOCK_START
  "trigger.music.septabee": {
    "icon": "\uf001",
    "label": "SEPTABEE",
    "description": "Retro studio DAW: audio-rate parameter modulation, JIT, circa-1987 terminal vibes",
    "aliases": ["septabee", "music", "daw", "beat", "studio"],
    "when": "test -x $BIN",
    "action": "septabee"
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
      ok "SEPTABEE entry removed from the Omarchy menu"
    else
      warn "Inconsistent markers in $MENU, nothing removed."
    fi
  else
    ok "No SEPTABEE block in the menu, nothing to do."
  fi
  # A previous entry that our block used to follow can keep a trailing comma
  # (legal only while another entry follows it) — strip it so the menu stays
  # valid even after removal, then run the usual repair + validation.
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

[[ -x $BIN ]] || warn "Septabee is not installed yet ($BIN) — the entry stays hidden until then."

info "Adding the 'Trigger > Music > SEPTABEE' menu entry"
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

ok "Menu configured: Trigger > Music > SEPTABEE"
echo "  (omarchy-menu.jsonc is reloaded automatically; otherwise: omarchy restart shell)"

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
info "Setup complete. Summary:"
echo "  • Omarchy menu  -> Trigger > Music > SEPTABEE"
echo "  • App launcher  -> $DESKTOP_DST (icon septabee)"