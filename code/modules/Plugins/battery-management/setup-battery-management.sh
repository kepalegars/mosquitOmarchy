#!/usr/bin/env bash
# =============================================================================
# Mosquito Battery — battery service, profile icon and panel
# =============================================================================
# Installs the power-profile panel and corrected battery telemetry. The former
# ultra-save mode (CPU/power cap plus watchdog) was abandoned; this module now
# only changes the battery icon color with the selected power profile.
#
# Usage:
#   ./setup-battery-management.sh            # apply (idempotent)
#   ./setup-battery-management.sh --remove   # remove the old menu/privileged artifacts
#   ./setup-battery-management.sh --refresh-plugin battery|indicators

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../lib/gui-run.bash"  # gui-run: reopen in a terminal when launched from a file manager
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../../lib/plugin-clone.bash
source "$SCRIPT_DIR/../../../lib/plugin-clone.bash"
# mq_sudo: the root cleanup must not require the whole script to run as root
# (root-owned files in $HOME, and the uninstaller cannot re-exec itself).
if [[ -f "$SCRIPT_DIR/../../../lib/elevate.bash" ]]; then
  # shellcheck source=../../../lib/elevate.bash
  source "$SCRIPT_DIR/../../../lib/elevate.bash"
else
  mq_sudo() { sudo "$@"; }
fi

info() { echo -e "\033[1;34m==>\033[0m $*"; }
ok()   { echo -e "\033[1;32m  ✓\033[0m $*"; }
warn() { echo -e "\033[1;33m  !\033[0m $*"; }
err()  { echo -e "\033[1;31m  ✗\033[0m $*" >&2; }

# Resolve the REAL invoking user's home even when run via `sudo bash`
# (as root, $HOME=/root, but the binaires/scripts live in the user's home).
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
USR_BIN_DIR="/usr/local/bin"
MENU_DIR="$REAL_HOME/.config/omarchy/extensions"
MENU="$MENU_DIR/omarchy-menu.jsonc"
BLOCK_START="// >>> Omarchy_Custom_Scripts_UltraSave"
BLOCK_END="// <<< Omarchy_Custom_Scripts_UltraSave"
SUDOERS_FILE="/etc/sudoers.d/battery-management"
UDEV_DST="/etc/udev/rules.d/99-lenovo-charge-threshold.rules"

if [[ ! -d /usr/share/omarchy ]]; then
  echo "This script is meant for Omarchy." >&2
  exit 1
fi

REMOVE=false
REFRESH_PLUGIN=""
case "${1:-}" in
  --remove) REMOVE=true ;;
  --refresh-plugin) REFRESH_PLUGIN="${2:-}" ;;
esac
if [[ ${1:-} == --refresh-plugin && -z $REFRESH_PLUGIN ]]; then
  err "--refresh-plugin needs battery or indicators"
  exit 2
fi

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
  mkdir -p "$BIN_DIR"

  deploy_bin "power-helper"
  # battery-status: corrected battery telemetry. The stock
  # omarchy-battery-status / omarchy-power-present pair reports a USB-C
  # PERIPHERAL as a charger (any type=USB supply with online=1), which made the
  # machine claim it was charging while the battery drained, and rendered an
  # empty time / 0.0W / no charging icon on real USB-C PD chargers that never
  # flip the AC (type=Mains) flag. This fork decides from the battery's own
  # status and only reports "-" instead of inventing a 0.0W. Tests:
  # code/modules/Plugins/battery-management/battery-status-test
  deploy_bin "battery-status"
# CPU/GPU temperatures for the power panel (CPU always, GPU only on a
# discrete card; APU-only machines get one compact CPU field).
deploy_bin "battery-temps"

  [[ -d "$BIN_DIR" ]] && PATH="$BIN_DIR:$PATH"
fi

# -----------------------------------------------------------------------------
# 1b. Mosquito battery plugin — ONE plugin for the service and the bar widget
#     The battery service (real-charger guard) and the power-profile bar widget
#     used to be two plugins (mosquito.battery + mosquito.power) that had to be
#     kept in sync. They now share one directory and manifest, so Omarchy lists
#     a single "Mosquito Battery" and the bar shows one battery icon.
#     Cloned from omarchy.battery; our Service.qml, Panel.qml, Model.js and
#     manifest are overlaid on every run.
# -----------------------------------------------------------------------------
BATTERY_CLONED=0

