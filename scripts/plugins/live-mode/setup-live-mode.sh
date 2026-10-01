#!/usr/bin/env bash
# setup-live-mode.sh — installs the Omarchy LIVE MODE system.
#
# What it installs:
#   1. binaries       (~/.local/bin): live-mode, live-mode-watch, live-mode-root
#                      (+ mosquito-live-mode-tui built from ./tui-go)
#   2. sudoers        (/etc/sudoers.d/live-mode) : NOPASSWD for live-mode-root
#                      (command + env_keep, same pattern as battery-management)
#   3. QML overlay    (~/.config/omarchy/plugins/mosquito.livemode) : red frame
#   4. menu entries   (~/.config/omarchy/extensions/omarchy-menu.jsonc):
#                      trigger > music > "live mode" (toggle)
#                      trigger > music > "manage live mode" (TUI)
#
# Run as the affected user. The sudoers part requires root —
#   sudo bash setup-live-mode.sh        (full install)
#   sudo bash setup-live-mode.sh --uninstall
#   bash setup-live-mode.sh --status    (read-only, no sudo)
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/marker-strip.bash"  # marker_strip: safe managed-block removal
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/elevate.bash"  # mq_sudo: themed prompt, one question per run
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_USER="${SUDO_USER:-${LOGNAME:-$USER}}"
REAL_HOME=$(eval echo "~$REAL_USER" 2>/dev/null || echo "$HOME")
BIN_DIR="$REAL_HOME/.local/bin"
MENU_DIR="$REAL_HOME/.config/omarchy/extensions"
MENU="$MENU_DIR/omarchy-menu.jsonc"
PLUG_DIR="$REAL_HOME/.config/omarchy/plugins"
PLUG_INST="$PLUG_DIR/mosquito.livemode"
PLUG_SRC="$SCRIPT_DIR/omarchy-plugins/mosquito.livemode"
TUI_SRC="$SCRIPT_DIR/tui-go"

MENU_START="// >>> Omarchy_Custom_Scripts - live-mode (managed by setup-live-mode.sh)"
MENU_END="// <<< Omarchy_Custom_Scripts - live-mode (managed by setup-live-mode.sh)"
SUDOERS_FILE="/etc/sudoers.d/live-mode"

REMOVE=false
YES=0
STATUS_ONLY=0

ok()   { printf '\033[32m●\033[0m %s\n' "$*"; }
warn() { printf '\033[33m●\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[31m●\033[0m %s\n' "$*" >&2; }

usage() {
  cat <<USAGE_EOF
Usage: $0 [options]

  (no option)          interactive menu (install / uninstall / status / quit)
  -y, --yes            non-interactive install (idempotent)
  --uninstall, --remove  remove sudoers + menu entry + plugin (binaries stay)
  --status             show the current state, modify nothing
  -h, --help           this help

  The sudoers part requires root: run with 'sudo bash $0' (or '$0' options).
USAGE_EOF
}

# ---------------------------------------------------------------------------
# 1. Binaries
# ---------------------------------------------------------------------------

install_binaries() {
  mkdir -p "$BIN_DIR"
  cp "$SCRIPT_DIR/live-mode"      "$BIN_DIR/live-mode"
  cp "$SCRIPT_DIR/live-mode-watch" "$BIN_DIR/live-mode-watch"
  cp "$SCRIPT_DIR/live-mode-root" "$BIN_DIR/live-mode-root"
  chmod 755 "$BIN_DIR/live-mode" "$BIN_DIR/live-mode-watch" "$BIN_DIR/live-mode-root"
  ok "Binaries installed: live-mode, live-mode-watch, live-mode-root"

  if [[ -d "$TUI_SRC" ]]; then
    if [[ ! -f "$TUI_SRC/go.sum" ]]; then
      (cd "$TUI_SRC" && go mod tidy >/dev/null 2>&1) || warn "go mod tidy skipped"
    fi
    local out
    out=$( (cd "$TUI_SRC" && go build -o "$BIN_DIR/mosquito-live-mode-tui" .) 2>&1 ) || {
      warn "Could not build the manage TUI (go said: $out)"
      return 0
    }
    chmod 755 "$BIN_DIR/mosquito-live-mode-tui"
    ok "Manage TUI built and installed: $BIN_DIR/mosquito-live-mode-tui"
  fi
}

