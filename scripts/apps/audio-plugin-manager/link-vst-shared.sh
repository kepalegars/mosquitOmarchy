#!/usr/bin/env bash
# link-vst-shared.sh — Creates/refreshes the symlinks that connect the wine prefixes
# to the shared local VST folders (the resolved VST root, see resolve_vst_root below)
# so that a single plugin installation is visible from everything:
#   - yabridge wine prefix  (~/.wine)      -> Bitwig / REAPER (Windows plugins via yabridge)
#   - ableton-linux prefix  (~/.wine-ableton) -> Ableton Live native Linux (custom wine)
#   - vst-manager prefix    (~/.wine-vst)  -> dedicated install prefix for the VST manager
#
# The plugin files remain IN the root's vst/vst3/clap folders ; the Windows folders
# (Common Files/VST3, Steinberg/VSTPlugins...) become entry points
# to this shared folder. Can be re-run at will (idempotent).
#
# Usage :
#   ./link-vst-shared.sh             # links the two detected prefixes
#   ./link-vst-shared.sh --prefix ~/.wine   # one specific prefix only
#   ./link-vst-shared.sh -y          # non-interactive (no questions)
set -euo pipefail

# Wine's Mono/Gecko installers open a bare white window in the corner of
# the screen when a prefix lacks .NET/HTML support (seen during every
# wine install in setup-ableton.sh and the audio plugin manager). The
# documented ok kill-switch: empty overrides for mscoree (Mono) and
# mshtml (Gecko) — wine never spawns those helper dialogues, and each
# script honors an user-exported override by keeping it.
export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-mscoree,mshtml=}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# VST shared root resolution — (see setup-audio-stack.sh's resolve_vst_root
# for the ordering rationale; this copy must agree exactly with the setup
# script and with lib-audio-plugin-manager-core.sh, otherwise the wine
# prefix links point one way and the tools scan another)
resolve_vst_root() {
  if [[ -n "${AUDIOSTACK_VST_ROOT:-}" ]]; then
    printf '%s\n' "$AUDIOSTACK_VST_ROOT"
    return
  fi
  if find "$HOME/Music/Audio Plugins" -mindepth 2 \( -iname '*.dll' -o -iname '*.vst3' -o -iname '*.clap' \) 2>/dev/null | grep -q .; then
    printf '%s\n' "$HOME/Music/Audio Plugins"
  elif find "$HOME/VST" -mindepth 2 \( -iname '*.dll' -o -iname '*.vst3' -o -iname '*.clap' \) 2>/dev/null | grep -q .; then
    printf '%s\n' "$HOME/VST"
  elif [[ -d "$HOME/Music/Audio Plugins/vst3" ]]; then
    printf '%s\n' "$HOME/Music/Audio Plugins"
  else
    printf '%s\n' "$HOME/VST"
  fi
}
VST_ROOT="$(resolve_vst_root)"
VST_SRC_VST2="$VST_ROOT/vst"; VST_SRC_VST3="$VST_ROOT/vst3"; VST_SRC_CLAP="$VST_ROOT/clap"

G='\033[1;32m'; B='\033[1;34m'; Y='\033[1;33m'; R='\033[1;31m'; N='\033[0m'
msg(){ printf "${B}==>${N} %s\n" "$*"; }
ok(){ printf " ${G}✓${N} %s\n" "$*"; }
warn(){ printf " ${Y}!${N} %s\n" "$*"; }
err(){ printf " ${R}✗${N} %s\n" "$*" >&2; }

PREFIXES=()
while (( $# )); do a="$1"; case "$a" in
  --prefix) shift; PREFIXES+=("$1") ;;
  -y|--yes) YES=1 ;;
  -h|--help) sed -n '19,23p' "$0"; exit 0 ;;
  *) echo "Unknown option: $a" >&2; exit 1 ;;
esac; shift; done

