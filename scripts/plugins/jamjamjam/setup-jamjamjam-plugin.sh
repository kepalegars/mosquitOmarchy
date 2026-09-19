#!/usr/bin/env bash
# =============================================================================
# Omarchy Custom - jamjamjam plugin
# =============================================================================
# Installs the jamjamjam-plugin bar widget plugin into
# ~/.config/omarchy/plugins and enables it in the bar layout.
#
# The plugin provides:
#   • Real-time audio analysis: key, BPM, chord + a tuner (INPUT: PC/MIC)
#   • Chord progression + loop detection, live in the guitar neck TUI while
#     you hold its big scout button (also drives the metronome at the BPM)
#   • Guitar neck visualization of the detected key's scale (numbered degrees)
#   • Optional Shazam song hook (pip install --user shazamio, via this script)
#   • MIDI device detection + real-time chord display for played chords
#   • A simple synthesizer with 5 selectable waveforms (plays MIDI input)
#
# Usage:
#   ./setup-jamjamjam-plugin.sh           # installs/enables the plugin
#   ./setup-jamjamjam-plugin.sh --remove  # removes the plugin + bar entry
#
# Prerequisites: python3 with numpy; pw-cat, pw-record, aseqdump (PipeWire + ALSA).
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/gui-run.bash"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

info() { echo -e "\033[1;34m==>\033[0m $*"; }
ok()   { echo -e "\033[1;32m  ✓\033[0m $*"; }
warn() { echo -e "\033[1;33m  !\033[0m $*"; }
err()  { echo -e "\033[1;31m  ✗\033[0m $*" >&2; }

if [[ $EUID -eq 0 && -n ${SUDO_USER:-} ]]; then
  REAL_USER="$SUDO_USER"
else
  REAL_USER="${USER:-$(id -un)}"
fi
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
REAL_HOME="${REAL_HOME:-$HOME}"

PLUGIN_ID="jamjamjam-plugin"
PLUGIN_DIR="$REAL_HOME/.config/omarchy/plugins/$PLUGIN_ID"
PLUGIN_SRC="$SCRIPT_DIR/omarchy-plugins/$PLUGIN_ID"
SHELL_JSON="$REAL_HOME/.config/omarchy/shell.json"
BIN_DIR="$REAL_HOME/.local/bin"
TUI_SRC="$SCRIPT_DIR/tui-go"
DISPATCHER="$SCRIPT_DIR/jamjamjam-tui"
ANALYZE_SRC="$SCRIPT_DIR/jamjamjam-analyze"
ANALYZE_BIN="$BIN_DIR/jamjamjam-analyze"
BINDINGS_LUA="$REAL_HOME/.config/hypr/bindings.lua"
ANALYZE_BIND_START="-- jamjamjam-analyze-bind-start"
ANALYZE_BIND_END="-- jamjamjam-analyze-bind-end"

if [[ ! -d /usr/share/omarchy ]]; then
  echo "This script is meant for Omarchy." >&2
  exit 1
fi

REMOVE=false
[[ ${1:-} == "--remove" ]] && REMOVE=true

# -----------------------------------------------------------------------------
# Dependency check
# -----------------------------------------------------------------------------
check_dep() {
  # $1 = command, $2 = human-readable package hint
  if ! command -v "$1" >/dev/null 2>&1; then
    warn "Missing: $1 ($2)"
    return 1
  fi
  return 0
}

ensure_deps() {
  local missing=0
  check_dep pw-cat   "pipewire / pipewire-utils"
  check_dep pw-record "pipewire / pipewire-utils"
  check_dep aseqdump "alsa-utils"
  check_dep python3  "python"
  python3 -c "import numpy" 2>/dev/null || { warn "Missing: python3 numpy (pip install numpy)"; missing=1; }
  return "$missing"
}

# -----------------------------------------------------------------------------
# Install
# -----------------------------------------------------------------------------
install_plugin() {
  if [[ ! -d "$PLUGIN_SRC" ]]; then
    err "Plugin sources not found: $PLUGIN_SRC"
    return 1
  fi
  mkdir -p "$PLUGIN_DIR"
  cp -a "$PLUGIN_SRC/." "$PLUGIN_DIR/"
  ok "Plugin $PLUGIN_ID installed to $PLUGIN_DIR"
}

add_to_bar() {
  [[ -f "$SHELL_JSON" ]] || { warn "No shell.json — plugin copied but not added to the bar."; return 0; }
  grep -q "\"$PLUGIN_ID\"" "$SHELL_JSON" && { ok "Plugin already in the bar layout."; return 0; }

  local tmp
  tmp=$(mktemp)
  # Add to the LEFT section, right after omarchy.workspaces.
  python3 - "$SHELL_JSON" "$PLUGIN_ID" "$tmp" <<'PYEOF'
import json, sys
path, plugin_dir, out = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding='utf-8') as f:
    data = json.load(f)
