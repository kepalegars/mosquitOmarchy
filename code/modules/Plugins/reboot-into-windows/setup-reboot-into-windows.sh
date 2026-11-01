#!/usr/bin/env bash
# =============================================================================
# Reboot into Windows — System menu entry + one-shot UEFI boot switch
# =============================================================================
# Adds one entry under System in the Omarchy menu:
#
#   Reboot into Windows
#
# The entry starts `reboot-into-windows` in a floating terminal. That helper
# finds the firmware's "Windows Boot Manager" entry, shows a 15 s countdown
# with a yes/no confirmation, arms BootNext for the next boot only, verifies
# it, then reboots through Omarchy's own reboot path.
#
# Nothing global is installed: ~/.local/bin/reboot-into-windows plus a marked
# block in ~/.config/omarchy/extensions/omarchy-menu.jsonc.
#
# Usage:
#   ./setup-reboot-into-windows.sh            # install / refresh (idempotent)
#   ./setup-reboot-into-windows.sh --status   # installed | missing | partial
#   ./setup-reboot-into-windows.sh --remove   # remove helper + menu entry
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../lib/gui-run.bash"  # gui-run: reopen in a terminal when launched from a file manager
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf ' \033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf ' \033[1;33m!\033[0m %s\n' "$*" >&2; }
err()  { printf ' \033[1;31m✗\033[0m %s\n' "$*" >&2; }

# Resolve the real invoking user's home even under sudo.
if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
  REAL_USER="${SUDO_USER:-$(getent passwd "${PKEXEC_UID:-0}" 2>/dev/null | cut -d: -f1)}"
  REAL_USER="${REAL_USER:-root}"
else
  REAL_USER="${USER:-$(id -un)}"
fi
REAL_HOME="$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6)"
REAL_HOME="${REAL_HOME:-$HOME}"

BIN="$REAL_HOME/.local/bin/reboot-into-windows"
MENU_DIR="$REAL_HOME/.config/omarchy/extensions"
MENU="$MENU_DIR/omarchy-menu.jsonc"
START="// >>> mosquitOmarchy - reboot into windows (managed by setup-reboot-into-windows.sh)"
END="// <<< mosquitOmarchy - reboot into windows"

[[ -d /usr/share/omarchy ]] || { err "This module is meant for Omarchy."; exit 1; }

MODE=install
case "${1:-}" in
  --status) MODE=status ;;
  --remove) MODE=remove ;;
  -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
  "") : ;;
  *) err "Unknown option: $1 (supported: --status, --remove)"; exit 2 ;;
esac

status() {
  [[ -x $BIN ]] || { echo missing; return; }
  [[ -f $MENU ]] && grep -qF "$START" "$MENU" || { echo partial; return; }
  echo ok
}

remove_block() {
  [[ -f $MENU ]] || return 0
  local tmp
  tmp="$(mktemp)"
  awk -v start="$START" -v end="$END" '
    $0 == start { skip=1; next }
    $0 == end   { skip=0; next }
    !skip       { print }
  ' "$MENU" > "$tmp"
  mv "$tmp" "$MENU"
}

if [[ $MODE == status ]]; then
  status
  exit 0
fi

if [[ $MODE == remove ]]; then
  info "Removing Reboot into Windows"
  rm -f "$BIN"
  remove_block
  ok "Helper and System menu entry removed (BootNext is left untouched)."
  exit 0
fi

# ---------------------------------------------------------------------------
# 1. Deploy the helper
# ---------------------------------------------------------------------------
mkdir -p "$REAL_HOME/.local/bin"
install -m 0755 "$SCRIPT_DIR/reboot-into-windows" "$BIN"
if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
  chown "$REAL_USER:$REAL_USER" "$BIN" 2>/dev/null || true
fi
bash -n "$BIN" || { err "Invalid syntax in $BIN"; exit 1; }
ok "Helper installed: $BIN"

# ---------------------------------------------------------------------------
# 2. Add the System menu entry (marked block, idempotent)
# ---------------------------------------------------------------------------
mkdir -p "$MENU_DIR"
[[ -f $MENU ]] || printf '{\n}\n' > "$MENU"
[[ -s $MENU ]] || printf '{\n}\n' > "$MENU"

# Back up before the first edit of this run; keep it simple and dated.
cp -f "$MENU" "$MENU.bak.reboot-windows-$(date +%s)" 2>/dev/null || true

remove_block

blockfile="$(mktemp)"
cat > "$blockfile" <<EOF
$START
  "system.reboot-windows": {
    "icon": "󰖳",
    "label": "Reboot into Windows",
    "description": "Arm the firmware's Windows Boot Manager for the next boot only (15 s countdown, yes/no), then reboot.",
    "aliases": ["windows", "windows 11", "reboot windows", "boot windows", "winboot"],
    "when": "test -x $BIN",
    "action": "omarchy-launch-floating-terminal-with-presentation $BIN"
  },
$END
EOF

tmp="$(mktemp)"
awk -v blockfile="$blockfile" '
  NR == 1 {
    print
    while ((getline line < blockfile) > 0) print line
    next
  }
  { print }
' "$MENU" > "$tmp"

# Validate the JSONC after removing line comments. A broken menu would take
# the whole Omarchy menu down, so restore the backup rather than write it.
if command -v jq >/dev/null 2>&1; then
  if ! grep -v '^[[:space:]]*//' "$tmp" | jq empty 2>/dev/null; then
    rm -f "$tmp" "$blockfile"
    err "Generated menu is not valid JSONC — the previous menu was kept."
    exit 1
  fi
fi
mv "$tmp" "$MENU"
rm -f "$blockfile"
if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
  chown "$REAL_USER:$REAL_USER" "$MENU" 2>/dev/null || true
fi
ok "System menu entry installed: Reboot into Windows"

# ---------------------------------------------------------------------------
# 3. Report what the helper sees (never blocks on a missing Windows entry)
# ---------------------------------------------------------------------------
if command -v efibootmgr >/dev/null 2>&1; then
  if "$BIN" --list >/dev/null 2>&1; then
    ok "Windows Boot Manager detected."
  else
    warn "No Windows Boot Manager found yet — the menu entry stays, but it will say so until Windows is installed/restored."
  fi
else
  warn "efibootmgr is missing (UEFI only); install it before using the entry."
fi

info "Done. The entry lives in System → Reboot into Windows."