# if no prefix specified: detection of the existing prefixes
if ((${#PREFIXES[@]} == 0)); then
  [[ -d "$HOME/.wine/drive_c" ]] && PREFIXES+=("$HOME/.wine")
  [[ -d "$HOME/.wine-ableton/drive_c" ]] && PREFIXES+=("$HOME/.wine-ableton")
  [[ -d "$HOME/.wine-vst/drive_c" ]] && PREFIXES+=("$HOME/.wine-vst")
fi

[[ -e "$VST_SRC_VST2" || -e "$VST_SRC_VST3" || -e "$VST_SRC_CLAP" ]] || {
  warn "No VST folder found: $VST_SRC_VST2 / $VST_SRC_VST3 / $VST_SRC_CLAP"
  warn "Re-run after installing the audio stack (setup-audio-stack.sh)."
}

# Link tables: relative path in drive_c -> shared VST folder
# (source of truth: the standard Windows installer structure)
declare -A LINKS=(
  ["Program Files/Common Files/VST3"]="$VST_SRC_VST3"
  ["Program Files (x86)/Common Files/VST3"]="$VST_SRC_VST3"
  ["Program Files/Common Files/CLAP"]="$VST_SRC_CLAP"
  ["Program Files (x86)/Common Files/CLAP"]="$VST_SRC_CLAP"
  ["Program Files/Steinberg/VSTPlugins"]="$VST_SRC_VST2"
  ["Program Files (x86)/Steinberg/VSTPlugins"]="$VST_SRC_VST2"
)

echo
msg "Linking the wine prefixes -> shared VST folders"
echo "   Plugin source: $VST_SRC_VST2 / $VST_SRC_VST3 / $VST_SRC_CLAP"

local_prefix_name(){
  if [[ "$1" == "$HOME/.wine" ]]; then echo "yabridge (~/.wine)"
  elif [[ "$1" == "$HOME/.wine-ableton" ]]; then echo "ableton-linux (~/.wine-ableton)"
  elif [[ "$1" == "$HOME/.wine-vst" ]]; then echo "vst-manager (~/.wine-vst)"
  else echo "$1"; fi
}

mkdir -p "$VST_SRC_VST2" "$VST_SRC_VST3" "$VST_SRC_CLAP"

changed=0
for pf in "${PREFIXES[@]}"; do
  [[ -d "$pf/drive_c" ]] || { warn "$(local_prefix_name "$pf") : drive_c missing, ignored"; continue; }
  msg "Prefix: $(local_prefix_name "$pf")"
  for rel in "${!LINKS[@]}"; do
    target="${LINKS[$rel]}"
    [[ -d "$target" ]] || continue
    link="$pf/drive_c/$rel"
    # Already a correct symlink ?
    if [[ -L "$link" && "$(readlink -f "$link")" == "$(readlink -f "$target")" ]]; then
      ok "   already linked: $rel"
      continue
    fi
    # A real folder exists (e.g. installed before) -> we set it aside
    if [[ -d "$link" && ! -L "$link" ]]; then
      bak="$link.orig-$(date +%s)"
      warn "   $rel exists as a real folder -> moved to $(basename "$link").orig"
      mv "$link" "$bak" || { err "   unable to move $link"; continue; }
    fi
    mkdir -p "$(dirname "$link")"
    rm -f "$link"
    ln -s "$target" "$link"
    ok "   $rel -> ${target#"$HOME/"}"
    changed=1
  done
done

if ((changed)); then
  echo
  msg "Refreshing yabridge"
  if command -v yabridgectl >/dev/null; then
    yabridgectl sync >/dev/null 2>&1 && ok "yabridgectl sync OK" || warn "sync inconclusive"
  else
    warn "yabridgectl missing — the yabridge plugins will not be updated."
  fi
fi
echo
ok "Done: the plugins placed in $VST_ROOT/{vst,vst3,clap} are now visible"
ok "by all the DAWs (Bitwig/REAPER via yabridge, Ableton via its own wine prefix)."