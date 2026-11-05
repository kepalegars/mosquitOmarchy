#!/usr/bin/env bash
# =============================================================================
# mosquitOmarchy - jamjamjam plugin
# =============================================================================
# Installs the mosquito.jamjamjam bar widget plugin into
# ~/.config/omarchy/plugins and enables it in the bar layout.
#
# The plugin provides:
#   • Real-time audio analysis: key, BPM, chord + a tuner (INPUT: PC/MIC)
#   • Chord progression + loop detection, plus a metronome at the BPM
#   • Guitar neck visualization of the detected key's scale (numbered degrees)
#
# Usage:
#   ./setup-jamjamjam-plugin.sh           # installs/enables the plugin
#   ./setup-jamjamjam-plugin.sh --remove  # removes the plugin + bar entry
#
# Prerequisites: python3 (numpy for key/BPM/chord; the tuner works without it),
# pw-cat, pw-record and parec (PipeWire).
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../lib/gui-run.bash"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../lib/marker-strip.bash"  # marker_strip: safe managed-block removal
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../lib/elevate.bash"     # mq_sudo: install python-numpy
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

PLUGIN_ID="mosquito.jamjamjam"
LEGACY_PLUGIN_ID="jamjamjam-plugin"
PLUGIN_DIR="$REAL_HOME/.config/omarchy/plugins/$PLUGIN_ID"
LEGACY_PLUGIN_DIR="$REAL_HOME/.config/omarchy/plugins/$LEGACY_PLUGIN_ID"
PLUGIN_SRC="$SCRIPT_DIR/omarchy-plugins/$PLUGIN_ID"
SHELL_JSON="$REAL_HOME/.config/omarchy/shell.json"
BIN_DIR="$REAL_HOME/.local/bin"
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
  # parec reaches sink monitors (pw-record cannot on PipeWire 1.6); without it
  # the analyzer hears silence even though the plugin looks installed.
  check_dep parec    "pipewire-pulse / libpulse"
  check_dep python3  "python"
  python3 -c "import numpy" 2>/dev/null || { warn "Missing: python3 numpy (python-numpy)"; missing=1; }
  return "$missing"
}

# numpy is the one dependency the installer can fix itself. It is needed for
# key/BPM/chord analysis; the tuner is pure Python and works without it, so a
# failed download must NOT abort the install (the Omarchy mirror times out on
# the tiny .sig files now and then — one retry usually gets them from cache).
ensure_numpy() {
  python3 -c "import numpy" 2>/dev/null && { ok "numpy present"; return 0; }
  info "Installing python-numpy (key/BPM/chord analysis needs it)…"
  local attempt
  for attempt in 1 2 3; do
    if mq_sudo pacman -S --needed --noconfirm python-numpy \
       && python3 -c "import numpy" 2>/dev/null; then
      ok "python-numpy installed"
      return 0
    fi
    if (( attempt < 3 )); then
      warn "pacman failed (mirror timeout?) — retry $attempt/3…"
      sleep 3
    fi
  done
  err "Could not install python-numpy."
  err "The tuner and metronome still work; key/BPM/chord stay off until it is installed."
  err "Retry later with: sudo pacman -S python-numpy"
  return 1
}

# -----------------------------------------------------------------------------
# Install
# -----------------------------------------------------------------------------
install_plugin() {
  if [[ ! -d "$PLUGIN_SRC" ]]; then
    err "Plugin sources not found: $PLUGIN_SRC"
    return 1
  fi
  # Adopt the legacy jamjamjam-plugin clone when present: same plugin, old id.
  if [[ -d "$LEGACY_PLUGIN_DIR" && ! -d "$PLUGIN_DIR" ]]; then
    omarchy plugin disable "$LEGACY_PLUGIN_ID" >/dev/null 2>&1 || true
    mv "$LEGACY_PLUGIN_DIR" "$PLUGIN_DIR"
    ok "Legacy plugin $LEGACY_PLUGIN_ID adopted as $PLUGIN_ID"
  fi
  mkdir -p "$PLUGIN_DIR"
  cp -a "$PLUGIN_SRC/." "$PLUGIN_DIR/"
  ok "Plugin $PLUGIN_ID installed to $PLUGIN_DIR"
}

