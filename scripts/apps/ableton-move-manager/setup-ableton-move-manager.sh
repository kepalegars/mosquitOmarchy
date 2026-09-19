#!/usr/bin/env bash
# =============================================================================
# Omarchy Custom — "mosquito Move Manager" (ableton-move-converter module)
# =============================================================================
# Central installer for the Ableton Move → Ableton Live → Bitwig Studio
# workflow. Reproduces on a fresh machine:
#
#   1. mosquito-move-manager  (~/.local/bin/mosquito-move-manager) : workflow
#   2. move-bundle-to-midi    (~/.local/bin/move-bundle-to-midi)   : MIDI export
#   3. move-bundle-to-als     (~/.local/bin/move-bundle-to-als)    : .als export (beta)
#   4. move-udev-refresh      (~/.local/bin/move-udev-refresh)    : udev helper
#   5. move-manager-webapp    (~/.local/bin/move-manager-webapp)  : Move Manager webapp
#                             (dedicated Chromium profile, downloads → ablbundle)
#   5. udev rule              (/etc/udev/rules.d/99-ableton-move.rules)
#                             : warns on disconnect only while the Move
#                               Manager webapp is actively in use
#   6. Chromium policy        (/etc/chromium/policies/managed/ableton-move.json)
#                             : Move Manager downloads never ask the "Keep?"
#                               prompt (that dialog is unreliable on Hyprland)
#   7. Projects folders       (<projects>/{ablbundle,als,bwproject,bwproject/midi,Presets})
#   7b. Bitwig converter      (<bin-dir>/bwpreset-converter/ : convert_bw_kit.py
#                              + template_blocks.pkl, "Convert a preset" →
#                              Bitwig preset; output under <projects>/Presets)
#   8. Omarchy overlay        : mosquito.confirm (native Yes/No prompts,
#                              used by the dispatcher's flag-driven flows
#                              and shared with power-management) enabled
#   9. Omarchy menu           : ONE entry "mosquito Move Manager"
#                              (legacy/duplicate entries are purged)
#  10. Legacy launcher        : ~/.local/share/applications/move-session.desktop
#                              is removed (the menu entry replaces it)
#  11. Webapp icon            (~/.local/share/icons/hicolor/256x256/apps/
#                              ableton-move-manager.png) : the custom Move
#                              Manager icon for the webapp/launcher
#  12. ydotool NOPASSWD       (/etc/sudoers.d/mosquito-move-manager-ydotoold)
#                              : lets the TUI run ydotoold (no terminal for a
#                                sudo prompt) so the .als opens in Bitwig
#
# Usage:
#   ./setup-ableton-move-manager.sh   # interactive menu (install/uninstall/status/quit)
#   ./setup-ableton-move-manager.sh -y        # non-interactive install (idempotent)
#   ./setup-ableton-move-manager.sh --uninstall # removes udev rule + menu entry
#   ./setup-ableton-move-manager.sh --status   # current state, without modifying anything
#   ./setup-ableton-move-manager.sh -h         # help
#
# One-stop install/uninstall for the ableton-move-converter module:
#   • install   -> this script (menu option 1 / -y; also triggered by the
#                  'move-session' module of setup-customarchy.sh once wired)
#   • uninstall -> this script --uninstall, or the module of setup-customarchy.sh
#
# Optional udev rule + chromium policy + ydotool NOPASSWD rule require root
# (run: sudo bash $0).
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/gui-run.bash"  # gui-run: reopen in a terminal when launched from a file manager
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/elevate.bash"  # mq_sudo: native pkexec prompt when not root
set -euo pipefail

# Wine's Mono/Gecko installers open a bare white window in the corner of
# the screen when a prefix lacks .NET/HTML support (seen during every
# wine install in setup-ableton.sh and the audio plugin manager). The
# documented ok kill-switch: empty overrides for mscoree (Mono) and
# mshtml (Gecko) — wine never spawns those helper dialogues, and each
# script honors an user-exported override by keeping it.
export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-mscoree,mshtml=}"

# Key-wait close on every exit path (even a crash): when the script runs in a
# terminal (e.g. Nautilus provides a pty so gui-run's exec is skipped), keep
# the window open until a key is pressed — same behavior as the foot wrapper.
# Inside the gui-run wrapper (GUI_RUN_EXEC=1) its own "Press Enter" takes over.
_waited_close=0
wait_any_key_close() {
  (( _waited_close )) && return 0
  _waited_close=1
  [[ -t 0 && -z ${GUI_RUN_EXEC:-} ]] || return 0
  printf '\n  ✓ Press a key to close this window.\n'
  read -r -n1 2>/dev/null || true
  printf '\r\033[K\n' 2>/dev/null || true
}
trap wait_any_key_close EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

info() { echo -e "\033[1;34m==>\033[0m $*"; }
ok()   { echo -e "\033[1;32m  ✓\033[0m $*"; }
warn() { echo -e "\033[1;33m  !\033[0m $*"; }
err()  { echo -e "\033[1;31m  ✗\033[0m $*" >&2; }

# Resolve the REAL invoking user's home even when run via `sudo bash`.
if [[ $EUID -eq 0 && -n ${SUDO_USER:-} ]]; then
  REAL_USER="$SUDO_USER"
else
  REAL_USER="${USER:-$(id -un)}"
fi
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6 || true)"
REAL_HOME="${REAL_HOME:-$HOME}"