# ---------------------------------------------------------------------------
# 1b. mosquito patchbay (parked in the scratchpad by live mode).
#
# Our own `mosquito-patchbay` is what live mode will drive once it exists. Until
# then qpwgraph stands in for it, so a machine never loses the feature just
# because our binary is not written yet. The native one wins whenever it is
# installed; qpwgraph is only a fallback, and if NEITHER is there we say how to
# get one rather than leaving live mode to skip the step silently.
# ---------------------------------------------------------------------------

PATCHBAY_BIN_NAME="mosquito-patchbay"

install_routing_tool() {
  if [[ -x "$REAL_HOME/.local/bin/$PATCHBAY_BIN_NAME" ]] || command -v "$PATCHBAY_BIN_NAME" >/dev/null 2>&1; then
    ok "mosquito patchbay present: $PATCHBAY_BIN_NAME"
    return 0
  fi
  if command -v qpwgraph >/dev/null 2>&1; then
    ok "mosquito patchbay: using qpwgraph as the stand-in until $PATCHBAY_BIN_NAME exists."
    return 0
  fi
  # Neither. Offer qpwgraph now (it is the only thing that can be installed
  # today); the native patchbay comes from the mosquitomarchy setup itself.
  if [[ $EUID -eq 0 ]] && command -v pacman >/dev/null 2>&1; then
    if pacman -S --needed --noconfirm qpwgraph >/dev/null 2>&1; then
      ok "mosquito patchbay installed (qpwgraph stand-in): qpwgraph"
    else
      warn "Could not install qpwgraph (pacman failed) — install it manually."
    fi
  else
    warn "No mosquito patchbay available. Run the mosquitomarchy setup for the native one,"
    warn "or install the stand-in (root): pacman -S qpwgraph"
  fi
}

# ---------------------------------------------------------------------------
# 1c. Hyprland float rule: all mosquito terminal managers open untiled, at
# the same fixed foot size (-W 92x92 at launch). Idempotent marked block in
# hyprland.lua, the same pattern fix-keepassxc-window.sh established.
# ---------------------------------------------------------------------------

CONF_HYPR="$REAL_HOME/.config/hypr/hyprland.lua"
FLOAT_START="-- >>> live-mode-tui-floating >>> mosquito terminal managers open untiled"
FLOAT_END="-- >>> live-mode-tui-floating <<<"

install_hypr_rule() {
  mkdir -p "$(dirname "$CONF_HYPR")"
  touch "$CONF_HYPR"
  # Strip an earlier block (idempotent install).
  marker_strip "$CONF_HYPR" "$FLOAT_START" "$FLOAT_END"
  cat >> "$CONF_HYPR" <<EOF
$FLOAT_START
-- Live Mode's own TUI floats + centered, and no pixel size is forced: its
-- dispatcher launches foot with -W 92x92, so the terminal keeps its square
-- geometry and no title gets clipped.
--
-- Only its OWN TUI. This block used to also carry the audio-plugin-manager and
-- move-manager TUIs, which duplicated the rules their own setup scripts already
-- install under "mosquito-audio-plugin-manager-tui-setup" and
-- "move-manager-tui-setup" — two identical o.window lines for the same class in
-- the same file. Whoever needs those rules now owns them in one place only.
o.window("org.omarchy.mosquito-live-mode-tui", { float = true, center = true })
$FLOAT_END
EOF
  ok "Hyprland rule installed: mosquito live-mode TUI opens untiled (foot 92x92)"
}

