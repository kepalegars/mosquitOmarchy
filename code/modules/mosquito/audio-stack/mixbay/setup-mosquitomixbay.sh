#!/usr/bin/env bash
# =============================================================================
# mosquitOmarchy - "mosquitomixbay" (install / status)
# =============================================================================
# USB-audio control bay: Audient EVO 8 (full control via evo_raw kmod),
# EVO 4 (same protocol), SSL 12 via douze, RME Fireface UCX II / ESI UGM192
# (ALSA level 1) and user-added beta interfaces.
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
[[ -f "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../../lib/go-build-env.bash" ]] && source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../../lib/go-build-env.bash"  # contained Go caches (no ~/go)
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../../lib/elevate.bash"  # mq_sudo

info()  { echo -e "\033[1;34m==>\033[0m $*"; }
ok()    { echo -e "\033[1;32m ✓\033[0m $*"; }
warn()  { echo -e "\033[1;33m !\033[0m $*"; }
die()   { warn "$*"; exit 1; }

YES=0 STATUS_ONLY=0 NO_KMOD=0 UNINSTALL=0 NO_FOUNDATION=0
for a in "$@"; do case "$a" in
  -y|--yes) YES=1 ;;
  --status) STATUS_ONLY=1 ;;
  --no-kmod) NO_KMOD=1 ;;
  --no-foundation) NO_FOUNDATION=1 ;;
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
  [[ -f "$HOME/.config/wireplumber/wireplumber.conf.d/50-mixbay-interfaces.conf" ]] \
    || miss="${miss:+$miss, }audio foundation (WirePlumber/udev/rate)"
  [[ -x "$BIN_DIR/mixbay-reverse" ]] || miss="${miss:+$miss, }reverse harness (usbmon)"
  [[ -n $miss ]] && { echo "partial:missing ${miss# }"; return; }
  echo ok
}

if ((STATUS_ONLY)); then mixbay_status; exit 0; fi

if ((UNINSTALL)); then
  info "Uninstalling mosquitomixbay (userspace only)"
  if [[ -x "$SCRIPT_DIR/foundation/audio-foundation.sh" ]]; then
    bash "$SCRIPT_DIR/foundation/audio-foundation.sh" --remove \
      || warn "audio foundation removal reported a problem"
  fi
  [[ -x "$BIN_DIR/mixbay-startup" ]] && "$BIN_DIR/mixbay-startup" --remove || true
  rm -f "$BIN_DIR/mosquito-mixbay" "$BIN_DIR/mosquito-mixbay-actions" "$BIN_DIR/mosquito-mixbay-tui" "$BIN_DIR/mosquito-mixbay-compat" "$BIN_DIR/mixbay-audio-foundation" "$BIN_DIR/mixbay-audio-defaults" "$BIN_DIR/mixbay-setup-ssl12" "$BIN_DIR/mixbay-startup" "$BIN_DIR/mixbay-reverse"
  ok "binaries removed from $BIN_DIR"
  if [[ -f "$HOME/.config/hypr/hyprland.lua" ]]; then
    sed -i '/-- >>> mosquito-mixbay-tui-setup >>>/,/-- <<< mosquito-mixbay-tui-setup <<</d' "$HOME/.config/hypr/hyprland.lua"
    hyprctl reload >/dev/null 2>&1 || true
    ok "Hyprland float rule removed"
  fi
  rm -f "$HOME/.local/share/applications/mosquito-mixbay.desktop"
  command -v update-desktop-database >/dev/null && update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
  if [[ -f /etc/udev/rules.d/99-evo8-capture.rules || -f /usr/local/lib/mosquitomixbay/evo8-capture-enable.py ]]; then
    mq_sudo bash -c 'rm -f /etc/udev/rules.d/99-evo8-capture.rules /usr/local/lib/mosquitomixbay/evo8-capture-enable.py; udevadm control --reload-rules' \
      && ok "EVO 8 capture helper removed" \
      || warn "could not remove the EVO 8 capture helper (needs sudo)"
  fi
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