add_to_bar() {
  [[ -f "$SHELL_JSON" ]] || { warn "No shell.json — plugin copied but not added to the bar."; return 0; }
  # Legacy bar id from before the mosquito.jamjamjam rename: swap it in place
  # so the widget keeps its bar position instead of being dropped + re-added.
  if grep -q "\"$LEGACY_PLUGIN_ID\"" "$SHELL_JSON"; then
    sed -i "s#\"$LEGACY_PLUGIN_ID\"#\"$PLUGIN_ID\"#g" "$SHELL_JSON"
    ok "Bar layout migrated: $LEGACY_PLUGIN_ID -> $PLUGIN_ID"
  fi
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
  local data_dir="$REAL_HOME/.local/share/mosquito.jamjamjam"
  local legacy_data_dir="$REAL_HOME/.local/share/jamjamjam-plugin"
  if [[ -d "$legacy_data_dir" && ! -d "$data_dir" ]]; then
    mv "$legacy_data_dir" "$data_dir"
    ok "Legacy data dir adopted: $data_dir"
  fi
  mkdir -p "$data_dir"
  ok "Data dir ready: $data_dir"
}

# -----------------------------------------------------------------------------
# Retire the abandoned neck TUI / RIGHT CTRL helper from older installs.
# The sources stay in the repository, but nothing is installed or bound.
# -----------------------------------------------------------------------------
CONF_HYPR="$REAL_HOME/.config/hypr/hyprland.lua"
TILE_START="-- >>> jamjamjam-neck-tiled >>> guitar neck TUI opens tiled"
TILE_END="-- <<< jamjamjam-neck-tiled <<<"

retire_tui() {
  if [[ -f "$BINDINGS_LUA" ]]; then
    marker_strip "$BINDINGS_LUA" "$ANALYZE_BIND_START" "$ANALYZE_BIND_END" || true
  fi
  if [[ -f "$CONF_HYPR" ]]; then
    marker_strip "$CONF_HYPR" "$TILE_START" "$TILE_END" || true
  fi
  rm -f "$BIN_DIR/jamjamjam-neck" "$BIN_DIR/jamjamjam-tui" "$BIN_DIR/jamjamjam-analyze"
  rm -f "$REAL_HOME/.local/state/jamjamjam/tui.pid"
  if command -v hyprctl >/dev/null 2>&1; then
    hyprctl reload >/dev/null 2>&1 || true
  fi
  ok "Legacy neck TUI, helper, window rule and binding retired."
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
  if [[ -d "$LEGACY_PLUGIN_DIR" ]]; then
    rm -rf "$LEGACY_PLUGIN_DIR"
    ok "Legacy plugin $LEGACY_PLUGIN_ID removed as well"
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
legacy = 'jamjamjam-plugin'
for section in ('left', 'center', 'right'):
    items = layout.get(section, [])
    layout[section] = [item for item in items if item.get('id') not in (plugin_dir, legacy)]
plugins = data.get('plugins', [])
data['plugins'] = [p for p in plugins if (p.get('id') if isinstance(p, dict) else p) not in (plugin_dir, legacy)]
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
  retire_tui
  info "Uninstall complete. Restart the shell: omarchy restart shell"
else
  ensure_deps || true
  # Warn, do not abort: a flaky mirror must not cost the user the tuner.
  ensure_numpy || true
  install_plugin
  add_to_bar
  install_data
  retire_tui
  info "Setup complete. Summary:"
  echo "  • Plugin installed  -> $PLUGIN_DIR"
  echo "  • Bar entry added   -> LEFT section (after omarchy.workspaces)"
  echo "  • Audio analysis    -> speaker monitor (INPUT icon switches to MIC)"
  echo
  echo "  Restart the shell if the widget does not show: omarchy restart shell"
  echo "  Open the panel to analyze audio (key/BPM/chords), view the guitar"
  echo "  neck, tune an instrument, and use the metronome."
fi