left = data.get('bar', {}).get('layout', {}).get('left', [])
ids = [item.get('id') for item in left]
if plugin_dir not in ids:
    insert_at = len(left)
    for i, item_id in enumerate(ids):
        if item_id == 'omarchy.workspaces':
            insert_at = i + 1
            break
    left.insert(insert_at, {'id': plugin_dir})
with open(out, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
PYEOF
  mv "$tmp" "$SHELL_JSON"
  ok "Plugin added to the bar LEFT section (after omarchy.workspaces)."
}

install_data() {
  local data_dir="$REAL_HOME/.local/share/jamjamjam-plugin"
  mkdir -p "$data_dir"
  ok "Data dir ready: $data_dir"
}

# -----------------------------------------------------------------------------
# Optional Shazam song hook: needs shazamio (python3 -m pip install --user).
# The backend runs without it — matching is simply reported as unavailable.
# -----------------------------------------------------------------------------
install_shazam() {
  if python3 -c "import shazamio" 2>/dev/null; then
    ok "Shazamio present — song matching enabled."
    return 0
  fi
  info "Installing optional Shazamio (user) for song recognition…"
  if ! python3 -m pip --version >/dev/null 2>&1; then
    warn "python3-pip missing — skipping shazamio (song matching stays off)."
    return 0
  fi
  # Never fatal: shazamio is an optional extra.
  if python3 -m pip install --user shazamio >/dev/null 2>&1; then
    ok "Shazamio installed — song matching enabled."
    return 0
  fi
  # Arch's PEP 668 ("externally-managed-environment") blocks --user pip; a
  # user-scope install is the documented workaround for per-user packages.
  if python3 -m pip install --user --break-system-packages shazamio >/dev/null 2>&1 &&
     python3 -c "import shazamio" 2>/dev/null; then
    ok "Shazamio installed (user, --break-system-packages) — song matching enabled."
  else
    warn "shazamio install failed — song matching stays off (offline / no permission?)."
  fi
}

# -----------------------------------------------------------------------------
# Guitar-neck TUI: build the Go viewer, install dispatcher + floating prompt rule.
# -----------------------------------------------------------------------------
install_tui() {
  mkdir -p "$BIN_DIR"
  if [[ ! -d "$TUI_SRC" ]]; then
    warn "TUI sources not found ($TUI_SRC) — skipping the neck TUI."
    return 0
  fi
  if [[ ! -f "$TUI_SRC/go.sum" ]]; then
    (cd "$TUI_SRC" && go mod tidy >/dev/null 2>&1) || warn "go mod tidy skipped"
  fi
  local out
  out=$( (cd "$TUI_SRC" && go build -o "$BIN_DIR/jamjamjam-neck" .) 2>&1 ) || {
    warn "Could not build the neck TUI (go said: $out)"
    return 0
  }
  chmod 755 "$BIN_DIR/jamjamjam-neck"
  ok "Neck TUI built and installed: $BIN_DIR/jamjamjam-neck"

  if [[ ! -f "$DISPATCHER" ]]; then
    warn "Dispatcher missing ($DISPATCHER) — skipping."
    return 0
  fi
  cp "$DISPATCHER" "$BIN_DIR/jamjamjam-tui"
  chmod 755 "$BIN_DIR/jamjamjam-tui"
  ok "Dispatcher installed: $BIN_DIR/jamjamjam-tui"
}

CONF_HYPR="$REAL_HOME/.config/hypr/hyprland.lua"
TILE_START="-- >>> jamjamjam-neck-tiled >>> guitar neck TUI opens tiled"
TILE_END="-- >>> jamjamjam-neck-tiled <<<"

install_hypr_rule() {
  mkdir -p "$(dirname "$CONF_HYPR")"
  touch "$CONF_HYPR"
  # Strip an earlier block (idempotent install).
  sed -i "/$TILE_START/,/$TILE_END/d" "$CONF_HYPR"
  cat >> "$CONF_HYPR" <<EOF
$TILE_START
-- The jamjamjam neck TUI opens like every other mosquito terminal TUI:
-- floating, centered omarchy-style prompt window (dispatcher launches foot
-- at 120x34 --app-id=org.omarchy.jamjamjam-tui).
o.window("org.omarchy.jamjamjam-tui", { float = true, center = true })
$TILE_END
EOF
  ok "Hyprland rule installed: jamjamjam neck TUI floating + centered"
}

