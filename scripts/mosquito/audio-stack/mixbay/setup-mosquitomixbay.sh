#!/usr/bin/env bash
# =============================================================================
# mosquitOmarchy - "mosquitomixbay" (install / status)
# =============================================================================
# USB-audio control bay: Audient EVO 8 (full control via evo_raw kmod),
# EVO 4 (same protocol), RME Fireface UCX II / ESI UGM192 / PreSonus
# Quantum ES 4 (ALSA level 1 + persistent demo).
#
# Installs:
#   1. mosquito-mixbay + mosquito-mixbay-actions → ~/.local/bin
#      (dispatchers, same architecture as the sibling audio-plugin-manager)
#   2. mosquito-mixbay-tui → ~/.local/bin (compiled Go/Bubble Tea over the
#      shared lib/tui-kit; the ONLY interface)
#   3. Hyprland float rule for the TUI window
#   4. evo_raw kernel module (/dev/evo4, /dev/evo8) via kmod/install-evo-raw.sh
#      — optional but required for REAL hardware control; without it the bay
#      runs in persistent DEMO mode (fully usable for prep/rehearsal).
#
# Usage:
#   ./setup-mosquitomixbay.sh        install (interactive, silent re-install)
#   ./setup-mosquitomixbay.sh -y     non-interactive install
#   ./setup-mosquitomixbay.sh --status
#   ./setup-mosquitomixbay.sh --uninstall   # userspace only; kmod + state kept
#
# The Omarchy audio panel clone and the media-key guard are owned by the
# sibling levels-guard module. Installing Mixbay alone never touches them.
# =============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../lib/elevate.bash"  # mq_sudo

info()  { echo -e "\033[1;34m==>\033[0m $*"; }
ok()    { echo -e "\033[1;32m ✓\033[0m $*"; }
warn()  { echo -e "\033[1;33m !\033[0m $*"; }
die()   { warn "$*"; exit 1; }

YES=0 STATUS_ONLY=0 NO_KMOD=0 UNINSTALL=0
for a in "$@"; do case "$a" in
  -y|--yes) YES=1 ;;
  --status) STATUS_ONLY=1 ;;
  --no-kmod) NO_KMOD=1 ;;
  --uninstall) UNINSTALL=1 ;;
esac; done

