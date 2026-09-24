#!/usr/bin/env bash
# =============================================================================
# Omarchy Custom - Battery Management
# =============================================================================
# Central installer for ALL battery/charge tooling behind the custom.power
# panel widget. Reproduces on a fresh machine:
#
#   1. ultra-save          (~/.local/bin/ultra-save)          : on/off/status toggle
#   2. sudoers             (/etc/sudoers.d/battery-management) : NOPASSWD + D-BUS env
#   3. power-helper        (~/.local/bin + /usr/local/bin)     : plugin back-end helper
#   4. udev rule           (/etc/udev/rules.d/99-lenovo-charge-threshold.rules)
#                          : makes charge_control_*_threshold writable by wheel
#   5. mega-caffeine       (~/.local/bin/mega-caffeine)       : coffee mode (laptop
#                          closed without sleeping, red tint, natural-language durations)
#   5b. ultra-save-watch    (~/.local/bin/ultra-save-watch)   : CPU-saturation watchdog
#                          under ultra-save (systemd --user timer, every 60s)
#   6. Removes the old "System > Ultra-save mode" block from the Omarchy menu
#      (now useless: the toggle lives in the custom.power plugin).
#   7. Adds a "Mega caffeine" entry to the Omarchy menu bar
#      (Trigger > Toggle) toggling the coffee mode on/off.
#
# Notifications (charge threshold reached) are sent by the custom.power
# plugin, no longer by the scripts (ultra-save-monitor has been removed). The
# ultra-save-watch watchdog does NOT send profile-change notifications: it
# warns when ultra-save's CPU cap is being saturated and would freeze the
# desktop, with a clickable action that disables ultra-save.
#
# Usage:
#   ./setup-battery-management.sh            # applies everything (idempotent)
#   ./setup-battery-management.sh --remove   # removes udev+sudoers+menu, stops caffeine
#
# One-stop install/uninstall for the whole battery module:
#   • install   -> this script (also triggered by the 'battery' module of mosquitomarchy-setup.sh)
#   • uninstall -> this script --remove, or the 'battery' module of mosquitomarchy-setup.sh --uninstall
#
# Prerequisites: power-profiles-daemon, amd-pstate/intel_pstate, Omarchy.
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/gui-run.bash"  # gui-run: reopen in a terminal when launched from a file manager
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

info() { echo -e "\033[1;34m==>\033[0m $*"; }
ok()   { echo -e "\033[1;32m  ✓\033[0m $*"; }
warn() { echo -e "\033[1;33m  !\033[0m $*"; }
err()  { echo -e "\033[1;31m  ✗\033[0m $*" >&2; }

# Resolve the REAL invoking user's home even when run via `sudo bash`
# (as root, $HOME=/root, but the binaires/scripts live in the user's home).
if [[ $EUID -eq 0 && -n ${SUDO_USER:-} ]]; then
  REAL_USER="$SUDO_USER"
else
  REAL_USER="${USER:-$(id -un)}"
fi
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
REAL_HOME="${REAL_HOME:-$HOME}"

BIN_DIR="$REAL_HOME/.local/bin"
USR_BIN_DIR="/usr/local/bin"
MENU_DIR="$REAL_HOME/.config/omarchy/extensions"
MENU="$MENU_DIR/omarchy-menu.jsonc"
BLOCK_START="// >>> Omarchy_Custom_Scripts_UltraSave"
BLOCK_END="// <<< Omarchy_Custom_Scripts_UltraSave"
MENU_MC_START="// >>> Omarchy_Custom_Scripts - managed by setup-battery-management.sh (mega-caffeine)"
MENU_MC_END="// <<< Omarchy_Custom_Scripts - managed by setup-battery-management.sh (mega-caffeine)"
# Historical names of this script, in case the menu file still carries the
# markers of a previous rename (either the very first setup- name or the
# intermediate battery-management.sh name).
MENU_MC_LEGACY_START="// >>> Omarchy_Custom_Scripts - managed by battery-management.sh (mega-caffeine)"
MENU_MC_LEGACY_END="// <<< Omarchy_Custom_Scripts - managed by battery-management.sh (mega-caffeine)"
MENU_MC_LEGACY2_START="// >>> Omarchy_Custom_Scripts - managed by setup-battery-management.sh (mega-caffeine)"
MENU_MC_LEGACY2_END="// <<< Omarchy_Custom_Scripts - managed by setup-battery-management.sh (mega-caffeine)"
SUDOERS_FILE="/etc/sudoers.d/battery-management"
STATE_DIR="$REAL_HOME/.local/state/ultra-save"
UDEV_SRC="$SCRIPT_DIR/power-plugin/99-lenovo-charge-threshold.rules"
UDEV_DST="/etc/udev/rules.d/99-lenovo-charge-threshold.rules"

