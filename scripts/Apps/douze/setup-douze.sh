#!/usr/bin/env bash
# =============================================================================
# douze — SSL 12 control + Omarchy360 mixer (install / update / uninstall)
# =============================================================================
# douze (https://github.com/xenicle/douze) reverse-engineers the SSL 12's USB
# control interface and gives Linux back what SSL 360 does on Windows/macOS:
# mixer, monitoring, preamps, loopback, clock, meters, profiles. Omarchy360
# (https://github.com/FenrirRhogar/omarchy360) is the native Omarchy bar/overlay
# front end for douze's local HTTP API.
#
# This module installs the whole chain cleanly:
#   1. douze checkout in ~/.local/share/douze (the omarchy360 branch, which
#      exposes the extensions the plugin uses; upstream is one flag away),
#   2. its only runtime dependency (python-pyusb),
#   3. a 70-douze.rules udev rule (TAG+="uaccess", numbered before
#      73-seat-late.rules so it is not silently ignored),
#   4. the douze user service (graphical-session.target, restarted on update),
#   5. the PipeWire split into ssl12.pb12/pb34/pb56/pb78 + the WirePlumber
#      no-suspend rule, when the SSL 12 is connected and in Pro Audio,
#   6. the Omarchy360 shell plugin (bar icon + overlay).
#
# Everything is idempotent. `--update` pulls the latest douze and the plugin,
# then restarts the daemon.
#
# Usage:
#   ./setup-douze.sh                 # install / refresh (interactive)
#   ./setup-douze.sh -y              # non-interactive
#   ./setup-douze.sh --update        # git pull + plugin update + restart daemon
#   ./setup-douze.sh --upstream      # track xenicle/douze instead of the fork
#   ./setup-douze.sh --status        # missing | partial:… | ok
#   ./setup-douze.sh --remove        # userspace + udev + PipeWire + plugin
#   ./setup-douze.sh --purge         # also delete the checkout and ~/.config/sslctl
#   --no-restart / --restart-pipewire control the PipeWire restart after setup.
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/gui-run.bash"  # gui-run: reopen in a terminal when launched from a file manager
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/elevate.bash"  # mq_sudo: native prompt, never a blind sudo hang
set -euo pipefail

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf ' \033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf ' \033[1;33m!\033[0m %s\n' "$*" >&2; }
err()  { printf ' \033[1;31m✗\033[0m %s\n' "$*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ${EUID:-$(id -u)} -eq 0 && -n ${SUDO_USER:-} ]]; then
  err "Run this as $SUDO_USER, not root: it installs a systemctl --user service."
  err "The script elevates only the udev rule itself (mq_sudo)."
  exit 1
fi

# Douze stores its state in ~/.config/sslctl (profiles, mixer state).
DOUZE_HOME="${DOUZE_HOME:-$HOME/.local/share/douze}"
DOUZE_REPO="${DOUZE_REPO:-https://github.com/FenrirRhogar/douze}"
DOUZE_BRANCH="${DOUZE_BRANCH:-omarchy360}"
UDEV_RULE="/etc/udev/rules.d/70-douze.rules"
SYSTEMD_DIR="$HOME/.config/systemd/user"
SERVICE="$SYSTEMD_DIR/douze.service"
DROPIN_DIR="$SYSTEMD_DIR/douze.service.d"
PIPEWIRE_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/pipewire/pipewire.conf.d/99-ssl12-sinks.conf"
WP_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/wireplumber/wireplumber.conf.d/51-ssl12-no-suspend.conf"
PLUGIN_ID="fenrirrhogar.omarchy360"
PLUGIN_URL="https://github.com/FenrirRhogar/omarchy360"

YES=0 UPDATE=0 UPSTREAM=0 REMOVE=0 PURGE=0 STATUS=0 NO_RESTART=0
for a in "$@"; do case "$a" in
  -y|--yes) YES=1 ;;
  --update) UPDATE=1; YES=1; NO_RESTART=1 ;;
  --upstream) UPSTREAM=1 ;;
  --remove) REMOVE=1 ;;
  --purge) REMOVE=1; PURGE=1 ;;
  --status) STATUS=1 ;;
  --no-restart) NO_RESTART=1 ;;
  --restart-pipewire) NO_RESTART=0 ;;
  -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
  *) err "Unknown option: $a"; exit 2 ;;
