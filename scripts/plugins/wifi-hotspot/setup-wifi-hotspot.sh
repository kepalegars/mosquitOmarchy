#!/usr/bin/env bash
# =============================================================================
# mosquitOmarchy - "wifi-hotspot" (install / status / uninstall)
# =============================================================================
# Hotspot row in the Wi-Fi panel, right below the Wi-Fi band section: a
# toggle for an NM-native persistent hotspot profile plus a gear button
# opening its settings (SSID, password, band).
#
# Installs:
#   1. mosquito-hotspot -> ~/.local/bin (nmcli backend: status/toggle/setup)
#   2. ~/.config/omarchy/plugins/mosquito.network — a CLONE of the stock
#      omarchy.network panel with the hotspot block injected (marked, so a
#      reinstall re-clones stock fresh and re-applies cleanly), bar repointed
#      at it in shell.json.
#
# Usage:
#   ./setup-wifi-hotspot.sh              install
#   ./setup-wifi-hotspot.sh -y           non-interactive install
#   ./setup-wifi-hotspot.sh --status     missing | partial:... | ok
#   ./setup-wifi-hotspot.sh --uninstall  remove the clone + backend (keeps
#                                        the NM hotspot profile, if any)
# =============================================================================
set -euo pipefail

info()  { echo -e "\033[1;34m==>\033[0m $*"; }
ok()    { echo -e "\033[1;32m ✓\033[0m $*"; }
warn()  { echo -e "\033[1;33m !\033[0m $*"; }
die()   { warn "$*"; exit 1; }

YES=0 STATUS_ONLY=0 UNINSTALL=0
for a in "$@"; do case "$a" in
  -y|--yes) YES=1 ;;
  --status) STATUS_ONLY=1 ;;
  --uninstall) UNINSTALL=1 ;;
  -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) die "unknown option: $a" ;;
esac; done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
PLUG="$HOME/.config/omarchy/plugins"
PLUGIN_ID="mosquito.network"
PLUGIN_DIR="$PLUG/$PLUGIN_ID"
SHELL_JSON="$HOME/.config/omarchy/shell.json"
MARK_START="// >>> mosquito-hotspot >>>"
MARK_END="// <<< mosquito-hotspot <<<"

hotspot_status(){
  [[ -x $BIN_DIR/mosquito-hotspot ]] || { echo missing; return; }
  local miss=""
  [[ -d $PLUGIN_DIR ]] || miss="${miss:+$miss, }plugin clone"
  grep -qF "$MARK_START" "$PLUGIN_DIR/Panel.qml" 2>/dev/null || miss="${miss:+$miss, }hotspot row"
  grep -qE "\"$PLUGIN_ID\"" "$SHELL_JSON" 2>/dev/null || miss="${miss:+$miss, }bar repoint"
  [[ -n $miss ]] && { echo "partial:missing ${miss# }"; return; }
  echo ok
}

if ((STATUS_ONLY)); then hotspot_status; exit 0; fi

if ((UNINSTALL)); then
  info "Uninstalling the Wi-Fi hotspot row"
  if grep -qE "\"$PLUGIN_ID\"" "$SHELL_JSON" 2>/dev/null; then
    cp -f "$SHELL_JSON" "$SHELL_JSON.bak.unhotspot-$(date +%s)" 2>/dev/null || true
    sed -i -E "s#\"$PLUGIN_ID\"#\"omarchy.network\"#g" "$SHELL_JSON"
    ok "bar layout repointed at the stock network panel"
  fi
  command -v omarchy >/dev/null 2>&1 && omarchy plugin disable "$PLUGIN_ID" >/dev/null 2>&1 || true
  rm -rf "$PLUGIN_DIR"
  ok "plugin clone removed"
  rm -f "$BIN_DIR/mosquito-hotspot"
  ok "backend removed"
  if nmcli -t -f NAME connection show 2>/dev/null | grep -qxF "mosquito-hotspot"; then
    warn "NM hotspot profile kept (delete it with: nmcli connection delete id mosquito-hotspot)"
  fi
  ok "wifi-hotspot uninstalled — reload the shell: omarchy-restart-shell"
  exit 0
fi

mkdir -p "$BIN_DIR"

