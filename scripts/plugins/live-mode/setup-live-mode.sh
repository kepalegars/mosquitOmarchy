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
# 1b. Audio routing tool (qpwgraph — parked in the scratchpad by live mode).
# ---------------------------------------------------------------------------

install_routing_tool() {
  if command -v qpwgraph >/dev/null 2>&1; then
    ok "Audio routing tool present: qpwgraph"
    return 0
  fi
  if [[ $EUID -eq 0 ]] && command -v pacman >/dev/null 2>&1; then
    if pacman -S --needed --noconfirm qpwgraph >/dev/null 2>&1; then
      ok "Audio routing tool installed: qpwgraph"
    else
      warn "Could not install qpwgraph (pacman failed) — install it manually."
    fi
  else
    warn "qpwgraph missing — live mode will skip the routing tool. Install it (root): pacman -S qpwgraph"
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
  sed -i "/$FLOAT_START/,/$FLOAT_END/d" "$CONF_HYPR"
  cat >> "$CONF_HYPR" <<EOF
$FLOAT_START
-- All three mosquito terminal managers float + center, and none of them
-- forces a pixel size: every dispatcher launches foot with -W 92x92, so the
-- terminal keeps its square geometry and no title gets clipped.
o.window("org.omarchy.mosquito-live-mode-tui", { float = true, center = true })
o.window("org.omarchy.mosquito-audio-plugin-manager-tui", { float = true, center = true })
o.window("org.omarchy.mosquito-move-manager-tui", { float = true, center = true })
$FLOAT_END
EOF
  ok "Hyprland rule installed: mosquito TUI managers open untiled (foot 92x92)"
}

remove_hypr_rule() {
  sed -i "/$FLOAT_START/,/$FLOAT_END/d" "$CONF_HYPR" 2>/dev/null || true
  ok "Hyprland float rule removed"
}

refresh_hypr() {
  hyprctl reload >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# 2. Sudoers
# ---------------------------------------------------------------------------

install_sudoers() {
  if [[ $EUID -ne 0 ]]; then
    warn "Sudoers requires root — run: sudo bash $0"
    return 1
  fi
  cat > "$SUDOERS_FILE" <<SUDOEOF
$REAL_USER ALL=(root) NOPASSWD: $BIN_DIR/live-mode-root apply, $BIN_DIR/live-mode-root restore, $BIN_DIR/live-mode-root status, $BIN_DIR/live-mode-root thermal-cap *, $BIN_DIR/live-mode-root thermal-restore
Defaults! $BIN_DIR/live-mode-root env_keep += "DISPLAY WAYLAND_DISPLAY XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS"
SUDOEOF
  chmod 440 "$SUDOERS_FILE"
  if visudo -cf "$SUDOERS_FILE" &>/dev/null; then
    ok "Sudoers installed (NOPASSWD live-mode-root + env_keep)"
  else
    rm -f "$SUDOERS_FILE"
    err "Sudoers invalid — removed."
    return 1
  fi
}

remove_sudoers() {
  if [[ $EUID -ne 0 ]]; then
    warn "Removing the sudoers file requires root — run: sudo bash $0 --uninstall"
    return 1
  fi
  [[ -f "$SUDOERS_FILE" ]] && rm -f "$SUDOERS_FILE" && ok "Sudoers removed."
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

menu_block() {
  cat <<MC_EOF
$MENU_START
  "trigger.music.live-mode": {
    "icon": "🔴",
    "label": "Live Mode",
    "description": "Max performance, audio optimized: stays awake, thermal guard, routing tool in scratchpad, no gaps/tint",
    "aliases": ["live", "live-mode", "performance", "mode-live", "rehearsal", "mosquito"],
    "when": "test -x $BIN_DIR/live-mode",
    "checked": "test -f $REAL_HOME/.local/state/live-mode/active",
    "action": "$BIN_DIR/live-mode toggle"
  },
  "trigger.music.live-mode-manage": {
    "icon": "⚪",
    "label": "Live Mode Manager",
    "description": "Configure the next Live Mode session (thermal limit, background apps, routing tool)",
    "aliases": ["manage", "live-mode-manager", "live-manager", "mosquito"],
    "when": "test -x $BIN_DIR/mosquito-live-mode-tui",
    "action": "$BIN_DIR/live-mode manage"
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
    if grep -qF '"trigger.music.live-mode"' "$MENU"; then
      warn "Menu already contains the live-mode entry without managed markers — manual fix needed."
      return 0
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
    ok "Menu entries ensured: Trigger > Music > Live Mode / Live Mode Manager"
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
  if [[ -f $SUDOERS_FILE ]]; then
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
  if [[ -f $MENU ]] && grep -q '"trigger.music.live-mode"' "$MENU"; then
    echo "  ✓ trigger > music > Live Mode (+ manage)"
  else
    echo "  ✗ not present"
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
  ok "Live mode installed. Use it via:  live-mode toggle   (or Trigger ▸ Music ▸ Live Mode)."
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