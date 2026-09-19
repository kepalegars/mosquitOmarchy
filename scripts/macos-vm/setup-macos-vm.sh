#!/bin/bash
# =============================================================================
# Omarchy Custom - Setup macOS VM (OSX-For-Omarchy, QEMU/KVM + OpenCore)
# =============================================================================
# Integrates the OSX-For-Omarchy tooling as a proper module:
#
#   1. osx-kvm-installer.sh : the interactive installer (packages + KVM + OVMF
#      + OpenCore + macOS recovery + disk + launcher + desktop entry per VM)
#   2. macOS VM Manager TUI  : gum-based menu (create / delete / details),
#      bound to Super+Alt+A with a floating centered window rule
#   3. Menu entry "macOS VM" : Setup > macOS VM (omarchy-launch-or-focus-tui)
#   4. Files are deployed to ~/.local/bin and are self-locating (no clone path)
#
# Rebased on https://github.com/28allday/OSX-For-Omarchy (vendored + patched:
# self-locating paths, Omarchy bindings.lua window rules instead of the
# upstream bindings.conf appends). The Super+Alt+A keybinding is registered
# through setup-keybindings.sh so it lives in the ONE marker block that script
# owns (Omarchy_Custom_Scripts_Keys); this script only keeps the window rule.
#
# Usage :
#   ./setup-macos-vm.sh            # deploys everything (idempotent, auto-detects)
#   ./setup-macos-vm.sh --remove   # removes helpers + menu/keybinding (keeps ~/OSX-KVM)
#
# Prerequisites : Omarchy + KVM (/dev/kvm). The installer itself installs the
# heavy dependencies (qemu-full, libvirt, edk2-ovmf, samba, dmg2img, …).
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/gui-run.bash"  # gui-run: reopen in a terminal when launched from a file manager
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/elevate.bash"  # mq_sudo: native pkexec prompt when not root
set -euo pipefail

info()  { echo -e "\033[1;34m==>\033[0m $*"; }
ok()    { echo -e "\033[1;32m ✓\033[0m $*"; }
warn()  { echo -e "\033[1;33m !\033[0m $*"; }
die()   { warn "$*"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
APPS_DIR="$HOME/.local/share/applications"
MENU_DIR="$HOME/.config/omarchy/extensions"
MENU="$MENU_DIR/omarchy-menu.jsonc"
HYPR_DIR="$HOME/.config/hypr"
HYPRLAND="$HYPR_DIR/hyprland.lua"
VMS_ROOT="$HOME/OSX-KVM"

# Managed marker blocks (removal is `--remove`).
BLOCK_BEGIN='// >>> Omarchy_Custom_Scripts_MacosVm'
BLOCK_END='// <<< Omarchy_Custom_Scripts_MacosVm'
HYPR_BEGIN='-- >>> Omarchy_Custom_Scripts_MacosVm'
HYPR_END='-- <<< Omarchy_Custom_Scripts_MacosVm'

# The Super+Alt+A binding is owned by the keybindings manager, not by a marker.
KEYBINDS="$SCRIPT_DIR/../setup-keybindings.sh"
MENU_KEY='setup.macosvm'

# ── Omarchy menu helpers (JSONC, marker-based) ─────────────────────────────
# See setup-omarchy-vm.sh: strip the marked block AND any legacy unmarked key,
# normalize trailing commas, then insert after the opening brace. This is what
# keeps the menu valid (a duplicate legacy setup.macosvm + a missing comma used
# to make the whole file unparseable, hiding every menu entry).
strip_marker_block() {
  [[ -f $MENU ]] || return 0
  local tmp; tmp=$(mktemp)
  awk -v b="$BLOCK_BEGIN" -v e="$BLOCK_END" '
    $0 == b {skip=1; next}
    $0 == e {skip=0; next}
    skip {next}
    {print}
  ' "$MENU" > "$tmp" && mv "$tmp" "$MENU"
}

strip_menu_key() {
  [[ -f $MENU ]] || return 0
  local key="$1" tmp; tmp=$(mktemp)
  awk -v key="$key" '
    !skip && $0 ~ ("^[[:space:]]*\"" key "\"[[:space:]]*:[[:space:]]*\\{") {
      o=gsub(/\{/,"{"); c=gsub(/\}/,"}");
      depth=o-c;
      if (depth<=0) next
      skip=1; next
    }
    skip {
      o=gsub(/\{/,"{"); c=gsub(/\}/,"}");
      depth+=o-c;
      if (depth<=0) skip=0
      next
    }
    {print}
  ' "$MENU" > "$tmp" && mv "$tmp" "$MENU"
}

normalize_menu() {
  [[ -f $MENU ]] || return 0
  python3 - "$MENU" <<'PY' 2>/dev/null || true
import re, sys
p = sys.argv[1]
t = open(p, encoding="utf-8").read()
t = re.sub(r',(\s*[}\]])', r'\1', t)
open(p, "w", encoding="utf-8").write(t)
PY
}


REMOVE=false
for a in "$@"; do
  case "$a" in
    --remove) REMOVE=true ;;
    -y|--yes) : ;;
    -h|--help) sed -n '1,26p' "$0"; exit 0 ;;
    *) echo "Unknown option: $a (supported: --remove -y)" >&2; exit 1 ;;
  esac