# First-connection onboarding helper (called by mosquito-mixbay before the
# TUI). The repo root is baked in so --apply can reuse the full installer;
# the script falls back to its own location when run from the checkout.
if [[ -f "$SCRIPT_DIR/compat/interface-onboarding.sh" ]]; then
  COMPAT_TMP="$(mktemp "$BIN_DIR/.mosquito-mixbay-compat.XXXXXX")"
  sed "s|@MIXBAY_ROOT@|$SCRIPT_DIR|g" "$SCRIPT_DIR/compat/interface-onboarding.sh" > "$COMPAT_TMP"
  chmod +x "$COMPAT_TMP"
  bash -n "$COMPAT_TMP" || { rm -f "$COMPAT_TMP"; die "Invalid syntax: mosquito-mixbay-compat"; }
  # mv replaces the inode: safe even when the caller is the running helper.
  mv -f "$COMPAT_TMP" "$BIN_DIR/mosquito-mixbay-compat"
  ok "mosquito-mixbay-compat deployed: $BIN_DIR/mosquito-mixbay-compat"
fi

# Audio foundation helper (status/apply/remove, also used by the TUI and the
# onboarding prompt). Same @MIXBAY_ROOT@ baking as the compat helper.
if [[ -f "$SCRIPT_DIR/foundation/audio-foundation.sh" ]]; then
  FOUNDATION_TMP="$(mktemp "$BIN_DIR/.mixbay-audio-foundation.XXXXXX")"
  sed "s|@MIXBAY_ROOT@|$SCRIPT_DIR|g" "$SCRIPT_DIR/foundation/audio-foundation.sh" > "$FOUNDATION_TMP"
  chmod +x "$FOUNDATION_TMP"
  bash -n "$FOUNDATION_TMP" || { rm -f "$FOUNDATION_TMP"; die "Invalid syntax: mixbay-audio-foundation"; }
  mv -f "$FOUNDATION_TMP" "$BIN_DIR/mixbay-audio-foundation"
  ok "mixbay-audio-foundation deployed: $BIN_DIR/mixbay-audio-foundation"
fi

# Guided USB reverse-engineering harness (usbmon capture + pyusb replay).
if [[ -f "$SCRIPT_DIR/harness/mixbay-reverse.py" ]]; then
  cp "$SCRIPT_DIR/harness/mixbay-reverse.py" "$BIN_DIR/mixbay-reverse"
  chmod +x "$BIN_DIR/mixbay-reverse"
  python3 -m py_compile "$BIN_DIR/mixbay-reverse" 2>/dev/null \
    || warn "mixbay-reverse deployed but python syntax check failed"
  ok "mixbay-reverse deployed: $BIN_DIR/mixbay-reverse"
fi

# Login autostart / scratchpad helper (both enabled by default at install).
if [[ -f "$SCRIPT_DIR/startup/mixbay-startup" ]]; then
  cp "$SCRIPT_DIR/startup/mixbay-startup" "$BIN_DIR/mixbay-startup"
  chmod +x "$BIN_DIR/mixbay-startup"
  bash -n "$BIN_DIR/mixbay-startup" || die "Invalid syntax: mixbay-startup"
  "$BIN_DIR/mixbay-startup" --apply || warn "could not write the Mixbay autostart line"
  ok "mixbay-startup deployed (login + scratchpad, on by default)"
fi

# SSL 12 setup wrapper: the TUI action "Set up / repair SSL 12" runs this in
# the terminal. It delegates to the douze module (one source of truth for
# clone/service/udev/PipeWire/plugin).
SSL12_SETUP_SRC="$SCRIPT_DIR/../../../Apps/douze/setup-douze.sh"
if [[ -f "$SSL12_SETUP_SRC" ]]; then
  SSL12_TMP="$(mktemp "$BIN_DIR/.mixbay-setup-ssl12.XXXXXX")"
  cat > "$SSL12_TMP" <<EOF
