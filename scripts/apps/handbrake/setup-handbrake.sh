#!/usr/bin/env bash
# setup-handbrake.sh — HandBrake (GUI + CLI) on Omarchy / Arch Linux
#
# - installs the HandBrake Qt GUI (ghb) + HandBrakeCLI (the GUI package does
#   NOT ship the CLI) + the H.264/H.265 encoder libs (x264/x265) + the
#   GStreamer plugins for high-quality video previews
# - syncs the presets from the presets/ folder (exported from the HandBrake
#   GUI, one or many JSON per file) into the HandBrake user config
#   (~/.config/ghb/presets.json) under an "Omarchy" category. Re-running the
#   script re-syncs the category (idempotent).
# - adds Hyprland compatibility rules (opaque window + no default opacity →
#   no rendering artifacts) in ~/.config/hypr/hyprland.lua
# - HandBrake follows the Omarchy theme automatically (QT_QPA_PLATFORMTHEME=gtk3
#   set by Omarchy): the Qt UI inherits the active GTK theme at each login.
#
# Usage:
#   ./setup-handbrake.sh                        # interactive
#   ./setup-handbrake.sh -y                     # non-interactive (defaults)
#   ./setup-handbrake.sh --presets-dir=PATH     # preset folder to sync (default: presets/)
#   ./setup-handbrake.sh --status               # current state, changes nothing
#   ./setup-handbrake.sh -h                     # help
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/gui-run.bash"  # gui-run: reopen in a terminal when launched from a file manager
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/elevate.bash"  # mq_sudo: native pkexec prompt when not root
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GHB_DIR="$HOME/.config/ghb"
PRESETS_FILE="$GHB_DIR/presets.json"
HYPR="$HOME/.config/hypr/hyprland.lua"
MARK="Omarchy_Custom_Scripts_Handbrake"

YES=0 STATUS_ONLY=0 PRESETS_DIR="$SCRIPT_DIR/presets"
while (( $# )); do a="$1"; case "$a" in
  -y|--yes) YES=1 ;;
  --status) STATUS_ONLY=1 ;;
  --presets-dir=*) PRESETS_DIR="${a#*=}" ;;
  -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
  *) echo "Unknown option: $a (supported: -y --status --presets-dir=PATH)" >&2; exit 1 ;;
esac; shift; done
[[ -d $PRESETS_DIR ]] || PRESETS_DIR="$SCRIPT_DIR/presets"

G='\033[1;32m'; B='\033[1;34m'; Y='\033[1;33m'; R='\033[1;31m'; N='\033[0m'
msg(){ printf "${B}==>${N} %s\n" "$*"; }
ok(){ printf " ${G}✓${N} %s\n" "$*"; }
warn(){ printf " ${Y}!${N} %s\n" "$*"; }
err(){ printf " ${R}✗${N} %s\n" "$*" >&2; }
hr(){ printf '%.0s─' {1..70}; echo; }
pkg_has(){ pacman -Q "$1" &>/dev/null; }

ask(){
  local q="$1" def="${2:-y}" r
  ((YES)) && { ok "(auto) $q -> yes"; return 0; }
  if command -v gum >/dev/null; then
    gum confirm "$q" --default=$([[ $def == y ]] && echo true || echo false) && return 0 || return 1
  fi
  read -rp "$q [$([ $def = y ] && echo Y/n || echo y/N)] " r
  r="${r:-$def}"; [[ $r =~ ^[oOyY] ]]
}

# ───────────────────────── Packages ─────────────────────────
# handbrake (GUI) deliberately drops HandBrakeCLI at build time → install the
# CLI as its own split package. x264/x265 + ffmpeg bring the software H.264/H.265
# encoders; gst-* enable the in-GUI video previews.
deploy_pkgs=("handbrake" "handbrake-cli" "ffmpeg" "x264" "x265" "gst-libav" "gst-plugins-good")

