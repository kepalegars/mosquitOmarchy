#!/usr/bin/env bash
# =============================================================================
# mosquitOmarchy - "wifi-hotspot" (install / status / uninstall)
# =============================================================================
# Hotspot in the Wi-Fi panel: the hotspot zone + hero action forked from
# Guneshbari/omarchy-network, driven by the forked mosquito-hotspot backend,
# settings edited in the mosquito-hotspot-tui terminal UI.
#
# Installs:
#   1. mosquito-hotspot -> ~/.local/bin (FORKED backend: that project's
#      hotspot query + apply scripts, plus a mosquito NM fallback when
#      neither create_ap nor ethernet is around and a "configured" flag
#      for the settings TUI)
#   2. mosquito-hotspot-tui -> ~/.local/bin (Go/Bubble Tea settings UI:
#      SSID, password, band; defaults hostname/12345678/5GHz when unset)
#   3. ~/.config/omarchy/plugins/mosquito.network — a CLONE of the stock
#      omarchy.network panel with two marked blocks injected (hero hotspot
#      action + hotspot zone), bar repointed at it in shell.json.
#
# Usage:
#   ./setup-wifi-hotspot.sh              install
#   ./setup-wifi-hotspot.sh -y           non-interactive install
#   ./setup-wifi-hotspot.sh --status     missing | partial:... | ok
#   ./setup-wifi-hotspot.sh --uninstall  remove the clone + backend + TUI
#                                        (keeps any NM hotspot profile)
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

hotspot_status(){
  [[ -x $BIN_DIR/mosquito-hotspot && -x $BIN_DIR/mosquito-hotspot-tui ]] || { echo missing; return; }
  local miss=""
  [[ -d $PLUGIN_DIR ]] || miss="${miss:+$miss, }plugin clone"
  grep -qF "mosquito-hotspot-zone" "$PLUGIN_DIR/Panel.qml" 2>/dev/null || miss="${miss:+$miss, }hotspot zone"
  grep -qF "mosquito-hotspot-hero" "$PLUGIN_DIR/Panel.qml" 2>/dev/null || miss="${miss:+$miss, }hero action"
  grep -qE "\"$PLUGIN_ID\"" "$SHELL_JSON" 2>/dev/null || miss="${miss:+$miss, }bar repoint"
  [[ -n $miss ]] && { echo "partial:missing ${miss# }"; return; }
  echo ok
}

if ((STATUS_ONLY)); then hotspot_status; exit 0; fi

if ((UNINSTALL)); then
  info "Uninstalling the Wi-Fi hotspot"
  if grep -qE "\"$PLUGIN_ID\"" "$SHELL_JSON" 2>/dev/null; then
    cp -f "$SHELL_JSON" "$SHELL_JSON.bak.unhotspot-$(date +%s)" 2>/dev/null || true
    sed -i -E "s#\"$PLUGIN_ID\"#\"omarchy.network\"#g" "$SHELL_JSON"
    ok "bar layout repointed at the stock network panel"
  fi
  command -v omarchy >/dev/null 2>&1 && omarchy plugin disable "$PLUGIN_ID" >/dev/null 2>&1 || true
  rm -rf "$PLUGIN_DIR"
  ok "plugin clone removed"
  rm -f "$BIN_DIR/mosquito-hotspot" "$BIN_DIR/mosquito-hotspot-tui"
  ok "backend + settings TUI removed"
  if nmcli -t -f NAME connection show 2>/dev/null | grep -qxF "Hotspot"; then
    warn "NM hotspot profile kept (delete it with: nmcli connection delete id Hotspot)"
  fi
  ok "wifi-hotspot uninstalled — reload the shell: omarchy-restart-shell"
  exit 0
fi

mkdir -p "$BIN_DIR"

# -----------------------------------------------------------------------------
# 1. Backend (forked) + settings TUI
# -----------------------------------------------------------------------------
[[ -f "$SCRIPT_DIR/mosquito-hotspot" ]] || die "mosquito-hotspot not found next to this script"
cp "$SCRIPT_DIR/mosquito-hotspot" "$BIN_DIR/mosquito-hotspot"
chmod +x "$BIN_DIR/mosquito-hotspot"
bash -n "$BIN_DIR/mosquito-hotspot" || die "Invalid syntax: mosquito-hotspot"
ok "backend deployed: $BIN_DIR/mosquito-hotspot"

