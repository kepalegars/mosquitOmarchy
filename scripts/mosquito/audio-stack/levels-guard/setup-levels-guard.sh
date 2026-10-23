#!/usr/bin/env bash
# =============================================================================
# mosquitOmarchy - Levels Guard (install / status / uninstall)
# =============================================================================
# Owns the two native control surfaces that must not touch an Audient EVO's USB
# hardware volume while Mixbay manages it:
#   1. the cloned Omarchy audio panel (mosquito.levels-guard);
#   2. the media-key block in Hyprland bindings.
#
# The Mixbay TUI only writes ~/.config/mosquitomixbay/ui.json
# (`allow_native_volume`); this script never rewrites an explicit preference.
# A missing key means false, which is what makes the guard ON on first install.
#
# Usage:
#   ./setup-levels-guard.sh            install
#   ./setup-levels-guard.sh -y         non-interactive
#   ./setup-levels-guard.sh --status   ok | partial:missing ... | missing
#   ./setup-levels-guard.sh --uninstall
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
PLUGIN_ID="mosquito.levels-guard"
PLUGIN_NAME="Mosquito Levels Guard"
PLUGIN_DIR="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
OLD_PLUGIN_ID="mosquito.mixbay-audio"
OLD_PLUGIN_DIR="$HOME/.config/omarchy/plugins/$OLD_PLUGIN_ID"
AUDIO_UPSTREAM="/usr/share/omarchy/shell/plugins/panels/audio"
HYPR_BINDINGS="$HOME/.config/hypr/bindings.lua"
HELPER_SRC="$SCRIPT_DIR/levels-guard"
HELPER_BIN="$BIN_DIR/levels-guard"
OLD_HELPER_BIN="$BIN_DIR/mixbay-native-volume"
PATCH="$SCRIPT_DIR/levels-guard-plugin/patch.py"

info()  { echo -e "\033[1;34m==>\033[0m $*"; }
ok()    { echo -e "\033[1;32m ✓\033[0m $*"; }
warn()  { echo -e "\033[1;33m !\033[0m $*"; }

STATUS_ONLY=0 UNINSTALL=0 YES=0
for a in "$@"; do case "$a" in
  -y|--yes) YES=1 ;;
  --status) STATUS_ONLY=1 ;;
  --uninstall|--remove) UNINSTALL=1 ;;
esac; done

plugin_enabled(){
  command -v omarchy-plugin-list >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  omarchy-plugin-list --json 2>/dev/null |
    jq -e --arg id "$PLUGIN_ID" 'any(.[]; .id == $id and .enabled == true)' >/dev/null 2>&1
}

guard_status(){
  local miss=""
  [[ -x $HELPER_BIN ]] || miss="${miss:+$miss, }levels-guard helper"
  [[ -d $PLUGIN_DIR ]] || miss="${miss:+$miss, }$PLUGIN_ID plugin"
  if [[ -d $PLUGIN_DIR ]] && ! plugin_enabled; then
    miss="${miss:+$miss, }$PLUGIN_ID disabled"
  fi
  grep -qF -- '-- >>> levels-guard >>>' "$HYPR_BINDINGS" 2>/dev/null \
    || miss="${miss:+$miss, }media-key block"
  if [[ -n $miss ]]; then
    if [[ ! -d $PLUGIN_DIR && ! -x $HELPER_BIN ]]; then echo missing
    else echo "partial:missing ${miss# }"; fi
    return
  fi
  echo ok
}

if ((STATUS_ONLY)); then guard_status; exit 0; fi

audio_upstream_hash(){
  sha256sum "$AUDIO_UPSTREAM/Panel.qml" "$AUDIO_UPSTREAM/Model.js" "$AUDIO_UPSTREAM/manifest.json" 2>/dev/null |
    sha256sum | awk '{print $1}'
}

audio_installed_hash(){
  sha256sum "$1/Panel.qml" "$1/Model.js" 2>/dev/null | sha256sum | awk '{print $1}'
}