BIN_DIR="$REAL_HOME/.local/bin"
MENU_DIR="$REAL_HOME/.config/omarchy/extensions"
MENU="$MENU_DIR/omarchy-menu.jsonc"
MENU_START="// >>> Omarchy_Custom_Scripts - ableton-move-converter (managed by setup-ableton-move-manager.sh)"
MENU_END="// <<< Omarchy_Custom_Scripts - ableton-move-converter (managed by setup-ableton-move-manager.sh)"
# Legacy markers from the pre-rename installer — still present on some installs,
# migrated to the new ones at the next install/remove (no duplicate entry).
LEGACY_MENU_START="// >>> Omarchy_Custom_Scripts - managed by setup-move-session.sh"
LEGACY_MENU_END="// <<< Omarchy_Custom_Scripts - managed by setup-move-session.sh"
UDEV_SRC="$SCRIPT_DIR/99-ableton-move.rules"
UDEV_DST="/etc/udev/rules.d/99-ableton-move.rules"
CHROMIUM_POLICY_SRC="$SCRIPT_DIR/99-ableton-move-chromium-policy.json"
CHROMIUM_POLICY_DST="/etc/chromium/policies/managed/ableton-move.json"
# NOPASSWD drop-in for the ydotool direct-open path (see
# ensure_ydotoold_nopasswd): the Go TUI runs this over pipes with no terminal,
# so an interactive sudo password prompt can never be answered.
SUDOERS_DST="/etc/sudoers.d/mosquito-move-manager-ydotoold"
LEGACY_DESKTOP="$REAL_HOME/.local/share/applications/move-session.desktop"
WEBAPP_ICON_SRC="$SCRIPT_DIR/move-manager-icon.png"
WEBAPP_ICON_DST="$REAL_HOME/.local/share/icons/hicolor/256x256/apps/ableton-move-manager.png"
MOVE_DIR="$REAL_HOME/Music/Ableton Move Projects"
# Respect a custom projects folder chosen at first run of move-session.
if [[ -f "$REAL_HOME/.config/move-session/prefs" ]]; then
  source "$REAL_HOME/.config/move-session/prefs" || true
  [[ -n ${MOVE_PROJECTS_DIR:-} ]] && MOVE_DIR="$MOVE_PROJECTS_DIR"
fi

if [[ ! -d /usr/share/omarchy ]]; then
  echo "This script is meant for Omarchy." >&2
  exit 1
fi

REMOVE=false
YES=0
STATUS_ONLY=0
usage() {
  cat <<USAGE_EOF
Usage: $0 [options]

  (no option)          interactive menu (install / uninstall / status / quit)
  -y, --yes            non-interactive install (idempotent)
  --uninstall, --remove  remove the menu entry + udev rule + chromium policy + ydotool NOPASSWD (binaries stay)
  --status             show the current state, modify nothing
  -h, --help           this help

  The udev rule + chromium policy + ydotool NOPASSWD rule require root: run with 'sudo bash $0' (or '$0' options).
USAGE_EOF
}
while (($#)); do
  case "$1" in
    -y|--yes) YES=1 ;;
    --uninstall|--remove) REMOVE=true ;;
    --status) STATUS_ONLY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown option: $1 (see -h)"; exit 1 ;;
  esac
  shift
done

# -----------------------------------------------------------------------------
# 0. Status (--status): read-only snapshot of the deployed state
# -----------------------------------------------------------------------------
do_status() {
  local b
  echo
  info "mosquito Move Manager — status"
  for b in mosquito-move-manager mosquito-move-manager-tui \
           lib-move-manager-core.sh move-bundle-to-midi move-bundle-to-als \
           move-udev-refresh move-manager-webapp; do
    if [[ -x $BIN_DIR/$b ]]; then
      local v
      v=$("$BIN_DIR/$b" --version 2>/dev/null | head -1) || v=""
      ok "$b -> $BIN_DIR/$b${v:+ ($v)}"
    else
      warn "$b -> not deployed ($BIN_DIR/$b)"
    fi
  done
  if [[ -f $BIN_DIR/bwpreset-converter/convert_bw_kit.py ]]; then
    ok "Bitwig preset converter: $BIN_DIR/bwpreset-converter/"
  else
    warn "Bitwig preset converter not deployed ($BIN_DIR/bwpreset-converter/) — Bitwig .bwpreset conversion disabled"
  fi
  if [[ -d $MOVE_DIR ]]; then
    ok "projects folder: $MOVE_DIR"
  else
    warn "projects folder missing: $MOVE_DIR (created on install)"
  fi
  if [[ -f /etc/udev/rules.d/99-ableton-move.rules ]]; then
    ok "udev rule installed: /etc/udev/rules.d/99-ableton-move.rules"
  else
    warn "udev rule not installed (requires root: sudo bash $0)"
  fi
  if [[ -f /etc/chromium/policies/managed/ableton-move.json ]]; then
    ok "chromium policy installed: /etc/chromium/policies/managed/ableton-move.json (no 'Keep?' prompt on Move Manager downloads)"
  else
    warn "chromium policy not installed (requires root: sudo bash $0)"
  fi
  if [[ -f $SUDOERS_DST ]]; then
    ok "ydotoold NOPASSWD rule installed: $SUDOERS_DST (Bitwig direct-open works from the TUI)"
  else
    warn "ydotoold NOPASSWD rule not installed (requires root: sudo bash $0) — Bitwig direct-open falls back to a bare launch"
  fi
  if [[ -f $WEBAPP_ICON_DST ]]; then
    ok "webapp icon installed: $WEBAPP_ICON_DST"
  else
    warn "webapp icon not installed ($WEBAPP_ICON_DST) — Move Manager launcher falls back to a generic icon"
  fi
  if [[ -f $REAL_HOME/.config/move-session/prefs ]]; then
    ok "prefs: $(grep -v '^#' "$REAL_HOME/.config/move-session/prefs" | tr '\n' ' ')"
  else
    ok "prefs: none yet (created at first session)"
  fi
  echo
}

