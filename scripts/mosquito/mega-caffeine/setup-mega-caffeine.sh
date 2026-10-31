#!/usr/bin/env bash
# =============================================================================
# Omarchy Custom - Mega caffeine (coffee mode)
# =============================================================================
# Coffee mode only: close the laptop, let everything run — red tint, sleep
# blocked while the lid is closed, natural-language durations.
#
# It deploys mega-caffeine and its "Trigger > Toggle > Mega caffeine" menu
# entry. Mega caffeine is independent of battery-management.
#
# Usage:
#   ./setup-mega-caffeine.sh            # install (idempotent)
#   ./setup-mega-caffeine.sh --remove   # stop coffee mode + remove menu entry
#   ./setup-mega-caffeine.sh --status   # 0 when binary + menu entry are there
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/gui-run.bash"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

info() { echo -e "\033[1;34m==>\033[0m $*"; }
ok()   { echo -e "\033[1;32m  ✓\033[0m $*"; }
warn() { echo -e "\033[1;33m  !\033[0m $*"; }
err()  { echo -e "\033[1;31m  ✗\033[0m $*" >&2; }

# Resolve the REAL invoking user's home even when run via sudo/pkexec.
if [[ $EUID -eq 0 ]]; then
  REAL_USER="${SUDO_USER:-}"
  if [[ -z $REAL_USER && -n ${PKEXEC_UID:-} ]]; then
    REAL_USER="$(getent passwd "$PKEXEC_UID" | cut -d: -f1)"
  fi
  [[ -n $REAL_USER ]] || REAL_USER="$(logname 2>/dev/null || true)"
  [[ -n $REAL_USER ]] || REAL_USER="root"
else
  REAL_USER="${USER:-$(id -un)}"
fi
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
REAL_HOME="${REAL_HOME:-$HOME}"

BIN_DIR="$REAL_HOME/.local/bin"
MENU_DIR="$REAL_HOME/.config/omarchy/extensions"
MENU="$MENU_DIR/omarchy-menu.jsonc"
STATE_DIR="$REAL_HOME/.local/state/caffeine"

MENU_START="// >>> Omarchy_Custom_Scripts - managed by setup-mega-caffeine.sh (mega-caffeine)"
MENU_END="// <<< Omarchy_Custom_Scripts - managed by setup-mega-caffeine.sh (mega-caffeine)"
# Markers written by the old combined battery installer.
MENU_LEGACY_START="// >>> Omarchy_Custom_Scripts - managed by setup-battery-management.sh (mega-caffeine)"
MENU_LEGACY_END="// <<< Omarchy_Custom_Scripts - managed by setup-battery-management.sh (mega-caffeine)"
MENU_LEGACY2_START="// >>> Omarchy_Custom_Scripts - managed by battery-management.sh (mega-caffeine)"
MENU_LEGACY2_END="// <<< Omarchy_Custom_Scripts - managed by battery-management.sh (mega-caffeine)"

if [[ ! -d /usr/share/omarchy ]]; then
  echo "This script is meant for Omarchy." >&2
  exit 1
fi

REMOVE=false
STATUS=false
case "${1:-}" in
  --remove) REMOVE=true ;;
  --status) STATUS=true ;;
  "") ;;
  *) err "Unknown option: $1"; exit 2 ;;
esac

menu_present() {
  [[ -f $MENU ]] && grep -qF "$MENU_START" "$MENU"
}

if [[ $STATUS == true ]]; then
  [[ -x "$BIN_DIR/mega-caffeine" ]] && menu_present
  exit
fi

if [[ $REMOVE == true ]]; then
  if [[ -x "$BIN_DIR/mega-caffeine" ]]; then
    "$BIN_DIR/mega-caffeine" off >/dev/null 2>&1 || true
    ok "Coffee mode stopped (if it was active)"
  fi
  rm -rf "$STATE_DIR"
  ok "Caffeine state directory removed ($STATE_DIR)"
  if menu_present; then
    local_start="$(grep -nF "$MENU_START" "$MENU" | head -1 | cut -d: -f1)"
    local_end="$(grep -nF "$MENU_END" "$MENU" | head -1 | cut -d: -f1)"
    if [[ -n $local_start && -n $local_end && $local_end -gt $local_start ]]; then
      tmp="$(mktemp)"
      head -n $((local_start - 1)) "$MENU" > "$tmp"
      tail -n +$((local_end + 1)) "$MENU" >> "$tmp"
      mv "$tmp" "$MENU"
      sed -i ':a;N;$!ba;s/,\([[:space:]]*\n[[:space:]]*}\)/\1/' "$MENU"
      [[ -s $MENU ]] || printf '{\n}\n' > "$MENU"
      ok "Menu entry removed: Trigger > Toggle > Mega caffeine"
    else
      warn "Inconsistent mega-caffeine markers in $MENU."
    fi
  else
    ok "No Mega caffeine menu entry, nothing to remove."
  fi
  exit 0