remove_key_block(){
  [[ -f $HYPR_BINDINGS ]] || return 0
  python3 - "$HYPR_BINDINGS" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
lines = p.read_text().splitlines(keepends=True)
out, skip = [], False
for line in lines:
    if '-- >>> levels-guard >>>' in line or '-- >>> mixbay-native-volume >>>' in line:
        skip = True
        continue
    if '-- <<< levels-guard <<<' in line or '-- <<< mixbay-native-volume <<<' in line:
        skip = False
        continue
    if not skip:
        out.append(line)
p.write_text(''.join(out))
PY
}

install_key_block(){
  mkdir -p "$(dirname "$HYPR_BINDINGS")"
  touch "$HYPR_BINDINGS"
  remove_key_block
  cat >>"$HYPR_BINDINGS" <<EOF
-- >>> levels-guard >>> EVO USB volume belongs to mosquitomixbay
hl.unbind("XF86AudioRaiseVolume")
hl.unbind("XF86AudioLowerVolume")
hl.unbind("XF86AudioMute")
hl.unbind("XF86AudioMicMute")
hl.unbind("ALT + XF86AudioRaiseVolume")
hl.unbind("ALT + XF86AudioLowerVolume")
o.bind("XF86AudioRaiseVolume", "Volume up", "$HELPER_BIN output raise", { locked = true, repeating = true })
o.bind("XF86AudioLowerVolume", "Volume down", "$HELPER_BIN output lower", { locked = true, repeating = true })
o.bind("XF86AudioMute", "Mute", "$HELPER_BIN output mute-toggle", { locked = true })
o.bind("ALT + XF86AudioRaiseVolume", "Volume up precise", "$HELPER_BIN output +1", { locked = true, repeating = true })
o.bind("ALT + XF86AudioLowerVolume", "Volume down precise", "$HELPER_BIN output -1", { locked = true, repeating = true })
o.bind("XF86AudioMicMute", "Mute microphone", "$HELPER_BIN input", { locked = true })
-- <<< levels-guard <<<
EOF
  hyprctl reload >/dev/null 2>&1 || true
}

remove_old_plugin(){
  [[ -d $OLD_PLUGIN_DIR ]] || return 0
  if command -v omarchy-plugin-disable >/dev/null 2>&1; then
    omarchy-plugin-disable "$OLD_PLUGIN_ID" >/dev/null 2>&1 || warn "could not disable $OLD_PLUGIN_ID"
  fi
  rm -rf "$OLD_PLUGIN_DIR"
  rm -rf "$(dirname "$PLUGIN_DIR")"/.mixbay-audio.* 2>/dev/null || true
  ok "old $OLD_PLUGIN_ID removed"
}

remove_plugin(){
  [[ -d $PLUGIN_DIR ]] || return 0
  if command -v omarchy-plugin-disable >/dev/null 2>&1; then
    omarchy-plugin-disable "$PLUGIN_ID" >/dev/null 2>&1 \
      || { warn "could not disable $PLUGIN_ID"; return 1; }
  fi
  command -v omarchy-plugin-enable >/dev/null 2>&1 \
    && omarchy-plugin-enable omarchy.audio >/dev/null 2>&1 || true
  rm -rf "$PLUGIN_DIR"
  rm -rf "$(dirname "$PLUGIN_DIR")"/.levels-guard.* 2>/dev/null || true
}