# -----------------------------------------------------------------------------
# 0b. Interactive menu (no flag, stdin is a terminal)
# -----------------------------------------------------------------------------
step_main_menu() {
  local choice installed=0
  [[ -x $BIN_DIR/mosquito-move-manager ]] && installed=1
  echo
  echo "   What to do ?"
  if (( installed )); then
    echo "    1) Re-install / update (already deployed)"
  else
    echo "    1) Install mosquito Move Manager"
  fi
  echo "    2) Uninstall (menu entry + udev rule + chromium policy + ydotool NOPASSWD; binaries stay)"
  echo "    3) Status"
  echo "    4) Quit"
  echo
  read -rp "   Choice [1-4] : " choice || choice=""
  case "$choice" in
    1) return 0 ;;                # normal installation flow
    2) remove_menu; remove_udev; remove_chromium_policy; remove_ydotoold_nopasswd; echo; info "Uninstall complete: menu entry + udev rule + chromium policy + ydotool NOPASSWD removed."; echo "  The binaries stay in $BIN_DIR (mosquito-move-manager (+ -tui/lib-move-manager-core.sh, -features.sh), move-bundle-to-midi, move-bundle-to-als, move-udev-refresh, move-manager-webapp)."; exit 0 ;;
    3) do_status; exit 0 ;;
    4) echo "Bye."; exit 0 ;;
    q|Q) echo "Bye."; exit 0 ;;
    *) warn "Invalid choice — we continue the installation."; return 0 ;;
  esac
}

# -----------------------------------------------------------------------------
# 0. Projects folder structure
# -----------------------------------------------------------------------------
touch_baseline_dirs() {
  mkdir -p "$MOVE_DIR/ablbundle" "$MOVE_DIR/als" "$MOVE_DIR/bwproject" "$MOVE_DIR/bwproject/midi" "$MOVE_DIR/Presets"
}

# -----------------------------------------------------------------------------
# 1. Deployment of the binaries (~/.local/bin)
# -----------------------------------------------------------------------------
deploy_bin() {
  local name="$1" src dst
  [[ -n ${1:-} ]] || return 0
  src="$SCRIPT_DIR/$name"
  dst="$BIN_DIR/$name"
  if [[ ! -f $src ]]; then
    warn "$name not found in $SCRIPT_DIR — ignored."
    return 0
  fi
  if [[ -f $dst ]] && cmp -s "$src" "$dst"; then
    ok "$name already in place and up to date ($dst)"
    return 0
  fi
  cp "$src" "$dst"
  chmod +x "$dst"
  if head -1 "$dst" | grep -q python; then
    python3 -c "import ast,sys; ast.parse(open(sys.argv[1], encoding='utf-8').read())" "$dst" \
      || { err "Invalid syntax: $name"; return 1; }
  else
    bash -n "$dst" || { err "Invalid syntax: $name"; return 1; }
  fi
  ok "$name deployed ($dst)"
}

# The deployed lib-move-manager-core.sh sources elevate.bash for mq_sudo, so
# the shared helper must sit next to it in ~/.local/bin.
deploy_elevate() {
  local src="$SCRIPT_DIR/../../lib/elevate.bash" dst="$BIN_DIR/elevate.bash"
  if [[ ! -f $src ]]; then
    warn "elevate.bash not found ($src) — mq_sudo falls back to sudo"
    return 0
  fi
  if [[ -f $dst ]] && cmp -s "$src" "$dst"; then
    ok "elevate.bash already in place and up to date ($dst)"
    return 0
  fi
  cp "$src" "$dst"
  chmod 0644 "$dst"
  ok "elevate.bash deployed ($dst)"
}

# Deploys converter/resources the Python converter needs to FIND at runtime
# (its template lookup is relative to the script: <bin-dir>/converter/…).
deploy_converter_resources() {
  local src="$SCRIPT_DIR/converter" dst="$BIN_DIR/converter"
  [[ -d $src ]] || { warn "converter/ resources not found in $SCRIPT_DIR — .ablpresetbundle step will be limited."; return 0; }
  mkdir -p "$dst"
  local f rel
  while IFS= read -r -d '' f; do
    rel="${f#$src/}"
    mkdir -p "$(dirname "$dst/$rel")"
    if [[ -f "$dst/$rel" ]] && cmp -s "$f" "$dst/$rel"; then
      continue
    fi
    cp "$f" "$dst/$rel"
  done < <(find "$src" -type f -print0)
  ok "converter resources deployed ($dst)"
}

# Deploys the Bitwig .bwpreset converter (script + its template_blocks.pkl)
# as a self-contained module-local directory: <bin-dir>/bwpreset-converter/.
# The converter resolves its template relative to itself, and the actions
# lib resolves the script module-local first, then from $BIN_DIR — exactly
# the convert-adg-to-move + converter/ pattern used above.
deploy_bwpreset_converter() {
  local src="$SCRIPT_DIR/bwpreset-converter" dst="$BIN_DIR/bwpreset-converter"
  [[ -d $src ]] || { warn "bwpreset-converter/ not found in $SCRIPT_DIR — Bitwig .bwpreset conversion disabled."; return 0; }
  mkdir -p "$dst"
  local f rel
  while IFS= read -r -d '' f; do
    rel="${f#$src/}"
    mkdir -p "$(dirname "$dst/$rel")"
    if [[ -f "$dst/$rel" ]] && cmp -s "$f" "$dst/$rel"; then
      continue
    fi
    cp "$f" "$dst/$rel"
  done < <(find "$src" -type f -print0)
  if [[ -f $dst/convert_bw_kit.py ]]; then
    chmod +x "$dst/convert_bw_kit.py"
    python3 -c "import ast,sys; ast.parse(open(sys.argv[1], encoding='utf-8').read())" "$dst/convert_bw_kit.py" \
      || { err "Invalid syntax: bwpreset-converter/convert_bw_kit.py"; return 1; }
  fi
  ok "bwpreset-converter deployed ($dst)"
}