fi

# -----------------------------------------------------------------------------
# Deploy the binary.
# -----------------------------------------------------------------------------
mkdir -p "$BIN_DIR"
if [[ -f "$BIN_DIR/mega-caffeine" ]] && cmp -s "$SCRIPT_DIR/mega-caffeine" "$BIN_DIR/mega-caffeine" 2>/dev/null; then
  ok "mega-caffeine already in place and up to date ($BIN_DIR/mega-caffeine)"
else
  cp "$SCRIPT_DIR/mega-caffeine" "$BIN_DIR/mega-caffeine"
  chmod +x "$BIN_DIR/mega-caffeine"
  bash -n "$BIN_DIR/mega-caffeine" || { err "Invalid syntax: mega-caffeine"; exit 1; }
  ok "mega-caffeine deployed ($BIN_DIR/mega-caffeine)"
fi

# -----------------------------------------------------------------------------
# 3. Menu entry (Trigger > Toggle > Mega caffeine).
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
  [[ -f $MENU ]] || return 0
  local out
  out=$(python3 -c "$FIX_JSONC" "$MENU" 2>&1) || {
    warn "Invalid JSONC in $MENU (python said: $out)"
    return 1
  }
  ok "Menu $MENU valid"
}

mc_block() {
  cat <<MC_EOF
$MENU_START
  "trigger.toggle.mega-caffeine": {
    "icon": "\uf0f4",
    "label": "Mega caffeine",
    "description": "Coffee mode: laptop closed without sleeping, red tint, natural-language duration",
    "aliases": ["coffee", "cafe", "mode-cafe", "power-mode", "mosquito"],
    "when": "test -x $REAL_HOME/.local/bin/mega-caffeine",
    // NOT a plain read of ~/.local/state/caffeine/state: a reboot leaves that
    // file saying "on" with no session behind it, so the entry stayed ticked
    // and clicking it ran a "turn it off" for something already dead. The
    // script's --active checks the state AND that the inhibitor is really
    // running, and clears the leftover on the way.
    //
    // These MUST be // comments: the menu is JSONC and the installer validates
    // it by stripping // lines. A # line here produced a menu that looked
    // right in a diff and would not parse at all.
    "checked": "$REAL_HOME/.local/bin/mega-caffeine --active",
    "action": "$REAL_HOME/.local/bin/mega-caffeine toggle"
  },
$MENU_END
MC_EOF
}

migrate_mc_markers() {
  [[ -f $MENU ]] || return 0
  if grep -qF "$MENU_LEGACY_START" "$MENU" || grep -qF "$MENU_LEGACY_END" "$MENU" \
     || grep -qF "$MENU_LEGACY2_START" "$MENU" || grep -qF "$MENU_LEGACY2_END" "$MENU"; then
    sed -i "s|$MENU_LEGACY_START|$MENU_START|g; s|$MENU_LEGACY_END|$MENU_END|g; s|$MENU_LEGACY2_START|$MENU_START|g; s|$MENU_LEGACY2_END|$MENU_END|g" "$MENU"
    ok "Mega caffeine menu markers migrated to setup-mega-caffeine.sh"
  fi
}

install_mc_menu() {
  mkdir -p "$MENU_DIR"
  local block start_line end_line open_line tmp
  block="$(mc_block)"
  if [[ ! -f $MENU ]]; then
    printf '{\n%s\n}\n' "$block" > "$MENU"
  elif grep -qF "$MENU_START" "$MENU"; then
    start_line=$(grep -nF "$MENU_START" "$MENU" | head -1 | cut -d: -f1)
    end_line=$(grep -nF "$MENU_END" "$MENU" | head -1 | cut -d: -f1)
    if [[ -z $start_line || -z $end_line || $end_line -le $start_line ]]; then
      warn "Inconsistent mega-caffeine markers in $MENU - manual fix needed."
      return 0
    fi
    tmp=$(mktemp)
    head -n $((start_line - 1)) "$MENU" > "$tmp"
    printf '%s\n' "$block" >> "$tmp"
    tail -n +$((end_line + 1)) "$MENU" >> "$tmp"
    mv "$tmp" "$MENU"
  else
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
    ok "Menu bar entry added: Trigger > Toggle > Mega caffeine"
  else
    warn "Menu JSONC invalid after adding the entry - fix $MENU manually."
  fi
}

migrate_mc_markers
install_mc_menu

echo
info "Setup complete: mega-caffeine + its Trigger > Toggle > Mega caffeine menu entry."
echo "  Use it from the menu, or: mega-caffeine on|off|toggle|status"