if [[ ! -d /usr/share/omarchy ]]; then
  echo "This script is meant for Omarchy." >&2
  exit 1
fi

REMOVE=false
[[ ${1:-} == "--remove" ]] && REMOVE=true

# -----------------------------------------------------------------------------
# 1. Deployment of the binaries (~/.local/bin)
# -----------------------------------------------------------------------------
deploy_bin() {
  # $1 = binary name. Copies $SCRIPT_DIR/$name to ~/.local/bin unless the
  # installed copy is already identical (so a repo update propagates on rerun).
  local name="$1"
  local src="$SCRIPT_DIR/$name" dst="$BIN_DIR/$name"
  if [[ ! -f "$src" ]]; then
    if [[ -f "$dst" ]]; then ok "$name present ($dst, no repo copy)"; else warn "$name not found — ignored."; fi
    return 0
  fi
  if [[ -f "$dst" ]] && cmp -s "$src" "$dst" 2>/dev/null; then
    ok "$name already in place and up to date ($dst)"
    return 0
  fi
  cp "$src" "$dst"
  chmod +x "$dst"
  bash -n "$dst" || { err "Invalid syntax: $name"; return 1; }
  ok "$name deployed ($dst)"
}

if [[ $REMOVE == false ]]; then
  mkdir -p "$BIN_DIR" "$STATE_DIR"

  deploy_bin "ultra-save"
  deploy_bin "power-helper"
  deploy_bin "mega-caffeine"

  [[ -d "$BIN_DIR" ]] && PATH="$BIN_DIR:$PATH"
fi