# -----------------------------------------------------------------------------
# 1. Backend
# -----------------------------------------------------------------------------
[[ -f "$SCRIPT_DIR/mosquito-hotspot" ]] || die "mosquito-hotspot not found next to this script"
cp "$SCRIPT_DIR/mosquito-hotspot" "$BIN_DIR/mosquito-hotspot"
chmod +x "$BIN_DIR/mosquito-hotspot"
bash -n "$BIN_DIR/mosquito-hotspot" || die "Invalid syntax: mosquito-hotspot"
ok "backend deployed: $BIN_DIR/mosquito-hotspot"

# -----------------------------------------------------------------------------
# 2. Clone the stock panel (fresh every time, so stock updates flow through)
# -----------------------------------------------------------------------------
fresh_clone(){
  # Clone stock into PLUGIN_DIR. The clone command sometimes lands directly
  # under our name, sometimes under <user>.network — take either.
  rm -rf "$PLUGIN_DIR"
  command -v omarchy >/dev/null 2>&1 || die "omarchy CLI not found"
  omarchy plugin clone omarchy.network >/dev/null 2>&1 || die "could not clone omarchy.network"
  [[ -d $PLUGIN_DIR ]] && return 0
  if [[ -d "$PLUG/$(whoami).network" ]]; then
    mv "$PLUG/$(whoami).network" "$PLUGIN_DIR"
    return 0
  fi
  die "clone landed nowhere usable — check 'omarchy plugin list'"
}
if [[ ! -d $PLUGIN_DIR ]]; then
  fresh_clone
  ok "cloned omarchy.network -> $PLUGIN_ID"
else
  # Re-clone stock over it: a reinstall must track Omarchy's panel, not our
  # last patched copy (the hotspot block is re-applied below).
  fresh_clone
  ok "re-cloned stock panel (hotspot block re-applied below)"
fi

# Manifest: our id and name (a fresh clone carries the stock ones).
mf="$PLUGIN_DIR/manifest.json"
if command -v jq >/dev/null 2>&1 && [[ -f $mf ]]; then
  jq --arg id "$PLUGIN_ID" '.id=$id | .name="Mosquito Network" | .author="Mosquito"' "$mf" >"$mf.tmp" && mv "$mf.tmp" "$mf"
else
  sed -i -E "s/\"id\"[[:space:]]*:[[:space:]]*\"[^\"]+\"/\"id\": \"$PLUGIN_ID\"/" "$mf"
fi
# Our own QML self-references (moduleName, ipcTarget, summon target). The
# backend script names (omarchy-network-band, with DASHES) must NOT match.
sed -i -E 's#"omarchy\.network"#"'$PLUGIN_ID'"#g' "$PLUGIN_DIR"/Panel.qml 2>/dev/null || true
ok "manifest + self-references renamed to $PLUGIN_ID"

# -----------------------------------------------------------------------------
# 3. Inject the hotspot block (marked: stripped and re-applied every run)
# -----------------------------------------------------------------------------
python3 - "$PLUGIN_DIR/Panel.qml" "$SCRIPT_DIR/hotspot-panel.qmlfrag" <<'PYEOF'
import re, sys
panel, frag = sys.argv[1], sys.argv[2]
src = open(panel).read()
block = open(frag).read().rstrip() + "\n"
# Strip a previous injection first: idempotent by construction.
src = re.sub(r"      // >>> mosquito-hotspot >>>.*?      // <<< mosquito-hotspot <<<\n",
             "", src, flags=re.DOTALL)
anchor = "      // DNS provider selection."
assert src.count(anchor) == 1, "DNS anchor not found (stock panel changed?)"
src = src.replace(anchor, block + anchor)
open(panel, "w").write(src)
print("hotspot block injected")
PYEOF

# -----------------------------------------------------------------------------
# 4. Bar repoint + enable
# -----------------------------------------------------------------------------
if grep -qE '"omarchy\.network"' "$SHELL_JSON" 2>/dev/null; then
  cp -f "$SHELL_JSON" "$SHELL_JSON.bak.hotspot-$(date +%s)" 2>/dev/null || true
  sed -i -E 's#"omarchy\.network"#"mosquito.network"#g' "$SHELL_JSON"
  ok "bar layout repointed: network widget -> $PLUGIN_ID"
fi
command -v omarchy >/dev/null 2>&1 && omarchy plugin enable "$PLUGIN_ID" >/dev/null 2>&1 || true
ok "plugin $PLUGIN_ID present + enabled"

info "wifi-hotspot ready — reload the shell: omarchy-restart-shell"
info "status: $(hotspot_status)"
