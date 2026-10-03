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

# ---------------------------------------------------------------------------
# Vendor support DATA, as opposed to plugin entry points.
#
# The links above answer "where does a host look for plugins". They do not
# answer "where does a plugin look for its own files", and that is a different
# question with a different answer.
#
# A Windows plugin bundle is not self-contained. Several vendors ship a thin
# loader next to the real code:
#
#   * Kilohearts: every kHs*.vst3 is a ~240 KB stub that imports only
#     KERNEL32/USER32/SHELL32/ole32 and calls LoadLibrary for "HeartCore" --
#     a single 74 MB DLL the installer drops at C:\ProgramData\Kilohearts.
#   * iZotope: the bundles in the shared store symlink their Cores/ and
#     Presets/ back to C:\Program Files\iZotope\... . Pro-R and RX read
#     impulse responses from there and report them missing when the path is
#     absent or empty.
#
# Both live INSIDE the prefix, at a path compiled into the binary, so a host
# running under a prefix that lacks them fails in a way that looks like a
# broken install: "Could not load HeartCore", "missing impulse response
# files". Nothing about the plugin files is wrong -- they are in the shared
# folder and correctly linked. The prefix they run in is simply not the prefix
# they were installed into.
#
# So the support data is linked across prefixes too, from the one prefix where
# the vendor actually installed it. A prefix that already holds real content of
# its own is never replaced -- only an absent, empty, or already-linked path is.
# ---------------------------------------------------------------------------