# -----------------------------------------------------------------------------
# 1b. Omarchy custom.power plugin (bar widget: charge limit + ultra-save)
#     Recreates it if missing: clones omarchy.power then renames to custom.power.
# -----------------------------------------------------------------------------
ensure_power_plugin() {
  local PLUG="$REAL_HOME/.config/omarchy/plugins"
  local PLUGIN_ID="custom.power"
  local PLUGIN_DIR="$PLUG/$PLUGIN_ID"
  local SHELL_JSON="$REAL_HOME/.config/omarchy/shell.json"

  [[ -f "$REAL_HOME/.config/omarchy/shell.json" ]] || return 0

  if [[ -d "$PLUGIN_DIR" ]]; then
    ok "Omarchy plugin $PLUGIN_ID already present"
  else
    # A residual <user>.power clone (mosquito.power)? re-adopt it.
    if [[ -d "$PLUG/$REAL_USER.power" ]]; then
      warn "Clone $REAL_USER.power present — renamed to $PLUGIN_ID"
      mv "$PLUG/$REAL_USER.power" "$PLUGIN_DIR"
    else
      warn "Plugin $PLUGIN_ID missing — cloning from omarchy.power"
      omarchy plugin clone omarchy.power || { warn "Could not clone omarchy.power"; return 1; }
      if [[ -d "$PLUG/$REAL_USER.power" ]]; then
        mv "$PLUG/$REAL_USER.power" "$PLUGIN_DIR"
      else
        warn "Clone $REAL_USER.power not found after cloning."
        return 1
      fi
    fi

    # Force the manifest id to custom.power
    local mf="$PLUGIN_DIR/manifest.json"
    if command -v jq >/dev/null 2>&1 && [[ -f $mf ]]; then
      jq --arg id "$PLUGIN_ID" '.id=$id' "$mf" >"$mf.tmp" && mv "$mf.tmp" "$mf"
    else
      sed -i -E "s/\"id\"[[:space:]]*:[[:space:]]*\"[^\"]+\"/\"id\": \"$PLUGIN_ID\"/" "$mf"
    fi
  fi

  # ALWAYS repoint the bar layout to custom.power and enable it. A reinstall, an
  # Omarchy update or an earlier partial run can leave shell.json on the STOCK
  # omarchy.power (or a stale <user>.power clone): the customized widget then
  # exists but is never shown, so nothing we change in its QML has any effect.
  if grep -qE "\"(omarchy|${REAL_USER})\\.power\"" "$SHELL_JSON" 2>/dev/null; then
    cp -f "$SHELL_JSON" "$SHELL_JSON.bak.fix-power-$(date +%s)" 2>/dev/null || true
    sed -i -E "s#\"(omarchy|${REAL_USER})\.power\"#\"$PLUGIN_ID\"#g" "$SHELL_JSON"
    ok "Bar layout repointed: power widget -> $PLUGIN_ID"
  fi
  # And any self-reference inside the plugin's own QML.
  sed -i -E "s#\"(omarchy|${REAL_USER})\.power\"#\"$PLUGIN_ID\"#g" "$PLUGIN_DIR"/*.qml 2>/dev/null || true
  omarchy plugin enable "$PLUGIN_ID" >/dev/null 2>&1 || true
  ok "Omarchy plugin $PLUGIN_ID present + enabled (bar widget)"
}

# -----------------------------------------------------------------------------
# 1c. Omarchy custom plugins (bar widget + overlay) — same clone/rename pattern
#     but with QML sources shipped in ./omarchy-plugins/ (the stock clones are
#     then patched so a fresh machine reproduces this machine's customizations):
#       • custom.power/Panel.qml          : charge-limit notif + toggles
#       • mosquito.indicators/            : StayAwake red icon + time tooltip
#       • mosquito.confirm/               : native Yes/No overlay for prompts
# -----------------------------------------------------------------------------
PLUG_SRC="$SCRIPT_DIR/omarchy-plugins"
PLUG_DIR="$REAL_HOME/.config/omarchy/plugins"

overlay_plugin_files() {
  # $1 = plugin dir name, rest = file paths relative to $PLUG_SRC
  local dir="$1"
  shift
  [[ -d "$PLUG_SRC/$dir" && -d "$PLUG_DIR/$dir" ]] || return 0
  local rel found=""
  for rel in "$@"; do
    if [[ -f "$PLUG_SRC/$dir/$rel" ]]; then
      cp "$PLUG_SRC/$dir/$rel" "$PLUG_DIR/$dir/$rel"
      found=1
    fi
  done
  [[ -n $found ]] && ok "Custom QML applied to $dir" || true
}

ensure_indicators_plugin() {
  [[ -f "$REAL_HOME/.config/omarchy/shell.json" ]] || return 0
  if [[ -d "$PLUG_DIR/mosquito.indicators" ]]; then
    ok "Omarchy plugin mosquito.indicators already present"
  else
    if [[ -d "$PLUG_DIR/$REAL_USER.indicators" ]]; then
      warn "Clone $REAL_USER.indicators present — renamed to mosquito.indicators"
      mv "$PLUG_DIR/$REAL_USER.indicators" "$PLUG_DIR/mosquito.indicators"
    else
      warn "Plugin mosquito.indicators missing — cloning from omarchy.indicators"
      omarchy plugin clone omarchy.indicators || { warn "Could not clone omarchy.indicators"; return 1; }
      if [[ -d "$PLUG_DIR/$REAL_USER.indicators" ]]; then
        mv "$PLUG_DIR/$REAL_USER.indicators" "$PLUG_DIR/mosquito.indicators"
      else
        warn "Clone $REAL_USER.indicators not found after cloning."
        return 1
      fi
    fi
    local mf="$PLUG_DIR/mosquito.indicators/manifest.json"
    if command -v jq >/dev/null 2>&1 && [[ -f $mf ]]; then
      jq --arg id "mosquito.indicators" '.id=$id' "$mf" >"$mf.tmp" && mv "$mf.tmp" "$mf"
    else
      sed -i -E "s/\"id\"[[:space:]]*:[[:space:]]*\"[^\"]+\"/\"id\": \"mosquito.indicators\"/" "$mf"
    fi
    sed -i "s|\"$REAL_USER\\.indicators\"|\"mosquito.indicators\"|g" "$REAL_HOME/.config/omarchy/shell.json"
    omarchy plugin enable mosquito.indicators >/dev/null 2>&1 || true
    ok "Omarchy plugin mosquito.indicators cloned and enabled (bar widget)"
  fi
  overlay_plugin_files "mosquito.indicators" "Indicators.qml" "indicators/StayAwake.qml"
}

ensure_confirm_plugin() {
  [[ -f "$REAL_HOME/.config/omarchy/shell.json" ]] || return 0
  if [[ -d "$PLUG_DIR/mosquito.confirm" ]]; then
    ok "Omarchy plugin mosquito.confirm already present"
  elif [[ -d "$PLUG_SRC/mosquito.confirm" ]]; then
    mkdir -p "$PLUG_DIR/mosquito.confirm"
    cp -a "$PLUG_SRC/mosquito.confirm/." "$PLUG_DIR/mosquito.confirm/"
    ok "Omarchy plugin mosquito.confirm installed (overlay)"
  else
    warn "Plugin sources missing in $PLUG_SRC — mosquito.confirm not installed."
    return 0
  fi
  omarchy plugin enable mosquito.confirm >/dev/null 2>&1 || true
  ok "Omarchy plugin mosquito.confirm enabled (overlay)"
}

if [[ $REMOVE == false ]]; then
  ensure_power_plugin || true
  overlay_plugin_files "custom.power" "Panel.qml" "Model.js"
  ensure_indicators_plugin || true
  ensure_confirm_plugin || true
fi

# -----------------------------------------------------------------------------
# 2. Sudoers (requires root)
# -----------------------------------------------------------------------------
if [[ $REMOVE == true ]]; then
  if [[ -f "$SUDOERS_FILE" ]]; then
    rm -f "$SUDOERS_FILE"
    ok "Sudoers removed ($SUDOERS_FILE)"
  else
    ok "Sudoers absent, nothing to do."
  fi
else
  if [[ $EUID -eq 0 ]]; then
    cat > "$SUDOERS_FILE" <<SUDOEOF
$REAL_USER ALL=(root) NOPASSWD: $BIN_DIR/ultra-save on, $BIN_DIR/ultra-save off, $BIN_DIR/ultra-save toggle
Defaults! $BIN_DIR/ultra-save env_keep += "DISPLAY WAYLAND_DISPLAY XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS"
SUDOEOF
    chmod 440 "$SUDOERS_FILE"
    if visudo -cf "$SUDOERS_FILE" &>/dev/null; then
      ok "Sudoers installed (no password + D-BUS env_keep)"
    else
      rm -f "$SUDOERS_FILE"
      err "Sudoers invalid — removed."
    fi
  else
    warn "Sudoers not installed (requires root). Run: sudo bash $0"
  fi
fi

# -----------------------------------------------------------------------------
# 3. ultra-save-watch monitor (systemd --user timer).
#    The old ultra-save-monitor (sent profile-change notifications) stays
#    removed: notifications are handled by the custom.power plugin. The NEW
#    ultra-save-watch fills a different gap — it watches for CPU saturation
#    WHILE ultra-save is ON (so the 30% frequency cap freezes the desktop,
#    e.g. a DAW render) and posts a critical Omarchy notification whose click
#    disables ultra-save. Installed as mosquito-ultra-save-watch.timer.
# -----------------------------------------------------------------------------
TIMER_DIR="$REAL_HOME/.config/systemd/user"
WATCH_NAME="mosquito-ultra-save-watch"
WATCH_SV="$TIMER_DIR/$WATCH_NAME.service"
WATCH_TM="$TIMER_DIR/$WATCH_NAME.timer"
systemctl --user disable --now ultra-save-monitor.timer 2>/dev/null || true
rm -f "$TIMER_DIR/ultra-save-monitor.service" "$TIMER_DIR/ultra-save-monitor.timer"

# Forbidden path separator in a systemd unit name; the timer must be unique.
install_watch_timer() {
  local svc timer
  mkdir -p "$TIMER_DIR"
  svc="$(cat <<EOF
[Unit]
Description=mosquito ultra-save CPU-saturation watchdog
# Only meaningful when ultra-save is ON; the script itself no-ops otherwise.

[Service]
Type=oneshot
ExecStart=$BIN_DIR/ultra-save-watch
EOF
)"
  timer="$(cat <<EOF
[Unit]
Description=Run the mosquito ultra-save watchdog periodically

[Timer]
OnBootSec=120
OnUnitActiveSec=60
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF
)"
  printf '%s\n' "$svc" > "$WATCH_SV"
  printf '%s\n' "$timer" > "$WATCH_TM"
  chmod 0644 "$WATCH_SV" "$WATCH_TM"
  systemctl --user daemon-reload 2>/dev/null || true
  systemctl --user enable --now "$WATCH_NAME.timer" 2>/dev/null || true
  ok "Ultra-save watchdog enabled ($WATCH_NAME.timer, every 60s; notifies when CPU is saturated under ultra-save)"
}

remove_watch_timer() {
  systemctl --user disable --now "$WATCH_NAME.timer" 2>/dev/null || true
  rm -f "$WATCH_SV" "$WATCH_TM"
  systemctl --user daemon-reload 2>/dev/null || true
  ok "Ultra-save watchdog disabled ($WATCH_NAME.timer removed)"
}

if [[ $REMOVE == true ]]; then
  remove_watch_timer
else
  deploy_bin "ultra-save-watch"
  install_watch_timer
fi

# -----------------------------------------------------------------------------
# 4. power-helper in /usr/local/bin (for the Omarchy shell)
# -----------------------------------------------------------------------------
if [[ $REMOVE == false ]]; then
  if [[ $EUID -eq 0 ]]; then
    cp "$BIN_DIR/power-helper" "$USR_BIN_DIR/power-helper" 2>/dev/null \
      && chmod 0755 "$USR_BIN_DIR/power-helper" \
      && ok "power-helper installed in $USR_BIN_DIR" \
      || warn "Failed to copy helper into /usr/local/bin"
  else
    warn "Helper /usr/local/bin not copied (requires root). Run: sudo bash $0"
  fi
fi

# -----------------------------------------------------------------------------
# 4. udev charge-control rule (requires root) — makes the thresholds writable
# -----------------------------------------------------------------------------
if [[ $REMOVE == true ]]; then
  if [[ -f "$UDEV_DST" ]]; then
    rm -f "$UDEV_DST"
    udevadm control --reload 2>/dev/null || true
    ok "udev charge-control rule removed"
  else
    ok "udev charge-control rule absent, nothing to do."
  fi
else
  if [[ $EUID -eq 0 ]]; then
    if [[ ! -f "$UDEV_SRC" ]]; then
      warn "udev rule not found ($UDEV_SRC) — charge-control not configured."
    else
      cp "$UDEV_SRC" "$UDEV_DST"
      chown root:root "$UDEV_DST"
      chmod 0644 "$UDEV_DST"
      udevadm control --reload
      udevadm trigger --subsystem-match=power_supply
      ok "udev rule installed ($UDEV_DST)"
    fi
    # Apply immediately (and not only via the trigger): chown + chmod.
    # chown alone does NOT grant write — the chmod 0660 for wheel is required.
    for t in charge_control_start_threshold charge_control_end_threshold; do
      [[ -e "/sys/class/power_supply/BAT0/$t" ]] || continue
      chown root:wheel "/sys/class/power_supply/BAT0/$t" 2>/dev/null
      chmod 0660 "/sys/class/power_supply/BAT0/$t" 2>/dev/null
    done
    ok "Charge thresholds made writable by wheel (0660)"
  else
    warn "udev rule + thresholds not configured (requires root). Run: sudo bash $0"
  fi
fi

# -----------------------------------------------------------------------------
# 5. Cleanup of the old "System > Ultra-save mode" block in the Omarchy menu
#    (now driven by the custom.power widget, no menu entry needed anymore)
# -----------------------------------------------------------------------------
remove_menu_block() {
  [[ -f $MENU ]] || { ok "Menu absent, nothing to remove."; return 0; }
  local tmp start_line end_line

  # Case 1: block delimited by the old markers (former setup-ultrasave.sh).
  if grep -qF "$BLOCK_START" "$MENU"; then
    start_line=$(grep -nF "$BLOCK_START" "$MENU" | cut -d: -f1 | head -1)
    end_line=$(grep -nF "$BLOCK_END" "$MENU" | cut -d: -f1 | head -1)
    if [[ -z $start_line || -z $end_line || $end_line -le $start_line ]]; then
      warn "Inconsistent Ultra-save markers in $MENU."
    else
      tmp=$(mktemp)
      head -n $((start_line - 1)) "$MENU" > "$tmp"
      tail -n +$((end_line + 1)) "$MENU" >> "$tmp"
      mv "$tmp" "$MENU"
      ok "Ultra-save block (markers) removed from the Omarchy menu"
      # fix a possible orphan comma
      sed -i ':a;N;$!ba;s/,\([[:space:]]*\n[[:space:]]*\)}/\1}/' "$MENU"
      return 0
    fi
  fi

  # Case 2: "system.ultrasave" entry alone, without markers (current menu state).
  if grep -qF '"system.ultrasave"' "$MENU"; then
    start_line=$(grep -nF '"system.ultrasave"' "$MENU" | cut -d: -f1 | head -1)
    # Find the closing brace of the object by counting {} without taking
    # strings into account (the menu JSON has no { } in action values).
    local depth=0 line text
    end_line=""
    for (( line=start_line; line<=$(wc -l < "$MENU"); line++ )); do
      text=$(sed -n "${line}p" "$MENU")
      depth=$(( depth + $(printf %s "$text" | tr -cd '{' | wc -c) - $(printf %s "$text" | tr -cd '}' | wc -c) ))
      if (( depth == 0 )); then end_line="$line"; break; fi
    done
    if [[ -n $end_line ]]; then
      tmp=$(mktemp)
      head -n $((start_line - 1)) "$MENU" > "$tmp"
      tail -n +$((end_line + 1)) "$MENU" >> "$tmp"
      mv "$tmp" "$MENU"
      # fix the orphan comma left by the previous element
      sed -i ':a;N;$!ba;s/,\([[:space:]]*\n[[:space:]]*\)}/\1}/' "$MENU"
      ok "Entry 'system.ultrasave' removed from the Omarchy menu"
      return 0
    fi
    warn "Could not locate the end of the 'system.ultrasave' entry in $MENU."
    return 0
  fi

  ok "No Ultra-save trace in the menu, nothing to do."
}

remove_menu_block

# -----------------------------------------------------------------------------
# 5b. Omarchy menu bar: "Mega caffeine" entry (Trigger > Toggle)
# -----------------------------------------------------------------------------
migrate_mc_markers() {
  # One-time rename of the block markers (old script names → the current one).
  [[ -f $MENU ]] || return 0
  if grep -qF "$MENU_MC_LEGACY_START" "$MENU" || grep -qF "$MENU_MC_LEGACY_END" "$MENU" \
     || grep -qF "$MENU_MC_LEGACY2_START" "$MENU" || grep -qF "$MENU_MC_LEGACY2_END" "$MENU"; then
    sed -i "s|$MENU_MC_LEGACY_START|$MENU_MC_START|g; s|$MENU_MC_LEGACY_END|$MENU_MC_END|g; s|$MENU_MC_LEGACY2_START|$MENU_MC_START|g; s|$MENU_MC_LEGACY2_END|$MENU_MC_END|g" "$MENU"
    ok "Mega caffeine menu markers migrated to setup-battery-management.sh"
  fi
}
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

mc_block() {
  cat <<MC_EOF
$MENU_MC_START
  "trigger.toggle.mega-caffeine": {
    "icon": "\uf0f4",
    "label": "Mega caffeine",
    "description": "Coffee mode: laptop closed without sleeping, red tint, natural-language duration",
    "aliases": ["coffee", "cafe", "mode-cafe", "power-mode", "mosquito"],
    "when": "test -x $REAL_HOME/.local/bin/mega-caffeine",
    "checked": "[[ \"\$(cat $REAL_HOME/.local/state/caffeine/state 2>/dev/null)\" == on ]]",
    "action": "$REAL_HOME/.local/bin/mega-caffeine toggle"
  },
$MENU_MC_END
MC_EOF
}

install_mc_menu() {
  mkdir -p "$MENU_DIR"
  local block start_line end_line open_line tmp
  block="$(mc_block)"
  if [[ ! -f $MENU ]]; then
    printf '{\n%s\n}\n' "$block" > "$MENU"
  elif grep -qF "$MENU_MC_START" "$MENU"; then
    start_line=$(grep -nF "$MENU_MC_START" "$MENU" | head -1 | cut -d: -f1)
    end_line=$(grep -nF "$MENU_MC_END" "$MENU" | head -1 | cut -d: -f1)
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

remove_mc_menu() {
  if [[ -f $MENU ]] && grep -qF "$MENU_MC_START" "$MENU"; then
    local start_line end_line tmp
    start_line=$(grep -nF "$MENU_MC_START" "$MENU" | head -1 | cut -d: -f1)
    end_line=$(grep -nF "$MENU_MC_END" "$MENU" | head -1 | cut -d: -f1)
    if [[ -n $start_line && -n $end_line && $end_line -gt $start_line ]]; then
      tmp=$(mktemp)
      head -n $((start_line - 1)) "$MENU" > "$tmp"
      tail -n +$((end_line + 1)) "$MENU" >> "$tmp"
      mv "$tmp" "$MENU"
      sed -i ':a;N;$!ba;s/,\([[:space:]]*\n[[:space:]]*}\)/\1/' "$MENU"
      [[ -s $MENU ]] || printf '{\n}\n' > "$MENU"
      write_menu || true
      ok "Menu bar entry removed: Mega caffeine"
    else
      warn "Inconsistent mega-caffeine markers in $MENU."
    fi
  else
    ok "No Mega caffeine entry in the menu, nothing to do."
  fi
}

migrate_mc_markers   # rename legacy markers before install/remove (idempotent)

# -----------------------------------------------------------------------------
# 5c. On --remove: stop any active coffee mode and clear its state, then remove
#     the menu entry (the binaries themselves are kept).
# -----------------------------------------------------------------------------
if [[ $REMOVE == true ]]; then
  if [[ -x "$BIN_DIR/mega-caffeine" ]]; then
    "$BIN_DIR/mega-caffeine" off >/dev/null 2>&1 || true
    ok "Coffee mode stopped (if it was active)"
  fi
  rm -rf "$REAL_HOME/.local/state/caffeine"
  ok "Caffeine state directory removed (${REAL_HOME}/.local/state/caffeine)"
  remove_mc_menu
else
  migrate_mc_markers
  install_mc_menu
fi

# -----------------------------------------------------------------------------
# 6. Summary
# -----------------------------------------------------------------------------
echo ""
if [[ $REMOVE == true ]]; then
  info "Uninstall complete: udev + sudoers + menu entry removed."
  echo "  Caffeine stopped and its state cleared."
  echo "  Ultra-save watchdog timer removed."
  echo "  The scripts stay in $BIN_DIR (ultra-save, power-helper, mega-caffeine, ultra-save-watch):"
  echo "    use the 'battery' module of mosquitomarchy-setup.sh --uninstall to remove them too."
else
  info "Setup complete. Summary:"
  echo "  • ultra-save            -> $BIN_DIR/ultra-save (toggle/status)"
  echo "  • Watchdog              -> $BIN_DIR/ultra-save-watch (timer every 60s)"
  echo "  • Plugin helper         -> $BIN_DIR/power-helper + /usr/local/bin"
  echo "  • Coffee mode           -> $BIN_DIR/mega-caffeine (toggle/status)"
  echo "  • Charge control (udev) -> thresholds writable by wheel (Lenovo P14s)"
  echo "  • Omarchy widget        -> custom.power plugin (charge limit + ultra-save)"
  echo "  • Omarchy overlay       -> mosquito.confirm plugin (native Yes/No prompts)"
  echo "  • Omarchy indicators    -> mosquito.indicators widget (stay-awake red icon + tooltip)"
  echo "  • Omarchy menu          -> Trigger > Toggle > Mega caffeine (coffee mode toggle)"
  echo "  • Omarchy menu          -> old 'System > Ultra-save mode' block removed"
  echo
  # The QML/bar changes only take effect after a shell restart: do it now for
  # the user instead of only asking them to (unless we are root).
  if [[ $EUID -ne 0 ]] && command -v omarchy >/dev/null 2>&1; then
    if omarchy restart shell >/dev/null 2>&1; then
      ok "Omarchy shell restarted (widget/QML reloaded)"
    else
      warn "Could not restart the shell — run manually: omarchy restart shell"
    fi
  else
    echo "  Restart the shell if the widget does not show: omarchy restart shell"
    echo "  (if not run as root, rerun once: sudo bash $0 for udev/sudoers)"
  fi
fi
