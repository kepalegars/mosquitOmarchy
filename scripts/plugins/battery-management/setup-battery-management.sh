#!/usr/bin/env bash
# =============================================================================
# Mosquito Power — battery profile icon and panel
# =============================================================================
# Installs the power-profile panel and corrected battery telemetry. The former
# ultra-save mode (CPU/power cap plus watchdog) was abandoned; this module now
# only changes the battery icon color with the selected power profile.
#
# Usage:
#   ./setup-battery-management.sh            # apply (idempotent)
#   ./setup-battery-management.sh --remove   # remove the old menu/privileged artifacts
#   ./setup-battery-management.sh --refresh-plugin power|indicators

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/gui-run.bash"  # gui-run: reopen in a terminal when launched from a file manager
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/plugin-clone.bash
source "$SCRIPT_DIR/../../lib/plugin-clone.bash"

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
  err "--refresh-plugin needs power or indicators"
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
  # scripts/plugins/battery-management/battery-status-test
  deploy_bin "battery-status"

  [[ -d "$BIN_DIR" ]] && PATH="$BIN_DIR:$PATH"
fi

# -----------------------------------------------------------------------------
# 1b. Mosquito mosquito.power plugin (bar widget: power profiles)
#     Recreates it if missing: clones omarchy.power then renames to
#     mosquito.power. The legacy custom.power clone is adopted (renamed) when
#     found, so no machine keeps the old id.
# -----------------------------------------------------------------------------
POWER_CLONED=0
ensure_power_plugin() {
  local PLUG="$REAL_HOME/.config/omarchy/plugins"
  local PLUGIN_ID="mosquito.power"
  local PLUGIN_DIR="$PLUG/$PLUGIN_ID"
  local SHELL_JSON="$REAL_HOME/.config/omarchy/shell.json"

  [[ -f "$REAL_HOME/.config/omarchy/shell.json" ]] || return 0

  if [[ -d "$PLUGIN_DIR" ]]; then
    ok "Omarchy plugin $PLUGIN_ID already present"
  else
    # A legacy custom.power clone, or a residual <user>.power clone? Re-adopt.
    if [[ -d "$PLUG/custom.power" ]]; then
      warn "Legacy clone custom.power present — renamed to $PLUGIN_ID"
      mv "$PLUG/custom.power" "$PLUGIN_DIR"
      omarchy plugin disable custom.power >/dev/null 2>&1 || true
    elif [[ -d "$PLUG/$REAL_USER.power" ]]; then
      warn "Clone $REAL_USER.power present — renamed to $PLUGIN_ID"
      mv "$PLUG/$REAL_USER.power" "$PLUGIN_DIR"
    else
      warn "Plugin $PLUGIN_ID missing — cloning from omarchy.power"
      POWER_CLONED=1
      omarchy plugin clone omarchy.power || { warn "Could not clone omarchy.power"; return 1; }
      if [[ -d "$PLUG/$REAL_USER.power" ]]; then
        mv "$PLUG/$REAL_USER.power" "$PLUGIN_DIR"
      else
        warn "Clone $REAL_USER.power not found after cloning."
        return 1
      fi
    fi
  fi

  # Force the manifest id AND the mosquito display name (a fresh clone carries
  # omarchy.power's or the legacy custom.power's "My Power" name).
  local mf="$PLUGIN_DIR/manifest.json"
  if command -v jq >/dev/null 2>&1 && [[ -f $mf ]]; then
    jq --arg id "$PLUGIN_ID" '.id=$id | .name="Mosquito Power" | .author="Mosquito" | if has("barWidget") then .barWidget.displayName="Mosquito Power" else . end' "$mf" >"$mf.tmp" && mv "$mf.tmp" "$mf"
  else
    sed -i -E "s/\"id\"[[:space:]]*:[[:space:]]*\"[^\"]+\"/\"id\": \"$PLUGIN_ID\"/" "$mf"
  fi

  # ALWAYS repoint the bar layout to mosquito.power and enable it. A reinstall,
  # an Omarchy update or an earlier partial run can leave shell.json on the
  # STOCK omarchy.power (or a stale custom.power / <user>.power clone): the
  # customized widget then exists but is never shown, so nothing we change in
  # its QML has any effect.
  if grep -qE "\"(omarchy|custom|${REAL_USER})\\.power\"" "$SHELL_JSON" 2>/dev/null; then
    cp -f "$SHELL_JSON" "$SHELL_JSON.bak.fix-power-$(date +%s)" 2>/dev/null || true
    sed -i -E "s#\"(omarchy|custom|${REAL_USER})\.power\"#\"$PLUGIN_ID\"#g" "$SHELL_JSON"
    ok "Bar layout repointed: power widget -> $PLUGIN_ID"
  fi
  # And any self-reference inside the plugin's own QML.
  sed -i -E "s#\"(omarchy|custom|${REAL_USER})\.power\"#\"$PLUGIN_ID\"#g" "$PLUGIN_DIR"/*.qml 2>/dev/null || true
  omarchy plugin enable "$PLUGIN_ID" >/dev/null 2>&1 || true
  ok "Omarchy plugin $PLUGIN_ID present + enabled (bar widget)"
}

# -----------------------------------------------------------------------------
# 1c. Omarchy custom plugins (bar widget + overlay) — same clone/rename pattern
#     but with QML sources shipped in ./omarchy-plugins/ (the stock clones are
#     then patched so a fresh machine reproduces this machine's customizations):
#       • mosquito.power/Panel.qml          : profile-colored battery icon
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
  [[ -f "$REAL_HOME/.config/omarchy/shell.json" ]] || return 0
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
    power)
      id="mosquito.power"; source_id="omarchy.power"; ensure="ensure_power_plugin"
      files=("Panel.qml" "Model.js") ;;
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
  warn "Could not refresh $id — the previous clone was restored."
  return 1
}

if [[ -n $REFRESH_PLUGIN ]]; then
  refresh_plugin "$REFRESH_PLUGIN"
  exit $?
fi

if [[ $REMOVE == false ]]; then
  ensure_power_plugin || true
  overlay_plugin_files "mosquito.power" "Panel.qml" "Model.js"
  record_clone_stamp "mosquito.power" "omarchy.power" "$POWER_CLONED"

  # Omarchy's OWN power panel, overlaid for the same reason. It is disabled in
  # favour of mosquito.power on this desktop, but it is one `omarchy plugin
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
if [[ $EUID -eq 0 && $LEGACY_ACTIVE -eq 0 ]]; then
  rm -f "$SUDOERS_FILE"
elif [[ $EUID -eq 0 ]]; then
  warn "Keeping the legacy sudoers rule so ultra-save can still be turned off."
else
  [[ ! -e $SUDOERS_FILE ]] || warn "Legacy sudoers remains; rerun as root to remove: sudo bash $0"
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
  else
    warn "legacy charge-control udev rule present — rerun as root to remove: sudo bash $0"
  fi
fi

# -----------------------------------------------------------------------------
# 5. Cleanup of the old "System > Ultra-save mode" block in the Omarchy menu
#    (now driven by the mosquito.power widget, no menu entry needed anymore)
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
  info "Uninstall complete: legacy udev + sudoers removed."
  if (( LEGACY_ACTIVE )); then
    echo "  Ultra-save is still active; its executable/state/sudoers were preserved. Turn it off, then rerun this script."
  else
    echo "  Legacy ultra-save binaries, state, timer and menu entry removed."
  fi
else
  info "Setup complete. Summary:"
  echo "  • Plugin helper         -> $BIN_DIR/power-helper + /usr/local/bin"
  echo "  • Battery status        -> $BIN_DIR/battery-status (corrected charger/0W detection)"
  echo "  • Omarchy widget        -> mosquito.power plugin (power-profile icon colors)"
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