# What a prefix must actually HOLD for a copy of <rel> to be usable in its own
# right. Prints one required path per line, relative to the rel root.
#
# "Has some files" is the wrong test, and it is wrong in the direction that
# keeps the broken copy: a partial vendor install leaves a populated folder
# behind. ~/.wine carried a 33 MB ProgramData/Kilohearts with the installer,
# the cache and the log -- and no HeartCore.core_64, because the run that
# produced it was interrupted or written to the wrong prefix. ~/.wine-ableton
# carried Program Files/iZotope holding only VocalSynth 2, with none of the
# Cores the shared bundles point at. Both look populated and both are exactly
# what makes a plugin report its own data missing.
#
# So the requirement is derived from what the plugins actually dereference: the
# iZotope bundles in the shared store are symlinks into
# "<prefix>/drive_c/Program Files/iZotope/<product>/Cores", so the required
# product names are read back out of those symlinks instead of being guessed.
data_requirement() {
  case "$1" in
    ProgramData/Kilohearts)
      # The one file every kHs loader hands to LoadLibrary.
      printf 'HeartCore.core_64\n' ;;
    *iZotope)
      local link target rel="${1##*/}" seen="" p
      while IFS= read -r -d '' link; do
        target="$(readlink "$link" 2>/dev/null)" || continue
        [[ $target == *"/Program Files/$rel/"* || $target == *"/Program Files (x86)/$rel/"* ]] || continue
        p="${target#*"/Program Files/$rel/"}"; p="${p%%/*}"
        [[ -n $p && $p != */* ]] || continue
        [[ $seen == *"|$p|"* ]] && continue
        seen="$seen|$p|"
        printf '%s\n' "$p"
      done < <(find "$VST_SRC_VST3" -type l -print0 2>/dev/null) ;;
  esac
}

# Is this prefix's own copy of <rel> complete enough to stand on its own?
data_copy_usable() {
  local root="$1" req
  [[ -d "$root" ]] || return 1
  while IFS= read -r req; do
    [[ -n $req ]] || continue
    [[ -e "$root/$req" ]] || return 1
  done < <(data_requirement "$2")
  # A rel with no derivable requirement is only trusted when it is not empty.
  if ! data_requirement "$2" | grep -q .; then
    [[ -n $(ls -A "$root" 2>/dev/null | head -1) ]] || return 1
  fi
  return 0
}

# The prefix that OWNS the vendor data: the one where the vendor installer ran,
# meaning the only prefix whose copy satisfies the vendor's own requirement.
data_owner_prefix() {
  local pf rel
  for rel in "ProgramData/Kilohearts" "Program Files/iZotope" "Program Files (x86)/iZotope"; do
    for pf in "$HOME/.wine-vst" "$HOME/.wine" "$HOME/.wine-ableton"; do
      [[ -d "$pf/drive_c" ]] || continue
      if data_copy_usable "$pf/drive_c/$rel" "$rel"; then
        printf '%s\n' "$pf"; return
      fi
    done
  done
  printf '%s\n' "$HOME/.wine-vst"
}

OWNER_PREFIX="$(data_owner_prefix)"

DATA_RELS=(
  "ProgramData/Kilohearts"
  "Program Files/iZotope"
  "Program Files (x86)/iZotope"
)

link_vendor_data() {
  local pf="$1" rel src dst bak
  [[ -d "$OWNER_PREFIX/drive_c" ]] || return 0
  [[ "$pf" == "$OWNER_PREFIX" ]] && return 0
  for rel in "${DATA_RELS[@]}"; do
    src="$OWNER_PREFIX/drive_c/$rel"
    dst="$pf/drive_c/$rel"
    [[ -d "$src" ]] || continue
    # Already the right link?
    if [[ -L "$dst" && "$(readlink -f "$dst")" == "$(readlink -f "$src")" ]]; then
      ok "   support data already linked: $rel"
      continue
    fi
    # A prefix whose own copy satisfies the vendor's requirement keeps it: this
    # links the plugin support tree, it does not decide which install of a DAW
    # is authoritative. A copy that does NOT satisfy it -- empty, or left behind
    # by an interrupted install -- is set aside rather than kept, because
    # keeping it is what produces "Could not load HeartCore".
    if [[ -d "$dst" && ! -L "$dst" ]]; then
      if data_copy_usable "$dst" "$rel"; then
        ok "   $rel kept: this prefix has a complete copy of its own"
        continue
      fi
      bak="$dst.orig-$(date +%s)"
      warn "   $rel is incomplete here -> moved to $(basename "$bak")"
      mv "$dst" "$bak" || { err "   unable to set aside $dst"; continue; }
    fi
    mkdir -p "$(dirname "$dst")"
    rm -f "$dst"
    ln -s "$src" "$dst"
    ok "   support data linked: $rel -> ${src#"$HOME/"}"
    changed=1
  done
  return 0
}

mkdir -p "$VST_SRC_VST2" "$VST_SRC_VST3" "$VST_SRC_CLAP"

# ---------------------------------------------------------------------------
# Vendor dependency DLLs, made reachable from where the plugin actually loads.
#
# A plugin folder may hold more than plugins. Sonible ships five VST3s plus
# sonible_onnxruntime_v1-15-1.dll, and smartEQ4.vst3 / smartgate.vst3 carry that
# DLL in their PE IMPORT TABLE -- a load-time dependency, not an optional one.
#
# This matters because of where the plugin ends up. In the store the DLL is a
# sibling of the plugin, which is exactly where a Windows loader looks first.
# yabridge does not run the plugin from there: it puts the Windows file inside
# the bundle at Contents/x86_64-win/ and loads THAT. The sibling is now two
# levels up and out of reach, so the dependency stops resolving and the plugin
# never initialises. Two levels of indirection that no amount of reinstalling
# touches, which is why "reinstall it a few times" never changed anything.
#
# It is visible inside the vendor's own layout: the Sonible plugins that DO
# work here (smartchain, smartcomp3) are proper bundles, and they carry the DLL
# in Contents/x86_64-win/ next to the plugin. The flat ones have nowhere to put
# it.
#
# So: every .dll sitting in a plugin's install folder, that is not itself a
# plugin, is linked next to the file yabridge actually loads. Plugins with no
# such dependency -- iZotope and FabFilter import only Wine builtins -- are
# untouched, which is why they never showed the symptom.
# ---------------------------------------------------------------------------

link_plugin_deps() {
  local link dir target dep name
  local -a deps

  # VST3: the Windows file lives in Contents/x86_64-win/ inside the bundle, so
  # the dependency goes into that same directory -- which is dirname of the
  # link, not the link plus a suffix.
  local wdir
  while IFS= read -r -d '' link; do
    [[ -L $link ]] || continue
    target="$(readlink -f "$link" 2>/dev/null)" || continue
    dir="$(dirname "$target")"
    wdir="$(dirname "$link")"
    deps=()
    for dep in "$dir"/*.dll; do
      [[ -f $dep ]] || continue
      deps+=("$dep")
    done
    ((${#deps[@]})) || continue
    for dep in "${deps[@]}"; do
      local dl="$wdir/$(basename "$dep")"
      if [[ -L $dl && "$(readlink -f "$dl")" == "$(readlink -f "$dep")" ]]; then
        continue
      fi
      mkdir -p "$wdir"
      rm -f "$dl"
      ln -s "$dep" "$dl"
      ok "   dependency next to $(basename "$link"): $(basename "$dep")"
      changed=1
    done
  done < <(find "$HOME/.vst3/yabridge" -type l -path '*/Contents/x86_64-win/*' -print0 2>/dev/null)

  # VST2: the wrapper is already flat, so the dependency is a sibling of the
  # .so -- but of the LINK, not of its target, so the link is what we write to.
  while IFS= read -r -d '' link; do
    [[ -L $link ]] || continue
    target="$(readlink -f "$link" 2>/dev/null)" || continue
    dir="$(dirname "$target")"
    for dep in "$dir"/*.dll; do
      [[ -f $dep ]] || continue
      [[ "$(basename "$dep")" == "$(basename "$link")" ]] && continue
      local dl="$(dirname "$link")/$(basename "$dep")"
      if [[ -L $dl && "$(readlink -f "$dl")" == "$(readlink -f "$dep")" ]]; then
        continue
      fi
      rm -f "$dl"
      ln -s "$dep" "$dl"
      ok "   dependency next to $(basename "$link"): $(basename "$dep")"
      changed=1
    done
  done < <(find "$HOME/.vst/yabridge" -maxdepth 2 -type l -name '*.dll' -print0 2>/dev/null)
  return 0
}

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
  link_vendor_data "$pf"
done
link_plugin_deps

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