# Exactly ONE widget from the battery family in the bar layout. The legacy
# separate ids (mosquito.power, custom.power, <user>.power) are adopted into
# the merged id, and leftover duplicates are dropped. Blindly repointing every
# power id is how the bar ended up with two battery widgets: a stale clone id
# (kapeq_mosquito.power) renders nothing while its plugin dir is gone, then
# becomes a second live widget the moment it is repointed.
normalize_bar_widget(){  # <shell.json> <user> <suffix> [canonical-id] [extra-id…]
  python3 - "$1" "$2" "$3" "${@:4}" <<'PY'
import json, os, sys, time
path, user, suffix, extra = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
CANON = extra[0] if extra else "mosquito." + suffix
IDS = {"omarchy." + suffix, "custom." + suffix, user + "." + suffix, CANON, *extra}
try:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
except (OSError, ValueError):
    sys.exit(0)
layout = data.get("bar", {}).get("layout")
if not isinstance(layout, dict):
    sys.exit(0)
positions = [(sec, i, it.get("id"))
             for sec, items in layout.items() if isinstance(items, list)
             for i, it in enumerate(items)
             if isinstance(it, dict) and it.get("id") in IDS]
if not positions:
    sys.exit(0)
if len(positions) == 1 and positions[0][2] == CANON:
    sys.exit(0)  # already correct: no write, no backup
# Keep the live clone when one is placed (prefer the right cluster, where the
# power widget lives), else adopt the first matching entry.
canon = [p for p in positions if p[2] == CANON]
if canon:
    keep = next((p for p in canon if p[0] == "right"), canon[0])
else:
    keep = positions[0]
    layout[keep[0]][keep[1]]["id"] = CANON
drop = {p[:2] for p in positions} - {keep[:2]}
for section, items in layout.items():
    if isinstance(items, list) and any(s == section for s, _ in drop):
        gone = {i for s, i in drop if s == section}
        layout[section] = [it for i, it in enumerate(items) if i not in gone]
try:
    with open(path, encoding="utf-8") as src:
        backup = path + ".bak.fix-" + suffix + "-" + str(int(time.time()))
        with open(backup, "w", encoding="utf-8") as dst:
            dst.write(src.read())
except OSError:
    pass
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
os.replace(tmp, path)
print("changed")
PY
}