done

# -----------------------------------------------------------------------------
# 0. Prerequisites / auto-detection
# -----------------------------------------------------------------------------
[[ -d /usr/share/omarchy ]] || die "This script is meant for Omarchy."
if [[ ! -e /dev/kvm ]]; then
  warn "/dev/kvm is missing — the VMs cannot run. Enable VT-x/AMD-V + KVM first."
fi
[[ -f $SCRIPT_DIR/../setup-keybindings.sh ]] || die "setup-keybindings.sh not found — cannot register the Super+Alt+A binding."
for s in osx-kvm-installer.sh macos-vm-tui.sh launch-macos-tui.sh; do
  [[ -f "$SCRIPT_DIR/$s" ]] || die "Vendored file missing: $SCRIPT_DIR/$s"
done

# -----------------------------------------------------------------------------
# 1. Deploy the three scripts to ~/.local/bin (self-locating, no clone path)
# -----------------------------------------------------------------------------
if [[ $REMOVE == false ]]; then
  info "Deploying the macOS VM scripts to $BIN_DIR"
  mkdir -p "$BIN_DIR"
  for s in osx-kvm-installer.sh macos-vm-tui.sh launch-macos-tui.sh; do
    install -m 0755 "$SCRIPT_DIR/$s" "$BIN_DIR/$s"
    bash -n "$BIN_DIR/$s" || die "Syntax error in $BIN_DIR/$s"
    ok "$s deployed"
  done

  # The Omarchy menu action and the Super+Alt+A keybinding call
  # `omarchy-launch-or-focus-tui macos-vm-tui`, which resolves the command on
  # PATH — so a name WITHOUT the .sh is required (xdg-terminal-exec does not
  # try extensions). This tiny wrapper execs the real TUI; without it the menu
  # entry silently does nothing.
  cat > "$BIN_DIR/macos-vm-tui" << 'TUI_WRAPPER_EOF'
#!/usr/bin/env bash
# Wrapper so `omarchy-launch-or-focus-tui macos-vm-tui` (Omarchy menu /
# Super+Alt+A) finds the TUI under a PATH name without the .sh extension.
exec "$(dirname "$(readlink -f "$0")")/macos-vm-tui.sh" "$@"
TUI_WRAPPER_EOF
  chmod +x "$BIN_DIR/macos-vm-tui"
  bash -n "$BIN_DIR/macos-vm-tui"
  ok "macos-vm-tui wrapper deployed (menu/keybinding launch)"

  # TUI relies on gum (also used by the installer's menus).
  info "Checking gum (TUI + installer menus)"
  if command -v gum >/dev/null; then
    ok "gum present: $(gum --version)"
  else
    warn "gum missing — installing it (TUI + installer require it)"
    mq_sudo -v || die "Password required to install gum."
    mq_sudo pacman -S --needed --noconfirm gum || die "gum installation failed."
    ok "gum installed"
  fi

  echo "  • Installer -> $BIN_DIR/osx-kvm-installer.sh (run it, or use the TUI)"
  echo "  • TUI       -> $BIN_DIR/macos-vm-tui.sh"
  echo "  • Launcher  -> $BIN_DIR/launch-macos-tui.sh"
fi

# -----------------------------------------------------------------------------
# 2. Omarchy menu entry (block "Setup > macOS VM")
# -----------------------------------------------------------------------------
read_menu_block() {
  cat <<BLOCK_EOF
$BLOCK_BEGIN
  "setup.macosvm": {
    "icon": "󰀵",
    "label": "macOS VM",
    "description": "macOS VMs in QEMU/KVM — create, launch, delete (Super+Alt+A)",
    "aliases": ["macos", "osx", "vm"],
    "action": "omarchy-launch-or-focus-tui macos-vm-tui"
  },
$BLOCK_END
BLOCK_EOF
}

insert_menu_block() {
  mkdir -p "$MENU_DIR"
  # Drop any previous marked block and any legacy unmarked key first, so we
  # never end up with a duplicate (which is what corrupted the file).
  strip_marker_block
  strip_menu_key "$MENU_KEY"
  normalize_menu

  local block_tmp; block_tmp=$(mktemp)
  read_menu_block > "$block_tmp"

  if [[ ! -f $MENU ]]; then
    { echo "{"; cat "$block_tmp"; echo "}"; } > "$MENU"
  else
    # Insert right after the opening brace: the block ends with a comma, so
    # whatever key follows stays valid, and normalize_menu cleans the tail.
    local open_line; open_line=$(grep -nE '^[[:space:]]*\{[[:space:]]*$' "$MENU" | cut -d: -f1 | head -1)
    if [[ -z $open_line ]]; then
      rm -f "$block_tmp"; warn "Could not find the opening brace in $MENU — entry not added."; return
    fi
    local tmp; tmp=$(mktemp)
    head -n "$open_line" "$MENU" > "$tmp"
    cat "$block_tmp" >> "$tmp"
    tail -n +$((open_line + 1)) "$MENU" >> "$tmp"
    mv "$tmp" "$MENU"
  fi
  rm -f "$block_tmp"
  normalize_menu
}