#!/usr/bin/env bash
exec bash "$SSL12_SETUP_SRC" -y --update --restart-pipewire "\$@"
EOF
  chmod +x "$SSL12_TMP"
  mv -f "$SSL12_TMP" "$BIN_DIR/mixbay-setup-ssl12"
  ok "mixbay-setup-ssl12 deployed: $BIN_DIR/mixbay-setup-ssl12"
fi

# -----------------------------------------------------------------------------
# 2. Build the Go TUI (build-time-only Go dependency, same as siblings)
# -----------------------------------------------------------------------------
if ! command -v go >/dev/null 2>&1; then
  warn "go not found — mosquito-mixbay-tui won't be built. Install go (mise / pacman -S go) and re-run."
else
  TUI_TMP_OUT="$(mktemp "$BIN_DIR/.mosquito-mixbay-tui.XXXXXX")"
  TUI_VERSION="$(cat "$SCRIPT_DIR/../../../../../VERSION" 2>/dev/null || echo dev)"
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
-- No size forced: the TUI joins Omarchy's own floating-window tag (system.lua:
-- float + center + size 875x600) and foot keeps Omarchy's font/padding/scale.
o.window("org.omarchy.mosquito-mixbay-tui", { tag = "+floating-window" })
o.window("org.omarchy.mosquito-mixbay-scratchpad", { float = true, center = true, size = { 1000, 780 } })
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
# 5. EVO 8 USB capture enable (system-wide, on every connect)
# -----------------------------------------------------------------------------
# EU51 may be disabled by the firmware after power-on. The Go driver also asks
# for it once per process, but this udev hook makes capture work in every app
# (DAW included) before Mixbay is ever launched.
CAPTURE_HELPER=/usr/local/lib/mosquitomixbay/evo8-capture-enable.py
CAPTURE_RULE=/etc/udev/rules.d/99-evo8-capture.rules
if mq_sudo bash -c "
  install -D -m 755 '$SCRIPT_DIR/kmod/evo8-capture-enable.py' '$CAPTURE_HELPER'
  install -D -m 644 '$SCRIPT_DIR/kmod/99-evo8-capture.rules' '$CAPTURE_RULE'
  udevadm control --reload-rules
  udevadm trigger --action=add --subsystem-match=misc --sysname-match=evo8 2>/dev/null || true
  [[ -e /dev/evo8 ]] && /usr/bin/python3 '$CAPTURE_HELPER' || true
"; then
  ok "EVO 8 capture helper installed ($CAPTURE_RULE)"
else
  warn "EVO 8 capture helper not installed — mic capture may stay silent"
fi

# -----------------------------------------------------------------------------
# 5b. Audio foundation: udev seat access, WirePlumber rules, EVO 8 split,
#     rate defaults, default sink/source. Applied by default; this is the
#     "pro audio pack" that makes the graph reliable under the mixer.
# -----------------------------------------------------------------------------
if ((NO_FOUNDATION)); then
  ok "audio foundation skipped (--no-foundation)"
elif [[ -x "$SCRIPT_DIR/foundation/audio-foundation.sh" ]]; then
  FOUNDATION_ARGS=(--apply)
  if ((YES)) || ask "Apply the audio foundation and restart PipeWire now?" y; then
    FOUNDATION_ARGS+=(--restart)
  fi
  if bash "$SCRIPT_DIR/foundation/audio-foundation.sh" "${FOUNDATION_ARGS[@]}"; then
    ok "audio foundation applied"
  else
    warn "audio foundation reported a problem — run: mixbay-audio-foundation --status"
  fi
else
  warn "foundation/audio-foundation.sh not found — audio foundation skipped"
fi

# -----------------------------------------------------------------------------
# 6. Menu: lives in Setup ▸ mosquito (no Apps .desktop), like the siblings
# -----------------------------------------------------------------------------
rm -f "$HOME/.local/share/applications/mosquito-mixbay.desktop"
command -v update-desktop-database >/dev/null && update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
ok "menu: mosquitomixbay lives in Setup ▸ mosquito (no apps .desktop)"

info "mosquitomixbay ready — run: mosquito-mixbay"
info "status: $(mixbay_status)"