ensure_battery_plugin() {
  local PLUG="$REAL_HOME/.config/omarchy/plugins"
  local PLUGIN_ID="mosquito.battery"
  local PLUGIN_DIR="$PLUG/$PLUGIN_ID"
  local SHELL_JSON="$REAL_HOME/.config/omarchy/shell.json"
  local cloned rel

  [[ -f "$SHELL_JSON" ]] || return 0

  if [[ ! -d $PLUGIN_DIR ]]; then
    # A residual <user>.battery clone? Re-adopt it instead of cloning again.
    for cloned in "$PLUG/$REAL_USER.battery" "$PLUG"/*.battery; do
      [[ -d $cloned && $cloned != "$PLUGIN_DIR" ]] || continue
      mv "$cloned" "$PLUGIN_DIR" 2>/dev/null && break
    done
  fi
  if [[ ! -d $PLUGIN_DIR ]]; then
    if ! omarchy plugin clone omarchy.battery >/dev/null 2>&1; then
      warn "Could not clone omarchy.battery — copying the stock service directory"
      mkdir -p "$PLUGIN_DIR" 2>/dev/null || true
      cp -r /usr/share/omarchy/shell/plugins/services/battery/. "$PLUGIN_DIR/" 2>/dev/null || true
    fi
    for cloned in "$PLUG/$REAL_USER.battery" "$PLUG"/*.battery; do
      [[ -d $cloned && $cloned != "$PLUGIN_DIR" ]] || continue
      mv "$cloned" "$PLUGIN_DIR" 2>/dev/null && break
    done
    [[ -d $PLUGIN_DIR ]] || { warn "Clone of omarchy.battery not found"; return 1; }
    BATTERY_CLONED=1
  else
    ok "Omarchy plugin $PLUGIN_ID already present"
  fi

  # Our files, always: the QML and the merged manifest are the module's.
  for rel in Service.qml Panel.qml Model.js manifest.json; do
    if [[ ! -f "$PLUG_SRC/$PLUGIN_ID/$rel" ]]; then
      warn "Missing source file $PLUG_SRC/$PLUGIN_ID/$rel"
      return 1
    fi
    cp -f "$PLUG_SRC/$PLUGIN_ID/$rel" "$PLUGIN_DIR/$rel" 2>/dev/null \
      || { warn "Could not install $PLUGIN_ID/$rel"; return 1; }
  done
  # Upstream's BatteryModel.js is the service's model: keep the clone's copy.
  if [[ ! -f "$PLUGIN_DIR/BatteryModel.js" && -f /usr/share/omarchy/shell/plugins/services/battery/BatteryModel.js ]]; then
    cp -f /usr/share/omarchy/shell/plugins/services/battery/BatteryModel.js "$PLUGIN_DIR/BatteryModel.js" 2>/dev/null || true
  fi
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true

  # Migrate the retired power widget BEFORE enabling. Renaming in place keeps
  # its position and inline settings (e.g. showPercentage) instead of dropping
  # them with the old entry.
  normalize_bar_widget "$SHELL_JSON" "$REAL_USER" power "$PLUGIN_ID" >/dev/null || true

  # One battery service and one battery widget: ours replaces the stock ones.
  omarchy plugin disable omarchy.battery >/dev/null 2>&1 || true
  omarchy plugin disable omarchy.power >/dev/null 2>&1 || true
  if ! omarchy plugin enable "$PLUGIN_ID" >/dev/null 2>&1; then
    warn "Battery plugin installed but not enabled — run: omarchy plugin enable $PLUGIN_ID"
  fi
  # enable places a bar widget; drop any duplicate it just added next to the
  # migrated entry (the migrated one wins, settings included).
  normalize_bar_widget "$SHELL_JSON" "$REAL_USER" power "$PLUGIN_ID" >/dev/null || true

  # The separate power plugin is retired: its QML now lives in mosquito.battery.
  # Removing a clone makes Omarchy restore its source (omarchy.power) in the
  # bar, so absorb that restored entry into ours afterwards.
  omarchy plugin disable mosquito.power >/dev/null 2>&1 || true
  omarchy plugin remove mosquito.power --yes >/dev/null 2>&1 || true
  rm -rf "$PLUG/mosquito.power" "$PLUG/custom.power" "$PLUG/$REAL_USER.power" 2>/dev/null || true
  normalize_bar_widget "$SHELL_JSON" "$REAL_USER" power "$PLUGIN_ID" >/dev/null || true

  ok "Omarchy plugin $PLUGIN_ID (battery service + power widget)"
}

# -----------------------------------------------------------------------------
# 1c. mosquitOmarchy plugins (bar widget + overlay) — same clone/rename pattern
#     but with QML sources shipped in ./omarchy-plugins/ (the stock clones are
#     then patched so a fresh machine reproduces this machine's customizations):
#       • mosquito.battery/Panel.qml       : profile-colored battery icon
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

INDICATORS_CLONED=0
ensure_indicators_plugin() {
  local shell_json="$REAL_HOME/.config/omarchy/shell.json"
  [[ -f "$shell_json" ]] || return 0
  # The clone only customizes an indicators widget the user ALREADY has on the
  # bar. `omarchy plugin enable` places a bar widget, so enabling it here on a
  # machine that never asked for indicators is how a set of hidden icons
  # (idle lock, DND…) appeared out of nowhere. Adopt/refresh, never add.
  local in_bar=0
  grep -qE '"(omarchy|mosquito|'"$REAL_USER"')\.indicators"' "$shell_json" 2>/dev/null && in_bar=1
  if (( ! in_bar )) && [[ ! -d "$PLUG_DIR/mosquito.indicators" ]]; then
    ok "No indicators widget in the bar — skipped (nothing added)."
    return 0
  fi
  if [[ -d "$PLUG_DIR/mosquito.indicators" ]]; then
    ok "Omarchy plugin mosquito.indicators already present"
  else
    if [[ -d "$PLUG_DIR/$REAL_USER.indicators" ]]; then
      warn "Clone $REAL_USER.indicators present — renamed to mosquito.indicators"
      mv "$PLUG_DIR/$REAL_USER.indicators" "$PLUG_DIR/mosquito.indicators"
    else
      warn "Plugin mosquito.indicators missing — cloning from omarchy.indicators"
      INDICATORS_CLONED=1
      omarchy plugin clone omarchy.indicators || { warn "Could not clone omarchy.indicators"; return 1; }
      if [[ -d "$PLUG_DIR/$REAL_USER.indicators" ]]; then
        mv "$PLUG_DIR/$REAL_USER.indicators" "$PLUG_DIR/mosquito.indicators"
      else
        warn "Clone $REAL_USER.indicators not found after cloning."
        return 1
      fi
    fi
    sed -i "s|\"$REAL_USER\\.indicators\"|\"mosquito.indicators\"|g" "$shell_json"
    # Only (re)place it when the bar already had an indicators widget.
    (( in_bar )) && omarchy plugin enable mosquito.indicators >/dev/null 2>&1 || true
    ok "Omarchy plugin mosquito.indicators cloned (bar widget already present)"
  fi
  # Exactly one indicators widget. `omarchy plugin enable` adds a bar entry on
  # top of the one the user already had, which is how the same widget ended up
  # in both centerBegin and centerEnd.
  local layout_change
  layout_change="$(normalize_bar_widget "$shell_json" "$REAL_USER" indicators)"
  if [[ $layout_change == changed ]]; then
    ok "Bar layout: one indicators widget (duplicates removed)"
  fi
  # The clone carries Omarchy's "My Indicators" display name. Patch it on
  # EVERY run, not only on the first clone: an existing clone kept the stock
  # name for ever otherwise.
  local mf="$PLUG_DIR/mosquito.indicators/manifest.json"
  if command -v jq >/dev/null 2>&1 && [[ -f $mf ]]; then
    jq --arg id "mosquito.indicators" '.id=$id | .name="Mosquito Indicators" | .author="Mosquito" | if has("barWidget") then .barWidget.displayName="Mosquito Indicators" else . end' "$mf" >"$mf.tmp" && mv "$mf.tmp" "$mf"
  else
    sed -i -E "s/\"id\"[[:space:]]*:[[:space:]]*\"[^\"]+\"/\"id\": \"mosquito.indicators\"/" "$mf"
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


# Record or refresh the upstream baseline for a managed clone. A pre-existing
# clone with no stamp is left unstamped on purpose: writing today's upstream
# hash would hide the very drift Health is meant to report. Only a clone this
# run actually created gets a baseline.
record_clone_stamp(){
  local id="$1" source_id="$2" fresh="$3" dir="$PLUG_DIR/$1" up
  [[ -d $dir ]] || return 0
  if [[ -f $(plugin_clone_stamp_file "$dir") ]]; then
    plugin_clone_update_stamp "$dir" >/dev/null 2>&1 || true
  elif (( fresh )); then
    up="$(plugin_clone_source_hash "$source_id" 2>/dev/null || true)"
    [[ -n $up ]] && plugin_clone_write_stamp "$dir" "$up" >/dev/null 2>&1 || true
  fi
}

refresh_plugin(){
  local key="$1" id source_id ensure dir leftover leftover_bak backup
  local -a files
  case $key in
    power|battery)
      id="mosquito.battery"; source_id="omarchy.battery"; ensure="ensure_battery_plugin"
      files=("Service.qml" "Panel.qml" "Model.js" "manifest.json") ;;
    indicators)
      id="mosquito.indicators"; source_id="omarchy.indicators"; ensure="ensure_indicators_plugin"
      files=("Indicators.qml" "indicators/StayAwake.qml") ;;
    *) err "Unknown plugin to refresh: $key"; return 2 ;;
  esac

  dir="$PLUG_DIR/$id"
  [[ -d $dir ]] || { warn "$id is not installed — nothing to refresh."; return 1; }
  leftover="$PLUG_DIR/$REAL_USER.${id#mosquito.}"
  backup="$PLUG_DIR/.refresh-$id.$$"
  leftover_bak="$leftover.refresh.$$"
  mv "$dir" "$backup" || return 1
  if [[ -e $leftover ]]; then
    mv "$leftover" "$leftover_bak" || {
      mv "$backup" "$dir" 2>/dev/null || true
      warn "Could not move the old $REAL_USER ${id#mosquito.} clone aside."
      return 1
    }
  fi

  local rc=0 up
  "$ensure" || rc=1
  if (( rc == 0 )) && [[ -d $dir ]]; then
    overlay_plugin_files "$id" "${files[@]}" || rc=1
    up="$(plugin_clone_source_hash "$source_id" 2>/dev/null || true)"
    if [[ -z $up ]] || ! plugin_clone_write_stamp "$dir" "$up"; then rc=1; fi
    omarchy plugin validate "$dir" >/dev/null 2>&1 || rc=1
  else
    rc=1
  fi

  if (( rc == 0 )); then
    omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
    omarchy plugin enable "$id" >/dev/null 2>&1 || true
    if [[ $id == mosquito.battery ]]; then
      normalize_bar_widget "$REAL_HOME/.config/omarchy/shell.json" "$REAL_USER" power "$id" >/dev/null 2>&1 || true
    else
      normalize_bar_widget "$REAL_HOME/.config/omarchy/shell.json" "$REAL_USER" "$key" >/dev/null 2>&1 || true
    fi
    rm -rf "$backup" || true
    if [[ -e $leftover_bak ]]; then rm -rf "$leftover_bak" || true; fi
    ok "Refreshed $id from the current $source_id"
    return 0
  fi

  rm -rf "$dir" "$leftover" || true
  mv "$backup" "$dir" 2>/dev/null || true
  if [[ -e $leftover_bak ]]; then mv "$leftover_bak" "$leftover" 2>/dev/null || true; fi
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
  omarchy plugin enable "$id" >/dev/null 2>&1 || true
  if [[ $id == mosquito.battery ]]; then
    normalize_bar_widget "$REAL_HOME/.config/omarchy/shell.json" "$REAL_USER" power "$id" >/dev/null 2>&1 || true
  else
    normalize_bar_widget "$REAL_HOME/.config/omarchy/shell.json" "$REAL_USER" "$key" >/dev/null 2>&1 || true
  fi
  warn "Could not refresh $id — the previous clone was restored."
  return 1
}

if [[ -n $REFRESH_PLUGIN ]]; then
  refresh_plugin "$REFRESH_PLUGIN"
  exit $?
fi

if [[ $REMOVE == false ]]; then
  ensure_battery_plugin || true
  record_clone_stamp "mosquito.battery" "omarchy.battery" "$BATTERY_CLONED"

  # Omarchy's OWN power panel, overlaid for the same reason. It is disabled in
  # favour of mosquito.battery on this desktop, but it is one `omarchy plugin
  # enable omarchy.power` away from being live again, and its setProfile() calls
  # omarchy-powerprofiles-set directly — so a machine that switched back would
  # silently lose the Live Mode guard. The overlay is only applied when the
  # plugin directory actually exists; an Omarchy update replaces the original
  # file, and this setup run puts ours back.
  if [[ -d "$PLUG_DIR/omarchy.power" ]]; then
    cp "$PLUG_SRC/omarchy.power/Panel.qml" "$PLUG_DIR/omarchy.power/Panel.qml" 2>/dev/null \
      && ok "Live Mode power guard applied to omarchy.power too" \
      || warn "Could not overlay omarchy.power/Panel.qml"
  fi
  ensure_indicators_plugin || true
  record_clone_stamp "mosquito.indicators" "omarchy.indicators" "$INDICATORS_CLONED"
  ensure_confirm_plugin || true
fi

# Remove privileged artifacts left by the retired ultra-save mode.
TIMER_DIR="$REAL_HOME/.config/systemd/user"
LEGACY_STATE="$REAL_HOME/.local/state/ultra-save"
LEGACY_ACTIVE=0
if grep -qx 'on' "$LEGACY_STATE/state" 2>/dev/null; then
  if [[ -x "$BIN_DIR/ultra-save" ]]; then
    if [[ $EUID -eq 0 ]]; then
      SUDO_USER="$REAL_USER" HOME="$REAL_HOME" "$BIN_DIR/ultra-save" off >/dev/null 2>&1 || LEGACY_ACTIVE=1
    else
      sudo -n "$BIN_DIR/ultra-save" off >/dev/null 2>&1 || LEGACY_ACTIVE=1
    fi
  else
    LEGACY_ACTIVE=1
  fi
  (( LEGACY_ACTIVE )) && warn "Ultra-save is active but could not be safely disabled; preserving its binary and state. Run: sudo $BIN_DIR/ultra-save off"
fi
if (( LEGACY_ACTIVE )); then
  warn "Keeping the legacy sudoers rule so ultra-save can still be turned off."
elif [[ $EUID -eq 0 ]]; then
  rm -f "$SUDOERS_FILE"
elif [[ -e $SUDOERS_FILE ]]; then
  mq_sudo rm -f "$SUDOERS_FILE" && ok "Legacy sudoers rule removed" \
    || warn "Legacy sudoers remains; run: sudo rm -f $SUDOERS_FILE"
fi
systemctl --user disable --now mosquito-ultra-save-watch.timer ultra-save-monitor.timer 2>/dev/null || true
rm -f "$TIMER_DIR/mosquito-ultra-save-watch.service" "$TIMER_DIR/mosquito-ultra-save-watch.timer" \
      "$TIMER_DIR/ultra-save-monitor.service" "$TIMER_DIR/ultra-save-monitor.timer" \
      "$BIN_DIR/ultra-save-watch"
if (( ! LEGACY_ACTIVE )); then
  rm -f "$BIN_DIR/ultra-save"
  rm -rf "$LEGACY_STATE"
fi
systemctl --user daemon-reload 2>/dev/null || true

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
    sudo -n install -m 0755 "$BIN_DIR/power-helper" "$USR_BIN_DIR/power-helper" \
      && ok "power-helper updated in $USR_BIN_DIR" \
      || warn "Root helper was not updated; run: sudo install -m 0755 $BIN_DIR/power-helper $USR_BIN_DIR/power-helper"
  fi
fi

# Legacy charge-control udev rule cleanup.
if [[ -f "$UDEV_DST" ]]; then
  if [[ $EUID -eq 0 ]]; then
    rm -f "$UDEV_DST"
    udevadm control --reload 2>/dev/null || true
    ok "legacy charge-control udev rule removed"
  elif mq_sudo rm -f "$UDEV_DST"; then
    mq_sudo udevadm control --reload 2>/dev/null || true
    ok "legacy charge-control udev rule removed"
  else
    warn "legacy charge-control udev rule remains; run: sudo rm -f $UDEV_DST"
  fi
fi

# -----------------------------------------------------------------------------
# 5. Cleanup of the old "System > Ultra-save mode" block in the Omarchy menu
#    (now driven by the mosquito.battery widget, no menu entry needed anymore)
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
# 6. Summary
# -----------------------------------------------------------------------------
echo ""
if [[ $REMOVE == true ]]; then
  # Hand the bar back to the stock power widget BEFORE the merged plugin
  # disappears. First consolidate the battery family to one entry (keeping its
  # position and settings), then rename that entry to the stock id.
  normalize_bar_widget "$REAL_HOME/.config/omarchy/shell.json" "$REAL_USER" power mosquito.battery >/dev/null 2>&1 || true
  normalize_bar_widget "$REAL_HOME/.config/omarchy/shell.json" "$REAL_USER" power omarchy.power >/dev/null 2>&1 || true
  omarchy plugin disable mosquito.battery >/dev/null 2>&1 || true
  omarchy plugin remove mosquito.battery --yes >/dev/null 2>&1 || true
  # Legacy separate power plugin from older installs.
  omarchy plugin disable mosquito.power >/dev/null 2>&1 || true
  omarchy plugin remove mosquito.power --yes >/dev/null 2>&1 || true
  rm -rf "$PLUG_DIR/mosquito.power" "$PLUG_DIR/custom.power" "$PLUG_DIR/$REAL_USER.power" 2>/dev/null || true
  omarchy plugin enable omarchy.battery >/dev/null 2>&1 || true
  omarchy plugin enable omarchy.power >/dev/null 2>&1 || true
  normalize_bar_widget "$REAL_HOME/.config/omarchy/shell.json" "$REAL_USER" power omarchy.power >/dev/null 2>&1 || true
  info "Uninstall complete."
  if (( LEGACY_ACTIVE )); then
    echo "  Ultra-save is still active; its executable/state/sudoers were preserved. Turn it off, then rerun this script."
  else
    echo "  Legacy ultra-save binaries, state, timer and menu entry removed."
  fi
else
  info "Setup complete. Summary:"
  echo "  • Plugin helper         -> $BIN_DIR/power-helper + /usr/local/bin"
  echo "  • Battery status        -> $BIN_DIR/battery-status (corrected charger/0W detection)"
  echo "  • Battery plugin        -> mosquito.battery (service + power-profile widget)"
  echo "  • Omarchy overlay       -> mosquito.confirm plugin (native Yes/No prompts)"
  echo "  • Omarchy indicators    -> mosquito.indicators widget (stay-awake red icon + tooltip)"
  echo "  • Legacy ultra-save menu entry removed"
  (( LEGACY_ACTIVE )) && echo "  • Legacy ultra-save is active; executable/state/sudoers preserved until it is safely turned off"
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
    echo "  Rerun with sudo only if a legacy sudoers file or charge-control rule remains."
  fi
fi