remove_menu_block() {
  [[ -f $MENU ]] || return 0
  strip_marker_block
  strip_menu_key "$MENU_KEY"
  normalize_menu
  ok "Block 'Setup > macOS VM' removed from the menu"
}

# -----------------------------------------------------------------------------
# 3. Hyprland integration (marker blocks, idempotent)
# -----------------------------------------------------------------------------
upsert_block_file() {
  # $1 = file, $2 = begin marker, $3 = end marker, $4 = block body
  local file="$1" b="$2" e="$3" body="$4" tmp
  mkdir -p "$(dirname "$file")"
  if [[ ! -f $file ]]; then
    : > "$file"
  fi
  if grep -qF -- "$b" "$file"; then
    local sb=$(grep -nF -- "$b" "$file" | cut -d: -f1 | head -1)
    local se=$(grep -nF -- "$e" "$file" | cut -d: -f1 | head -1)
    if [[ -n $sb && -n $se && $se -gt $sb ]]; then
      tmp=$(mktemp)
      head -n $((sb - 1)) "$file" > "$tmp"
      printf '%s\n%s\n' "$body" "$e" >> "$tmp"
      tail -n +$((se + 1)) "$file" >> "$tmp"
      mv "$tmp" "$file"
    fi
  else
    printf '\n%s\n%s\n' "$body" "$e" >> "$file"
  fi
}

drop_block_from_file() {
  # $1 = file, $2 = begin marker, $3 = end marker
  local file="$1" b="$2" e="$3"
  [[ -f $file ]] || return 0
  if grep -qF -- "$b" "$file"; then
    local sb=$(grep -nF -- "$b" "$file" | cut -d: -f1 | head -1)
    local se=$(grep -nF -- "$e" "$file" | cut -d: -f1 | head -1)
    if [[ -n $sb && -n $se && $se -gt $sb ]]; then
      tmp=$(mktemp)
      head -n $((sb - 1)) "$file" > "$tmp"
      tail -n +$((se + 1)) "$file" >> "$tmp"
      mv "$tmp" "$file"
      grep -q '[^[:space:]]' "$file" 2>/dev/null || : > "$file"
    fi
  fi
}

macos_rule_body() {
  cat <<'BODY'
-- >>> Omarchy_Custom_Scripts_MacosVm
-- macOS VM Manager TUI: floating centered window (setup-macos-vm.sh)
o.window("org.omarchy.macos-vm-tui", { float = true, center = true, size = { 800, 600 } })
BODY
}

hypr_reload_check() {
  hyprctl reload >/dev/null 2>&1 || true
  local err
  err="$(hyprctl configerrors -j 2>/dev/null | jq -r '.[] | select(. == "*macos-vm*")' 2>/dev/null | head -1)"
  if ${SHOW_ERRORS:-false} && [[ -n $err ]]; then
    warn "Hyprland reports a config error: $err"
  fi
}

if [[ $REMOVE == false ]]; then
  info "Configuring the 'Setup > macOS VM' entry in the Omarchy menu"
  insert_menu_block
  ok "Menu configured: Setup > macOS VM"

  if [[ -f $HYPRLAND ]]; then
    upsert_block_file "$HYPRLAND" "$HYPR_BEGIN" "$HYPR_END" "$(macos_rule_body)"
    ok "Window rule added: org.omarchy.macos-vm-tui floats centered (800x600)"
  fi

  info "Registering the keybinding through setup-keybindings.sh (its marker block)"
  bash "$KEYBINDS" -y --ensure "SUPER + ALT + A" "macOS VM Manager" "omarchy-launch-or-focus-tui macos-vm-tui" launch || warn "Could not register Super+Alt+A"

  hypr_reload_check
else
  info "Removing the macOS VM scripts"
  for s in osx-kvm-installer.sh macos-vm-tui.sh launch-macos-tui.sh; do
    rm -f "$BIN_DIR/$s"
  done
  rm -f "$BIN_DIR/macos-vm-tui"
  ok "scripts removed from $BIN_DIR"
  remove_menu_block
  drop_block_from_file "$HYPRLAND" "$HYPR_BEGIN" "$HYPR_END"
  bash "$KEYBINDS" -y --remove-key "SUPER + ALT + A" || warn "Could not remove Super+Alt+A"
  ok "Menu entry, keybinding and window rule removed"
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
info "setup-macos-vm:"
if [[ $REMOVE == true ]]; then
  echo "  • Helpers, menu, keybinding and window rule removed"
  echo "  • The VMs themselves (~/OSX-KVM) are kept. Delete them manually if wanted."
else
  echo "  • Installer -> osx-kvm-installer.sh  (interactive: packages, recovery, VM)"
  echo "  • Manager  -> Super+Alt+A or the 'macOS VM' menu entry (TUI)"
  echo "  • Remove   -> ./setup-macos-vm.sh --remove"
  echo ""
  echo "  First run: install the VM"
  echo "    $BIN_DIR/osx-kvm-installer.sh      (or create a VM later through the TUI)"
fi