# Deploys the vendored move-bitwig sources (the Bitwig Move integration
# builds + installs from this copy on the host).
deploy_move_bitwig() {
  local src="$SCRIPT_DIR/move-bitwig" dst="$REAL_HOME/.local/share/mosquito-move-manager/move-bitwig"
  [[ -d $src ]] || { warn "move-bitwig/ not found in $SCRIPT_DIR — Bitwig Move integration skipped."; return 0; }
  mkdir -p "$dst"
  local f rel
  while IFS= read -r -d '' f; do
    rel="${f#$src/}"
    mkdir -p "$(dirname "$dst/$rel")"
    if [[ -f "$dst/$rel" ]] && cmp -s "$f" "$dst/$rel"; then
      continue
    fi
    cp "$f" "$dst/$rel"
  done < <(find "$src" -type f -print0)
  ok "move-bitwig sources deployed ($dst)"
}

# -----------------------------------------------------------------------------
# 2. Omarchy overlay for native prompts (mosquito.confirm)
# -----------------------------------------------------------------------------
configure_tracker_exclusion() {
  # GNOME/Tracker (localsearch) indexes $HOME recursively by default and
  # tries to extract metadata from every new file, including the MIDI
  # exports this module writes. Its libmodplug-based MIDI parser has a real
  # segfault bug on some files it generates (SIGSEGV in CSoundFile::ReadMID,
  # confirmed via coredumpctl — a genuine system-library bug, nothing to do
  # with the exported file's correctness). `ignored-directories` matches by
  # folder name anywhere under the indexed roots, so this keeps Tracker out
  # of the whole projects folder without touching indexing elsewhere.
  [[ $EUID -eq 0 ]] && return 0
  command -v gsettings >/dev/null 2>&1 || return 0
  local dir_name current
  dir_name="$(basename "$MOVE_DIR")"
  current=$(gsettings get org.freedesktop.Tracker3.Miner.Files ignored-directories 2>/dev/null) || return 0
  [[ $current == *"'$dir_name'"* ]] && { ok "Tracker already excludes $dir_name"; return 0; }
  local updated="${current%]}, '$dir_name']"
  if gsettings set org.freedesktop.Tracker3.Miner.Files ignored-directories "$updated" 2>/dev/null; then
    ok "Tracker/localsearch excluded from $dir_name (avoids a known libmodplug MIDI-parsing crash)"
  else
    warn "could not update Tracker's ignored-directories — MIDI exports may still trigger a localsearch-extractor crash (harmless to your files, just a system service restarting)"
  fi
}

# -----------------------------------------------------------------------------
# 1b. TUI build — the ONLY interface. There is no native interface and no
# interface mode file anymore (Roadmap 3.9): every no-argument launch goes
# through the dispatcher straight into this binary, so building it is now
# mandatory-honest rather than optional — still non-fatal to the rest of
# the install (udev, menu, … work independently), but until it's built the
# manager's interactive menu simply can't launch (the flag-driven actions
# keep working; they don't need the TUI).
# -----------------------------------------------------------------------------
build_and_deploy_tui() {
  # mosquito-move-manager-tui is a compiled Go/Bubble Tea program (see
  # tui-go/ and the shared ../tui-kit component library) — no runtime
  # dependency on Go, only a build-time one. `go` not on PATH (or a build
  # failure) degrades worse than it used to: there is nowhere else to fall
  # back, so say exactly that.
  if ! command -v go >/dev/null 2>&1; then
    warn "go not found — mosquito-move-manager-tui (Go/Bubble Tea) won't be built. The TUI is the ONLY interface, so the menu can't launch until it is. Install go (e.g. via mise, or sudo pacman -S go) and re-run this installer."
    return 0
  fi
  # Build to a temp file first, then move into place: `go build -o` refuses
  # to overwrite a destination that isn't already a Go build output (a
  # real, deliberate safety check) — and the old bash-script
  # mosquito-move-manager-tui this replaces sits at that exact path on any
  # machine that had it deployed before.
  local tmp_out
  tmp_out="$(mktemp "$BIN_DIR/.mosquito-move-manager-tui.XXXXXX")"
  if ! (cd "$SCRIPT_DIR/tui-go" && go build -o "$tmp_out" .); then
    rm -f "$tmp_out"
    warn "mosquito-move-manager-tui build failed — the menu can't launch until it builds (re-run this installer after fixing the cause)."
    return 0
  fi
  chmod +x "$tmp_out"
  mv -f "$tmp_out" "$BIN_DIR/mosquito-move-manager-tui"
  ok "mosquito-move-manager-tui built and deployed ($BIN_DIR/mosquito-move-manager-tui)"
}

ensure_confirm_plugin() {
  # Always re-copies over whatever's deployed, not just on first install:
  # a stale deployed copy silently never picking up repo changes (this
  # used to skip entirely once the destination existed) was found to be
  # exactly why the deployed and repo copies of Confirm.qml had already
  # drifted apart in an earlier round, before that got caught and both
  # were manually re-synced. `cp -a` is cheap and idempotent either way.
  local PLUG_DIR="$REAL_HOME/.config/omarchy/plugins"
  local SRC_DIR="$SCRIPT_DIR/../../plugins/power-management/omarchy-plugins/mosquito.confirm"
  if [[ -d $SRC_DIR ]]; then
    mkdir -p "$PLUG_DIR/mosquito.confirm"
    cp -a "$SRC_DIR/." "$PLUG_DIR/mosquito.confirm/"
    ok "Omarchy plugin mosquito.confirm installed/updated (native Yes/No overlay)"
  elif [[ -d "$PLUG_DIR/mosquito.confirm" ]]; then
    ok "Omarchy plugin mosquito.confirm already present (repo source not found to re-sync from — kept as-is)"
  else
    warn "mosquito.confirm sources not found — prompts will use the zenity fallback."
    return 0
  fi
  omarchy plugin enable mosquito.confirm >/dev/null 2>&1 || true
  ok "Omarchy plugin mosquito.confirm enabled (native Yes/No overlay)"
}

