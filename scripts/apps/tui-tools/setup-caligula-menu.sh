#!/usr/bin/env bash
# setup-caligula-menu.sh — Caligula integration: Omarchy menu entry + icon +
# launch fix. =============================================================================
# Caligula is an interactive disk-imaging TUI (AUR package "caligula-git",
# upstream https://caligula.audio-less.app). Two gotchas this script solves:
#   • caligula-git installs /usr/bin/caligula + icons but NO user-facing
#     launcher, so nothing picks it up in the app menu by default.
#   • bare `caligula` just prints its usage and exits (rc=2), and even `burn`
#     aborts unless given a real IMAGE file — so we install a tiny
#     ~/.local/bin/caligula-ui wrapper that prompts for the image (via
#     omarchy-file-select/zenity) when none is given, then starts the burn TUI
#     in auto-interactive mode (it asks which disk to write — no -o needed).
#
# This script (called by setup-tuis.sh after the AUR install, standalone too):
#   1. Installs the icon
#      ~/.local/share/icons/hicolor/256x256/apps/caligula.png
#      (repo asset scripts/apps/tui-tools/caligula-logo.png).
#   2. Installs the launcher wrapper ~/.local/bin/caligula-ui.
#   3. Installs/normalizes ~/.local/share/applications/caligula.desktop
#      (replacing any stale Caligula.desktop whose Exec fired `caligula` bare
#      and only ever showed the usage screen).
#   4. Adds the "trigger.system.caligula" entry to
#      ~/.config/omarchy/extensions/omarchy-menu.jsonc (independent marked
#      block, JSONC comma repair + validity check — same technique as
#      setup-septabee-menu.sh).
#
# Usage:
#   ./setup-caligula-menu.sh            # applies (idempotent)
#   ./setup-caligula-menu.sh --remove   # removes the entry + icon + launcher
#
# NOTE: if an Omarchy update overwrites omarchy-menu.jsonc, rerunning this
# script (or setup-tuis.sh) is enough to re-apply the entry.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

info() { echo -e "\033[1;34m==>\033[0m $*"; }
ok()   { echo -e "\033[1;32m ✓\033[0m $*"; }
warn() { echo -e "\033[1;33m !\033[0m $*"; }

BIN=/usr/bin/caligula
WRAPPER_DST="$HOME/.local/bin/caligula-ui"
ICON_SRC="$SCRIPT_DIR/caligula-logo.png"
ICON_DST="$HOME/.local/share/icons/hicolor/256x256/apps/caligula.png"
DESKTOP_DST="$HOME/.local/share/applications/caligula.desktop"
DESKTOP_LEGACY="$HOME/.local/share/applications/Caligula.desktop"
MENU_DIR="$HOME/.config/omarchy/extensions"
MENU="$MENU_DIR/omarchy-menu.jsonc"
BLOCK_START="// >>> Omarchy_Custom_Scripts - caligula (managed by setup-caligula-menu.sh)"
BLOCK_END="// <<< Omarchy_Custom_Scripts - caligula (managed by setup-caligula-menu.sh)"

REMOVE=false
[[ ${1:-} == "--remove" ]] && REMOVE=true

# -----------------------------------------------------------------------------
# 1. Icon + launcher wrapper + .desktop
# -----------------------------------------------------------------------------
if [[ $REMOVE == true ]]; then
  rm -f "$ICON_DST"
  rm -f "$WRAPPER_DST"
  rm -f "$DESKTOP_DST"
  ok "Removed icon, wrapper and launcher (caligula-git still installs the CLI)."
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

  # The launcher: bare `caligula` only prints usage and exits (rc=2), and
  # even `burn` must be given a real IMAGE — the interactive disk picker needs
  # a valid image path or the CLI just aborts. This wrapper therefore prompts
  # for the image file when none was given, then starts the burn TUI (auto
  # interactive mode: it asks which disk to write, no -o needed).
  mkdir -p "$HOME/.local/bin"
  if [[ ! -f $WRAPPER_DST ]] || ! grep -q "omarchy-file-select\|zenity" "$WRAPPER_DST"; then
    cat > "$WRAPPER_DST" <<'EOF'