remove_hypr_rule() {
  marker_strip "$CONF_HYPR" "$FLOAT_START" "$FLOAT_END" 2>/dev/null || true
  ok "Hyprland float rule removed"
}

refresh_hypr() {
  hyprctl reload >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# 2. Sudoers
# ---------------------------------------------------------------------------

install_sudoers() {
  # Ask for the elevation instead of only warning that it is needed.
  #
  # This used to bail out with "Sudoers requires root — run: sudo bash <this
  # script>". That made the module report `partial` on every install, so the
  # run ended in "Install finished with errors" while the user had in fact
  # installed everything and had never been asked for a password: the file the
  # module exists to write was simply never written, and nothing prompted.
  #
  # mq_sudo raises the same password prompt Omarchy uses everywhere else
  # (themed, one question per run) and the rest of the run reuses that cache.
  local body
  body="$(cat <<SUDOEOF
$REAL_USER ALL=(root) NOPASSWD: $BIN_DIR/live-mode-root apply, $BIN_DIR/live-mode-root restore, $BIN_DIR/live-mode-root status, $BIN_DIR/live-mode-root thermal-cap *, $BIN_DIR/live-mode-root thermal-restore
Defaults! $BIN_DIR/live-mode-root env_keep += "DISPLAY WAYLAND_DISPLAY XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS"
SUDOEOF
)"
  if [[ $EUID -ne 0 ]]; then
    printf '\033[34m==>\033[0m Asking for the password to write %s (one question; the rest of the run reuses it)…\n' "$SUDOERS_FILE"
  fi
  # The body goes through STDIN, never through the environment or the command
  # line: pkexec scrubs the environment, and a sudoers line is full of spaces
  # and quotes, so both of those are ways to write a different file than the
  # one you meant. stdin is identical under sudo and under pkexec.
  if ! printf '%s\n' "$body" | mq_sudo tee "$SUDOERS_FILE" >/dev/null; then
    err "Could not write $SUDOERS_FILE"
    return 1
  fi
  mq_sudo chmod 440 "$SUDOERS_FILE" 2>/dev/null || chmod 440 "$SUDOERS_FILE" 2>/dev/null || true
  # visudo must run as root too: the file is root-owned 0440, and a sudoers
  # check that runs as the user cannot read it, so it reported "invalid" for a
  # perfectly good file and the script deleted it again.
  if mq_sudo visudo -cf "$SUDOERS_FILE" &>/dev/null; then
    # Marker for the status check. /etc/sudoers.d is drwxr-x--- root, so
    # "is the sudoers file there?" is NOT a question the user account can
    # answer, and answering it needs a password — which a status read must
    # never demand. The setup therefore records the outcome somewhere the user
    # CAN read, and the status reads that. It is written last, so it only exists
    # once the file really is installed and validated.
    mkdir -p "$REAL_HOME/.local/state/mosquitomarchy"
    printf 'installed\n' > "$REAL_HOME/.local/state/mosquitomarchy/live-mode-sudoers"
    ok "Sudoers installed (NOPASSWD live-mode-root + env_keep)"
  else
    mq_sudo rm -f "$SUDOERS_FILE" 2>/dev/null || rm -f "$SUDOERS_FILE" 2>/dev/null || true
    err "Sudoers invalid — removed."
    return 1
  fi
}