install_pkgs(){
  msg "System packages (handbrake, handbrake-cli, H.264/H.265 encoders, preview plugins)"
  local missing=() p
  for p in "${deploy_pkgs[@]}"; do pkg_has "$p" || missing+=("$p"); done
  if ((${#missing[@]})); then
    mq_sudo -v || { err "Password required to install: ${missing[*]}"; return 1; }
    mq_sudo pacman -S --needed --noconfirm "${missing[@]}" || { err "Installation failed: ${missing[*]}"; return 1; }
    ok "Installed: ${missing[*]}"
  else
    ok "Already present: ${deploy_pkgs[*]}"
  fi
  command -v HandBrakeCLI &>/dev/null && ok "HandBrakeCLI available: $(command -v HandBrakeCLI)" \
    || warn "HandBrakeCLI not found (handbrake-cli package?)."
}

# ───────────────────────── Preset sync ─────────────────────────
# Merges exports (HandBrake GUI → Export… → .json) from the presets folder into
# ~/.config/ghb/presets.json under an "Omarchy" category. The category is
# refreshed on every run (idempotent, no duplicates). HandBrake must not be
# running: it rewrites this file when it closes.
install_presets(){
  if ! command -v python3 &>/dev/null; then warn "python3 missing — presets not synced."; return 0; fi
  if [[ ! -d $PRESETS_DIR ]] || ! compgen -G "$PRESETS_DIR/*.json" >/dev/null 2>&1; then
    warn "No preset files in $PRESETS_DIR (*.json) — export some from the HandBrake GUI and re-run."
    return 0
  fi
  if pgrep -x ghb &>/dev/null; then
    warn "HandBrake is RUNNING — close it first so it doesn't overwrite the presets file."
    if (( YES )) || ask "Close HandBrake now and continue?" y; then
      pkill -x ghb &>/dev/null || true
    else
      warn "Presets not synced (HandBrake running)."
      return 0
    fi
  fi
  msg "Syncing presets from $PRESETS_DIR → $PRESETS_FILE (Omarchy category)"
  mkdir -p "$GHB_DIR"
  [[ -f $PRESETS_FILE ]] && cp -a "$PRESETS_FILE" "$PRESETS_FILE.bak-$(date +%Y%m%d-%H%M%S)"
  local out
  if ! out="$(python3 - "$PRESETS_FILE" "$PRESETS_DIR" <<'PY'
import json, os, sys

presets_file, presets_dir = sys.argv[1], sys.argv[2]

def items_of(obj):
    # Any JSON value -> list of preset/folder root items.
    if isinstance(obj, dict):
        pl = obj.get("PresetList")
        if isinstance(pl, list):
            return pl
        if obj.get("PresetName"):
            return [obj]
        return []
    if isinstance(obj, list):
        items = []
        for e in obj:
            if isinstance(e, dict) and not e.get("PresetName") and isinstance(e.get("PresetList"), list):
                items.extend(e["PresetList"])
            elif isinstance(e, dict) and e.get("PresetName"):
                items.append(e)
        return items
    return []

roots = []
if os.path.isfile(presets_file):
    try:
        roots = items_of(json.load(open(presets_file, encoding="utf-8")))
    except Exception as ex:
        print("presets.json unreadable, rebuilding:", ex, file=sys.stderr)
        roots = []

imported = []
for fn in sorted(os.listdir(presets_dir)):
    if not fn.endswith(".json"):
        continue
    path = os.path.join(presets_dir, fn)
    try:
        imported.extend(items_of(json.load(open(path, encoding="utf-8"))))
    except Exception as ex:
        print("skip", fn, "-", ex, file=sys.stderr)

roots = [r for r in roots if r.get("PresetName") != "Omarchy"]

if imported:
    seen, kept = set(), []
    for it in imported:
        name = it.get("PresetName")
        if not name or name in seen:
            continue
        seen.add(name)
        kept.append(it)
    roots.append({"PresetName": "Omarchy", "Folder": True, "FolderOpen": False,
                  "ChildrenArray": kept})

os.makedirs(os.path.dirname(presets_file), exist_ok=True)
with open(presets_file, "w", encoding="utf-8") as fh:
    json.dump(roots, fh, indent=2)

print("imported:", len(imported), "preset(s) into the \"Omarchy\" category")
PY
)"; then
    err "Preset merge failed."
    return 1
  fi
  [[ -n $out ]] && ok "$out"
}

# ───────────────────────── Hyprland compatibility ─────────────────────────
# HandBrake is a Qt6 app running native Wayland on Omarchy. With the default
# Omarchy window opacity it can show transient artifacts during encodes /
# previews → exempt it from the opacity layer and force an opaque window.
hypr_compat(){
  mkdir -p "$(dirname "$HYPR")"
  touch "$HYPR"
  if grep -qF -- "$MARK" "$HYPR"; then
    ok "Hyprland rules already present ($MARK block)"
  else
    cat >> "$HYPR" <<'EOF'

-- >>> Omarchy_Custom_Scripts_Handbrake
-- HandBrake (Qt6 / Wayland): opaque window, exempt from the default opacity
-- (avoids rendering artifacts while encoding / previewing).
o.window({ class = "^org\\.handbrake\\.ghb$|^ghb$|^HandBrake$" }, { tag = "-default-opacity", opaque = true })
-- <<< Omarchy_Custom_Scripts_Handbrake
EOF
    hyprctl reload >/dev/null 2>&1 || true
    ok "Hyprland rules added ($HYPR)"
  fi
}

# ───────────────────────── Theme note ─────────────────────────
theme_check(){
  # Omarchy sets QT_QPA_PLATFORMTHEME=gtk3: Qt apps (HandBrake) inherit the
  # active GTK theme → they follow `omarchy theme set` automatically.
  if env | grep -q 'QT_QPA_PLATFORMTHEME=gtk3' || grep -q 'QT_QPA_PLATFORMTHEME.*gtk3' \
       /usr/share/omarchy/default/hypr/envs.lua ~/.config/hypr/envs.lua 2>/dev/null; then
    ok "Theme: HandBrake follows the Omarchy theme (QT_QPA_PLATFORMTHEME=gtk3)"
  else
    ok "Theme: HandBrake uses the system Qt/GTK theme"
  fi
}

# ───────────────────────── Status ─────────────────────────
do_status(){
  hr; msg "HandBrake status"
  pkg_has handbrake   && ok "Package   handbrake : installed"     || warn "Package   handbrake : missing"
  pkg_has handbrake-cli && ok "Package handbrake-cli : installed" || warn "Package handbrake-cli : missing"
  if command -v HandBrakeCLI &>/dev/null; then
    ok "Binary    HandBrakeCLI : $(command -v HandBrakeCLI)"
    local enc
    enc="$(HandBrakeCLI --encoder-list 2>/dev/null | grep -oE 'x26[45]|nvenc_h26[45]|qsv_h26[45]|vce_h26[45]' | sort -u | tr '\n' ' ')"
    ok "Encoders  H.264/H.265 : ${enc:-none}"
  else
    warn "Binary    HandBrakeCLI : absent"
  fi
  if [[ -f $PRESETS_FILE ]]; then
    local n=0
    n="$(python3 -c "import json;d=json.load(open('$PRESETS_FILE'));print(sum(1 for r in d if r.get('PresetName')=='Omarchy' for _ in r.get('ChildrenArray',[])))" 2>/dev/null || echo 0)"
    ok "Presets   Omarchy category : $n preset(s) synced"
  else
    warn "Presets   $PRESETS_FILE : absent (run the install to sync)"
  fi
  [[ -f $HYPR ]] && grep -qF -- "$MARK" "$HYPR" && ok "Hyprland  rules : present ($HYPR)" \
    || warn "Hyprland  rules : absent"
  hr
}

# ───────────────────────── Main ─────────────────────────
main(){
  ((STATUS_ONLY)) && { do_status; exit 0; }
  msg "install-handbrake — HandBrake GUI + CLI for Omarchy"
  install_pkgs || exit 1
  install_presets || true
  hypr_compat
  theme_check
  echo
  hr; msg "HandBrake — ready"
  ok "Launch: ghb   (or the launcher  → HandBrake)"
  ok "CLI:    HandBrakeCLI — see handbrake/README.md for the preset-based examples"
  ok "Presets: synced from $PRESETS_DIR into ~/.config/ghb/presets.json (category 'Omarchy')"
  ok "Re-run: this script to re-sync the presets after adding files in the presets folder"
  hr
}

main "$@"