#!/usr/bin/env bash
# Launcher wrapper for Caligula's interactive TUI — bare `caligula` only
# prints usage and exits; the burn flow needs a real IMAGE, so pick one
# here when none was passed, then start the interactive disk-picking TUI.
set -euo pipefail
image="${1:-}"
if [[ -z $image ]]; then
  if command -v omarchy-file-select >/dev/null 2>&1; then
    image=$(omarchy-file-select --title "Image to flash (ISO/IMG/BIN/DD)" --extensions "iso img bin dd" 2>/dev/null | head -1)
  elif command -v zenity >/dev/null 2>&1; then
    image=$(zenity --file-selection --title="Image to flash (ISO/IMG/BIN/DD)" --file-filter="Images | *.iso *.img *.bin *.dd" 2>/dev/null) || true
  else
    read -r -p "Image to flash (ISO/IMG/BIN/DD): " image
  fi
fi
[[ -n $image ]] || { echo "No image selected — Caligula not launched." >&2; exit 0; }
exec caligula burn "$image"
EOF
    chmod +x "$WRAPPER_DST"
    ok "Launcher wrapper installed ($WRAPPER_DST)"
  else
    ok "Launcher wrapper already in place ($WRAPPER_DST)"
  fi

  # Normalize the .desktop (the user's earlier one launched bare `caligula`,
  # which only showed the usage screen) — a stale desktop gets replaced.
  stale_exec="Exec=xdg-terminal-exec"
  if [[ -f $DESKTOP_LEGACY ]] && grep -Eq "Exec=.*caligula" "$DESKTOP_LEGACY"; then
    if ! grep -q "caligula-ui" "$DESKTOP_LEGACY"; then
      warn "Replacing stale $DESKTOP_LEGACY (bare 'caligula' only shows usage, never launches)"
      rm -f "$DESKTOP_LEGACY"
    fi
  fi
  if [[ -f $DESKTOP_DST ]] && ! grep -q "caligula-ui" "$DESKTOP_DST"; then
    warn "Replacing stale $DESKTOP_DST (non-functional Exec)"
    rm -f "$DESKTOP_DST"
  fi
  if [[ ! -f $DESKTOP_DST ]]; then
    mkdir -p "$(dirname "$DESKTOP_DST")"
    cat > "$DESKTOP_DST" <<EOF
[Desktop Entry]
Type=Application
Name=Caligula
Comment=Interactive disk imaging (flash ISOs/USB drives, terminal) — installed via mosquitOmarchy
Exec=omarchy-launch-or-focus-tui caligula-ui
Terminal=false
Icon=caligula
Categories=System;Utility;
EOF
    ok "Launcher installed ($DESKTOP_DST)"
  else
    ok "Launcher already in place ($DESKTOP_DST)"
  fi
fi

command -v gtk-update-icon-cache >/dev/null 2>&1 \
  && gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" >/dev/null 2>&1 || true
command -v update-desktop-database >/dev/null 2>&1 \
  && update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true

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

# -----------------------------------------------------------------------------
# 3. "Trigger > System > Caligula" entry in the Omarchy menu
# -----------------------------------------------------------------------------
read_block() {
  cat <<BLOCK_EOF
$BLOCK_START
  "trigger.system.caligula": {
    "icon": "\uf0c7",
    "label": "Caligula — disk imaging",
    "description": "Interactive disk imaging: flash ISOs/USB drives (terminal TUI)",
    "aliases": ["caligula", "iso", "disk", "drive", "usb", "flash", "dd"],
    "when": "test -x $BIN",
    "action": "omarchy-launch-or-focus-tui caligula-ui"
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
      ok "Caligula entry removed from the Omarchy menu"
    else
      warn "Inconsistent markers in $MENU, nothing removed."
    fi
  else
    ok "No Caligula block in the menu, nothing to do."
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

[[ -x $BIN ]] || warn "Caligula is not installed yet ($BIN) — the entry stays hidden until then."

info "Adding the 'Trigger > System > Caligula' menu entry"
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

ok "Menu configured: Trigger > System > Caligula"
echo "  (omarchy-menu.jsonc is reloaded automatically; otherwise: omarchy restart shell)"

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
info "Setup complete. Summary:"
echo "  • Omarchy menu  -> Trigger > System > Caligula (launches $WRAPPER_DST)"
echo "  • App launcher  -> $DESKTOP_DST (icon caligula)"