ensure_tui_float_windowrule() {
  # Without this, mosquito-move-manager-tui's window tiles like any other
  # window instead of floating — Omarchy's own floating-window whitelist
  # (default/hypr/apps/system.lua) matches specific known app-ids
  # (org.omarchy.btop, org.omarchy.terminal, …) verbatim, not a wildcard, so
  # a custom app-id like ours is never covered by it. Same idempotent
  # marked-block pattern as scripts/apps/reaper/setup-reaper.sh: strip any
  # previously-injected block first so re-running after an edit actually
  # updates hyprland.lua rather than being a no-op, then append the current
  # one. Size matches Omarchy's own floating-window tag (system.lua) for
  # consistency with the rest of the desktop's TUI popups.
  local CONF="$REAL_HOME/.config/hypr/hyprland.lua"
  mkdir -p "$REAL_HOME/.config/hypr"
  touch "$CONF"
  sed -i '/-- >>> move-manager-tui-setup >>>/,/-- <<< move-manager-tui-setup <<</d' "$CONF"
  cat >>"$CONF" <<'EOF'
-- >>> move-manager-tui-setup >>> float mosquito-move-manager-tui (the
-- Bubble Tea TUI's own window) instead of the tiled default -- its app-id
-- isn't in Omarchy's own floating-window whitelist (that one only matches
-- a fixed set of known app-ids verbatim, not a wildcard).
o.window("org.omarchy.mosquito-move-manager-tui", { float = true, center = true })
-- <<< move-manager-tui-setup <<<
EOF
  hyprctl reload >/dev/null 2>&1 || true
  ok "Hyprland float rule for the TUI window installed/updated ($CONF)"
}

ensure_webapp_float_windowrule() {
  # Same idea as ensure_tui_float_windowrule above, but for the Move
  # Manager's own Chromium --app= window: it opens at a fraction of the
  # screen's size by default (a normal *tiled* fraction) and mis-centers.
  # Floating it, exactly like the Omarchy shell does for its own helper
  # windows (o.window title matches in default/hypr/apps/*.lua), makes it a
  # properly centered panel distinct from a workspace grid of terminals.
  # Matched on class (any Chromium) + title (the Move Manager page makes the
  # window title "Move Manager" — curl move.local confirms it) so a normal
  # Chromium window is never affected. Idempotent marked block, like above.
  local CONF="$REAL_HOME/.config/hypr/hyprland.lua"
  mkdir -p "$REAL_HOME/.config/hypr"
  touch "$CONF"
  sed -i '/-- >>> move-manager-webapp-setup >>>/,/-- <<< move-manager-webapp-setup <<</d' "$CONF"
  cat >>"$CONF" <<'EOF'
-- >>> move-manager-webapp-setup >>> float & center the Move Manager webapp
-- (a Chromium --app= window titled "Move Manager") instead of tiling it at
-- some small grid fraction. Matches any Chromium class with that page title,
-- so regular Chromium windows are unaffected.
o.window({ class = "[cC]hrom.*", title = "^Move Manager" }, { float = true, center = true, size = { 1100, 720 } })
-- <<< move-manager-webapp-setup <<<
EOF
  hyprctl reload >/dev/null 2>&1 || true
  ok "Hyprland float rule for the Move Manager webapp installed/updated ($CONF)"
}

# -----------------------------------------------------------------------------
# 3. Legacy launcher removal (single entry in the Omarchy menu)
# -----------------------------------------------------------------------------
remove_legacy_launcher() {
  if [[ -f $LEGACY_DESKTOP ]]; then
    rm -f "$LEGACY_DESKTOP"
    ok "Legacy launcher removed ($LEGACY_DESKTOP)"
  else
    ok "No legacy launcher left, nothing to remove."
  fi
}

# Stale binaries from prior names (move-session → ableton-move-converter →
# mosquito-move-manager). Both renames kept the module directory/id as
# "ableton-move-converter" — only the deployed executable's filename changed.
remove_stale_binary() {
  if [[ -f "$BIN_DIR/move-session" ]]; then
    rm -f "$BIN_DIR/move-session"
    ok "Stale legacy binary removed ($BIN_DIR/move-session)"
  fi
  if [[ -f "$BIN_DIR/ableton-move-converter" ]]; then
    rm -f "$BIN_DIR/ableton-move-converter"
    ok "Stale legacy binary removed ($BIN_DIR/ableton-move-converter, renamed to mosquito-move-manager)"
  fi
}

# -----------------------------------------------------------------------------
# 4. udev rule (requires root) — desktop notification when the Move is plugged
# -----------------------------------------------------------------------------
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

# The omarchy shell (launcher) runs as the real desktop user: a menu written
# through sudo must stay owned by and readable by that user, otherwise the
# entry is silently invisible in the launcher. Always force 0644 and, as root,
# revert to REAL_USER (no-op as the same user or on non-POSIX-y filesystems).
ensure_menu_readable() {
  [[ -f $MENU ]] || return 0
  chmod 644 "$MENU" 2>/dev/null || true
  if [[ $EUID -eq 0 ]]; then
    chown "$REAL_USER:$REAL_USER" "$MENU" 2>/dev/null || true
  fi
  if [[ -f $MENU.bak ]]; then
    chmod 644 "$MENU.bak" 2>/dev/null || true
    if [[ $EUID -eq 0 ]]; then
      chown "$REAL_USER:$REAL_USER" "$MENU.bak" 2>/dev/null || true
    fi
  fi
}

PURGE_LEGACY=$(cat << 'PYEOF'
import json, re, sys, io
path = sys.argv[1]
raw = io.open(path, encoding='utf-8').read()
data = re.sub(r'(?m)^[ \t]*//.*$', '', raw)
data = re.sub(r'/\*.*?\*/', '', data, flags=re.S)
data = re.sub(r',(\s*[}\]])', r'\1', data)
tree = json.loads(data)

MANAGED = "trigger.music.ableton-move-converter"
START_MARKER = sys.argv[2]
END_MARKER = sys.argv[3]

def is_ours(key, value):
    if key == MANAGED:
        return False
    k = key.lower()
    if "move" not in k:
        return False
    blob = json.dumps(value, ensure_ascii=False).lower()
    marks = ("move-session", "move_session", "ableton move", "bitwig")
    return any(m in blob or m in k for m in marks)

def scrub(node):
    removed = 0
    if isinstance(node, dict):
        for k in list(node):
            if is_ours(k, node[k]):
                del node[k]
                removed += 1
            elif isinstance(node[k], (dict, list)):
                removed += scrub(node[k])
    elif isinstance(node, list):
        for item in node:
            if isinstance(item, (dict, list)):
                removed += scrub(item)
    return removed

removed = scrub(tree)

# Reattach the marker comments around the managed block so that
# install_menu/remove_menu can still locate it after the rewrite (a plain
# json.dumps would drop every comment). Brace counting finds the block end.
def reattach(out):
    m = re.search(r'"%s"\s*:\s*\{' % re.escape(MANAGED), out)
    if not m:
        return out
    start = m.start()
    depth = 0
    i = m.end() - 1
    while i < len(out):
        c = out[i]
        if c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                break
        i += 1
    return out[:start] + START_MARKER + '\n' + out[start:i + 1] + '\n' + END_MARKER + out[i + 1:]

out = reattach(re.sub(r' +', ' ', json.dumps(tree, ensure_ascii=False, indent=2)).replace('\n  ', '\n  '))
io.open(path, 'w', encoding='utf-8').write(out)
sys.stderr.write("purged %d legacy converter menu entry/ies with markers kept\n" % removed)
PYEOF
)

purge_legacy_entries() {
  [[ -f $MENU ]] || { ok "No menu file yet, nothing to purge."; return 0; }
  if [[ ! -r $MENU ]]; then
    warn "Menu $MENU is root-readable only on this host — legacy purge skipped (run it with: sudo bash $0)"
    return 1
  fi
  cp "$MENU" "$MENU.bak" 2>/dev/null || true
  local out
  out=$(python3 -c "$PURGE_LEGACY" "$MENU" "$MENU_START" "$MENU_END" 2>&1) || {
    rm -f "$MENU.bak"
    warn "Could not purge legacy entries in $MENU (python said: $out) — fix manually."
    return 1
  }
  ok "$out (backup: $MENU.bak)"
  ensure_menu_readable
}

menu_block() {
  cat <<MC_EOF
$MENU_START
  "trigger.music": {
    "icon": "\uf001",
    "label": "Music"
  },
  "trigger.music.ableton-move-converter": {
    "icon": "\uf0ec",
    "label": "mosquito Move Manager",
    "description": "Move → Move Manager → Ableton Live → Bitwig: import sets, save .als exports or export MIDI, then open in Bitwig",
    "aliases": ["move", "movemanager", "move-manager", "ableton-move", "bitwig", "converter", "midi", "mosquito"],
    "when": "test -x $BIN_DIR/mosquito-move-manager",
    "action": "$BIN_DIR/mosquito-move-manager"
  },
$MENU_END
MC_EOF
}

# Locate the first managed block (new or legacy markers). Echoes "start end"
# (line numbers) or nothing. The end marker is the first one after the start, so
# a mutated/duplicate block is disambiguated: it is always replaced coherently.
menu_block_range() {
  local file="$1" start="" end="" l
  for m in "$MENU_START" "$LEGACY_MENU_START"; do
    l=$(grep -nF "$m" "$file" 2>/dev/null | head -1 | cut -d: -f1)
    if [[ -n $l ]]; then start=$l; break; fi
  done
  [[ -n $start ]] || return 1
  for m in "$MENU_END" "$LEGACY_MENU_END"; do
    l=$(grep -nF "$m" "$file" 2>/dev/null | awk -F: -v s="$start" '$1 >= s { print $1; exit }')
    if [[ -n $l ]]; then end=$l; break; fi
  done
  [[ -n $end ]] || return 1
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
      warn "Inconsistent ableton-move-converter markers in $MENU — manual fix needed."
      return 0
    fi
    tmp=$(mktemp)
    head -n $((start_line - 1)) "$MENU" > "$tmp"
    printf '%s\n' "$block" >> "$tmp"
    tail -n +$((end_line + 1)) "$MENU" >> "$tmp"
    mv "$tmp" "$MENU"
  else
    open_line=$(grep -n '^{[[:space:]]*$' "$MENU" | head -1 | cut -d: -f1 || true)
    if grep -qF '"trigger.music.ableton-move-converter"' "$MENU"; then
      warn "Menu already contains the ableton-move-converter entry without managed markers — manual fix needed (no duplicate inserted)."
      return 0
    fi
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
    ok "Menu bar entry ensured: Trigger > Music > Ableton Move Set to Bitwig converter"
  else
    warn "Menu JSONC invalid after adding the entry — fix $MENU manually."
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
      ok "Menu bar entry removed: ableton-move-converter"
    else
      warn "Inconsistent ableton-move-converter markers in $MENU."
    fi
  else
    ok "No ableton-move-converter entry in the menu, nothing to do."
  fi
  ensure_menu_readable
}

install_udev() {
  if [[ ! -f $UDEV_SRC ]]; then
    warn "udev rule not found ($UDEV_SRC) — auto-detect on plug disabled."
    return 0
  fi
  if mq_sudo bash -c '
      set -e
      install -o root -g root -m 0644 "$1" "$2"
      udevadm control --reload
    ' _ "$UDEV_SRC" "$UDEV_DST"; then
    ok "udev rule installed ($UDEV_DST)"
  else
    warn "udev rule not installed."
  fi
}

remove_udev() {
  if [[ -f $UDEV_DST ]]; then
    if mq_sudo bash -c '
        set -e
        rm -f "$1"
        udevadm control --reload 2>/dev/null || true
      ' _ "$UDEV_DST"; then
      ok "udev rule removed ($UDEV_DST)"
    else
      warn "udev rule kept."
    fi
  else
    ok "udev rule absent, nothing to do."
  fi
}

install_chromium_policy() {
  # Chromium managed policy: exempt the Move host from the safe-browsing
  # "This type of file can harm your computer. Keep?" download dialog, which is
  # unreliable on Hyprland. The webapp always runs through chromium (the
  # omarchy Launcher falls back to chromium.desktop), so this is enough.
  if [[ ! -f $CHROMIUM_POLICY_SRC ]]; then
    warn "chromium policy not found ($CHROMIUM_POLICY_SRC) — the 'Keep?' prompt stays."
    return 0
  fi
  if mq_sudo install -D -o root -g root -m 0644 "$CHROMIUM_POLICY_SRC" "$CHROMIUM_POLICY_DST"; then
    ok "chromium policy installed ($CHROMIUM_POLICY_DST)"
  else
    warn "chromium policy not installed."
  fi
}

ensure_ydotoold_nopasswd() {
  # ydotool direct-open runs from the Go TUI, whose runner has no terminal
  # (stdin/stdout are pipes), so an interactive sudo password prompt can
  # never be answered. Grant the invoking user NOPASSWD for exactly the root
  # commands open_als_in_bitwig_via_ydotool calls, so ydotoold can start and
  # Bitwig's Open dialog can be driven. Without this the ydotool path bails
  # and Bitwig is only launched bare — its CLI cannot open a .als, so the
  # project never loads (the "toujours rien" symptom).
  if ! command -v visudo >/dev/null 2>&1; then
    warn "visudo not found — refusing to install $SUDOERS_DST"
    return 0
  fi
  local tmp
  tmp="$(mktemp)" || {
    warn "could not create a temp file — NOPASSWD rule not installed"
    return 0
  }
  # Restrict each rule to the exact invocation: ydotoold, the stale-socket
  # rm, killing the daemon we started, and key injection through
  # `env YDOTOOL_SOCKET=/tmp/.ydotool_socket ydotool key …`. /usr/bin/true is
  # the passwordless-sudo capability probe at the top of the routine.
  # Deliberately NOT a blanket NOPASSWD on /usr/bin/env (that would be
  # equivalent to full passwordless root).
  cat > "$tmp" <<SUDOEOF
# Managed by setup-ableton-move-manager.sh — ydotool direct-open for the Go
# TUI (no terminal for a sudo password prompt). Exact commands used by
# open_als_in_bitwig_via_ydotool() in lib-move-manager-core.sh.
$REAL_USER ALL=(root) NOPASSWD: /usr/bin/ydotoold
$REAL_USER ALL=(root) NOPASSWD: /usr/bin/env YDOTOOL_SOCKET=/tmp/.ydotool_socket ydotool key *
$REAL_USER ALL=(root) NOPASSWD: /usr/bin/rm -f /tmp/.ydotool_socket
$REAL_USER ALL=(root) NOPASSWD: /usr/bin/kill
$REAL_USER ALL=(root) NOPASSWD: /usr/bin/true
SUDOEOF
  if ! visudo -cf "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    warn "ydotoold NOPASSWD rule failed visudo validation — removed, not installed"
    return 0
  fi
  # Single elevated install (pkexec GUI prompt when not already root): copy the
  # validated content into a same-filesystem temp under /etc/sudoers.d, then
  # atomically rename it into place. Deliberately one privilege escalation so
  # the GUI asks for the password only once.
  if ! mq_sudo bash -c '
      set -e
      tmp="$(mktemp /etc/sudoers.d/.mosquito-move-manager-ydotoold.XXXXXX)"
      trap "rm -f \"$tmp\"" EXIT
      cat > "$tmp"
      chmod 0440 "$tmp"
      chown root:root "$tmp" 2>/dev/null || true
      visudo -cf "$tmp" >/dev/null 2>&1
      mv -f "$tmp" "$1"
      trap - EXIT
    ' _ "$SUDOERS_DST" < "$tmp"; then
    rm -f "$tmp"
    warn "could not install $SUDOERS_DST — NOPASSWD rule not installed"
    return 0
  fi
  rm -f "$tmp"
  ok "ydotoold NOPASSWD rule installed ($SUDOERS_DST)"
}

remove_ydotoold_nopasswd() {
  if [[ -f $SUDOERS_DST ]]; then
    if mq_sudo rm -f "$SUDOERS_DST"; then
      ok "ydotoold NOPASSWD rule removed ($SUDOERS_DST)"
    else
      warn "ydotoold NOPASSWD rule kept."
    fi
  else
    ok "ydotoold NOPASSWD rule absent, nothing to do."
  fi
}

install_webapp_icon() {
  # A custom Move Manager icon (user-provided, stored as move-manager-icon.png
  # next to this script) for the Move Manager webapp/launcher — replaces the
  # old device-favicon-fetching approach, see mosquito-move-manager's
  # ensure_webapp(). Re-copied only when missing or stale so a fresh icon
  # asset in the repo always propagates.
  if [[ ! -f $WEBAPP_ICON_SRC ]]; then
    warn "webapp icon not found ($WEBAPP_ICON_SRC) — Move Manager launcher will use a generic icon."
    return 0
  fi
  if [[ -f $WEBAPP_ICON_DST ]] && cmp -s "$WEBAPP_ICON_SRC" "$WEBAPP_ICON_DST"; then
    ok "webapp icon already in place ($WEBAPP_ICON_DST)"
    return 0
  fi
  mkdir -p "$(dirname "$WEBAPP_ICON_DST")"
  cp "$WEBAPP_ICON_SRC" "$WEBAPP_ICON_DST"
  ok "webapp icon installed ($WEBAPP_ICON_DST)"
  command -v gtk-update-icon-cache >/dev/null 2>&1 \
    && gtk-update-icon-cache -f -t "$REAL_HOME/.local/share/icons/hicolor" >/dev/null 2>&1 || true
}

remove_webapp_icon() {
  if [[ -f $WEBAPP_ICON_DST ]]; then
    rm -f "$WEBAPP_ICON_DST"
    ok "webapp icon removed ($WEBAPP_ICON_DST)"
  else
    ok "webapp icon absent, nothing to do."
  fi
}

remove_chromium_policy() {
  if [[ -f $CHROMIUM_POLICY_DST ]]; then
    if mq_sudo rm -f "$CHROMIUM_POLICY_DST"; then
      ok "chromium policy removed ($CHROMIUM_POLICY_DST)"
    else
      warn "chromium policy kept."
    fi
  else
    ok "chromium policy absent, nothing to do."
  fi
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
if [[ $REMOVE == true ]]; then
  remove_menu
  remove_udev
  remove_chromium_policy
  remove_ydotoold_nopasswd
  remove_webapp_icon
  info "Uninstall complete: menu entry + udev rule + chromium policy + ydotool NOPASSWD + webapp icon removed."
  echo "  The binaries stay in $BIN_DIR (mosquito-move-manager (+ -tui/lib-move-manager-core.sh), move-bundle-to-midi, move-bundle-to-als, move-udev-refresh, move-manager-webapp):"
  echo "    use the 'ableton-move-manager' module of setup-customarchy.sh --uninstall to remove them too."
elif (( STATUS_ONLY )); then
  do_status
else
  # Interactive menu when launched without a flag and stdin is a terminal.
  if (( ! YES )); then
    if [[ ! -t 0 ]]; then
      err "stdin without a TTY: a flag is required (e.g. -y, --uninstall, --status)."
      echo "  see: $0 -h" >&2
      exit 1
    fi
    step_main_menu
  fi
  mkdir -p "$BIN_DIR"
  touch_baseline_dirs
  remove_stale_binary
  deploy_bin "lib-move-manager-core.sh"
  deploy_elevate
  deploy_bin "lib-move-manager-features.sh"
  deploy_bin "mosquito-move-manager-actions"
  build_and_deploy_tui
  deploy_bin "mosquito-move-manager"
  deploy_bin "move-bundle-to-midi"
  deploy_bin "move-bundle-to-als"
  deploy_bin "move-udev-refresh"
  deploy_bin "move-manager-webapp"
  deploy_bin "schwung-manager-webapp"
  deploy_bin "convert-adg-to-move"
  deploy_converter_resources
  deploy_bwpreset_converter
  deploy_move_bitwig
  # The TUI is the ONLY interface now (Roadmap 3.9): the old native script
  # and its interface mode file are stale — clean up any instance from a
  # pre-3.9 install so nothing on-disk still references the removed modes.
  if [[ -f $BIN_DIR/mosquito-move-manager-native ]]; then
    rm -f "$BIN_DIR/mosquito-move-manager-native"
    ok "Stale native-interface script removed ($BIN_DIR/mosquito-move-manager-native)"
  fi
  if [[ -f $REAL_HOME/.config/move-session/interface ]]; then
    rm -f "$REAL_HOME/.config/move-session/interface"
    ok "Stale interface mode file removed (~/.config/move-session/interface)"
  fi
  rm -f "$REAL_HOME/.config/move-session/interface-switch.log"
  ensure_confirm_plugin || true
  ensure_tui_float_windowrule || true
  ensure_webapp_float_windowrule || true
  configure_tracker_exclusion || true
  purge_legacy_entries || true
  install_menu
  remove_legacy_launcher
  install_udev
  install_chromium_policy
  ensure_ydotoold_nopasswd
  install_webapp_icon

  info "Setup complete. Summary:"
  echo "  • Interactive menu  -> $BIN_DIR/mosquito-move-manager (dispatcher: no args = the TUI,"
  echo "                        opened in a foot/xterm window if you aren't in one already)"
  echo "  • Flag actions      -> status / --demo / --address / --midi / --skip-manager /"
  echo "                        --no-bitwig / --pick-file (same dispatcher, with the flag)"
  echo "  • MIDI export      -> $BIN_DIR/move-bundle-to-midi"
  echo "  • .als export (beta) -> $BIN_DIR/move-bundle-to-als (Move → Live .als, no Ableton)"
  echo "  • udev disconnect-warn -> $BIN_DIR/move-udev-refresh"
  echo "  • Move Manager     -> $BIN_DIR/move-manager-webapp (dedicated Chromium profile, downloads → $MOVE_DIR/ablbundle)"
  echo "  • Convert a preset -> $BIN_DIR/convert-adg-to-move + converter/ resources (Ableton .adg → Move preset)"
  echo "  • Bitwig preset     -> $BIN_DIR/bwpreset-converter/ (Bitwig .bwpreset → Move preset; output in <working-dir>/Presets)"
  echo "  • Schwung Manager  -> $BIN_DIR/schwung-manager-webapp (dedicated Chromium profile, http://move[N].local:7700)"
  echo "  • Bitwig Move      -> .local/share/mosquito-move-manager/move-bitwig (controller scripts + on-device module)"
  echo "  • Chromium policy  -> no 'Keep?' prompt on Move Manager downloads (as root)"
  echo "  • ydotool NOPASSWD -> /etc/sudoers.d/mosquito-move-manager-ydotoold (as root; lets the TUI open the .als in Bitwig)"
  echo "  • Webapp icon      -> $WEBAPP_ICON_DST (custom Move Manager icon)"
  echo "  • Disconnect warn  -> udev rule (notifies only while the Move Manager webapp is actively in use)"
  echo "  • Folders          -> $MOVE_DIR/{ablbundle,als,bwproject,bwproject/midi}"
  echo "  • Omarchy overlay  -> mosquito.confirm plugin (native Yes/No prompts)"
  echo "  • Omarchy menu     -> Trigger > Music > mosquito Move Manager (menu: address / Move Manager / convert)"
  echo
  echo "  Run the menu from the Omarchy launcher or with: mosquito-move-manager"
  echo "  (if not run as root, run once: sudo bash $0 for the udev rule + chromium policy + ydotool NOPASSWD)"
fi