if command -v go >/dev/null 2>&1; then
  TUI_TMP_OUT="$(mktemp "$BIN_DIR/.mosquito-hotspot-tui.XXXXXX")"
  if (cd "$SCRIPT_DIR/tui-go" && go build -o "$TUI_TMP_OUT" .); then
    chmod +x "$TUI_TMP_OUT"
    mv -f "$TUI_TMP_OUT" "$BIN_DIR/mosquito-hotspot-tui"
    ok "settings TUI built and deployed ($BIN_DIR/mosquito-hotspot-tui)"
  else
    rm -f "$TUI_TMP_OUT"
    warn "mosquito-hotspot-tui build failed — the panel gear will have no settings UI until fixed."
  fi
else
  warn "go not found — mosquito-hotspot-tui won't be built (gear settings unavailable)."
fi

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
  # last patched copy (both blocks below are re-applied).
  fresh_clone
  ok "re-cloned stock panel (blocks re-applied below)"
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
# 3. Inject the hero action + hotspot zone (marked: stripped, re-applied)
# -----------------------------------------------------------------------------
python3 - "$PLUGIN_DIR/Panel.qml" "$SCRIPT_DIR/hotspot-hero.qmlfrag" "$SCRIPT_DIR/hotspot-zone.qmlfrag" <<'PYEOF'
import re, sys
panel, hero_frag, zone_frag = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(panel).read()
# Strip any previous injection, including the first-generation single block.
for start, end in [("// >>> mosquito-hotspot >>>", "// <<< mosquito-hotspot <<<"),
                   ("// >>> mosquito-hotspot-hero >>>", "// <<< mosquito-hotspot-hero <<<"),
                   ("// >>> mosquito-hotspot-zone >>>", "// <<< mosquito-hotspot-zone <<<"),
                   ("// >>> mosquito-hotspot-scanfilter >>>", "// <<< mosquito-hotspot-scanfilter <<<")]:
    src = re.sub(re.escape(start) + r".*?" + re.escape(end) + r"\n", "", src, flags=re.DOTALL)
hero = open(hero_frag).read().rstrip() + "\n"
zone = open(zone_frag).read().rstrip() + "\n"
anchor_hero = "          ToggleSwitch {\n            id: powerSwitch"
assert src.count(anchor_hero) == 1, "hero anchor not found (stock panel changed?)"
src = src.replace(anchor_hero, hero + anchor_hero)
anchor_zone = "      // DNS provider selection."
assert src.count(anchor_zone) == 1, "zone anchor not found (stock panel changed?)"
src = src.replace(anchor_zone, zone + anchor_zone)
# Hide our own hotspot from the scan list while it runs: the rows carry the
# SSID, and the keyboard nav indexes this same array, so filtering here (not
# in the view) keeps cursor and rows aligned.
scanfilter = """    // >>> mosquito-hotspot-scanfilter >>> hide our own hotspot while it runs
    if (hotspot.active && hotspot.ssid !== "") {
      wifiNetworks = wifiNetworks.filter(function(r) { return !r || r.ssid !== hotspot.ssid })
    }
    // <<< mosquito-hotspot-scanfilter <<<
"""
anchor_sync = "    wifiNetworks = Model.sortWifiRows(nets)"
assert src.count(anchor_sync) == 1, "sync anchor not found (stock panel changed?)"
src = src.replace(anchor_sync, anchor_sync + "\n" + scanfilter)
# Keep the Wi-Fi band row mounted whenever the radio answers. Omarchy's own
# gate (bandAvailable > 1) races right after a fresh clone and left the row
# off even though the radio reports two bands; the user asked for it back, so
# the gate becomes "on Wi-Fi", full stop.
src = src.replace("visible: root.canSelectBand", 'visible: root.kind === "wifi"')
open(panel, "w").write(src)
print("hero action + hotspot zone + scan filter + band force injected")
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