esac; done

if (( UPSTREAM )); then
  DOUZE_REPO="https://github.com/xenicle/douze"
  DOUZE_BRANCH="main"
fi

ask() {
  local q="$1" def="${2:-y}" r
  (( YES )) && return 0
  if command -v gum >/dev/null 2>&1; then
    gum confirm "$q" --default=$([[ $def == y ]] && echo true || echo false)
    return
  fi
  read -rp "$q [$([ "$def" = y ] && echo Y/n || echo y/N)] " r
  r="${r:-$def}"; [[ $r =~ ^[oOyY] ]]
}

has_pyusb() { python3 -c 'import usb.core' >/dev/null 2>&1; }

service_enabled() { systemctl --user is-enabled --quiet douze 2>/dev/null; }
service_active()  { systemctl --user is-active --quiet douze 2>/dev/null; }

plugin_installed() {
  command -v omarchy >/dev/null 2>&1 \
    && omarchy plugin list --json 2>/dev/null | grep -q "\"$PLUGIN_ID\""
}

ssl12_present() {
  # Two USB interfaces: 31e9:0024 (control) and 31e9:0005 (audio). Either
  # proves the card is plugged; the split only works with the audio one.
  local f
  for f in /sys/bus/usb/devices/*/idVendor; do
    [[ -r $f ]] || continue
    [[ "$(cat "$f" 2>/dev/null)" == "31e9" ]] && return 0
  done
  return 1
}

status() {
  [[ -d "$DOUZE_HOME/.git" ]] || { echo missing; return; }
  local partial=()
  has_pyusb || partial+=("pyusb")
  [[ -f $UDEV_RULE ]] || partial+=("udev rule")
  service_enabled || partial+=("service")
  plugin_installed || partial+=("omarchy360 plugin")
  [[ -f $PIPEWIRE_CONF ]] || partial+=("PipeWire split (optional: card must be in Pro Audio)")
  [[ -f $WP_CONF ]] || partial+=("WirePlumber no-suspend")
  if ((${#partial[@]})); then
    local IFS=,; echo "partial:missing ${partial[*]}"
  else
    echo ok
  fi
}

if (( STATUS )); then
  status
  exit 0
fi

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
if (( REMOVE )); then
  info "Uninstalling douze / Omarchy360"
  systemctl --user disable --now douze 2>/dev/null || true
  rm -f "$SERVICE" "$DROPIN_DIR/omarchy360.conf"
  rmdir "$DROPIN_DIR" 2>/dev/null || true
  systemctl --user daemon-reload 2>/dev/null || true
  ok "User service removed"

  if [[ -f $UDEV_RULE ]]; then
    mq_sudo rm -f "$UDEV_RULE" && mq_sudo udevadm control --reload-rules \
      && ok "udev rule removed" || warn "Could not remove $UDEV_RULE"
  fi

  rm -f "$PIPEWIRE_CONF" "$WP_CONF"
  ok "PipeWire split + WirePlumber rule removed"

  if plugin_installed; then
    omarchy plugin remove "$PLUGIN_ID" --yes >/dev/null 2>&1 \
      && ok "Omarchy360 plugin removed" || warn "Could not remove $PLUGIN_ID"
  fi

  if (( PURGE )); then
    rm -rf "$DOUZE_HOME" "$HOME/.config/sslctl" "$HOME/.cache/douze-fx"
    ok "Checkout, saved mixer state and FX cache deleted"
  else
    info "Kept: $DOUZE_HOME and ~/.config/sslctl (mixer state/profiles). Use --purge to delete."
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# 1. Dependency
# ---------------------------------------------------------------------------
if has_pyusb; then
  ok "python-pyusb already available"
elif command -v pacman >/dev/null 2>&1; then
  info "Installing python-pyusb"
  mq_sudo pacman -S --needed --noconfirm python-pyusb \
    || { err "Could not install python-pyusb"; exit 1; }
  has_pyusb || { err "python-pyusb installed but not importable"; exit 1; }
  ok "python-pyusb installed"
else
  info "Installing pyusb with pip (no pacman)"
  python3 -m pip install --user pyusb || { err "pip install pyusb failed"; exit 1; }
fi

# ---------------------------------------------------------------------------
# 2. Checkout (clone or fast-forward; never destroy local edits)
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "$DOUZE_HOME")"
if [[ -d "$DOUZE_HOME/.git" ]]; then
  current_remote="$(git -C "$DOUZE_HOME" remote get-url origin 2>/dev/null || true)"
  if [[ $current_remote != "$DOUZE_REPO" ]]; then
    warn "Existing checkout tracks $current_remote (not $DOUZE_REPO) — leaving it as is."
    warn "Move $DOUZE_HOME away, then re-run, to switch source."
  else
    if [[ -n "$(git -C "$DOUZE_HOME" status --porcelain 2>/dev/null)" ]]; then
      warn "Local changes in $DOUZE_HOME — not pulling (your edits are kept)."
    else
      info "Updating douze ($DOUZE_BRANCH)"
      git -C "$DOUZE_HOME" fetch --quiet origin "$DOUZE_BRANCH" || warn "git fetch failed — using the local copy"
      git -C "$DOUZE_HOME" checkout --quiet "$DOUZE_BRANCH" 2>/dev/null || true
      git -C "$DOUZE_HOME" pull --ff-only --quiet origin "$DOUZE_BRANCH" 2>/dev/null \
        && ok "douze up to date" || warn "Could not fast-forward — using the local copy"
    fi
  fi
else
  info "Cloning douze ($DOUZE_BRANCH)"
  [[ -e $DOUZE_HOME ]] && { err "$DOUZE_HOME exists but is not a git checkout"; exit 1; }
  git clone --branch "$DOUZE_BRANCH" --depth 1 "$DOUZE_REPO" "$DOUZE_HOME" \
    || { err "Clone failed: $DOUZE_REPO ($DOUZE_BRANCH)"; exit 1; }
  ok "douze cloned to $DOUZE_HOME"
fi
[[ -f "$DOUZE_HOME/tools/douze.py" ]] || { err "Unexpected checkout: tools/douze.py missing"; exit 1; }

# ---------------------------------------------------------------------------
# 3. udev: let the logged-in user open 31e9:0024 (no root daemon)
# ---------------------------------------------------------------------------
# 70-* is BEFORE 73-seat-late.rules: a uaccess rule numbered 99 is applied too
# late and is silently ignored (douze's own troubleshooting calls this the
# uaccess trap). MODE/GROUP audio would need a re-login; uaccess does not.
rule_tmp="$(mktemp)"
cat > "$rule_tmp" <<'RULE'
# SSL 12 control interface (31e9:0024) — douze/sslctl access without root.
# Keep this below 73: TAG+="uaccess" is handled by 73-seat-late.rules, so a
# 99-* rule would look installed and do nothing.
SUBSYSTEM=="usb", ATTRS{idVendor}=="31e9", ATTRS{idProduct}=="0024", TAG+="uaccess"
RULE
if [[ -f $UDEV_RULE ]] && cmp -s "$rule_tmp" "$UDEV_RULE"; then
  ok "udev rule already in place ($UDEV_RULE)"
else
  mq_sudo install -D -m 0644 "$rule_tmp" "$UDEV_RULE" \
    && mq_sudo udevadm control --reload-rules \
    && mq_sudo udevadm trigger --action=change --subsystem-match=usb 2>/dev/null \
    && ok "udev rule installed ($UDEV_RULE)" \
    || warn "Could not install the udev rule — douze will report 'permission denied' until it is."
fi
rm -f "$rule_tmp"

# ---------------------------------------------------------------------------
# 4. User service
# ---------------------------------------------------------------------------
mkdir -p "$SYSTEMD_DIR" "$DROPIN_DIR"
if [[ -f "$DOUZE_HOME/systemd/douze.service" ]]; then
  sed "s|%h/douze|$DOUZE_HOME|g" "$DOUZE_HOME/systemd/douze.service" > "$SERVICE"
else
  cat > "$SERVICE" <<EOF
[Unit]
Description=Douze - SSL 12 control daemon
After=graphical-session.target

[Service]
Environment=PYTHONUNBUFFERED=1
WorkingDirectory=$DOUZE_HOME
ExecStart=/usr/bin/env python3 tools/douze.py
KillMode=mixed
TimeoutStopSec=20
Restart=on-failure
RestartSec=10

[Install]
WantedBy=graphical-session.target
EOF
fi

# The front-panel "gui" USER button opens the Omarchy360 overlay.
cat > "$DROPIN_DIR/omarchy360.conf" <<EOF
[Service]
Environment="DOUZE_GUI_CMD=omarchy-shell shell toggle $PLUGIN_ID"
EOF

systemctl --user daemon-reload
systemctl --user enable douze >/dev/null 2>&1 || { err "Could not enable douze.service"; exit 1; }
if (( UPDATE )) || service_active; then
  systemctl --user restart douze 2>/dev/null || true
else
  systemctl --user start douze 2>/dev/null || true
fi
if service_active; then
  ok "douze service running"
else
  warn "douze service is not running yet — check: systemctl --user status douze"
fi

# ---------------------------------------------------------------------------
# 5. PipeWire: split the 8-channel Pro Audio sink into four stereo sinks
# ---------------------------------------------------------------------------
# The card must be connected AND in the Pro Audio profile: only that profile
# exposes pro-output-0..7. Without it there is nothing to split; say so now
# instead of writing a config that connects to nothing.
if ! command -v pw-link >/dev/null 2>&1; then
  warn "pw-link missing — PipeWire split skipped"
elif ! ssl12_present; then
  warn "SSL 12 not connected — connect it, set Pro Audio in pavucontrol, then re-run to install the split."
else
  if bash "$DOUZE_HOME/tools/install-pipewire.sh"; then
    ok "PipeWire split + WirePlumber no-suspend rule installed"
    # Restarting PipeWire cuts every app for a second: only do it when asked.
    if (( NO_RESTART )); then
      info "PipeWire not restarted (--no-restart). Restart it later to activate the split."
    elif (( YES )) || ask "Restart PipeWire now? Every playing app will glitch for a second." y; then
      systemctl --user restart pipewire pipewire-pulse wireplumber \
        && systemctl --user restart douze \
        && ok "PipeWire and douze restarted" \
        || warn "PipeWire restart failed — restart it by hand"
    else
      info "Split written; restart PipeWire (pipewire + pipewire-pulse + wireplumber) to use it."
    fi
  else
    warn "PipeWire split not installed — is the SSL 12 in the Pro Audio profile?"
  fi
fi

# ---------------------------------------------------------------------------
# 6. Omarchy360 plugin
# ---------------------------------------------------------------------------
if ! command -v omarchy >/dev/null 2>&1; then
  warn "omarchy CLI missing — Omarchy360 plugin skipped"
elif plugin_installed; then
  if (( UPDATE )); then
    omarchy plugin update "$PLUGIN_ID" --yes >/dev/null 2>&1 \
      && ok "Omarchy360 updated" || warn "Omarchy360 update failed"
    omarchy plugin enable "$PLUGIN_ID" >/dev/null 2>&1 || true
    omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
  else
    omarchy plugin enable "$PLUGIN_ID" >/dev/null 2>&1 || true
    ok "Omarchy360 already installed"
  fi
else
  info "Installing Omarchy360"
  if (( YES )); then
    omarchy plugin add "$PLUGIN_URL" --enable --yes >/dev/null 2>&1 \
      && ok "Omarchy360 installed (bar icon on the right)" \
      || warn "Omarchy360 install failed — install it later: omarchy plugin add $PLUGIN_URL --enable"
  else
    ask "Install the Omarchy360 mixer plugin (bar icon + overlay)?" y \
      && { omarchy plugin add "$PLUGIN_URL" --enable >/dev/null 2>&1 \
             && ok "Omarchy360 installed" \
             || warn "Omarchy360 install failed"; }
  fi
fi

# ---------------------------------------------------------------------------
# 7. Summary
# ---------------------------------------------------------------------------
echo
info "douze ready"
echo "  web GUI   : http://localhost:1212  (douze daemon)"
echo "  mixer     : Omarchy360 bar icon, or: omarchy-shell shell toggle $PLUGIN_ID"
echo "  card      : Pro Audio profile in the Omarchy audio panel / pavucontrol"
echo "  state     : ~/.config/sslctl (profiles, mixer state)"
echo "  update    : ./setup-douze.sh --update   (or mosquitomarchy update)"
echo "  check     : systemctl --user status douze"