remove_sudoers() {
  # Same as install: ask, do not only warn. A leftover sudoers grant is a
  # privilege the user believes they revoked, so it must not silently stay
  # behind because the uninstall could not raise a password.
  [[ -f "$SUDOERS_FILE" ]] || { ok "No sudoers file to remove."; return 0; }
  if mq_sudo rm -f "$SUDOERS_FILE"; then
    rm -f "$REAL_HOME/.local/state/mosquitomarchy/live-mode-sudoers"
    ok "Sudoers removed."
  else
    err "Could not remove $SUDOERS_FILE — remove it with: sudo rm -f '$SUDOERS_FILE'"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# 3. QML overlay plugin
# ---------------------------------------------------------------------------

install_plugin() {
  [[ -f "$REAL_HOME/.config/omarchy/shell.json" ]] || return 0
  if [[ -d "$PLUG_INST" ]]; then
    ok "Plugin mosquito.livemode already present"
  elif [[ -d "$PLUG_SRC" ]]; then
    mkdir -p "$PLUG_DIR"
    cp -a "$PLUG_SRC/." "$PLUG_INST/"
    ok "Plugin mosquito.livemode installed (overlay)"
  else
    warn "Plugin sources missing in $PLUG_SRC"
    return 0
  fi
  omarchy plugin enable mosquito.livemode >/dev/null 2>&1 || true
  ok "Plugin mosquito.livemode enabled"
}

remove_plugin() {
  rm -rf "$PLUG_INST"
  omarchy plugin disable mosquito.livemode >/dev/null 2>&1 || true
  ok "Plugin mosquito.livemode removed"
}

# ---------------------------------------------------------------------------
# 4. Menu entry (same managed-block pattern as setup-ableton-move-manager.sh)
# ---------------------------------------------------------------------------

FIX_JSONC=$(cat << 'PYEOF'
import json, re, sys, io
path = sys.argv[1]
data = io.open(path, encoding='utf-8').read()
data = re.sub(r'(?m)^[ \t]*//.*$', '', data)
data = re.sub(r'/\*.*?\*/', '', data, flags=re.S)
data = re.sub(r',(\s*[}\]])', r'\1', data)
try:
    json.loads(data)
    print("ok")
except Exception as e:
    sys.stderr.write("menu-not-json: %s\n" % e)
    sys.exit(1)
PYEOF
)

write_menu() {
  if [[ ! -f $MENU ]]; then return 0; fi
  local out
  out=$(python3 -c "$FIX_JSONC" "$MENU" 2>&1) || {
    warn "Invalid JSONC in $MENU (python said: $out)"
    return 1
  }
  ok "Menu $MENU valid"
  return 0
}

ensure_menu_readable() {
  [[ -f $MENU ]] || return 0
  chmod 644 "$MENU" 2>/dev/null || true
  if [[ $EUID -eq 0 ]]; then
    chown "$REAL_USER:$REAL_USER" "$MENU" 2>/dev/null || true
  fi
}

# Remove the Trigger > Music live-mode objects from a menu that has no managed
# markers, editing the raw text. Brace counting, not json.dumps: the menu is
# JSONC and a re-serialisation silently drops every comment, including the
# ">>> ... <<<" markers mosquitomarchy-setup.sh uses to replace its own block.
remove_legacy_unmarked() {
  [[ -f $MENU ]] || return 1
  local out
  out=$(python3 - "$MENU" <<'PY' 2>&1
import io, re, sys

path = sys.argv[1]
text = io.open(path, encoding='utf-8').read()
original = text
KEYS = ('trigger.music.live-mode-manage', 'trigger.music.live-mode')


def cut(text, key):
    m = re.search(r'"%s"\s*:\s*\{' % re.escape(key), text)
    if not m:
        return None
    start = m.start()
    depth = 0
    i = m.end() - 1
    end = None
    while i < len(text):
        if text[i] == '{':
            depth += 1
        elif text[i] == '}':
            depth -= 1
            if depth == 0:
                end = i + 1
                break
        i += 1
    if end is None:
        return None
    # Swallow the separating comma, whichever side it sits on.
    j = end
    while j < len(text) and text[j] in ' \t':
        j += 1
    if j < len(text) and text[j] == ',':
        end = j + 1
    else:
        k = start
        while k > 0 and text[k - 1] in ' \t':
            k -= 1
        if k > 0 and text[k - 1] == ',':
            text = text[:k - 1] + text[k:]
            start = k - 1
    # Take the whole line when the object sits alone on it, indentation included.
    ls = text.rfind('\n', 0, start) + 1
    head = ls if text[ls:start].strip() == '' else start
    le = text.find('\n', end)
    le = len(text) if le == -1 else le + 1
    tail = le if text[end:le].strip() == '' else end
    return text[:head] + text[tail:]


for key in KEYS:
    while True:
        nxt = cut(text, key)
        if nxt is None:
            break
        text = nxt

if text == original:
    sys.exit(1)
io.open(path, 'w', encoding='utf-8').write(text)
sys.stderr.write('legacy live-mode entries removed')
PY
  ) || return 1
  printf '%s' "$out" >/dev/null
  return 0
}

menu_block() {
  # One entry: a TOGGLE, not a launcher. The manager TUI stays under
  # Setup > mosquito (mosquitomarchy-setup.sh owns that), and the old
  # Trigger > Music duplicates are gone; what was missing was the one row that
  # actually turns live mode on, which is the thing you reach for mid-set.
  #
  # `checked` must reflect the real state, so the row ticks itself off when the
  # session is over. It is a command substitution, evaluated by the menu on
  # every open, so it cannot go stale the way a written-out state file does.
  #
  # These MUST be // comments: the menu is JSONC and the installer validates it
  # by stripping // lines.
  cat <<MC_EOF
$MENU_START
  "trigger.toggle.live-mode": {
    // U+1F534 RED CIRCLE, not fa-circle (U+F111). The menu has no per-entry
    // colour at all — MenuModel.labelFor() only ever appends a tick — so the
    // glyph is the only thing that CAN carry the red this row is supposed to
    // announce, and a Nerd Font glyph renders in the menu's single foreground
    // colour: the old \uf111 came out as a plain circle in the text colour,
    // which is why it never read as the live/performance indicator it is.
    // A colour emoji is the one glyph class that brings its own colour.
    "icon": "\ud83d\udd34",
    "label": "Live Mode",
    "description": "Performance session mode: keep the machine awake, thermal guard, no idle suspend",
    "aliases": ["live", "live-mode", "lmm", "toggle-live"],
    "when": "test -x $BIN_DIR/live-mode",
    "checked": "$BIN_DIR/live-mode --active",
    "action": "$BIN_DIR/live-mode toggle"
  },
$MENU_END
MC_EOF
}


menu_block_range() {
  local file="$1" start="" end="" l
  l=$(grep -nF "$MENU_START" "$file" 2>/dev/null | head -1 | cut -d: -f1)
  [[ -n $l ]] || return 1
  start=$l
  l=$(grep -nF "$MENU_END" "$file" 2>/dev/null | awk -F: -v s="$start" '$1 >= s { print $1; exit }')
  [[ -n $l ]] || return 1
  end=$l
  echo "$start $end"
}

install_menu() {
  if [[ -f $MENU ]] && { [[ ! -r $MENU || ! -w $MENU ]]; }; then
    warn "Menu $MENU is root-readable only — install it with: sudo bash $0"
    return 0
  fi
  mkdir -p "$MENU_DIR" || { warn "Menu directory not writable — install it with: sudo bash $0"; return 0; }
  local block range start_line end_line open_line tmp
  block="$(menu_block)"
  if [[ ! -f $MENU ]]; then
    printf '{\n%s\n}\n' "$block" > "$MENU"
  elif range=$(menu_block_range "$MENU"); then
    start_line=${range% *}
    end_line=${range#* }
    if [[ -z $start_line || -z $end_line || $end_line -le $start_line ]]; then
      warn "Inconsistent live-mode markers in $MENU — manual fix needed."
      return 0
    fi
    tmp=$(mktemp)
    head -n $((start_line - 1)) "$MENU" > "$tmp"
    printf '%s\n' "$block" >> "$tmp"
    tail -n +$((end_line + 1)) "$MENU" >> "$tmp"
    mv "$tmp" "$MENU"
  else
    # No managed markers, but a live-mode entry is present: a menu written by a
    # version from before the markers existed. Cut it out of the raw text rather
    # than bailing out — "manual fix needed" left the duplicates in the menu
    # forever, and re-serialising the file with json.dumps would have thrown away
    # every comment, including mosquitomarchy-setup.sh's own markers.
    if grep -qF '"trigger.music.live-mode"' "$MENU"; then
      if remove_legacy_unmarked; then
        ok "Removed the unmarked legacy live-mode entries (they no longer belong in the menu)."
      else
        warn "Could not remove the unmarked legacy live-mode entries — fix $MENU manually."
        return 0
      fi
    fi
    open_line=$(grep -n '^{[[:space:]]*$' "$MENU" | head -1 | cut -d: -f1 || true)
    tmp=$(mktemp)
    if [[ -n $open_line ]]; then
      head -n ${open_line} "$MENU" > "$tmp"
      printf '%s\n' "$block" >> "$tmp"
      tail -n +$((open_line + 1)) "$MENU" >> "$tmp"
    else
      cp "$MENU" "$tmp"
      printf '%s\n' "$block" >> "$tmp"
      printf '%s\n' '}' >> "$tmp"
    fi
    mv "$tmp" "$MENU"
  fi
  if write_menu; then
    ok "Menu checked: Trigger > Toggle > Live Mode entry present"
  else
    warn "Menu JSONC invalid after adding the entries — fix $MENU manually."
  fi
  ensure_menu_readable
}

remove_menu() {
  if [[ -f $MENU ]] && { [[ ! -r $MENU || ! -w $MENU ]]; }; then
    warn "Menu $MENU is root-readable only — remove it with: sudo bash $0 --uninstall"
    return 0
  fi
  local range start_line end_line tmp
  if [[ -f $MENU ]] && range=$(menu_block_range "$MENU"); then
    start_line=${range% *}
    end_line=${range#* }
    if [[ -n $start_line && -n $end_line && $end_line -gt $start_line ]]; then
      tmp=$(mktemp)
      head -n $((start_line - 1)) "$MENU" > "$tmp"
      tail -n +$((end_line + 1)) "$MENU" >> "$tmp"
      mv "$tmp" "$MENU"
      sed -i ':a;N;$!ba;s/,\([[:space:]]*\n[[:space:]]*}\)/\1/' "$MENU"
      [[ -s $MENU ]] || printf '{\n}\n' > "$MENU"
      write_menu || true
      ok "Menu entries removed: live-mode / manage live mode"
    else
      warn "Inconsistent live-mode markers in $MENU."
    fi
  else
    ok "No live-mode entries in the menu, nothing to do."
  fi
  ensure_menu_readable
}

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------

status() {
  echo "── Binaries ──────────────────────────────────────────────"
  for b in live-mode live-mode-watch live-mode-root mosquito-live-mode-tui; do
    if [[ -x "$BIN_DIR/$b" ]]; then
      echo "  ✓ $BIN_DIR/$b"
    else
      echo "  ✗ $BIN_DIR/$b (missing)"
    fi
  done
  echo "── Sudoers (/etc/sudoers.d/live-mode) ────────────────────"
  # The file is root-owned and unreadable by the user on purpose, so a plain
  # -f test reported "not installed" for a sudoers file that was very much
  # there — the install had just succeeded a line earlier. The marker written
  # at install time is the user-readable proof; fall back to -f only when the
  # user CAN read it (e.g. running as root).
  if [[ -f "$HOME/.local/state/mosquitomarchy/live-mode-sudoers" ]]; then
    echo "  ✓ installed (written $(cat "$HOME/.local/state/mosquitomarchy/live-mode-sudoers" 2>/dev/null || echo earlier))"
    if [[ -r $SUDOERS_FILE ]]; then
      grep -q live-mode-root "$SUDOERS_FILE" && echo "  ✓ live-mode-root NOPASSWD present"
    else
      echo "  • contents unreadable as $(id -un) — that is normal, it is root-owned"
    fi
  elif [[ -f $SUDOERS_FILE ]]; then
    echo "  ✓ installed"
    grep -q live-mode-root "$SUDOERS_FILE" && echo "  ✓ live-mode-root NOPASSWD present"
  else
    echo "  ✗ not installed (sudo bash $0 to install)"
  fi
  echo "── Plugin (mosquito.livemode) ────────────────────────────"
  if [[ -d $PLUG_INST ]]; then
    echo "  ✓ $PLUG_INST"
  else
    echo "  ✗ not installed"
  fi
  echo "── Menu entries ──────────────────────────────────────────"
  # Two different rows: the TOGGLE under Trigger > Toggle, and the manager TUI
  # under Setup > mosquito (that one is declared by mosquitomarchy-setup.sh, so
  # it is not this script's business). The old Trigger > Music pair must stay
  # gone.
  if [[ -f $MENU ]] && grep -qF '"trigger.toggle.live-mode"' "$MENU"; then
    echo "  ✓ trigger > toggle > Live Mode (toggles the session)"
  else
    echo "  ✗ trigger > toggle > Live Mode is missing — re-run the setup"
  fi
  if [[ -f $MENU ]] && grep -qF '"trigger.music.live-mode"' "$MENU"; then
    echo "  ✗ stale trigger > music > Live Mode still in the menu — re-run the setup"
  else
    echo "  ✓ no stale trigger > music > live-mode entry"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

for arg in "$@"; do
  case "$arg" in
    -y|--yes) YES=1 ;;
    --uninstall|--remove) REMOVE=true ;;
    --status) STATUS_ONLY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown option: $arg"; usage; exit 1 ;;
  esac
done

[[ $STATUS_ONLY -eq 1 ]] && { status; exit 0; }

if [[ $REMOVE == true ]]; then
  remove_sudoers || true
  remove_menu || true
  remove_plugin || true
  ok "Live mode removed (the ~/.local/bin binaries were left in place)."
  exit 0
fi

if [[ $YES -eq 0 && ! -t 0 ]]; then
  warn "No TTY: forcing -y (use --status for read-only)."
  YES=1
fi

if [[ $YES -eq 1 ]]; then
  install_binaries
  install_routing_tool || true
  install_sudoers || true
  install_plugin
  install_menu
  install_hypr_rule
  refresh_hypr
  ok "Live mode installed. Use it via:  live-mode toggle   (or Setup ▸ mosquito ▸ Live Mode Manager)."
  exit 0
fi

PS3="Choose an option: "
show_menu() {
  local i=1
  echo
  printf '  %d) %s\n' "$i" "Install live mode";   i=$((i+1))
  printf '  %d) %s\n' "$i" "Uninstall live mode"; i=$((i+1))
  printf '  %d) %s\n' "$i" "Status";             i=$((i+1))
  printf '  %d) %s\n' "$i" "Quit"
}

select opt in "Install live mode" "Uninstall live mode" "Status" "Quit"; do
  case "$opt" in
    "Install live mode")
      install_binaries || true
      install_routing_tool || true
      install_sudoers || true
      install_plugin || true
      install_menu || true
      install_hypr_rule || true
      refresh_hypr
      echo
      ok "Install finished. Choose again or quit."
      show_menu
      ;;
    "Uninstall live mode")
      remove_sudoers || true
      remove_menu || true
      remove_plugin || true
      remove_hypr_rule || true
      refresh_hypr
      echo
      ok "Uninstall finished. Choose again or quit."
      show_menu
      ;;
    "Status") status ;;
    "Quit") break ;;
    *) err "Invalid option." ;;
  esac
done