install_analyze_helper() {
  [[ -f "$ANALYZE_SRC" ]] || { warn "analyze helper missing: $ANALYZE_SRC"; return 0; }
  mkdir -p "$BIN_DIR"
  cp "$ANALYZE_SRC" "$ANALYZE_BIN"
  chmod 755 "$ANALYZE_BIN"
  ok "Global analyze helper installed: $ANALYZE_BIN"
}

install_analyze_bind() {
  mkdir -p "$(dirname "$BINDINGS_LUA")"
  touch "$BINDINGS_LUA"
  # Strip an earlier block (idempotent install).
  sed -i "/$ANALYZE_BIND_START/,/$ANALYZE_BIND_END/d" "$BINDINGS_LUA"
  cat >> "$BINDINGS_LUA" <<EOF
$ANALYZE_BIND_START
-- Hold to run the jamjamjam analysis while the neck TUI is open, even when the
-- TUI is not focused (the helper no-ops when the TUI is closed). Bound to the
-- RIGHT CTRL key. A modifier keysym gives no usable keydown for a bind, so the
-- press half uses the physical keycode (code:105 = evdev KEY_RIGHTCTRL 97 + 8)
-- and the release half the modifier form that Hyprland actually matches on
-- keyup (CTRL + Control_R). Verified with injected key events.
o.bind("code:105", "jamjamjam analyze (hold)", "$ANALYZE_BIN start")
o.bind("CTRL + Control_R", "jamjamjam analyze (release)", "$ANALYZE_BIN stop", { release = true })
$ANALYZE_BIND_END
EOF
  if command -v hyprctl >/dev/null 2>&1; then
    hyprctl reload >/dev/null 2>&1 || true
  fi
  ok "Hyprland binding installed: RIGHT CTRL (hold to analyze)"
}

remove_analyze_bind() {
  [[ -f "$BINDINGS_LUA" ]] || return 0
  sed -i "/$ANALYZE_BIND_START/,/$ANALYZE_BIND_END/d" "$BINDINGS_LUA"
  rm -f "$ANALYZE_BIN"
  if command -v hyprctl >/dev/null 2>&1; then
    hyprctl reload >/dev/null 2>&1 || true
  fi
  ok "Global analyze helper + binding removed."
}

# -----------------------------------------------------------------------------
# Remove
# -----------------------------------------------------------------------------
remove_plugin() {
  if [[ -d "$PLUGIN_DIR" ]]; then
    rm -rf "$PLUGIN_DIR"
    ok "Plugin $PLUGIN_ID removed from $PLUGIN_DIR"
  else
    ok "Plugin already absent."
  fi
}

remove_from_bar() {
  [[ -f "$SHELL_JSON" ]] || return 0
  grep -q "\"$PLUGIN_ID\"" "$SHELL_JSON" || { ok "Plugin not in the bar layout."; return 0; }
  local tmp
  tmp=$(mktemp)
  python3 - "$SHELL_JSON" "$PLUGIN_ID" "$tmp" <<'PYEOF'
import json, sys
path, plugin_dir, out = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding='utf-8') as f:
    data = json.load(f)
layout = data.get('bar', {}).get('layout', {})
for section in ('left', 'center', 'right'):
    items = layout.get(section, [])
    layout[section] = [item for item in items if item.get('id') != plugin_dir]
plugins = data.get('plugins', [])
data['plugins'] = [p for p in plugins if (p.get('id') if isinstance(p, dict) else p) != plugin_dir]
with open(out, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
PYEOF
  mv "$tmp" "$SHELL_JSON"
  ok "Plugin removed from the bar layout."
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
if [[ $REMOVE == true ]]; then
  remove_from_bar
  remove_plugin
  remove_analyze_bind
  info "Uninstall complete. Restart the shell: omarchy restart shell"
else
  ensure_deps || true
  install_plugin
  add_to_bar
  install_data
  install_shazam
  install_tui
  install_hypr_rule
  install_analyze_helper
  install_analyze_bind
  info "Setup complete. Summary:"
  echo "  • Plugin installed  -> $PLUGIN_DIR"
  echo "  • Bar entry added   -> LEFT section (after omarchy.workspaces)"
  echo "  • Neck TUI          -> $BIN_DIR/jamjamjam-neck + jamjamjam-tui"
  echo "  • Window rule       -> jamjamjam neck opens floating + centered"
  echo "  • Global analyze    -> RIGHT CTRL (hold) while the neck TUI is open"
  echo "  • Audio analysis    -> speaker monitor (INPUT icon switches to MIC)"
  echo
  echo "  Restart the shell if the widget does not show: omarchy restart shell"
  echo "  Open the panel to analyze audio (key/BPM/chords), view the guitar"
  echo "  neck, toggle MIDI mode and pick a synth waveform."
  echo "  The panel's GUITAR button (or: jamjamjam-tui) opens the neck TUI."
fi