ask(){
  local q="$1" def="${2:-y}" r
  ((YES)) && { ok "(auto) $q -> yes"; return 0; }
  if command -v gum >/dev/null; then
    gum confirm "$q" --default=$([[ $def == y ]] && echo true || echo false) && return 0 || return 1
  fi
  read -rp "$q [$([ $def = y ] && echo Y/n || echo y/N)] " r
  r="${r:-$def}"; [[ $r =~ ^[oOyY] ]]
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
mixbay_status(){
  local tui="$BIN_DIR/mosquito-mixbay-tui" disp="$BIN_DIR/mosquito-mixbay"
  [[ -x $disp && -x $tui ]] || { echo missing; return; }
  local miss=""
  grep -qF "mosquito-mixbay-tui-setup" "$HOME/.config/hypr/hyprland.lua" 2>/dev/null || miss="${miss:+$miss, }hyprland float rule"
  [[ -e /dev/evo8 || -e /dev/evo4 ]] || miss="${miss:+$miss, }evo_raw kmod (demo mode only)"
  [[ -n $miss ]] && { echo "partial:missing ${miss# }"; return; }
  echo ok
}

if ((STATUS_ONLY)); then mixbay_status; exit 0; fi

if ((UNINSTALL)); then
  info "Uninstalling mosquitomixbay (userspace only)"
  rm -f "$BIN_DIR/mosquito-mixbay" "$BIN_DIR/mosquito-mixbay-actions" "$BIN_DIR/mosquito-mixbay-tui"
  ok "binaries removed from $BIN_DIR"
  if [[ -f "$HOME/.config/hypr/hyprland.lua" ]]; then
    sed -i '/-- >>> mosquito-mixbay-tui-setup >>>/,/-- <<< mosquito-mixbay-tui-setup <<</d' "$HOME/.config/hypr/hyprland.lua"
    hyprctl reload >/dev/null 2>&1 || true
    ok "Hyprland float rule removed"
  fi
  rm -f "$HOME/.local/share/applications/mosquito-mixbay.desktop"
  command -v update-desktop-database >/dev/null && update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
  # The evo_raw kernel module stays: unloading it mid-session would cut a live
  # interface, and DKMS removal needs its own reboot story. Unload by hand
  # with `sudo modprobe -r evo_raw` if the hardware is gone for good.
  [[ -e /dev/evo8 || -e /dev/evo4 ]] && warn "evo_raw kmod left in place ($(ls /dev/evo* 2>/dev/null | tr '\n' ' ')) — sudo modprobe -r evo_raw to unload it."
  # Demo state + device shadows are personal data (rehearsal levels): kept.
  ok "mosquitomixbay uninstalled — demo/device state kept under ~/.config/"
  exit 0
fi

mkdir -p "$BIN_DIR"

# -----------------------------------------------------------------------------
# 1. Deploy the dispatchers
# -----------------------------------------------------------------------------
for f in mosquito-mixbay mosquito-mixbay-actions; do
  [[ -f "$SCRIPT_DIR/$f" ]] || die "$f not found next to this script"
  cp "$SCRIPT_DIR/$f" "$BIN_DIR/$f"
  chmod +x "$BIN_DIR/$f"
  bash -n "$BIN_DIR/$f" || die "Invalid syntax: $f"
  ok "$f deployed: $BIN_DIR/$f"
done

# -----------------------------------------------------------------------------
# 2. Build the Go TUI (build-time-only Go dependency, same as siblings)
# -----------------------------------------------------------------------------
if ! command -v go >/dev/null 2>&1; then
  warn "go not found — mosquito-mixbay-tui won't be built. Install go (mise / pacman -S go) and re-run."
else
  TUI_TMP_OUT="$(mktemp "$BIN_DIR/.mosquito-mixbay-tui.XXXXXX")"
  TUI_VERSION="$(cat "$SCRIPT_DIR/../../../../VERSION" 2>/dev/null || echo dev)"
  if (cd "$SCRIPT_DIR/tui-go" && go build -ldflags "-X main.appVersion=$TUI_VERSION" -o "$TUI_TMP_OUT" .); then
    chmod +x "$TUI_TMP_OUT"
    mv -f "$TUI_TMP_OUT" "$BIN_DIR/mosquito-mixbay-tui"
    ok "mosquito-mixbay-tui built and deployed ($BIN_DIR/mosquito-mixbay-tui)"
  else
    rm -f "$TUI_TMP_OUT"
    warn "mosquito-mixbay-tui build failed — re-run after fixing the cause."
  fi
fi

# -----------------------------------------------------------------------------
# 3. Hyprland float rule (same marked-block pattern as siblings)
# -----------------------------------------------------------------------------
HYPR_CONF="$HOME/.config/hypr/hyprland.lua"
mkdir -p "$HOME/.config/hypr"
touch "$HYPR_CONF"
sed -i '/-- >>> mosquito-mixbay-tui-setup >>>/,/-- <<< mosquito-mixbay-tui-setup <<</d' "$HYPR_CONF"
cat >>"$HYPR_CONF" <<'EOF'
-- >>> mosquito-mixbay-tui-setup >>> float mosquito-mixbay-tui
o.window("org.omarchy.mosquito-mixbay-tui", { float = true, center = true, size = { 1000, 780 } })
-- <<< mosquito-mixbay-tui-setup <<<
EOF
hyprctl reload >/dev/null 2>&1 || true
ok "Hyprland float rule installed ($HYPR_CONF)"

# -----------------------------------------------------------------------------
# 4. evo_raw kernel module (REAL EVO control; demo mode without it)
# -----------------------------------------------------------------------------
if [[ -e /dev/evo8 || -e /dev/evo4 ]]; then
  ok "evo_raw already live ($(ls /dev/evo* 2>/dev/null | tr '\n' ' '))"
elif ((NO_KMOD)); then
  ok "kmod skipped (--no-kmod) — the bay runs in DEMO mode"
elif ask "Install the evo_raw kernel module (REAL EVO 8/4 control — needs sudo + reboot-safe DKMS)?" y; then
  if bash "$SCRIPT_DIR/kmod/install-evo-raw.sh"; then
    ok "evo_raw installed"
  else
    warn "evo_raw install failed — the bay stays in DEMO mode (re-run kmod/install-evo-raw.sh later)."
  fi
else
  ok "skipped — the bay runs in DEMO mode until the kmod is installed"
fi

# -----------------------------------------------------------------------------
# 5. Menu: lives in Setup ▸ mosquito (no Apps .desktop), like the siblings
# -----------------------------------------------------------------------------
rm -f "$HOME/.local/share/applications/mosquito-mixbay.desktop"
command -v update-desktop-database >/dev/null && update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
ok "menu: mosquitomixbay lives in Setup ▸ mosquito (no apps .desktop)"

info "mosquitomixbay ready — run: mosquito-mixbay"
info "status: $(mixbay_status)"