install_plugin(){
  [[ -d $AUDIO_UPSTREAM ]] || { warn "Omarchy audio plugin not found at $AUDIO_UPSTREAM"; return 1; }
  local c
  for c in jq python3 sha256sum omarchy-plugin-validate omarchy-shell omarchy-plugin-enable omarchy-plugin-list; do
    command -v "$c" >/dev/null 2>&1 || { warn "$c missing — Levels Guard not installed"; return 1; }
  done
  local up_now old_up old_inst cur_inst
  up_now="$(audio_upstream_hash)"
  if [[ -e $PLUGIN_DIR ]]; then
    old_up="$(sed -n '1p' "$PLUGIN_DIR/.levels-guard-upstream" 2>/dev/null)"
    old_inst="$(sed -n '2p' "$PLUGIN_DIR/.levels-guard-upstream" 2>/dev/null)"
    cur_inst="$(audio_installed_hash "$PLUGIN_DIR")"
    if [[ -z $old_up || $old_up != "$up_now" ]]; then
      warn "upstream Omarchy audio panel changed — keeping installed Levels Guard (remove $PLUGIN_DIR to refresh)"
      return 0
    fi
    if [[ -z $old_inst || $old_inst != "$cur_inst" ]]; then
      warn "Levels Guard was edited locally — keeping it"
      return 0
    fi
  fi

  local plugins_dir stage
  plugins_dir="$(dirname "$PLUGIN_DIR")"
  mkdir -p "$plugins_dir"
  stage="$(mktemp -d "$plugins_dir/.levels-guard.XXXXXX")"
  if ! cp -aL "$AUDIO_UPSTREAM/." "$stage/"; then
    rm -rf "$stage"; warn "could not copy the Omarchy audio panel"; return 1
  fi
  if ! python3 "$PATCH" "$stage/Panel.qml"; then
    rm -rf "$stage"; warn "could not patch the Omarchy audio panel"; return 1
  fi
  if ! jq --arg id "$PLUGIN_ID" --arg name "$PLUGIN_NAME" '
      .id = $id |
      .name = $name |
      .barWidget.displayName = $name |
      .omarchy = ((.omarchy // {}) + {clonedFrom: "omarchy.audio"})
    ' "$stage/manifest.json" >"$stage/manifest.json.tmp"; then
    rm -rf "$stage"; warn "could not rewrite the audio plugin manifest"; return 1
  fi
  mv "$stage/manifest.json.tmp" "$stage/manifest.json"
  printf '%s\n%s\n' "$up_now" "$(audio_installed_hash "$stage")" >"$stage/.levels-guard-upstream"
  if ! omarchy-plugin-validate "$stage" >/dev/null; then
    rm -rf "$stage"; warn "the patched audio plugin failed Omarchy validation"; return 1
  fi
  remove_old_plugin
  rm -rf "$PLUGIN_DIR"
  mv "$stage" "$PLUGIN_DIR"
  [[ -f "$HOME/.config/omarchy/shell.json" ]] \
    && cp -a "$HOME/.config/omarchy/shell.json" "$HOME/.config/omarchy/shell.json.levels-guard.bak"
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
  local i
  for (( i = 0; i < 40; i++ )); do
    omarchy-plugin-list --json 2>/dev/null |
      jq -e --arg id "$PLUGIN_ID" 'any(.[]; .id == $id)' >/dev/null 2>&1 && break
    sleep 0.05
  done
  omarchy-plugin-enable "$PLUGIN_ID" >/dev/null 2>&1 \
    || { warn "installed but could not enable $PLUGIN_ID"; return 1; }
  ok "Omarchy audio panel guard installed ($PLUGIN_ID)"
}

if ((UNINSTALL)); then
  info "Uninstalling Levels Guard"
  remove_key_block
  remove_plugin || true
  rm -f "$HELPER_BIN" "$OLD_HELPER_BIN"
  hyprctl reload >/dev/null 2>&1 || true
  ok "Levels Guard removed (ui.json kept)"
  exit 0
fi

info "Installing Levels Guard"
if [[ ! -f $HELPER_SRC ]]; then warn "helper missing: $HELPER_SRC"; exit 1; fi
install_plugin || exit 1
mkdir -p "$BIN_DIR"
cp "$HELPER_SRC" "$HELPER_BIN"
chmod +x "$HELPER_BIN"
bash -n "$HELPER_BIN" || { warn "invalid helper syntax"; exit 1; }
rm -f "$OLD_HELPER_BIN"
install_key_block
ok "media-key guard installed ($HYPR_BINDINGS)"
ok "Levels Guard ready — status: $(guard_status)"
