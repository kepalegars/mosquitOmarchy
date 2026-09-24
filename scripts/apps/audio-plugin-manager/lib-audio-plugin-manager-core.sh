#!/usr/bin/env bash
# lib-audio-plugin-manager-core.sh — mosquito Audio Plugin Manager shared core (install /
# uninstall / standalone launch / prefixes)
#
# All the actual plugin-management logic — everything that doesn't change
# between entry points. NOT an entry point: sourced by `mosquito-audio-plugin-manager-
# actions` (a thin, non-interactive backend — see that file's own header) on
# behalf of `mosquito-audio-plugin-manager-tui`, a real Bubble Tea program (Go,
# tui-go/) that owns every interactive decision itself; and by the stable
# dispatcher `mosquito-audio-plugin-manager` for the flag-driven one-shot actions
# (launch/install/status — see below). The TUI is the ONLY interface: the
# dispatcher routes no-argument launches straight into it (opening a
# terminal if needed), so there is no interface switch anywhere and no
# separate native-mode entry point. Same architecture as the sibling
# mosquito-move-manager module — see its lib-move-manager-core.sh for the
# fuller rationale.
#
#   mosquito-audio-plugin-manager               interactive menu (the TUI)
#   mosquito-audio-plugin-manager install <file>.exe|.msi   install a given installer
#   mosquito-audio-plugin-manager launch <exe>  run a standalone executable (via wine)
#   mosquito-audio-plugin-manager --version | --help
#
# UI PRIMITIVE CONTRACT — when an interactive prompt is genuinely needed
# (the flag-driven paths that run through the shared core), the ui_*
# functions are defined INSIDE this file, guarded by
# ${MOSQUITO_AUDIO_PLUGIN_MANAGER_NATIVE_UI} (set by the dispatcher): the native
# Omarchy overlay (mosquito.confirm, omarchy-menu-input/-select), zenity as
# fallback, plain read on a tty. The actions backend pre-defines its own
# stubs and sources this file with the guard unset, so they keep winning —
# the Go TUI never needs a bash-rendered prompt, every decision is made in
# Go before an action is invoked:
#   ui_confirm MSG [NO_LABEL] [YES_LABEL]   0 = yes/second button, 1 = no/cancel
#   ui_info MSG                             single-OK-button notice
#   ui_input PROMPT [DEFAULT]               echoes entered text; 1 on cancel
#   ui_select [--plain] PROMPT OPTION...    each OPTION "display<TAB>value";
#                                           echoes chosen value; 0/1/2 = chosen/
#                                           cancelled/stdin EOF
#   ui_ready_or_die                         errors out if nothing usable to
#                                           render with, called once, early
#
# State: a machine-scoped log lives next to the script (audio-plugin-manager-state.json). It
# records the CURRENT TRUTH of the installed plugins (which wine prefix owns
# each plugin, which plugin files were created) plus the prefix-move history.
# If the log belongs to another machine, it is ignored (a fresh state is used).
#
# The "displayed executables" feature writes/removes .desktop launchers for the
# standalone executables you choose, so a given VST's standalone appears in the
# Omarchy app menu. Uninstallers and native Windows apps are never offered.
set -euo pipefail

# Wine's Mono/Gecko installers open a bare white window in the corner of
# the screen when a prefix lacks .NET/HTML support (seen during every
# wine install in setup-ableton.sh and the audio plugin manager). The
# documented ok kill-switch: empty overrides for mscoree (Mono) and
# mshtml (Gecko) — wine never spawns those helper dialogues, and each
# script honors an user-exported override by keeping it.
export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-mscoree,mshtml=}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILE_PICKER_MODE_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/audio-plugin-manager/file-picker"
PREFS_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/audio-plugin-manager/prefs"
FIXES_STATE="${XDG_CONFIG_HOME:-$HOME/.config}/audio-plugin-manager/fixes.json"

# ── Paths (same conventions as setup-audio-stack.sh) ────────────────────────
# This is a bare fallback only, for anything that sources the core without
# ever calling load_prefs() (there is no such caller today, but this keeps
# every var non-empty regardless). Every real entry point (the actions
# script, main()) calls load_prefs() early, which re-derives all of this
# from the persisted PLUGINS_ROOT preference via apply_plugins_root() below
# -- AUDIOSTACK_VST_ROOT still wins over everything, same as before, for
# test-fixture isolation. Default root resolution must agree with
# setup-audio-stack.sh's resolve_vst_root / link-vst-shared.sh: the shared
# root is the folder the wine prefixes' "Common Files/VST3|CLAP" symlinks
# point at (~/Music/Audio Plugins on this machine), NOT the legacy ~/VST —
# otherwise an installer writes through the prefix link into the real
# shared folder while this manager scans a path that doesn't exist and
# the whole install/uninstall/visibility chain breaks silently.
if [[ -n "${AUDIOSTACK_VST_ROOT:-}" ]]; then
  VST_ROOT="$AUDIOSTACK_VST_ROOT"
elif find "$HOME/Music/Audio Plugins" -mindepth 2 \( -iname '*.dll' -o -iname '*.vst3' -o -iname '*.clap' \) 2>/dev/null -print -quit | grep -q .; then
  VST_ROOT="$HOME/Music/Audio Plugins"
elif find "$HOME/VST" -mindepth 2 \( -iname '*.dll' -o -iname '*.vst3' -o -iname '*.clap' \) 2>/dev/null -print -quit | grep -q .; then
  VST_ROOT="$HOME/VST"
elif [[ -d "$HOME/Music/Audio Plugins/vst3" ]]; then
  VST_ROOT="$HOME/Music/Audio Plugins"
else
  VST_ROOT="$HOME/VST"
fi
VST_VST2="$VST_ROOT/vst"
VST_VST3="$VST_ROOT/vst3"
VST_CLAP="$VST_ROOT/clap"
BIN_DIR="$HOME/.local/bin"
APPS_DIR="$HOME/.local/share/applications"
DESKTOP_SLUG="vst-standalone"

# The machine-scoped state log lives in the mosquitOmarchy module folder
# (where link-vst-shared.sh sits), NOT in the deployed copy under ~/.local/bin.
# VST_STATE_DIR overrides it for tests / exotic layouts.
if [[ -n "${VST_STATE_DIR:-}" ]]; then
  STATE_DIR="$VST_STATE_DIR"
elif [[ -f "$SCRIPT_DIR/link-vst-shared.sh" ]]; then
  STATE_DIR="$SCRIPT_DIR"
else
  STATE_DIR="$HOME/mosquitOmarchy/scripts/apps/audio-plugin-manager"
fi
STATE_FILE="$STATE_DIR/audio-plugin-manager-state.json"
MACHINE_ID="$(cat /etc/machine-id 2>/dev/null || hostname)"

# ── Colors / messages ───────────────────────────────────────────────────────
G='\033[1;32m'; B='\033[1;34m'; Y='\033[1;33m'; R='\033[1;31m'; N='\033[0m'
msg(){ printf "${B}==>${N} %s\n" "$*"; }
ok(){ printf " ${G}✓${N} %s\n" "$*"; }
warn(){ printf " ${Y}!${N} %s\n" "$*" >&2; }
err(){ printf " ${R}✗${N} %s\n" "$*" >&2; }

# ── Native Omarchy UI (same helpers as the Move manager) ────────────────────
is_tty() { [[ -t 0 ]] && [[ -n ${TERM:-} && ${TERM:-} != dumb ]]; }

# The ui_* prompts are defined ONLY when ${MOSQUITO_AUDIO_PLUGIN_MANAGER_NATIVE_UI}
# is non-empty — that's the flag-driven path, where the stable dispatcher
# routes one-shot flag actions here (launch/install/status) and the shared
# core's own functions still need real prompts. The non-interactive actions
# backend (mosquito-audio-plugin-manager-actions) sources this file with the flag
# unset and pre-defines its own stubs, so they must keep winning there —
# the Go TUI makes every decision in Go before an action is ever invoked.
if [[ -n ${MOSQUITO_AUDIO_PLUGIN_MANAGER_NATIVE_UI:-} ]]; then

ui_confirm() {
  # $1 = message, $2 = optional "no"-button label (default "No"), $3 =
  # optional "yes"-button label (default "Yes") — 0 = yes/second button,
  # 1 = no/cancel. Native square overlay, zenity, or read.
  local msg="$1" no_label="${2:-No}" yes_label="${3:-Yes}"
  if is_tty; then
    local ans
    read -r -p "$msg [Y/N] " ans || return 1
    [[ $ans =~ ^[yYoO]$ ]]
    return
  fi
  if command -v omarchy-shell >/dev/null 2>&1; then
    local mel done s
    mel=$(mktemp); done=$(mktemp); rm -f "$done"
    s=$(jq -cn --arg message "$msg" --arg sel "$mel" --arg donef "$done" \
      --arg noLabel "$no_label" --arg yesLabel "$yes_label" \
      '{message:$message,selectionFile:$sel,doneFile:$donef,noLabel:$noLabel,yesLabel:$yesLabel}')
    omarchy-shell shell summon mosquito.confirm "$s" >/dev/null 2>&1 || true
    while [[ ! -e $done ]]; do sleep 0.05; done
    local ret=1
    [[ $(cat "$mel" 2>/dev/null) == yes ]] && ret=0
    rm -f "$mel" "$done"
    return $ret
  fi
  if command -v zenity >/dev/null 2>&1; then
    zenity --question --title="mosquito Audio Plugin Manager" --text="$msg" 2>/dev/null || return 1
    return 0
  fi
  warn "No GUI to ask — continuing as 'no'."
  return 1
}

ui_info() {
  # $1 = message(s). A native notice with a single OK button (Enter / Escape /
  # click all dismiss it). Falls back to a plain print + Enter on a tty.
  if is_tty; then
    printf '%s\n' "$1"
    read -rp "Press Enter to continue… " || true
    return 0
  fi
  if command -v omarchy-shell >/dev/null 2>&1; then
    local mel done
    mel=$(mktemp); done=$(mktemp); rm -f "$done"
    omarchy-shell shell summon mosquito.confirm "$(jq -cn --arg message "$1" --arg sel "$mel" --arg donef "$done" \
      '{message:$message,selectionFile:$sel,doneFile:$donef,okOnly:true}')" >/dev/null 2>&1 || true
    while [[ ! -e $done ]]; do sleep 0.05; done
    rm -f "$mel" "$done"
    return 0
  fi
  if command -v zenity >/dev/null 2>&1; then
    zenity --info --title="$1" --text="$1" 2>/dev/null || true
    return 0
  fi
  printf '%s\n' "$1"
  return 0
}

ui_input() {
  # $1 = prompt, $2 = default. Echoes the entered text; returns 1 on cancel.
  if is_tty; then
    printf '%s\n> ' "$1" >&2
    local ans
    read -r ans || return 1
    printf '%s\n' "$ans"
    return 0
  fi
  if command -v omarchy-menu-input >/dev/null 2>&1; then
    local out
    out=$(omarchy-menu-input "$1" --width 560 2>/dev/null || true)
    printf '%s\n' "$out"
    return 0
  fi
  if command -v zenity >/dev/null 2>&1; then
    zenity --entry --title="$1" --text="$1" --entry-text="${2:-}" 2>/dev/null || return 1
    return 0
  fi
  warn "No GUI input available — using default."
  printf '%s\n' "${2:-}"
}

ui_select() {
  # Usage: ui_select [--plain] <prompt> <option>...
  # Each option is "display<TAB>value". --plain omits the subtext.
  # Echoes the value of the chosen option; returns 1 on cancel, 2 on EOF.
  local plain=false
  if [[ ${1:-} == --plain ]]; then plain=true; shift; fi
  local prompt="$1"; shift
  local -a displays=() values=() native_opts=()
  local opt d v i
  for opt in "$@"; do
    d="${opt%%$'\t'*}"
    if [[ $opt == *$'\t'* ]]; then v="${opt#*$'\t'}"; else v="$d"; fi
    displays+=("$d"); values+=("$v")
    if $plain; then native_opts+=($'\t'"$d"); else native_opts+=($'\t'"$d"$'\t'"$v"); fi
  done

  if is_tty; then
    echo "$prompt" >&2
    for i in "${!displays[@]}"; do echo "  $((i+1)). ${displays[$i]}" >&2; done
    local n
    read -rp "> " n || return 2
    if [[ $n =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#displays[@]} )); then
      printf '%s\n' "${values[$((n-1))]}"
      return 0
    fi
    return 1
  fi

  if command -v omarchy-menu-select >/dev/null 2>&1; then
    local out label
    out=$(omarchy-menu-select "$prompt" "${native_opts[@]}" -- --width 720 --maxheight 520 2>/dev/null || true)
    if [[ -n $out ]]; then
      label="${out%%$'\t'*}"
      for i in "${!displays[@]}"; do
        if [[ ${displays[$i]} == "$label" ]]; then
          printf '%s\n' "${values[$i]}"
          return 0
        fi
      done
      printf '%s\n' "${out#*$'\t'}"
      return 0
    fi
  fi

  if command -v zenity >/dev/null 2>&1; then
    local args=() chosen
    for i in "${!displays[@]}"; do args+=("FALSE" "${displays[$i]}"); done
    chosen=$(zenity --list --title="$prompt" --column="Choice" --radiolist "${args[@]}" 2>/dev/null || true)
    if [[ -n $chosen ]]; then
      for i in "${!displays[@]}"; do
        [[ ${displays[$i]} == "$chosen" ]] && { printf '%s\n' "${values[$i]}"; return 0; }
      done
    fi
    return 1
  fi
  return 1
}

ui_ready_or_die() {
  is_tty && return 0
  command -v omarchy-menu-select >/dev/null 2>&1 && return 0
  command -v zenity >/dev/null 2>&1 && return 0
  err "no interactive UI available (not a tty, no Omarchy menu, no zenity)."
  exit 1
}

fi

# ── State log (machine-scoped current truth) ────────────────────────────────
state_compatible() {
  # The log is only valid on the machine that created it.
  [[ -f $STATE_FILE ]] || return 1
  [[ "$(jq -r .machine "$STATE_FILE" 2>/dev/null)" == "$MACHINE_ID" ]]
}

state_init() {
  # Ensures the state file exists for THIS machine. If a foreign log is found
  # (e.g. the repo was copied to another machine), it is ignored and replaced.
  if [[ ! -d $STATE_DIR ]]; then
    mkdir -p "$STATE_DIR"
  fi
  if ! state_compatible; then
    if [[ -f $STATE_FILE ]]; then
      warn "state log belongs to another machine — starting fresh ($STATE_FILE)"
    fi
    printf '{"machine":%s,"plugins":{},"history":[]}\n' \
      "$(jq -cn --arg m "$MACHINE_ID" '$m')" > "$STATE_FILE"
  fi
}

state_plugin_prefix() {
  # $1 = plugin key. Echoes the wine prefix owning it, or empty.
  local key="$1"
  state_compatible || return 0
  jq -r --arg k "$key" '.plugins[$k].prefix // empty' "$STATE_FILE" 2>/dev/null
}

state_plugin_files() {
  # $1 = plugin key. Emits one file per line (current truth of created files).
  local key="$1"
  state_compatible || return 0
  jq -r --arg k "$key" '.plugins[$k].files[]?' "$STATE_FILE" 2>/dev/null
}

state_plugin_standalones() {
  # $1 = plugin key. Emits the standalone executables registered for it.
  local key="$1"
  state_compatible || return 0
  jq -r --arg k "$key" '.plugins[$k].standalones[]?' "$STATE_FILE" 2>/dev/null
}

state_list_keys() {
  # Emits the plugin keys (current truth: what the log says is installed).
  state_compatible || return 0
  jq -r '.plugins | keys[]' "$STATE_FILE" 2>/dev/null
}

state_list_standalones() {
  # Emits every standalone executable the manager registered (state truth).
  # Only these are offered for launching / menu visibility — programs put into
  # wine by other means (regular installs, bottles, manual copies…) never show
  # up, so the toggle list can't grow with foreign executables.
  state_compatible || return 0
  jq -r '.plugins[].standalones[]?' "$STATE_FILE" 2>/dev/null
}

state_has() {
  # $1 = plugin key. Returns 0 when installed (per the log).
  local key="$1"
  state_compatible || return 1
  jq -e --arg k "$key" '.plugins | has($k)' "$STATE_FILE" >/dev/null 2>&1
}

state_set_prefix() {
  # $1 = plugin key, $2 = prefix. Updates the owning prefix of a plugin.
  local key="$1" prefix="$2" tmp
  state_compatible || state_init
  tmp=$(mktemp)
  jq --arg k "$key" --arg p "$prefix" \
    '.plugins[$k].prefix = $p' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

state_add_history() {
  # $1 = plugin key, $2 = from prefix, $3 = to prefix.
  local key="$1" from="$2" to="$3" tmp
  state_compatible || state_init
  tmp=$(mktemp)
  jq --arg k "$key" --arg f "$from" --arg t "$to" --arg at "$(date '+%Y-%m-%d %H:%M')" \
    '.history += [{"plugin":$k,"from":$f,"to":$t,"at":$at}]' "$STATE_FILE" > "$tmp" \
    && mv "$tmp" "$STATE_FILE"
}

state_history_text() {
  # Emits history lines as "plugin  :  prefix1 → prefix2".

  state_compatible || return 0
  jq -r '.history[] | "\(.plugin)  :  \(.from) → \(.to)"' "$STATE_FILE" 2>/dev/null
}

state_register_install() {
  # $1 = plugin key, $2 = prefix. Registers an installed plugin with the files
  # created by the installer (the truth of what exists now). The remaining
  # arguments are the "path<TAB>type" lines from scan_plugins — paths only.
  local key="$1" prefix="$2" tmp
  local -a files=() all=()
  local item f seen=""
  shift 2
  for item in "$@"; do files+=("${item%%$'\t'*}"); done
  # Preserve previously-known files for this key (re-installs keep old truth)
  # plus the freshly created ones, deduplicated.
  if state_compatible; then
    while IFS= read -r f; do [[ -n $f ]] && all+=("$f"); done <<< "$(state_plugin_files "$key")"
  fi
  all+=("${files[@]}")
  tmp=$(mktemp)
  jq -S --arg k "$key" --arg p "$prefix" \
    --argjson files "$(printf '%s\n' "${all[@]}" | grep -v '^$' | jq -R . | jq -s 'unique')" \
    '.plugins[$k] = {prefix:$p, files:$files}' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

state_register_standalone() {
  # $1 = plugin key, $2 = standalone exe path (registered for standalone use).
  local key="$1" exe="$2" tmp
  local -a cur=() all=()
  local f seen=""
  if state_compatible; then
    while IFS= read -r f; do [[ -n $f ]] && all+=("$f"); done <<< "$(state_plugin_standalones "$key")"
  fi
  all+=("$exe")
  tmp=$(mktemp)
  jq -S --arg k "$key" \
    --argjson list "$(printf '%s\n' "${all[@]}" | grep -v '^$' | jq -R . | jq -s 'unique')" \
    '.plugins[$k].standalones = $list' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

state_remove() {
  # $1 = plugin key. Removes the plugin from the state (current truth).
  local key="$1" tmp
  state_compatible || return 0
  tmp=$(mktemp)
  jq --arg k "$key" 'del(.plugins[$k])' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

state_clear_files() {
  # $1 = plugin key. Keeps the plugin in the log (key + prefix stay
  # "installed") but empties its tracked files, so reconcile() stops
  # reporting it as "in the log but NOT on this computer".
  local key="$1" tmp
  state_compatible || state_init
  tmp=$(mktemp)
  jq --arg k "$key" '.plugins[$k].files = []' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

purge_missing_keys() {
  # $1... = plugin keys. Removes the plugin everywhere (log + any standalone
  # .desktop menu entry it generated), for the "remove everywhere" choice.
  local k base f slug
  for k in "$@"; do
    while IFS=$'\t' read -r base f; do
      [[ -n $f ]] || continue
      slug="$APPS_DIR/$DESKTOP_SLUG-$(basename "${base%.exe}" | tr ' ' '-' | tr -cd '[:alnum:]-').desktop"
      rm -f "$slug"
    done <<< "$(state_plugin_standalones "$k" 2>/dev/null)"
    state_remove "$k" >/dev/null 2>&1 || true
  done
}

keep_missing_keys() {
  # $1... = plugin keys. "Add to log": keep the shared-log entry (it belongs
  # to another machine or will be synced back), but stop flagging it here.
  local k
  for k in "$@"; do
    state_clear_files "$k"
  done
}

# ── Wine prefixes (auto-detected on every run) ──────────────────────────────
scan_prefixes() {
  # Emits every wine prefix (any ~/.wine* directory holding a drive_c).
  local p
  for p in "$HOME"/.wine*; do
    [[ -d "$p/drive_c" ]] && printf '%s\n' "$p"
  done
  if [[ -n "${AUDIOSTACK_VST_ROOT:-}" ]]; then
    for p in "${AUDIOSTACK_VST_ROOT:-}"/*.wine*; do
      [[ -d "$p/drive_c" ]] && printf '%s\n' "$p"
    done
  fi
}

WINE_PREFIXES=()
while IFS= read -r p; do
  [[ -n $p ]] && WINE_PREFIXES+=("$p")
done < <(scan_prefixes | sort -u)

default_prefix() {
  # The prefix used when the user keeps the "same prefix" at install.
  # Prefer a prefix that already owns installed plugins (state truth). When
  # nothing is installed yet, always propose the dedicated ~/.wine-vst — never
  # reuse an existing generic prefix (~/.wine etc.), so plugin installs never
  # pollute the prefixes used by regular wine applications.
  local k p
  while IFS= read -r k; do
    [[ -n $k ]] || continue
    p="$(state_plugin_prefix "$k")"
    if [[ -n $p ]]; then printf '%s\n' "$p"; return 0; fi
  done <<< "$(state_list_keys)"
  printf '%s\n' "$HOME/.wine-vst"
}

# ── Detection helpers ───────────────────────────────────────────────────────
is_uninstaller() {
  # $1 = basename. unins000.exe, Uninstall.desktop, uninstaller… never offered.
  local b="${1,,}"
  [[ $b == unins* || $b == uninstall* || $b == *unins000* || $b == uninstaller* ]]
}

# Native Windows apps (iexplore, wmplayer, wordpad…), browser wheels (all Edge /
# WebView2 flavors), Copilot, anything "witch", and Guitar Pro (guitarpro.exe /
# gp7/8 etc.) are never VST standalones and are hidden automatically from every
# prefix (scan + standalone log), including future ones.
is_native_win_app() {
  local b="${1,,}" stem
  b="$(basename "$b")"
  stem="${b%.exe}"
  case "$stem" in
    iexplore|iexplorer|wmplayer|wordpad|write|notepad|mspaint|calc|magnify|osk|cmd|powershell|pwsh|regedit|explorer|rundll32|taskmgr|control|cmd.exe|*witch*|*edge*|*webview2*|*copilot*|*guitarpro*|guitar*pro*|gp[0-9]*)
      return 0 ;;
  esac
  return 1
}

# Scan ~/VST for plugin files. Emits "path<TAB>type" lines (type = format).
# No depth cap (same as the install detection) so bundle-depth installs
# (VST3/…/Plugin.vst3/Contents/…) show up in every list.
scan_plugins() {
  local f ext base
  # Also matches a hidden plugin (see toggle_vst_plugin_hidden(): renamed
  # with a trailing ".hidden" so yabridge/a DAW never sees it) -- the type
  # is read off the real extension, one level in from the ".hidden" suffix.
  find "$VST_VST2" "$VST_VST3" "$VST_CLAP" \
    -type f \( \
    -iname '*.dll' -o -iname '*.vst3' -o -iname '*.clap' -o -iname '*.so' \
    -o -iname '*.dll.hidden' -o -iname '*.vst3.hidden' -o -iname '*.clap.hidden' -o -iname '*.so.hidden' \
    \) 2>/dev/null | while IFS= read -r f; do
    base="${f%.hidden}"
    ext="${base##*.}"; ext="${ext,,}"
    case "$ext" in
      dll)   printf '%s\tvst2\n' "$f" ;;
      vst3)  printf '%s\tvst3\n' "$f" ;;
      clap)  printf '%s\tclap\n' "$f" ;;
      so)    printf '%s\tso\n' "$f" ;;
    esac
  done
  return 0
}

# Scan the wine prefixes for program folders that contain an uninstaller
# (i.e. properly installed Windows apps). Emits one line per folder.
scan_wine_programs() {
  local p d
  for p in "${WINE_PREFIXES[@]}"; do
    for d in "$p/drive_c/Program Files"/* "$p/drive_c/Program Files (x86)"/*; do
      [[ -d "$d" ]] || continue
      find "$d" -maxdepth 1 -type f \( -iname 'unins*.exe' -o -iname 'uninstall*.exe' \) \
        2>/dev/null | grep -q . && printf '%s\n' "$d"
    done
  done
}

# yabridge chainloader present next to a plugin file?
has_bridge() {
  # $1 = plugin file. A sibling .so with the same stem means it is bridged.
  local stem
  stem="${1%.*}"
  [[ -e "$stem.so" || -e "$1.so" ]]
}

# Is the current plugin detection exposing broken files (empty / bogus install)?
plugin_healthy() {
  local f="$1"
  [[ -s "$f" ]]
}

# The vendor/product label for a plugin file (relative to the VST root).
plugin_label() {
  local f="$1" rel
  rel="${f#$VST_ROOT/}"
  printf '%s\n' "${rel%/*}"
}

# The group (vendor folder) a plugin belongs to, without the vst/vst3/clap
# prefix, so same-source plugins cluster under one name.
plugin_group_label() {
  local f="$1" rel
  rel="$(plugin_label "$f")"
  case "$rel" in
    vst/*|vst3/*|clap/*) rel="${rel#*/}" ;;
  esac
  printf '%s\n' "${rel:-/}"
}

# The plugin key (a stable id) for a plugin file. Based on the vendor/filename
# so install and uninstall agree even if the list changes.
plugin_key() {
  local f="$1" rel base
  # A hidden plugin (see toggle_vst_plugin_hidden()) is the exact same
  # tracked plugin under a renamed path -- strip the suffix first so its
  # key matches the state entry recorded when it was installed, whether or
  # not it's currently hidden.
  f="${f%.hidden}"
  # Prefer the top-level structure: vendor + filename without the extension.
  rel="${f#$VST_ROOT/}"
  # Drop the leading format folder (vst/ vst3/ clap/) so "vst3/Vendor/Plugin.vst3"
  # keys consistently as "Vendor/Plugin" whether it lives in vst3 or clap.
  base="$(basename "$rel")"; base="${base%.*}"
  case "$rel" in
    vst/*|vst3/*|clap/*) rel="${rel#*/}" ;;
  esac
  case "$rel" in
    */*) printf '%s\n' "${rel%/*}/$base" ;;
    *)   printf '%s\n' "$base" ;;
  esac
}

# ── Install ─────────────────────────────────────────────────────────────────
# Point a wine prefix's standard install locations at the shared ~/VST folders
# (the same table as link-vst-shared.sh) so an installer that writes to
# "Program Files/Common Files/VST3" (or CLAP / Steinberg/VSTPlugins) lands
# directly inside the tracked folders and is detected after the run. This must
# happen BEFORE the installer launches — the shared linking in post_install is
# too late for the new-file detection. Idempotent.
link_prefix_to_vst() {
  local prefix="$1" pair rel target link
  [[ -d "$prefix/drive_c" ]] || return 0
  local -a pairs=(
    "Program Files/Common Files/VST3:$VST_VST3"
    "Program Files (x86)/Common Files/VST3:$VST_VST3"
    "Program Files/Common Files/CLAP:$VST_CLAP"
    "Program Files (x86)/Common Files/CLAP:$VST_CLAP"
    "Program Files/Steinberg/VSTPlugins:$VST_VST2"
    "Program Files (x86)/Steinberg/VSTPlugins:$VST_VST2"
  )
  for pair in "${pairs[@]}"; do
    rel="${pair%%:*}"; target="${pair#*:}"
    link="$prefix/drive_c/$rel"
    if [[ -L $link ]] && [[ "$(readlink -f "$link")" == "$(readlink -f "$target")" ]]; then
      continue
    fi
    if [[ -d $link && ! -L $link ]]; then
      # A real folder from a previous (unlinked) install or from wine itself —
      # move its content into the shared folder instead of losing it, then link.
      warn "found a real '$rel' folder in $prefix — moving its content into $(basename "$target") and linking it to the shared folder"
      mkdir -p "$target"
      find "$link" -mindepth 1 -maxdepth 1 -exec mv -t "$target" -- {} + 2>/dev/null || true
      rm -rf "$link"
    fi
    mkdir -p "$(dirname "$link")"
    rm -f "$link"
    ln -s "$target" "$link"
    ok "linked $prefix → $rel → shared $(basename "$target")"
  done
}

# ─── Detection helpers (mtime-independent) ────────────────────────────────
# Every plugin file currently in the shared folders.
list_shared_plugin_files() {
  find "$VST_VST2" "$VST_VST3" "$VST_CLAP" \
    -type f \( -iname '*.dll' -o -iname '*.vst3' -o -iname '*.clap' \) \
    -printf '%p\n' 2>/dev/null | sort
}

# Every plugin-like file inside the prefix (used to recover plugins an
# installer dropped into a private folder instead of the shared VST dirs).
list_prefix_plugin_files() {
  local prefix="$1"
  [[ -d $prefix/drive_c ]] || return 0
  find "$prefix/drive_c" \
    -type f \( -iname '*.dll' -o -iname '*.vst3' -o -iname '*.clap' \) \
    -printf '%p\n' 2>/dev/null | sort
}

# Strong Sonible / "smart chain" / SmartEQ detection on the installer path.
is_sonible_installer() {
  local f="$1" low
  low="$(printf '%s' "$f" | tr '[:upper:]' '[:lower:]')"
  case "$low" in
    *sonible*|*smartchain*|*smart\ chain*|*smarteq*|*smart:eq*|*smart_eq*) return 0 ;;
  esac
  return 1
}

# Idempotent: install the MFC42 runtime (mfc42.dll/mfc42u.dll) into a prefix
# when missing. winetricks caches the download; safe to call every time.
ensure_mfc42() {
  local prefix="$1"
  if ls "$prefix"/drive_c/windows/syswow64/mfc42u.dll \
        "$prefix"/drive_c/windows/system32/mfc42u.dll >/dev/null 2>&1; then
    ok "MFC42u already present in $prefix"
    return 0
  fi
  msg "Pre-installation patch: installing MFC42 (winetricks mfc42) into $prefix"
  if WINEPREFIX="$prefix" winetricks -q mfc42 >/dev/null 2>&1 \
     || WINEPREFIX="$prefix" winetricks mfc42; then
    ok "MFC42 patch applied (MFC42/MFC42u present in $prefix)"
  else
    warn "winetricks mfc42 failed — the Sonible installer may still hit the ISSKINU.DLL error."
  fi
}

# match_installed_plugin <installer-path> — when an installer produced NO new
# file because the plugin is ALREADY installed (a reinstall/update, or files
# written with archive timestamps that pre-date the run), match the installer
# to existing plugin files by name tokens so the run still counts as success.
# Tokens come from the installer filename and its parent folder, minus generic
# installer words and pure numbers (e.g. "Install_Xfer_Serum2_2.0.16.exe" in
# ".../Serum 2/WIN/" -> "serum2" / "serum").
match_installed_plugin() {
  local installer="$1" dir base tok
  base="$(basename -- "$installer")"; base="${base%.*}"
  dir="$(basename -- "$(dirname -- "$installer")")"
  local -a toks=()
  _mt_add_tokens() {
    local raw="$1" t
    raw="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr -c '[:alnum:]' ' ')"
    for t in $raw; do
      case "$t" in
        install|installer|setup|win|windows|win64|win32|x64|x86|amd64|no|password|exe|v|version|r2r|rls|mac|linux|dmg|zip|audio|plugins?|vst|vst3|vst2|clap) continue ;;
      esac
      [[ "$t" =~ ^[0-9]+([.][0-9]+)*$ ]] && continue
      (( ${#t} >= 4 )) && toks+=("$t")
    done
  }
  _mt_add_tokens "$base"
  _mt_add_tokens "$dir"
  ((${#toks[@]})) || return 0
  # Longest tokens first: a more specific match wins.
  local -a sorted
  mapfile -t sorted < <(printf '%s\n' "${toks[@]}" | awk '{print length, $0}' | sort -rn | cut -d' ' -f2- | awk '!seen[$0]++')
  local f low best=0
  local -a hits=()
  while IFS= read -r f; do
    low="$(printf '%s' "$f" | tr '[:upper:]' '[:lower:]')"
    for tok in "${sorted[@]}"; do
      (( ${#tok} > best )) || continue
      if [[ $low == *"$tok"* ]]; then
        hits+=("$f")
        [[ ${#tok} -gt best ]] && best=${#tok}
        break
      fi
    done
  done < <(list_shared_plugin_files)
  # Keep only hits matching the MOST specific token length.
  for f in "${hits[@]:-}"; do
    [[ -n $f ]] || continue
    low="$(printf '%s' "$f" | tr '[:upper:]' '[:lower:]')"
    for tok in "${sorted[@]}"; do
      [[ ${#tok} == "$best" ]] || continue
      [[ $low == *"$tok"* ]] && { printf '%s\n' "$f"; break; }
    done
  done | sort -u
}

install_plugin() {
  local file="$1" wine_prefix="${2:-$(default_prefix)}" f dst base
  # The prefix must point at the shared folders BEFORE the installer runs,
  # otherwise the new files land inside the prefix and detection misses them.
  link_prefix_to_vst "$wine_prefix"

  # mtime-INDEPENDENT detection: snapshot the FILE LISTS (shared folders + the
  # whole prefix) before the installer runs, then diff the sets after. Using
  # `find -newer <stamp>` missed installers that write files with an OLD mtime
  # (archive timestamps) — exactly the Serum 2 "No new VST file detected" case.
  local before after before_pfx after_pfx
  before="$(mktemp)"; after="$(mktemp)"
  before_pfx="$(mktemp)"; after_pfx="$(mktemp)"
  list_shared_plugin_files > "$before" 2>/dev/null || true
  list_prefix_plugin_files "$wine_prefix" > "$before_pfx" 2>/dev/null || true

  # ── PRE-INSTALLATION PATCH (automatic, no prompt) ─────────────────────
  # Sonible / "smart chain" installers are Inno Setup builds using the
  # ISSKINU.DLL skin runtime, which needs native MFC42u — without it the
  # installer dies with "Runtime error: Cannot import dll: …is-XXXX.tmp  # ISSKINU.DLL" before drawing anything. Strong detection: the installer's
  # name or its folder mentions sonible / smart chain / smarteq. The patch
  # only adds the mfc42 runtime (winetricks-managed, idempotent, cached).
  if is_sonible_installer "$file"; then
    ensure_mfc42 "$wine_prefix"
  fi

  msg "Running $file through wine (prefix: $wine_prefix — the installer shows its own window)…"
  WINEPREFIX="$wine_prefix" wine "$file" || warn "(wine exited with a non-zero code — continuing)"

  list_shared_plugin_files > "$after" 2>/dev/null || true
  list_prefix_plugin_files "$wine_prefix" > "$after_pfx" 2>/dev/null || true

  # .aux support files = files that appear in the shared folders or the prefix.
  local -a auxfiles=()
  while IFS= read -r f; do [[ -n $f ]] && auxfiles+=("$f"); done < <(
    {
      comm -13 "$before" "$after"
      comm -13 "$before_pfx" "$after_pfx"
    } 2>/dev/null | grep -i '\.aux$' | sort -u
  )
  if ((${#auxfiles[@]})); then
    msg "Detected ${#auxfiles[@]} new .aux file(s)"
    for f in "${auxfiles[@]}"; do rm -f "$f" && ok "deleted $(basename "$f")"; done
  fi

  local -a newfiles=()
  while IFS= read -r f; do [[ -n $f ]] && newfiles+=("$f"); done < <(
    comm -13 "$before" "$after" 2>/dev/null | grep -iE '\.(dll|vst3|clap)$' | sort -u
  )

  if ((${#newfiles[@]} == 0)); then
    # The installer wrote nothing into the shared folders: scan the WHOLE
    # prefix for files that appeared during this run (set difference, not
    # mtime). Exclude Windows/Temp/staging and obvious system DLLs, then
    # treat size > 450 KB as a real plugin bundle and copy it into place.
    local -a cand=() f_pkg b size
    while IFS= read -r f; do
      [[ -n $f ]] || continue
      case "$f" in
        *"/Temp/"*|*"/temp/"*|*"is-"*.tmp*|*"IS-"*.tmp*) continue;;
        *"/drive_c/windows/"*|*"/drive_c/Windows/"*) continue;;
        *"/drive_c/ProgramData/"*"/Temp/"*) continue;;
        *"/drive_c/users/"*"/Temp/"*) continue;;
      esac
      b="$(basename -- "$f")"
      case "${b,,}" in
        ntdll.dll|kernel32.dll|user32.dll|gdi32.dll|advapi32.dll|shell32.dll|ole32.dll|oleaut32.dll|combase32.dll|comdlg32.dll|version.dll|setupapi.dll|wininet.dll|ws2_32.dll|winmmbase.dll|winmm.dll|msvcrt.dll|msvcp140.dll|msvcp100.dll|msvcp120.dll|msvcp71.dll|msvcrt90.dll|api-ms-win-*|ucrtbase.dll|vcruntime140*.dll) continue;;
      esac
      size=$(stat -c '%s' -- "$f" 2>/dev/null || echo 0)
      (( size > 450000 )) || continue
      cand+=("$f")
    done < <(comm -13 "$before_pfx" "$after_pfx" 2>/dev/null | grep -iE '\.(dll|vst3|clap)$' | sort -u)

    if ((${#cand[@]} > 0)); then
      msg "Detected ${#cand[@]} new plugin file(s) inside the prefix (outside the shared folders):"
      printf '    %s\n' "${cand[@]}" >&2
      for f_pkg in "${cand[@]}"; do
        base="$(basename "$f_pkg")"
        case "${f_pkg##*.}" in vst3|VST3) dst="$VST_VST3";; clap|CLAP) dst="$VST_CLAP";; *) dst="$VST_VST2";; esac
        mkdir -p "$dst"
        cp -a "$f_pkg" "$dst/" 2>/dev/null || true
        ok "$base recovered from the prefix → $dst/"
        newfiles+=("$dst/$base")
      done
    fi
  fi

  rm -f "$before" "$after" "$before_pfx" "$after_pfx"


  if ((${#newfiles[@]} == 0)); then
    # Reinstall/update: the plugin is already there and the installer
    # rewrote it in place (possibly with an old archive mtime), so no NEW
    # path appeared. Match the installer to the existing plugin(s).
    local -a matched=()
    while IFS= read -r f; do [[ -n $f ]] && matched+=("$f"); done < <(match_installed_plugin "$file")
    if ((${#matched[@]})); then
      msg "Installer produced no NEW file — matching already-installed plugin(s) found:"
      for f in "${matched[@]}"; do
        ok "$(basename "$f") (already installed — matched to $(basename "$file"))"
        newfiles+=("$f")
      done
    fi
  fi

  if ((${#newfiles[@]} == 0)); then
    # An install that produced NO plugin file is a FAILED (or aborted by
    # the user) install — not a successful no-op. The TUI reads the exit
    # status to decide between "installed ✓ / see log" and
    # "installation failed/aborted — see log"; silently returning 0
    # here painted "✓ success" over a wine window the user had just
    # cancelled. Exit 1 with the same explanation; the state file stays
    # untouched (nothing was installed).
    warn "No new VST file detected in $VST_ROOT — the install likely did not complete (or was cancelled)."
    register_standalones_from_prefix "$wine_prefix"
    return 1
  fi
  for f in "${newfiles[@]}"; do
    base="$(basename "$f")"
    case "${f##*.}" in vst3|VST3) dst="$VST_VST3";; clap|CLAP) dst="$VST_CLAP";; *) dst="$VST_VST2";; esac
    rel="${f#$dst/}"; rel="${rel%/*}"
    if [[ $rel == "$f" ]]; then
      # Not under the right shared folder yet (the installer dropped it
      # somewhere else in the prefix) — copy it into place.
      rel=""
      mkdir -p "$dst"
      if [[ -d "$f" ]]; then cp -a "$f" "$dst/"; else cp -n "$f" "$dst/"; fi
      ok "$base → $dst/"
    else
      # Already inside the shared folder (the prefix links into it) — done.
      ok "$base → $dst/$rel (already in the shared folder)"
    fi
  done
  state_register_install "$(plugin_key "${newfiles[0]}")" "$wine_prefix" "${newfiles[@]}"
  register_standalones_from_prefix "$wine_prefix"
  post_install
  # Known per-plugin fixes (e.g. CrispyTuner's editor input) are applied on
  # first install so the GUI works out of the box; state + Lua block are
  # idempotent, so re-installing never duplicates rules.
  local fixname; fixname="$(basename "${newfiles[0]}")"; fixname="${fixname%%.*}"
  apply_known_fixes_for "$fixname"
  # Hand the freshly installed plugin to the caller in the same
  # self-describing shape list-all-plugins uses, then offer any remaining
  # plugin-scope fixes. The line is plain text on stdout so the Go TUI's
  # Runner can pick it up when this runs through the actions backend.
  local installed_value
  case "${newfiles[0]}" in
    "$VST_VST3"/*) installed_value="vst:vst3:${newfiles[0]}" ;;
    "$VST_CLAP"/*) installed_value="vst:clap:${newfiles[0]}" ;;
    *)             installed_value="vst:vst2:${newfiles[0]}" ;;
  esac
  printf 'installed-plugin: %s\n' "$installed_value"
  propose_fixes_after_install "$installed_value"
}

register_standalones_from_prefix() {
  # After an install, register the standalone executables of the prefix that
  # are not native Windows apps, so the "standalone" category stays accurate.
  local prefix="$1"
  [[ -d "$prefix/drive_c" ]] || return 0
  local f e key
  for f in "$prefix/drive_c/Program Files" "$prefix/drive_c/Program Files (x86)"; do
    [[ -d "$f" ]] || continue
    while IFS= read -r e; do
      [[ -n $e ]] || continue
      is_uninstaller "$(basename "$e")" && continue
      is_native_win_app "$(basename "$e")" && continue
      key="$(basename "$e")"; key="${key%.exe}"
      state_register_standalone "$key" "$e"
    done < <(find "$f" -maxdepth 3 -type f -iname '*.exe' 2>/dev/null)
  done
}

post_install() {
  if command -v yabridgectl >/dev/null; then
    yabridgectl sync >/dev/null 2>&1 && ok "yabridgectl sync OK"
  fi
  local linker="$SCRIPT_DIR/link-vst-shared.sh"
  if [[ ! -x $linker ]]; then
    # Deployed copy: resolve the module folder from the repo path convention.
    linker="$HOME/mosquitOmarchy/scripts/apps/audio-plugin-manager/link-vst-shared.sh"
  fi
  if [[ -x $linker ]]; then AUDIOSTACK_VST_ROOT="$VST_ROOT" bash "$linker" >/dev/null 2>&1 && ok "VST prefixes linked"; fi
}

# The Program Files path matching a given plugin filename (any prefix), or empty.
wine_source_of() {
  # Emits the first Program Files copy of a file across all known prefixes.
  # Returns non-zero when nothing is found (the caller relies on this to
  # decide whether a plugin belongs to a wine program folder or is a
  # standalone drop).
  #
  # -L matters: the wine prefixes' "Program Files/Common Files/VST3|CLAP"
  # and "Steinberg/VSTPlugins" paths are SYMLINKS into the shared program
  # root (~/Music/Audio Plugins/...). A plain `find -type f` does not follow
  # directory symlinks by default, so every plugin installed through the
  # linked folders (the normal path for an install) appeared UNOWNED and
  # would not group under its installer folder in the TUI's uninstall tree
  # (the user's "no way to open the crispy audio folder, plugins outside").
  local f="$1" p src=""
  for p in "${WINE_PREFIXES[@]}"; do
    src="$(find -L "$p/drive_c/Program Files" "$p/drive_c/Program Files (x86)" \
      -type f -name "$(basename "$f")" 2>/dev/null \
      | grep -v '\.orig' | head -1)" || true
    [[ -n $src ]] && { printf '%s\n' "$src"; return 0; }
  done
  return 1
}

# Walk up from a file until a folder containing an uninstaller is found.
wine_uninstaller_for() {
  # $1 = a full path under Program Files. Echoes the uninstaller path or nothing.
  local d src
  d="$(dirname "$1")"
  while [[ $d == *'/Program Files'* || $d == *'/Program Files (x86)'* && $d != '/' ]]; do
    src="$(find "$d" -maxdepth 1 -type f \( -iname 'unins*.exe' -o -iname 'uninstall*.exe' \) 2>/dev/null | head -1)"
    [[ -n $src ]] && { printf '%s\n' "$src"; return 0; }
    d="$(dirname "$d")"
  done
  return 1
}

# ── Wine-program folder grouping (shared by uninstall + plugin list) ────────
# The list-uninstallable tree groups a plugin under the wine-program folder
# that installed it; list-all-plugins (the "Installed plugins" setup list)
# uses the exact same helpers so both screens show the same folder rows and
# the same nesting. The wine-program scan is cached once per process.
_WINE_PROGRAM_FOLDERS_CACHED=""
WINE_PROGRAM_FOLDERS=()
wine_program_folders() {
  if [[ -z $_WINE_PROGRAM_FOLDERS_CACHED ]]; then
    WINE_PROGRAM_FOLDERS=()
    local d
    while IFS= read -r d; do [[ -n $d ]] && WINE_PROGRAM_FOLDERS+=("$d"); done < <(scan_wine_programs)
    _WINE_PROGRAM_FOLDERS_CACHED=1
  fi
  if ((${#WINE_PROGRAM_FOLDERS[@]})); then
    printf '%s\n' "${WINE_PROGRAM_FOLDERS[@]}"
  fi
  return 0
}

# wine_program_parent_of <plugin-value-or-path> — echoes "win:<folder>" for
# the wine-program folder that owns the plugin (direct ancestry, a DAT
# mention, the installer's ±1h mtime cluster, or the vendor-folder name
# match), or nothing for a standalone drop. Same heuristics list-uninstallable
# always used, factored out so the setup list cannot drift from the uninstall
# tree.
wine_program_parent_of() {
  local src wf dat plug_stem plug_mtime fm diff plug_vendor plug_vendor_lc wf_base
  src="$(wine_source_of "$1" 2>/dev/null || true)"
  [[ -n $src ]] || return 0
  while IFS= read -r wf; do
    [[ -n $wf ]] || continue
    case "$src" in "$wf"/*) printf 'win:%s\n' "$wf"; return 0 ;; esac
  done < <(wine_program_folders)
  # DAT mention: the uninstaller's data blob lists its product's own files;
  # scale-side companions keep the vendor stem in the file name.
  plug_stem="$(basename "$src")"; plug_stem="${plug_stem%%.*}"
  plug_mtime="$(stat -c %Y "$src" 2>/dev/null || echo 0)"
  while IFS= read -r wf; do
    [[ -n $wf ]] || continue
    dat="$wf/unins000.dat"
    if [[ -f $dat ]] && tr -d '\0' < "$dat" 2>/dev/null | grep -qiF "${plug_stem}"; then
      printf 'win:%s\n' "$wf"; return 0
    fi
    # ±1 hour cluster (installer writes the uninstaller last).
    fm="$(stat -c %Y "$wf/unins000.exe" 2>/dev/null || stat -c %Y "$wf" 2>/dev/null || echo 0)"
    diff=$(( plug_mtime > fm ? plug_mtime - fm : fm - plug_mtime ))
    if (( plug_mtime > 0 && fm > 0 && diff < 3600 )); then
      printf 'win:%s\n' "$wf"; return 0
    fi
  done < <(wine_program_folders)
  # Last-resort: the plugin's own vendor folder name matches the installer
  # folder name (e.g. "Crispy Audio").
  plug_vendor="$(basename "$(dirname "$src")")"
  plug_vendor_lc="${plug_vendor,,}"
  while IFS= read -r wf; do
    [[ -n $wf ]] || continue
    wf_base="$(basename "$wf")"
    if [[ "${wf_base,,}" == "$plug_vendor_lc" ]]; then
      printf 'win:%s\n' "$wf"; return 0
    fi
  done < <(wine_program_folders)
  return 0
}

# wine_program_rows_json — the folder-header rows for the tree, in the same
# JSON shape list-uninstallable/list-all-plugins emit for their plugin rows.
wine_program_rows_json() {
  local wf
  while IFS= read -r wf; do
    [[ -n $wf ]] || continue
    jq -nc --arg display "$(basename "$wf")" --arg value "win:$wf" \
      '{display:$display,value:$value,kind:"folder",parent:""}'
  done < <(wine_program_folders)
}

# ── Open a folder in the system file manager ─────────────────────────────────
# The canonical opener used elsewhere in this repo is xdg-open; the desktop
# fallbacks cover a machine where xdg-open is missing. Detached so a slow or
# hanging file manager never blocks the caller. Silent: returns 0 when an
# opener was launched, 1 when none is available (the caller reports the
# folder so the user still knows where the files are).
open_folder_path() {
  local dir="$1"
  if [[ ! -d $dir ]]; then
    dir="$(dirname "$dir")"
  fi
  [[ -n $dir ]] || return 1
  local opener=""
  if command -v xdg-open >/dev/null 2>&1; then opener="xdg-open"
  elif command -v nautilus >/dev/null 2>&1; then opener="nautilus --new-window"
  elif command -v dolphin >/dev/null 2>&1; then opener="dolphin"
  elif command -v thunar >/dev/null 2>&1; then opener="thunar"
  fi
  [[ -n $opener ]] || return 1
  setsid nohup $opener "$dir" >/dev/null 2>&1 < /dev/null &
  disown 2>/dev/null || true
  return 0
}

# ── Uninstall ───────────────────────────────────────────────────────────────
# Sort plugin scan lines by vendor/folder (the rel dir) so same-source plugins
# cluster together, then render with the group shown as a heading prefix.
uninstall_plugin() {
  local -a options=()
  local line f label key st=0

  while IFS= read -r line; do
    f="${line#*:}"; label="${line%%$'\t'*}"
    label="$(plugin_group_label "$f")"
    options+=("[$label]  ${f##*/}"$'\t'"${line#*$'\t'}")
  done < <(
    while IFS=$'\t' read -r f type; do
      [[ -n $f ]] || continue
      label="$(plugin_group_label "$f")"
      printf '%s\t%s:%s\n' "$label" "$type" "$f"
    done <<< "$(scan_plugins)" | sort -t $'\t' -k1,1 -k2,2
  )
  local wine_folder line_parts
  while IFS= read -r wine_folder; do
    [[ -n $wine_folder ]] || continue
    options+=("$(basename "$wine_folder")  (windows folder)"$'\t'"win:$wine_folder")
  done <<< "$(scan_wine_programs)"
  if ((${#options[@]} == 0)); then ui_info "No plugin to uninstall — nothing installed yet."; return 0; fi
  local pick
  pick=$(ui_select --plain "Uninstall which plugin?" "${options[@]}") || return 0
  ui_confirm "Remove '$(basename "${pick#*:}")'? (files go to ~/.cache/vst-quarantine, nothing is destroyed)" || { ok "kept"; return 0; }
  uninstall_target "$pick"
}

# Quarantine (copy to $2, delete on success) a ~/VST file given its absolute
# path. Used by the uninstall companion-files cleanup.
quarantine_vst_file() {
  local abs="$1" qdir="$2" rel
  rel="${abs#$VST_ROOT/}"
  if [[ -e $abs ]]; then
    mkdir -p "$qdir/VST/$(dirname "$rel")"
    if cp -a "$abs" "$qdir/VST/$rel" 2>/dev/null; then
      rm -f "$abs" 2>/dev/null
      ok "quarantined: $rel"
    else
      warn "could NOT quarantine $rel — keeping it in place"
    fi
  fi
}

# The mechanical part of uninstall_plugin, split out so
# mosquito-audio-plugin-manager-actions (the Go TUI's non-interactive backend) can
# call it once Go has already picked which plugin and confirmed — the only
# two decisions this whole function makes. $1 is "kind:target", exactly
# uninstall_plugin's own $pick shape, so both callers agree on it.
uninstall_target() {
  local pick="$1"
  local kind="${pick%%:*}"
  local target="${pick#*:}"

  local qdir="$HOME/.cache/vst-quarantine/$(date +%Y%m%d-%H%M%S)-uninstall"
  mkdir -p "$qdir"

  # Snapshot which ~/VST plugins have a Windows source BEFORE the uninstaller
  # runs (the uninstaller will remove those sources; the ~/VST copies then
  # become orphaned and are cleaned too).
  local -a had_source=()
  local f t
  while IFS=$'\t' read -r f t; do
    [[ -n $f ]] || continue
    if wine_source_of "$f" >/dev/null 2>&1; then had_source+=("$f"); fi
  done <<< "$(scan_plugins)"

  # 1. Locate the wine program folder (explicit win pick, or discover it from a
  #    VST pick via the plugin's Windows source copy), then run its uninstaller
  #    silently when one exists.
  local winedir=""
  if [[ $kind == win ]]; then
    winedir="$target"
  else
    local src
    src="$(wine_source_of "$target")" 2>/dev/null || true
    [[ -n $src ]] && winedir="$(dirname "$src")"
  fi
  local unins=""
  if [[ -n ${winedir:-} ]]; then
    unins="$(find "$winedir" -maxdepth 1 -type f \( -iname 'unins*.exe' -o -iname 'uninstall*.exe' \) 2>/dev/null | head -1 || true)"
  fi
  if [[ -n $unins ]]; then
    msg "Running uninstaller: $(basename "$unins")"
    wine "$unins" /VERYSILENT /NORESTART >/dev/null 2>&1 || warn "(uninstaller exit code ignored)"
  fi
  sleep 1

  # 2. Quarantine the wine folder (leave the original untouched).
  if [[ -n $winedir && -d $winedir ]]; then
    cp -a "$winedir" "$qdir/" 2>/dev/null && ok "windows folder → quarantine"
  fi

  # 3. Quarantine + remove the plugin files from ~/VST whose folder matches
  #    the plugin/vendor name being removed, and every plugin that had a
  #    Windows source before the uninstall and lost it (orphans). For each
  #    matched plugin its companion leftovers in the same folder go too:
  #    same-stem files of any kind (.aux / .dat sidecars, yabridge .so
  #    bridges…) plus .aux files regardless of name — nothing non-VST stale
  #    survives the uninstall.
  local f rel vendor orphan src
  declare -A done_file=()
  vendor="$(basename "$target")"
  while IFS=$'\t' read -r f type; do
    [[ -n $f ]] || continue
    rel="${f#$VST_ROOT/}"
    orphan=no
    for i in "${had_source[@]}"; do
      [[ $i == "$f" ]] || continue
      src="$(wine_source_of "$f")" 2>/dev/null || true
      [[ -z $src ]] && orphan=yes
      break
    done
    if [[ $rel == *"$vendor"* || $orphan == yes ]]; then
      local dir stem
      dir="$(dirname "$f")"
      stem="$(basename "$f")"; stem="${stem%.*}"
      local s base ext
      while IFS= read -r s; do
        [[ -n $s ]] || continue
        [[ -n ${done_file[$s]:-} ]] && continue
        done_file[$s]=1
        base="$(basename "$s")"
        ext="${base##*.}"; ext="${ext,,}"
        if [[ $ext == aux || $base == "$stem".* ]]; then
          quarantine_vst_file "$s" "$qdir"
        fi
      done < <(find "$dir" -maxdepth 1 -type f 2>/dev/null)
    fi
  done <<< "$(scan_plugins)"

  # 4. Remove the plugin's wine .desktop menu entries (quarantine them).
  local de
  [[ -d "$HOME/.local/share/applications" ]] &&
  find "$HOME/.local/share/applications" -path '*wine*' -iname '*.desktop' 2>/dev/null |
    while IFS= read -r de; do
      if grep -qi "$(basename "$target")" "$de" 2>/dev/null; then
        mkdir -p "$qdir/desktop"; cp "$de" "$qdir/desktop/"
        rm -f "$de"
        ok "hidden menu entry: $(basename "$de")"
      fi
    done || true

  # 5. Update the state log (this plugin is no longer installed).
  local k
  for k in $(state_list_keys); do
    if [[ $k == *"$vendor"* || $k == *"$(basename "${target%.*}")"* ]]; then
      state_remove "$k"
      ok "state log: removed '$k'"
    fi
  done
  if [[ $kind == vst2 ]]; then state_remove "$(basename "${target%.*}")"; fi
  if [[ $kind == vst3 ]]; then
    local k3="${target#$VST_ROOT/}"; k3="${k3%.*}"
    state_remove "${target#$VST_ROOT/}" 2>/dev/null || true
    state_remove "$(dirname "$k3")/$(basename "$k3")" 2>/dev/null || true
  fi

  # 6. Clean up leftovers.
  remove_vst_dir "$target"
  post_install
  ok "Done — see $qdir"
}

# Hide/show a VST plugin without uninstalling it: rename the file under the
# shared root's vst/vst3/clap folders with a trailing ".hidden" suffix so it no
# longer matches any of the extensions yabridge/a DAW scans for -- same mechanism
# as toggle_native_plugin_enabled() below, applied to the wine side. A
# yabridgectl sync (post_install(), the same helper install/uninstall
# already call) runs afterward so the change actually takes effect instead
# of only being true on next unrelated sync.
toggle_vst_plugin_hidden() {
  local entry="$1" new
  case "$entry" in
    "$VST_ROOT"/*) ;;
    *) err "not a plugin under $VST_ROOT: $entry"; return 1 ;;
  esac
  [[ -e $entry ]] || { err "not found: $entry"; return 1; }
  if [[ $entry == *.hidden ]]; then
    new="${entry%.hidden}"
    mv "$entry" "$new" || { err "could not show $entry"; return 1; }
    ok "shown: $(basename "$new")"
  else
    new="$entry.hidden"
    mv "$entry" "$new" || { err "could not hide $entry"; return 1; }
    ok "hidden: $(basename "$entry")"
  fi
  post_install
  printf '%s\n' "$new"
}

remove_vst_dir() {
  local d
  for d in "$VST_VST2" "$VST_VST3" "$VST_CLAP"; do
    while IFS= read -r sub; do
      [[ "$(basename "$sub")" == *"$(basename "$1")"* ]] || continue
      if [[ -z "$(find "$sub" -type f 2>/dev/null)" ]]; then rmdir "$sub" 2>/dev/null || true; fi
    done < <(find "$d" -maxdepth 1 -mindepth 1 -type d 2>/dev/null)
  done
}

# ── Manage prefixes ─────────────────────────────────────────────────────────
plugin_prefix_label() {
  # "Vendor/Plugin" → "Plugin"; "Plugin" → "Plugin"; standalone key → itself.
  local k="$1"
  printf '%s\n' "${k##*/}"
}

manage_prefixes() {
  state_init
  local -a keys=() options=() pick target
  local k prefix label
  while IFS= read -r k; do
    [[ -n $k ]] && keys+=("$k")
  done <<< "$(state_list_keys)"

  if ((${#keys[@]} == 0)); then
    # Fall back to the live scan so the option is still useful before any install.
    while IFS= read -r wd; do
      [[ -n $wd ]] || continue
      keys+=("win:$(basename "$wd")")
    done <<< "$(scan_wine_programs)"
    if ((${#keys[@]} == 0)); then
      if ((${#WINE_PREFIXES[@]} == 0)); then
        ui_info "No prefix to manage — nothing installed yet."
      else
        ui_info "No plugin to manage — nothing installed yet."
      fi
      return 0
    fi
  fi

  # Management history is ALWAYS last in "Manage prefixes".
  for k in "${keys[@]}"; do
    if [[ $k == win:* ]]; then
      options+=("$(plugin_prefix_label "${k#win:}")  (windows folder)"$'\t'"$k")
    else
      prefix="$(state_plugin_prefix "$k")"
      label="$(plugin_prefix_label "$k")"
      options+=("$label   →  $(basename "$prefix")"$'\t'"$k")
    fi
  done
  options+=("🕘  Management history"$'\t'"history")

  while :; do
    pick=$(ui_select --plain "Manage prefixes — move a plugin to another prefix:" "${options[@]}") || return 0
    if [[ $pick == history ]]; then
      local h
      h="$(state_history_text)"
      if [[ -z $h ]]; then ui_info "No previous moves — management history is empty."
      else msg "Prefix management history:"; printf '%s\n' "$h"; fi
      [[ -t 0 ]] && read -rp "Press Enter to return…" || sleep 1
      continue
    fi

    # Move the chosen plugin to another prefix (or its own).
    local cur="${prefix:-}"
    if [[ $pick == win:* ]]; then
      warn "This is a Windows program folder (not tracked in the state log) — moving not supported. Track it by installing via the manager."
      continue
    fi
    local cur_prefix
    cur_prefix="$(state_plugin_prefix "$pick")"
    [[ -n $cur_prefix ]] || { warn "No prefix known for '$pick' — reinstall it to track it."; continue; }

    local -a targets=()
    local tp t
    for tp in "${WINE_PREFIXES[@]}"; do
      [[ $tp != "$cur_prefix" ]] || continue
      targets+=("$(basename "$tp")"$'\t'"$tp")
    done
    targets+=("New prefix"$'\t'"new")
    target=$(ui_select --plain "Move '$(plugin_prefix_label "$pick")' to which prefix? (currently $(basename "$cur_prefix"))" "${targets[@]}") || continue
    if [[ $target == new ]]; then
      local newname newp
      newname=$(ui_input "Name of the new prefix (e.g. 'early' → ~/.wine-early):" "") || continue
      [[ -n $newname ]] || { warn "Empty name — cancelled."; continue; }
      newname="$(printf '%s' "$newname" | tr ' ' '-' | tr -cd '[:alnum:]-' | tr '[:upper:]' '[:lower:]')"
      newp="$HOME/.wine-$newname"
      if [[ ! -d "$newp/drive_c" ]]; then
        msg "Creating wine prefix: $newp"
        WINEPREFIX="$newp" wineboot -u >/dev/null 2>&1 || warn "(wineboot returned a non-zero code — continuing)"
      fi
      WINE_PREFIXES+=("$newp")
      target="$newp"
    fi
    if [[ $target == "$cur_prefix" ]]; then ok "same prefix — nothing to do."; continue; fi
    ui_confirm "Move '$(plugin_prefix_label "$pick")' from $(basename "$cur_prefix") to $(basename "$target")?" || { ok "kept in $(basename "$cur_prefix")"; continue; }
    move_plugin "$pick" "$cur_prefix" "$target"
    # Refresh the option labels after the move.
    if [[ $pick != win:* ]]; then
      prefix="$(state_plugin_prefix "$pick")"
    fi
  done
}

move_plugin() {
  # $1 = plugin key, $2 = from prefix, $3 = to prefix.
  local k="$1" from="$2" to="$3"
  # Physically relocate the wine program folder if the plugin lives there and
  # the plugin key has a ~/VST file whose source is in $from.
  local f src dstdir moved=no
  while IFS= read -r f; do
    [[ -n $f ]] || continue
    src="$(wine_source_of "$f")" 2>/dev/null || true
    [[ -z $src || $src != "$from"* ]] && continue
    if [[ -d "$to/drive_c/Program Files" ]]; then dstdir="$to/drive_c/Program Files"; else dstdir="$to/drive_c/Program Files (x86)"; fi
    local wfolder
    wfolder="$(dirname "$src")"
    if [[ -d $wfolder ]]; then
      cp -a "$wfolder" "$dstdir/" 2>/dev/null && moved=yes
    fi
  done <<< "$(state_plugin_files "$k")"
  state_set_prefix "$k" "$to"
  state_add_history "$k" "$from" "$to"
  ok "$(plugin_prefix_label "$k") moved: $(basename "$from") → $(basename "$to")${moved:+ (windows folder copied)}"
}

# ── Standalone executables ─────────────────────────────────────────────────
# The lists below are built from the state log (what THIS manager registered),
# never from a live scan of the prefixes. Programs installed by other means
# (bottles, manual wine, other installers…) stay out of both "Launch a
# standalone plugin" and the app-menu toggle, automatically.
executable_list() {
  local f
  while IFS= read -r f; do
    [[ -n $f ]] || continue
    [[ -e $f ]] || continue
    is_uninstaller "$(basename "$f")" && continue
    is_native_win_app "$(basename "$f")" && continue
    printf '%s\t%s\n' "$(basename "$f")" "$f"
  done <<< "$(state_list_standalones | sort -u)"
}

launch_standalone() {
  local list pick
  list="$(executable_list)"
  if [[ -z $list ]]; then ui_info "No standalone executable registered yet — install a plugin via the manager first."; return 0; fi
  pick=$(ui_select --plain "Launch a standalone plugin (via wine)?" "$list") || { ui_info "No standalone picked."; return 0; }
  msg "Launching wine $pick"
  setsid wine start /unix "$pick" >/dev/null 2>&1 &
  ok "launched (standalone window may open)"
}

# Manage which standalone executables get a .desktop launcher in the app menu.
# Selecting an executable does NOT return to the previous menu: several can be
# toggled in a row. Escape (or cancelling) returns to the main menu.
manage_executables() {
  local pick
  while :; do
    local -a entries=()
    local f base slug shown
    while IFS=$'\t' read -r f junk; do
      [[ -n $f ]] || continue
      base="$(basename "$f")"
      slug="$APPS_DIR/$DESKTOP_SLUG-$(basename "${base%.exe}" | tr ' ' '-' | tr -cd '[:alnum:]-').desktop"
      shown=hide
      [[ -f $slug ]] && shown=show
      entries+=("$([ $shown = show ] && echo '✓' || echo '○')  $base"$'\t'"$f")
    done <<< "$(executable_list)"
    if ((${#entries[@]} == 0)); then ui_info "No standalone executable registered yet — install a plugin via the manager first."; return 0; fi
    pick=$(ui_select --plain "Toggle which executables appear in the menu — keep picking to toggle several, Escape to finish:" "${entries[@]}") || return 0

    mkdir -p "$APPS_DIR"
    slug="$APPS_DIR/$DESKTOP_SLUG-$(basename "${pick%.exe}" | tr ' ' '-' | tr -cd '[:alnum:]-').desktop"
    if [[ -f $slug ]]; then
      rm -f "$slug"
      ok "hidden: $(basename "$pick")"
    else
      cat > "$slug" <<EOF
[Desktop Entry]
Name=$(basename "$pick")
Comment=VST standalone (managed by mosquito Audio Plugin Manager)
Exec=uwsm app -- mosquito-audio-plugin-manager launch "$pick"
Terminal=false
Type=Application
Categories=AudioVideo;Audio;
StartupNotify=false
EOF
      ok "shown in menu: $(basename "$pick")"
    fi
    # Loop: stay here so multiple executables can be toggled (Escape returns).
  done
}

# ── Status (one-shot CLI only, not a menu option) ───────────────────────────
status_report() {
  local plist line f type label verdict acc
  plist=$(scan_plugins)
  if [[ -z $plist ]]; then
    warn "No plugin found in $VST_ROOT/{vst,vst3,clap}"
    if state_compatible && jq -e '.plugins | length > 0' "$STATE_FILE" >/dev/null 2>&1; then
      msg "State log ($STATE_FILE) still lists:"
      printf '  %s\n' "$(state_list_keys)"
    fi
    return 0
  fi
  while IFS=$'\t' read -r f type; do
    [[ -n $f ]] || continue
    label="$(plugin_label "$f")"
    verdict="✓ installed"
    [[ $type == so ]] && verdict="✓ (native .so)"
    printf '%-14s %-28s %-22s %s\n' "[$type]" "$label" "$(basename "$f")" "$verdict"
  done <<< "$plist"
}

# ── Plugin list (first menu option) ─────────────────────────────────────────
# Grouped overview: "Plugin - wine prefix". A "Readme" entry is always last and
# explains where DAWs must point their plugin folders. Selecting the Readme
# opens it in a native info prompt; dismissing it (Enter / Escape / OK) returns
# to the list. Escape on the list itself returns to the main menu.
plugin_list() {
  local -a rows=()
  local f type key prefix pfx grp label sortkey name
  while IFS=$'\t' read -r sortkey grp name val; do
    rows+=("[$grp]  $name"$'\t'"$val")
  done < <(
    while IFS=$'\t' read -r f type; do
      [[ -n $f ]] || continue
      # VST settings filters (Hide VST2 / Hide 32-bit) -- see menu_vst_settings().
      # Bitness is only checked for .dll (vst2) scans: scan_plugins() only
      # matches FILES, and a real Windows VST3 bundle is a directory (never
      # matched here), so `file -b` on the scanned path is only meaningful
      # for the vst2 case in practice.
      [[ $type == vst2 && $HIDE_VST2 == true ]] && continue
      if [[ $type == vst2 && $HIDE_32BIT == true ]]; then
        file -b "$f" 2>/dev/null | grep -q '^PE32 executable' && continue
      fi
      key="$(plugin_key "$f")"
      label="$(plugin_label "$f")"
grp="${key%/*}"; [[ $key == "$grp" ]] && grp="${label#vst/}"; grp="${grp#vst3/}"; grp="${grp#clap/}"
      grp="$(basename "$grp")"
      prefix="$(state_plugin_prefix "$key")"
      if [[ -n $prefix ]]; then pfx=" - $(basename "$prefix")"; else pfx=""; fi
      name="${key##*/}${pfx}"
      case "$PLUGIN_SORT_MODE" in
        name)   sortkey="$name" ;;
        format) sortkey="$type" ;;
        date)   sortkey="$(printf '%020d' "$(stat -c %Y "$f" 2>/dev/null || echo 0)")" ;;
        *)      sortkey="$grp" ;;   # vendor (default)
      esac
      printf '%s\t%s\t%s\t%s:%s\n' "$sortkey" "$grp" "$name" "$type" "$f"
    done <<< "$(scan_plugins)" | sort -t $'\t' -k1,1 -k3,3
  )

  local readme pick
  readme=$'📖  Readme\treadme'
  local prompt="Installed plugins (grouped) — Readme is last:"
  if ((${#rows[@]} == 0)); then
    prompt="No plugin found in $VST_ROOT/{vst,vst3,clap} — the Readme below explains where DAWs must point:"
  fi
  while :; do
    pick=$(ui_select --plain "$prompt" "${rows[@]}" "$readme") || return 0
    if [[ $pick == readme ]]; then
      ui_info $'Where to point your DAW plugin folders:\n\n  vst\t→ '$VST_VST2$'\n  vst3\t→ '$VST_VST3$'\n  clap\t→ '$VST_CLAP$'\n'
      continue
    fi
    local kind="${pick%%:*}" target="${pick#*:}"
    ui_info "$(basename "$target")  (${kind})"$'\n\n'"$target"
    continue
  done
}

# ── Native plugins (LV2 / CLAP / native-Linux VST3 — no Wine involved) ─────
# A genuinely separate plugin universe from everything above: these formats
# are directory-scan-based (any host just looks in a fixed set of folders
# at startup), so there is no wine prefix, no yabridge, no install-into-a-
# prefix step — just "put the bundle where hosts look, or don't."
#
# Scan roots: user paths (~/.lv2, ~/.clap, ~/.vst3 — writable without sudo,
# so install/uninstall/enable-disable only ever touch these) plus the
# system paths (/usr/lib/{lv2,clap,vst3}, /usr/local/lib/{lv2,clap,vst3} —
# where a pacman/AUR-installed plugin lands) shown read-only: this tool
# never uninstalls or disables a system package, only tells you to use
# pacman.
#
# ~/.vst3 disambiguation: this is ALSO the standard yabridge target for
# bridged Windows VST3 plugins (see setup-audio-stack.sh's yabridge.toml
# step) — every entry found there is readlink'd first, and anything whose
# resolved target path contains "/.wine" is a yabridge bridge stub, not a
# native plugin, and is excluded here (it already appears in the VST list
# above).
# Bare fallback only (same caveat as VST_ROOT above) -- every real entry
# point overrides these via apply_plugins_root() (PLUGINS_ROOT/lv2,
# PLUGINS_ROOT/clap-native, PLUGINS_ROOT/vst3-native) once load_prefs()
# runs. Known limitation: a native plugin already sitting directly under
# the OLD hardcoded ~/.lv2, ~/.clap or ~/.vst3 before this change is not
# automatically swept into the new location -- move it by hand (or
# reinstall it) if you have one; this machine had none at the time this
# was written.
NATIVE_LV2_DIRS_USER=("$HOME/.lv2")
NATIVE_LV2_DIRS_SYSTEM=("/usr/lib/lv2" "/usr/local/lib/lv2")
NATIVE_CLAP_DIRS_USER=("$HOME/.clap")
NATIVE_CLAP_DIRS_SYSTEM=("/usr/lib/clap" "/usr/local/lib/clap")
NATIVE_VST3_DIRS_USER=("$HOME/.vst3")
NATIVE_VST3_DIRS_SYSTEM=("/usr/lib/vst3" "/usr/local/lib/vst3")

# An LV2 bundle folder is only counted as a plugin (not a spec/extension
# bundle like atom.lv2, core.lv2, … which ship with the lv2 package itself
# and also end in .lv2) if its manifest.ttl actually declares an
# `lv2:Plugin` (or a Plugin subclass, e.g. lv2:InstrumentPlugin) — the
# standard RDF self-description every real LV2 plugin bundle carries. Not a
# full Turtle parser, just the same substring check most lightweight LV2
# scanners use.
is_lv2_plugin_bundle() {
  local manifest="$1/manifest.ttl"
  [[ -f $manifest ]] || return 1
  grep -qE 'lv2:[A-Za-z]*Plugin' "$manifest" 2>/dev/null
}

# Is $1 (an entry directly under a ~/.vst3 or /usr/lib/vst3 scan root) a
# yabridge bridge stub rather than a genuine native plugin? See the
# disambiguation note above.
is_yabridge_stub() {
  local target; target="$(readlink -f "$1" 2>/dev/null || echo "$1")"
  [[ $target == *"/.wine"* ]]
}

# Emits one line per native plugin found: path<TAB>format<TAB>location<TAB>enabled
#   format:   lv2 | clap | vst3
#   location: user | system
#   enabled:  true | false (a ".disabled"-suffixed entry is how this tool
#             disables a plugin without uninstalling it — see
#             toggle_native_plugin_enabled())
scan_native_plugins() {
  local dir entry base fmt loc enabled name

  _scan_one() {
    local dir="$1" fmt="$2" loc="$3" pattern="$4"
    [[ -d $dir ]] || return 0
    local entry
    for entry in "$dir"/$pattern "$dir"/$pattern.disabled; do
      [[ -e $entry ]] || continue
      base="$(basename "$entry")"
      enabled=true
      [[ $base == *.disabled ]] && enabled=false
      if [[ $fmt == lv2 ]]; then
        # manifest.ttl lives inside the bundle directory itself -- a
        # .disabled rename only touches the directory's own name, the
        # manifest is still found at $entry/manifest.ttl either way.
        is_lv2_plugin_bundle "$entry" || continue
      fi
      if [[ $fmt == vst3 ]]; then
        is_yabridge_stub "$entry" && continue
      fi
      printf '%s\t%s\t%s\t%s\n' "$entry" "$fmt" "$loc" "$enabled"
    done
  }

  for dir in "${NATIVE_LV2_DIRS_USER[@]}"; do _scan_one "$dir" lv2 user "*.lv2"; done
  for dir in "${NATIVE_LV2_DIRS_SYSTEM[@]}"; do _scan_one "$dir" lv2 system "*.lv2"; done
  for dir in "${NATIVE_CLAP_DIRS_USER[@]}"; do _scan_one "$dir" clap user "*.clap"; done
  for dir in "${NATIVE_CLAP_DIRS_SYSTEM[@]}"; do _scan_one "$dir" clap system "*.clap"; done
  for dir in "${NATIVE_VST3_DIRS_USER[@]}"; do _scan_one "$dir" vst3 user "*.vst3"; done
  for dir in "${NATIVE_VST3_DIRS_SYSTEM[@]}"; do _scan_one "$dir" vst3 system "*.vst3"; done
  return 0
}

native_plugin_label() {
  local entry="$1" base
  base="$(basename "$entry")"
  base="${base%.disabled}"
  base="${base%.lv2}"; base="${base%.clap}"; base="${base%.vst3}"
  printf '%s\n' "$base"
}

# Sorted, filtered (per PLUGIN_SORT_MODE) list for display. Emits:
#   sortkey<TAB>label<TAB>format<TAB>location<TAB>enabled<TAB>path
native_plugin_list_rows() {
  local entry fmt loc enabled label sortkey
  while IFS=$'\t' read -r entry fmt loc enabled; do
    [[ -n $entry ]] || continue
    label="$(native_plugin_label "$entry")"
    case "$PLUGIN_SORT_MODE" in
      format) sortkey="$fmt" ;;
      date)   sortkey="$(printf '%020d' "$(stat -c %Y "$entry" 2>/dev/null || echo 0)")" ;;
      *)      sortkey="$label" ;;   # "vendor" has no real meaning here (no wine prefix) -- falls back to name, same as "name" mode
    esac
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$sortkey" "$label" "$fmt" "$loc" "$enabled" "$entry"
  done < <(scan_native_plugins) | sort -t $'\t' -k1,1 -k2,2
}

# ── Unified plugin list (VST + native together) ─────────────────────────────
# One list, one set of sort/hide rules, per explicit request: the tool
# manages "plugins" in general, format is just an attribute of a row, not a
# separate section to navigate to. Emits:
#   sortkey<TAB>label<TAB>origin<TAB>format<TAB>enabled<TAB>value
#   origin: vst | native
#   value:  "vst:<type>:<path>" or "native:<path>" -- self-describing, so
#           install/uninstall/toggle dispatch (mosquito-audio-plugin-manager-
#           actions) never has to guess which side a picked row came from.
# Sort modes: vendor (VST-only grouping; native rows fall back to name,
# same as native_plugin_list_rows() does alone), name, format, date.
all_plugin_list_rows() {
  local f type key prefix pfx grp label sortkey name enabled

  while IFS=$'\t' read -r f type; do
    [[ -n $f ]] || continue
    [[ $type == vst2 && $HIDE_VST2 == true ]] && continue
    if [[ $type == vst2 && $HIDE_32BIT == true ]]; then
      file -b "${f%.hidden}" 2>/dev/null | grep -q '^PE32 executable' && continue
    fi
    key="$(plugin_key "$f")"
    label="$(plugin_label "$f")"
    grp="${key%/*}"; [[ $key == "$grp" ]] && grp="${label#VST2/}"; grp="${grp#VST3/}"; grp="${grp#CLAP/}"
    grp="$(basename "$grp")"
    prefix="$(state_plugin_prefix "$key")"
    if [[ -n $prefix ]]; then pfx=" - $(basename "$prefix")"; else pfx=""; fi
    name="${key##*/}${pfx}"
    enabled=true
    [[ $f == *.hidden ]] && enabled=false
    case "$PLUGIN_SORT_MODE" in
      name)   sortkey="$name" ;;
      format) sortkey="$type" ;;
      date)   sortkey="$(printf '%020d' "$(stat -c %Y "${f%.hidden}" 2>/dev/null || echo 0)")" ;;
      *)      sortkey="$grp" ;;
    esac
    printf '%s\t%s\tvst\t%s\t%s\tvst:%s:%s\n' "$sortkey" "$name" "$type" "$enabled" "$type" "$f"
  done <<< "$(scan_plugins)"

  local entry fmt loc nenabled
  while IFS=$'\t' read -r entry fmt loc nenabled; do
    [[ -n $entry ]] || continue
    label="$(native_plugin_label "$entry")"
    case "$PLUGIN_SORT_MODE" in
      format) sortkey="$fmt" ;;
      date)   sortkey="$(printf '%020d' "$(stat -c %Y "$entry" 2>/dev/null || echo 0)")" ;;
      *)      sortkey="$label" ;;
    esac
    printf '%s\t%s\tnative\t%s\t%s\tnative:%s\n' "$sortkey" "$label" "$fmt" "$nenabled" "$entry"
  done < <(scan_native_plugins)
}

all_plugin_list_rows_sorted() {
  all_plugin_list_rows | sort -t $'\t' -k1,1 -k2,2
}

# Detects the format of a picked file/folder (possibly an archive) and
# installs it into the matching ~/.lv2, ~/.clap or ~/.vst3 — user paths
# only, never touches the system ones, so this never needs sudo.
install_native_plugin_from_file() {
  local src="$1" work="" cleanup_work=""
  case "$src" in
    *.zip|*.tar.gz|*.tgz|*.tar)
      work="$(mktemp -d)"; cleanup_work="$work"
      case "$src" in
        *.zip) unzip -oq "$src" -d "$work" 2>/dev/null || { err "could not extract $src"; rm -rf "$work"; return 1; } ;;
        *)     tar -xf "$src" -C "$work" 2>/dev/null || { err "could not extract $src"; rm -rf "$work"; return 1; } ;;
      esac
      ;;
    *) work="$(dirname "$src")" ;;
  esac

  # Look for exactly one recognizable bundle, up to 2 levels deep (archives
  # commonly wrap the bundle in one extra top-level folder).
  local found kind
  if [[ $src != *.zip && $src != *.tar* && $src != *.tgz ]]; then
    found="$src"
  else
    found="$(find "$work" -maxdepth 2 \( -iname '*.lv2' -o -iname '*.clap' -o -iname '*.vst3' \) -print -quit 2>/dev/null)"
  fi
  [[ -n $found ]] || { err "no .lv2/.clap/.vst3 bundle found in $src"; [[ -n $cleanup_work ]] && rm -rf "$cleanup_work"; return 1; }

  local dest_dir dest
  case "${found,,}" in
    *.lv2)  dest_dir="$HOME/.lv2";  kind=LV2  ;;
    *.clap) dest_dir="$HOME/.clap"; kind=CLAP ;;
    *.vst3) dest_dir="$HOME/.vst3"; kind=VST3 ;;
    *) err "unrecognized plugin format: $found"; [[ -n $cleanup_work ]] && rm -rf "$cleanup_work"; return 1 ;;
  esac
  mkdir -p "$dest_dir"
  dest="$dest_dir/$(basename "$found")"
  if [[ -e $dest ]]; then
    err "$kind plugin already installed: $dest (uninstall it first to replace)"
    [[ -n $cleanup_work ]] && rm -rf "$cleanup_work"
    return 1
  fi
  cp -a "$found" "$dest" || { err "copy failed: $found -> $dest"; [[ -n $cleanup_work ]] && rm -rf "$cleanup_work"; return 1; }
  [[ -n $cleanup_work ]] && rm -rf "$cleanup_work"
  ok "$kind plugin installed: $(basename "$dest") -> $dest_dir"
  printf '%s\n' "$dest"
}

# Non-destructive uninstall (same "never actually delete" spirit as
# quarantine_vst_file() above, separate quarantine dir since these are a
# different plugin universe entirely). Refuses system-path entries -- those
# came from pacman and go back through pacman.
uninstall_native_plugin() {
  local entry="$1"
  case "$entry" in
    "$HOME"/.lv2/*|"$HOME"/.clap/*|"$HOME"/.vst3/*) ;;
    *) err "not a user-installed plugin (installed via pacman -- use your package manager): $entry"; return 1 ;;
  esac
  [[ -e $entry ]] || { err "not found: $entry"; return 1; }
  local qdir="$HOME/.cache/audio-plugin-manager-quarantine/$(date +%Y%m%d-%H%M%S)-uninstall"
  mkdir -p "$qdir"
  mv "$entry" "$qdir/" || { err "could not quarantine $entry"; return 1; }
  ok "quarantined: $(basename "$entry") -> $qdir (files go to ~/.cache/audio-plugin-manager-quarantine, nothing is destroyed)"
}

# Enable/disable without uninstalling: every native-plugin host recognizes
# exactly the ".lv2"/".clap"/".vst3" suffix when scanning its folders, so
# appending ".disabled" makes a bundle invisible to every host without
# touching its contents; stripping the suffix re-enables it. Refuses
# system-path entries for the same reason uninstall does.
toggle_native_plugin_enabled() {
  local entry="$1" new
  case "$entry" in
    "$HOME"/.lv2/*|"$HOME"/.clap/*|"$HOME"/.vst3/*) ;;
    *) err "not a user-installed plugin (installed via pacman -- use your package manager): $entry"; return 1 ;;
  esac
  [[ -e $entry ]] || { err "not found: $entry"; return 1; }
  if [[ $entry == *.disabled ]]; then
    new="${entry%.disabled}"
    mv "$entry" "$new" || { err "could not enable $entry"; return 1; }
    ok "enabled: $(basename "$new")"
    printf '%s\n' "$new"
  else
    new="$entry.disabled"
    mv "$entry" "$new" || { err "could not disable $entry"; return 1; }
    ok "disabled: $(basename "$entry")"
    printf '%s\n' "$new"
  fi
}

# ── Launch reconciliation ───────────────────────────────────────────────────
# On every launch the log and the disk are compared:
#   1. plugins listed in the log whose files are missing on disk are reported
#      (native info prompt — "in the log but not on this computer");
#   2. plugin files found on disk but not tracked in the log are offered as a
#      native checkbox list; the ticked ones get registered into the manager.
reconcile() {
  local -a missing=() missing_keys=()
  local k f there
  while IFS= read -r k; do
    [[ -n $k ]] || continue
    local -a files=()
    while IFS= read -r f; do [[ -n $f ]] && files+=("$f"); done <<< "$(state_plugin_files "$k")"
    ((${#files[@]})) || continue
    there=0
    for f in "${files[@]}"; do [[ -e $f ]] && there=1 && break; done
    ((there)) || { missing_keys+=("$k"); missing+=("$(plugin_prefix_label "$k")  ($k)"); }
  done <<< "$(state_list_keys)"
if ((${#missing[@]})); then
    local choice
    choice=$(ui_select --plain $'Listed in the log but NOT on this computer:\n'"$(printf '  • %s\n' "${missing[@]}")"$'\nWhat do you want to do?' $'add to log'$'\t''keep these in the shared log (stop nagging)' $'remove everywhere'$'\t''remove them from the log and this computer') || { ui_info "kept in the log (nothing changed)."; choice=""; }
    if [[ $choice == "add to log" ]]; then
      keep_missing_keys "${missing_keys[@]}"
      ui_info "kept in the log: ${#missing[@]} plugin(s) will stop being flagged here."
    elif [[ $choice == "remove everywhere" ]]; then
      if ui_confirm "Really remove ${#missing[@]} plugin(s) from the log EVERYWHERE? Their files are already gone on this computer. This also clears their generated menu entries." 2; then
        purge_missing_keys "${missing_keys[@]}"
        ui_info "removed everywhere: ${#missing[@]} plugin(s)."
      else
        ui_info "kept in the log (nothing changed)."
      fi
    else
      ui_info $'kept in the log (nothing changed):\n'"$(printf '  • %s\n' "$choice")"
    fi
  fi

  local -a orphans=()
  local f t
  while IFS=$'\t' read -r f t; do
    [[ -n $f ]] || continue
    state_has "$(plugin_key "$f")" && continue
    orphans+=("$f")
  done <<< "$(scan_plugins)"
  ((${#orphans[@]})) && reconcile_tick_to_add "${orphans[@]}"
}

# "Scripts present on the computer but not in the log": show them as a native
# toggle (checkbox) list, register the ticked ones, remember the chosen ones.
reconcile_tick_to_add() {
  local -a candidates=("$@") chosen=()
  local pick f shown
  while :; do
    local -a rows=()
    for f in "${candidates[@]}"; do
      shown=○
      for i in "${chosen[@]}"; do [[ $i == "$f" ]] && shown=✓ && break; done
      rows+=("$shown  $(basename "$f")  ($(plugin_group_label "$f"))"$'\t'"$f")
    done
    pick=$(ui_select --plain "Found on disk but not tracked — tick the ones to add (Escape to finish):" "${rows[@]}") || break
    if [[ " ${chosen[*]} " == *" $pick "* ]]; then
      local -a tmp=()
      for i in "${chosen[@]}"; do [[ $i != "$pick" ]] && tmp+=("$i"); done
      chosen=("${tmp[@]}")
    else
      chosen+=("$pick")
    fi
  done

  local f src prefix
  for f in "${chosen[@]}"; do
    prefix="$(default_prefix)"
    src="$(wine_source_of "$f")" 2>/dev/null || src=""
    [[ -n $src ]] && prefix="${src%%/drive_c/*}"
    state_register_install "$(plugin_key "$f")" "$prefix" "$f"
    ok "added to the manager: $(basename "$f")"
  done
}

# ── Cleanup (one-shot, non-destructive) ──────────────────────────────────────
# "cleanup!" -- checks every plugin/log inconsistency in one pass instead of
# letting the startup dialog nag one at a time, then fixes them WITHOUT
# leaning toward deletion: the log and the files on disk are both treated as
# truth to keep.
#   1. missing plugins (in the log, files gone somewhere)   → KEPT in the log
#      (their tracked files are emptied -- stop flagging, entry stays);
#   2. untracked files on disk (orphans)                    → REGISTERED into
#      the log (the file stays, the log gains it), same as reconcile_tick_to_add;
#   3. a file tracked under several keys (duplicate refs)   → deduplicated,
#      kept only under its first key -- disk untouched;
#   4. dangling menu entries (.desktop whose standalone exe no longer exists)
#                                                           → removed (debris).
# The only deletion is that debris (a generated launcher for a file that is
# gone); real plugin files and log entries are never removed here.
# Last stdout line is a machine-readable JSON report; the actions script
# (`cleanup` command) uses `cleanup | tail -1` to get exactly it.
cleanup() {
  local -a kept=() registered=() desktops=() deduped=()

  # 1. Missing: in the log, at least one tracked file, all absent on disk.
  local -a missing=()
  local k
  while IFS= read -r k; do
    [[ -n $k ]] || continue
    local -a files=()
    local f there=0
    while IFS= read -r f; do [[ -n $f ]] && files+=("$f"); done <<< "$(state_plugin_files "$k")"
    ((${#files[@]})) || continue
    for f in "${files[@]}"; do [[ -e $f ]] && there=1 && break; done
    ((there)) || missing+=("$k")
  done <<< "$(state_list_keys)"
  if ((${#missing[@]})); then
    local mk
    for mk in "${missing[@]}"; do kept+=("$(plugin_prefix_label "$mk")  ($mk)"); done
    keep_missing_keys "${missing[@]}"
    ok "Cleanup: kept ${#kept[@]} missing plugin(s) in the log (stop nagging — nothing deleted)"
  fi

  # 2. Orphans: files on disk not tracked in the log.
  local -a orphans=()
  while IFS=$'\t' read -r f t; do
    [[ -n $f ]] || continue
    state_has "$(plugin_key "$f")" && continue
    orphans+=("$f")
  done <<< "$(scan_plugins)"
  if ((${#orphans[@]})); then
    local pf prefix src
    for pf in "${orphans[@]}"; do
      prefix="$(default_prefix)"
      src="$(wine_source_of "$pf" 2>/dev/null)" || src=""
      [[ -n $src ]] && prefix="${src%%/drive_c/*}"
      state_register_install "$(plugin_key "$pf")" "$prefix" "$pf"
      registered+=("$(basename "$pf")  ($(plugin_group_label "$pf"))")
    done
    ok "Cleanup: registered ${#registered[@]} untracked plugin(s) into the log (files kept)"
  fi

  # 3. Duplicate file tracking: one path referenced by several keys. Keep it
  #    under the alphabetically-first key only; the disk is never touched.
  if state_compatible; then
    local tmp_dup
    tmp_dup=$(mktemp)
    if jq -S '
        . as $root |
        (.plugins | to_entries | [.[].value.files[]? | select(. != null)]) as $all |
        (reduce $all[] as $fp ({}; .[$fp // ""] = ((.[$fp // ""]) + 1))) as $counts |
        .plugins |= with_entries(
          .key as $k |
          .value.files |= [ .[] | select(. != null)
            | . as $fp |
            if ($counts[$fp // ""] // 0) <= 1 then $fp
            else
              (($root.plugins | to_entries | sort_by(.key) | map(select((.value.files // []) | index($fp))) | .[0].key)) as $owner |
              if $k == $owner then $fp else empty end
            end
          ]
        )
      ' "$STATE_FILE" > "$tmp_dup" 2>/dev/null; then
      if ! cmp -s "$tmp_dup" "$STATE_FILE"; then
        mv "$tmp_dup" "$STATE_FILE"
        deduped+=("cross-key duplicate file reference")
        ok "Cleanup: deduplicated a file tracked under several keys (log only)"
      else
        rm -f "$tmp_dup"
      fi
    else
      rm -f "$tmp_dup"
    fi
  fi

  # 4. Dangling launchers: a generated .desktop for a standalone whose exe no
  #    longer exists on disk is pure debris (the launcher can only fail).
  mkdir -p "$APPS_DIR" 2>/dev/null || true
  while IFS= read -r k; do
    [[ -n $k ]] || continue
    local base f slug
    while IFS=$'\t' read -r base f; do
      [[ -n $base ]] || continue
      [[ -e $base ]] && continue
      slug="$APPS_DIR/$DESKTOP_SLUG-$(basename "${base%.exe}" | tr ' ' '-' | tr -cd '[:alnum:]-').desktop"
      if [[ -f $slug ]]; then
        rm -f "$slug"
        desktops+=("$(basename "$slug")")
      fi
    done <<< "$(state_plugin_standalones "$k" 2>/dev/null)"
  done <<< "$(state_list_keys)"
  ((${#desktops[@]})) && ok "Cleanup: removed ${#desktops[@]} dangling menu entr(y/ies) (exe gone)"

  if ((${#kept[@]} == 0 && ${#registered[@]} == 0 && ${#deduped[@]} == 0 && ${#desktops[@]} == 0)); then
    ok "Cleanup: everything already consistent"
  fi

  # Machine-readable report -- only when something consumes it (stdout is not
  # a terminal; e.g. the actions script's `cleanup | tail -1`). Interactive
  # runs just show the human lines above.
  if [[ ! -t 1 ]]; then
    jq -nc \
      --argjson kept "$(printf '%s\n' "${kept[@]:-}" | grep -v '^$' | jq -Rs 'split("\n") | map(select(. != ""))')" \
      --argjson registered "$(printf '%s\n' "${registered[@]:-}" | grep -v '^$' | jq -Rs 'split("\n") | map(select(. != ""))')" \
      --argjson desktops "$(printf '%s\n' "${desktops[@]:-}" | grep -v '^$' | jq -Rs 'split("\n") | map(select(. != ""))')" \
      --argjson deduped "$(printf '%s\n' "${deduped[@]:-}" | grep -v '^$' | jq -Rs 'split("\n") | map(select(. != ""))')" \
      '{kept:$kept,registered:$registered,desktops:$desktops,deduped:$deduped}'
  fi
}

# ── Interactive menu ────────────────────────────────────────────────────────
# Omarchy's app launcher shows a "Launching <app>…" OSD (AppLibrary.qml) that
# only closes when an app opens a toplevel window. This menu opens none, so the
# OSD would linger the whole session; close it best-effort a few times around
# the launch window instead.
suppress_launch_osd() {
  command -v omarchy-shell >/dev/null 2>&1 || return 0
  ( for _ in 1 2 3 4; do sleep 1; omarchy-shell -q osd close >/dev/null 2>&1; done ) &
}

# Flat prefs file (same load_prefs/save_prefs shape as the sibling
# mosquito-move-manager module's lib-move-manager-core.sh — one shared
# convention across both managers rather than a second, different
# persistence mechanism). The file-picker preference (above) stays its own
# single-value file — already deployed and working, no reason to migrate
# it into this one too.
load_prefs() {
  HIDE_VST2="false"
  HIDE_32BIT="false"
  PLUGIN_SORT_MODE="vendor"   # vendor (default) | name | format | date
  # How yabridged plugin EDITOR windows are managed. "hyprland" (the
  # Omarchy way): the editor surface is a plain toplevel Hyprland handles
  # itself — the current default everywhere. "classic" adds a static
  # Hyprland rule so wine plugin editors float with normal system
  # decorations (the "plasma/gnome-style frame" the user asked for, since
  # plain XWayland editor windows without it refuse interaction on this
  # setup).Configured in Settings; applies to future installs and to a
  # freshly written yabridge toml (see apply_plugin_handler).
  PLUGIN_WIN_HANDLER="hyprland"  # hyprland | classic
  PLUGINS_ROOT=""
  DOWNLOADS_DIR="$HOME/Downloads"   # default plugin installation file directory
  WIZARD_DONE=0   # 1 once the first-launch wizard has run (actions wizard-set-root)
  [[ -f $PREFS_FILE ]] && source "$PREFS_FILE" || true
  [[ ${WIZARD_DONE:-0} == 1 ]] && WIZARD_DONE=1 || WIZARD_DONE=0
  case "${PLUGIN_WIN_HANDLER:-}" in hyprland|classic) ;; *) PLUGIN_WIN_HANDLER="hyprland" ;; esac
  if [[ -z $PLUGINS_ROOT ]]; then
    # First run under this version: an existing install already has real
    # plugin files under the legacy default ($HOME/VST) -- keep using it
    # rather than silently switching underneath it (would orphan
    # yabridgectl's plugin_dirs and the state log's file tracking without
    # an explicit migration); a genuinely fresh install starts directly at
    # the new unified default. Either way this is saved once so it's a
    # stable decision from here on -- the only thing that changes it again
    # is an explicit migrate_plugins_root() call (Settings -> Plugins
    # folder).
    if [[ -d "$HOME/VST" ]] && find "$HOME/VST" -mindepth 1 -type f -print -quit 2>/dev/null | grep -q .; then
      PLUGINS_ROOT="$HOME/VST"
    else
      PLUGINS_ROOT="$HOME/Music/Audio Plugins"
      init_plugins_root
    fi
    save_prefs
  elif [[ "$PLUGINS_ROOT" == "$HOME/VST" || "$PLUGINS_ROOT" == "$HOME/Music/Plugins" ]] \
      && ! find "$PLUGINS_ROOT" -mindepth 1 -type f -print -quit 2>/dev/null | grep -q .; then
    # A legacy root that never accumulated any real plugin files (only the
    # empty per-format subfolders, like a half-initialized setup): point the
    # manager at the new default instead of leaving it aiming at an empty
    # legacy path -- non-destructive, nothing to move.
    PLUGINS_ROOT="$HOME/Music/Audio Plugins"
    init_plugins_root
    save_prefs
  fi
  apply_plugins_root
  # NOTE: deliberately NO apply_plugin_handler here. Loading prefs (every
  # status/list/launch invocation) must never touch ~/.config/hypr/hyprland.lua
  # — doing so rewrote the Omarchy config and triggered a hyprctl reload on
  # every launch, which the user experienced as "my Hyprland config reset when
  # I opened the manager". The handler rule block is written ONLY when the
  # user actually flips the Plugin window handler setting (set_plugin_handler)
  # or when a per-plugin fix is applied/removed (fix_apply/fix_remove ->
  # fix_write_block).
}

# Fresh root layout for the plugins folder: one Music-level folder holding
# one lowercase per-format subfolder, all created up-front so the manager
# (and any DAW pointed at it) has a complete structure from day one.
init_plugins_root() {
  mkdir -p "$PLUGINS_ROOT"/{vst,vst3,clap,clap-native,vst3-native,lv2}
  set_plugins_root_icon "$PLUGINS_ROOT"
}

# Best-effort custom folder icon (reuses the app's own deployed icon) for a
# freshly created PLUGINS_ROOT, via GVFS metadata (gio) -- respected by
# Nautilus/GTK file managers and pickers; a no-op where gio or the icon
# file isn't available (e.g. superfile, the terminal FM this module's own
# setup defaults to, has no concept of folder icons at all -- this is
# purely for anyone who also browses the folder graphically).
set_plugins_root_icon() {
  local dir="$1" icon="$HOME/.local/share/icons/hicolor/256x256/apps/mosquito-audio-plugin-manager.png"
  command -v gio >/dev/null 2>&1 || return 0
  [[ -f $icon ]] || return 0
  gio set "$dir" metadata::custom-icon "file://$icon" >/dev/null 2>&1 || true
}

save_prefs() {
  mkdir -p "$(dirname "$PREFS_FILE")"
  cat > "$PREFS_FILE" <<EOF
HIDE_VST2="$HIDE_VST2"
HIDE_32BIT="$HIDE_32BIT"
PLUGIN_SORT_MODE="$PLUGIN_SORT_MODE"
PLUGINS_ROOT="$PLUGINS_ROOT"
DOWNLOADS_DIR="$DOWNLOADS_DIR"
PLUGIN_WIN_HANDLER="$PLUGIN_WIN_HANDLER"
WIZARD_DONE="$WIZARD_DONE"
EOF
  write_dir_readme
}

# apply_plugin_handler: install/remove the STATIC Hyprland rules that make
# wine plugin editor windows behave like classic GTK/Qt windows (floating,
# with the system title bar — the "plasma/gnome-style frame" that lets
# their GUIs receive interaction under this compositor; several yabridged
# editors were reported inert before this toggle). Written into Omarchy's
# own hyprland.lua between label markers, so re-running the flip removes
# and rewrites exactly its own block, idempotently. handler="hyprland"
# removes the block (Hyprland's own tiling manages the editors).
apply_plugin_handler() {
  local lua="$HOME/.config/hypr/hyprland.lua"
  [[ -f $lua ]] || { warn "hyprland.lua not found — plugin-handler rules skipped"; return 0; }
  local _before; _before="$(mktemp)"
  cp -p "$lua" "$_before"
  # Idempotent strip of our labeled block. SAFE by construction: it drops
  # ONLY the known handler lines (its markers, its comment lines, its one
  # o.window rule) line by line — never a regex that can span unrelated
  # content. The previous "legacy" regex (`start marker .. first o.window`)
  # could delete the whole Omarchy preamble when a stray marker sat above
  # it, gutting hyprland.lua (the "emergency mode" bug).
  #
  # GUARD: the ORIGINAL file's preamble is captured first and the write is
  # refused only when the strip would DROP a preamble that WAS present. The
  # old guard tested the post-strip result for the literal tokens and so
  # false-positived ("refusing to write a gutted hyprland.lua") on any valid
  # config that legitimately has neither token, and never actually protected
  # anything when the original was already empty. Writing an empty result is
  # refused outright.
  #
  # The old drop entry for the `-- "\\."` comment line spelled the pattern
  # with ONE backslash, so it never matched the line the block actually
  # emits (two backslashes) — every run re-appended that comment, leaving
  # the repeating "-- \\." lines the user saw. The pattern below matches the
  # real line.
  if ! python3 - "$lua" <<'PYLUA'
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    original = f.read()
lines = original.split("\n")
drop = (
    "-- >>> mosquito_plugin_handler",
    "-- <<< mosquito_plugin_handler",
    "-- yabridged wine plugin GUIs",
    "-- their own UIs are interactable",
    "-- Covers yabridge editor toplevels",
    "-- NOTE: the pattern is a Lua string",
    '-- "\\\\.',
    "-- `hyprctl reload` fail parse",
    'o.window({ class = "^(yabridge-',
)
keep = [ln for ln in lines if not ln.strip().startswith(drop)]
data = "\n".join(keep).rstrip("\n") + "\n"
def has_preamble(s):
    return "default.hypr.omarchy" in s or "require(" in s
if not data.strip() or (has_preamble(original) and not has_preamble(data)):
    sys.stderr.write("refusing to write a gutted hyprland.lua\n")
    sys.exit(3)
with open(path, "w", encoding="utf-8") as f:
    f.write(data)
PYLUA
  then
    rm -f "$_before"
    warn "hyprland.lua looks gutted — plugin-handler block left untouched"
    return 0
  fi
  if [[ $PLUGIN_WIN_HANDLER == classic ]]; then
    cat >> "$lua" <<'LUABLOCK'
-- >>> mosquito_plugin_handler
-- yabridged wine plugin GUIs float as classic decorated windows so
-- their own UIs are interactable (Hyprland tiling leaves them inert).
-- Covers yabridge editor toplevels and bare wine .exe windows.
-- NOTE: the pattern is a Lua string, so the regex dot MUST be written
-- "\\." — a bare "\." is an invalid Lua escape sequence and makes
-- `hyprctl reload` fail parse the whole file.
o.window({ class = "^(yabridge-.*|.*\\.exe|wine.*)$" }, { float = true })
-- <<< mosquito_plugin_handler
LUABLOCK
    # Silent on purpose: this runs from set_plugin_handler (the user just
    # confirmed the change) and `ok` writes to stdout — printing here would
    # pollute the JSON command output the Go TUI parses (status-json,
    # list-all-plugins, …). The user-visible confirmation is
    # set_plugin_handler()'s own msg.
  fi
  # Reload Hyprland ONLY when the file really changed. This used to run on
  # EVERY actions invocation because load_prefs() called it; an unconditional
  # `hyprctl reload` re-applied the whole config (monitors/autostart/rules)
  # and read as "opening the manager reset my Hyprland config". The call was
  # removed from load_prefs entirely, and even here an unchanged file is a
  # no-op.
  if cmp -s "$_before" "$lua"; then
    rm -f "$_before"
    return 0
  fi
  rm -f "$_before"
  hyprctl reload >/dev/null 2>&1 || true
}

set_plugin_handler() {
  case "${1,,}" in
    classic|hyprland) ;;
    *) echo "unknown handler: $1 (use classic|hyprland)" >&2; return 1 ;;
  esac
  PLUGIN_WIN_HANDLER="${1,,}"
  save_prefs
  apply_plugin_handler
  msg "plugin window handler: $PLUGIN_WIN_HANDLER"
}

# ── Plugin fixes ────────────────────────────────────────────────────────────
# A fix is a small, independently idempotent rule block written into
# ~/.config/hypr/hyprland.lua between its own markers
# (-- >>> mosquito_fix_<id> .. -- <<< mosquito_fix_<id>). The applied state
# (which plugin a fix was applied for) lives in fixes.json; the Lua block is
# always regenerated from that state, so re-applying or removing cannot stack
# duplicate rules. Global fixes (scope=global) ignore the plugin and use the
# synthetic "__global__" marker so they are applied at most once.
fixes_state_init() {
  mkdir -p "$(dirname "$FIXES_STATE")" 2>/dev/null || true
  [[ -f $FIXES_STATE ]] || printf '%s\n' '{"applied":{}}' > "$FIXES_STATE"
}

# id|title|scope|description|category|plugin — one fix per line. The
# category is the picker's expanded-folder heading ("▾ Plugin windows"), so
# fixes that belong together are visually grouped and a whole category can be
# toggled with one key. The optional 6th field names the product a fix is
# specific to (e.g. "CrispyTuner"); the TUI groups such fixes under their
# "<Product> specific" category and does NOT tag the row again — the category
# already names the product. A plugin-specific fix is NEVER hidden: it stays
# visible and selectable for every plugin, since the same Wine issues can
# show up elsewhere. Fixes with an empty 6th field are generic. Fields 1/2/3
# must keep their fixed index (fix_id_valid/fix_scope_of/fix_title_for).
fixes_catalog() {
  cat <<'FIXCAT'
wine_gui_input|Wine plugin GUI input (Hyprland/XWayland)|plugin|Plugin editor windows float, unblurred and receive XWayland input even when the plugin asks not to (fixes inert / non-clickable GUIs such as CrispyTuner in Bitwig or REAPER). Applied per plugin, matched on the window title because these editors usually have an empty class.|Plugin windows|CrispyTuner
wine_tooltip|Ableton/Wine hover tooltips|plugin|Keeps the hover tooltips Wine plugins (e.g. CrispyTuner) create inside Ableton floating, unblurred, animation-free and never focused, so hovering them stops stealing input from the plugin. Applied once, independently of the chosen plugin.|CrispyTuner specific|CrispyTuner
cursor_no_warp|Stop the cursor recentering|global|Hyprland 0.56.2 has no per-window warp rule: this is a GLOBAL cursor option (cursor:no_warps + cursor:persistent_warps). Affects the whole desktop, not just Wine — only enable after confirming the recentering is Hyprland focus-warp and not Wine's own pointer handling.|Cursor|
FIXCAT
}

fix_id_valid() { fixes_catalog | cut -d'|' -f1 | grep -qx -- "$1"; }
fix_scope_of() { fixes_catalog | awk -F'|' -v id="$1" '$1==id{print $3}'; }
fix_title_for() { fixes_catalog | awk -F'|' -v id="$1" '$1==id{print $2}'; }

fixes_list_json() {
  while IFS='|' read -r id title scope desc category plugin; do
    [[ -n $id ]] || continue
    jq -nc --arg id "$id" --arg title "$title" --arg scope "$scope" --arg desc "$desc" --arg category "$category" --arg plugin "$plugin" \
      '{id:$id,title:$title,scope:$scope,description:$desc,category:$category,plugin:$plugin}'
  done < <(fixes_catalog)
}

# Plugin labels recorded for a fix id.
fix_applied_plugins() {
  fixes_state_init
  jq -r --arg id "$1" '.applied[$id] // [] | .[]' "$FIXES_STATE" 2>/dev/null
}

# fixes_applied_plugins — every plugin stem (fix_plugin_canonical form) that
# has at least one fix recorded as applied. A "__global__" entry is skipped:
# a global fix is not a per-plugin signal, so it must not light up every row.
# Feeds the fixes plugin chooser's accent indicator (list-applied-fix-plugins).
fixes_applied_plugins() {
  fixes_state_init
  jq -r '.applied // {} | to_entries[] | .value[]' "$FIXES_STATE" 2>/dev/null |
    while IFS= read -r p; do
      [[ -n $p && $p != __global__ ]] || continue
      fix_plugin_canonical "$p"
    done | sort -u
}

# fixes_state_path_of <plugin> — the bare plugin path behind a picker value
# ("vst:<type>:<path>", "native:<path>", "win:<path>") or a plain path.
fixes_state_path_of() {
  local p="$1"
  case "$p" in
    vst:*)    p="${p#vst:}"; p="${p#*:}" ;;
    native:*) p="${p#native:}" ;;
    win:*)    p="${p#win:}" ;;
  esac
  printf '%s\n' "$p"
}

# fix_plugin_canonical <plugin> — the stable per-plugin key a fix is recorded
# under: the product stem (basename minus extension), the same shape
# install_plugin() passes to apply_known_fixes_for(). Reducing every
# self-describing value ("vst:<type>:<path>", "native:<path>", "win:<folder>",
# a bare path, or a bare stem) to this one key is what makes fixes.json
# independent of the picker shape a change arrived in — and, for
# wine_gui_input, makes the generated title regex match the editor WINDOW
# TITLE (the product name) instead of the full "vst:vst3:/…" path. The
# synthetic "__global__" marker passes through untouched.
fix_plugin_canonical() {
  local p="$1" path stem
  [[ $p == __global__ ]] && { printf '%s\n' "$p"; return 0; }
  path="$(fixes_state_path_of "$p")"
  stem="$(basename "$path")"
  stem="${stem%%.*}"
  [[ -n $stem ]] || stem="$p"
  printf '%s\n' "$stem"
}

# fix_applied_for_plugin <fix-id> <plugin> — is the fix recorded as applied
# for this plugin? Both sides are canonicalized, so EVERY representation the
# state may hold (the full self-describing picker value, the bare plugin path,
# or the product stem install-time known fixes are recorded under) matches
# EVERY query shape — fixing the old one-way bug where a full value stored by
# the TUI never matched a stem query, leaving an applied fix unchecked and
# reporting "no change" on re-apply. A "__global__" entry also counts, so a
# global rule (or one mis-recorded globally) still reads as applied.
fix_applied_for_plugin() {
  local id="$1" plugin="$2" want stored
  want="$(fix_plugin_canonical "$plugin")"
  while IFS= read -r stored; do
    [[ -n $stored ]] || continue
    [[ $stored == __global__ ]] && return 0
    [[ "$(fix_plugin_canonical "$stored")" == "$want" ]] && return 0
  done < <(fix_applied_plugins "$id")
  return 1
}

# fix_set_applied_list <fix-id> <plugin...> — replaces the recorded plugin
# list for a fix id with exactly the given entries (already canonical).
fix_set_applied_list() {
  local id="$1"; shift
  local -a list=("$@")
  local tmp json
  if ((${#list[@]})); then
    json="$(printf '%s\n' "${list[@]}" | jq -R . | jq -s 'unique')"
  else
    json='[]'
  fi
  tmp="$(mktemp)"
  jq --arg id "$id" --argjson list "$json" '.applied[$id] = $list' "$FIXES_STATE" > "$tmp" && mv "$tmp" "$FIXES_STATE"
}

# list-plugin-fixes <plugin>: every fix with an "applied" flag for that plugin.
fixes_for_plugin_json() {
  local plugin="$1" id title scope desc category pfix applied
  while IFS='|' read -r id title scope desc category pfix; do
    [[ -n $id ]] || continue
    applied=false
    # One matcher for both scopes now: fix_applied_for_plugin treats a
    # "__global__" record as applied for any plugin (so a global fix is
    # globally on and a global-but-recorded-per-plugin fix still lights up
    # for that plugin), and a per-plugin record matches only its plugin.
    fix_applied_for_plugin "$id" "$plugin" && applied=true
    jq -nc --arg id "$id" --arg title "$title" --arg scope "$scope" --arg desc "$desc" --arg category "$category" --arg plugin "$pfix" --argjson applied "$applied" \
      '{id:$id,title:$title,scope:$scope,description:$desc,category:$category,plugin:$plugin,applied:$applied}'
  done < <(fixes_catalog)
}

# RE2/Lua-safe rendering of a plugin name into a Hyprland title regex.
fix_re_escape() {
  python3 -c 'import re,sys; print(re.escape(sys.argv[1]).replace(chr(34), chr(92)+chr(34)))' "$1"
}

# fix_render_rules <fix> <plugin...> — the Lua body (comments + rules) for a
# fix. For global fixes the plugin list is ignored.
fix_render_rules() {
  local fix="$1"; shift
  local -a plugins=("$@")
  local p esc
  case "$fix" in
    wine_gui_input)
      printf '%s\n' '-- Keeps wine/yabridge plugin editor windows floating + unblurred.'
      printf '%s\n' 'o.window({ class = "^(yabridge-.*|.*\\.exe|wine.*)$" }, { float = true, no_blur = true })'
      for p in "${plugins[@]}"; do
        [[ -n $p ]] || continue
        # Canonicalize here too, so a state written by an older build (full
        # "vst:vst3:/…" value) still emits a title regex that matches the
        # editor window title (the product stem) instead of the file path.
        esc="$(fix_re_escape "$(fix_plugin_canonical "$p")")"
        # Match the editor's REAL title, which is host-prefixed, e.g.
        # "VST3: CrispyTuner (CrispyAudio) - Track 1" in REAPER — an anchored
        # "^CrispyTuner" never matched (the user's inert-GUI bug). Case-
        # insensitive substring on the product name.
        printf 'o.window({ title = "(?i).*%s.*", xwayland = true }, { float = true, no_blur = true, allows_input = true })\n' "$esc"
      done
      ;;
    wine_tooltip)
      printf '%s\n' '-- Ableton/Wine hover tooltips: float, no blur/animation, never focused.'
      printf '%s\n' 'o.window({ class = "^ableton live 12 suite\\.exe$", title = "^tooltip$" },'
      printf '%s\n' '         { float = true, no_blur = true, no_anim = true, no_focus = true,'
      printf '%s\n' '           suppress_event = "activate activatefocus" })'
      ;;
    cursor_no_warp)
      printf '%s\n' '-- GLOBAL: stop Hyprland warping/recentering the cursor on focus changes.'
      printf '%s\n' 'hl.config({ cursor = { no_warps = true, persistent_warps = true } })'
      ;;
  esac
}

# Strips this fix's block from hyprland.lua, then rewrites it from the current
# plugin list (no list -> the block stays removed).
fix_write_block() {
  local fix="$1"; shift
  local -a plugins=("$@")
  local lua="$HOME/.config/hypr/hyprland.lua"
  [[ -f $lua ]] || { warn "hyprland.lua not found — fix rules not written"; return 0; }
  local _before; _before="$(mktemp)"
  cp -p "$lua" "$_before"
  # GUARD: capture the ORIGINAL first and refuse only when the strip would
  # DROP a preamble that WAS present (never on a valid file that happens not
  # to contain the literal tokens, and never writing an empty result). See
  # the fuller rationale on apply_plugin_handler's identical guard.
  if ! FIX_STRIP="$fix" python3 - "$lua" <<'PYLUA'
import os, re, sys
path = sys.argv[1]
fix = os.environ["FIX_STRIP"]
with open(path, encoding="utf-8") as f:
    original = f.read()
# Bounded strip: never cross the next `-- >>> ...` start marker, so a block
# with a missing end marker can't swallow unrelated content.
data = re.sub(
    r"(?ms)^-- >>> mosquito_fix_" + re.escape(fix) + r"\n(?:(?!^-- >>> ).)*?^-- <<< mosquito_fix_" + re.escape(fix) + r"[^\n]*\n?",
    "",
    original,
)
def has_preamble(s):
    return "default.hypr.omarchy" in s or "require(" in s
if not data.strip() or (has_preamble(original) and not has_preamble(data)):
    sys.stderr.write("refusing to write a gutted hyprland.lua\n")
    sys.exit(3)
with open(path, "w", encoding="utf-8") as f:
    f.write(data)
PYLUA
  then
    rm -f "$_before"
    warn "hyprland.lua looks gutted — fix rules left untouched"
    return 0
  fi
  if ((${#plugins[@]})); then
    {
      printf '%s\n' "-- >>> mosquito_fix_${fix}"
      printf '%s\n' "-- mosquito fix: $(fix_title_for "$fix") — applied for: ${plugins[*]}"
      fix_render_rules "$fix" "${plugins[@]}"
      printf '%s\n' "-- <<< mosquito_fix_${fix}"
    } >> "$lua"
    ok "hyprland rule block written: $fix"
  else
    ok "hyprland rule block removed: $fix"
  fi
  # Only reload Hyprland when the file actually changed.
  if cmp -s "$_before" "$lua"; then
    rm -f "$_before"
    return 0
  fi
  rm -f "$_before"
  if command -v hyprctl >/dev/null 2>&1; then hyprctl reload >/dev/null 2>&1 || true; fi
}

# fix_apply <plugin> <fix...>
# Records the plugin under its canonical stem (not the raw picker value) and
# drops any older, equivalent entry first, so the state stays shape-stable
# and a re-apply can never leave a stale full "vst:vst3:/…" duplicate behind.
# Global fixes collapse to the single "__global__" marker.
fix_apply() {
  local plugin="$1"; shift
  (($#)) || { echo "no fixes given" >&2; return 2; }
  fixes_state_init
  local fix scope target
  for fix in "$@"; do
    fix_id_valid "$fix" || { echo "unknown fix: $fix" >&2; return 2; }
    scope="$(fix_scope_of "$fix")"
    target="$(fix_plugin_canonical "$plugin")"
    local -a list=()
    if [[ $scope == global ]]; then
      list=("__global__")
    else
      local p
      while IFS= read -r p; do
        [[ -n $p ]] || continue
        [[ "$(fix_plugin_canonical "$p")" == "$target" ]] && continue
        list+=("$p")
      done < <(fix_applied_plugins "$fix")
      list+=("$target")
    fi
    fix_set_applied_list "$fix" "${list[@]}"
    local -a plugins=()
    while IFS= read -r p; do [[ -n $p ]] && plugins+=("$p"); done < <(fix_applied_plugins "$fix")
    fix_write_block "$fix" "${plugins[@]}"
    ok "fix applied: $(fix_title_for "$fix")"
  done
}

# fix_remove <plugin> <fix...>
# Removes the plugin whatever shape it was recorded in (full value, bare path,
# stem) plus any stale "__global__" marker, so the checkbox really clears.
fix_remove() {
  local plugin="$1"; shift
  (($#)) || { echo "no fixes given" >&2; return 2; }
  fixes_state_init
  local fix target p
  for fix in "$@"; do
    target="$(fix_plugin_canonical "$plugin")"
    local -a list=()
    while IFS= read -r p; do
      [[ -n $p ]] || continue
      [[ $p == __global__ ]] && continue
      [[ "$(fix_plugin_canonical "$p")" == "$target" ]] && continue
      list+=("$p")
    done < <(fix_applied_plugins "$fix")
    fix_set_applied_list "$fix" "${list[@]}"
    local -a plugins=()
    while IFS= read -r p; do [[ -n $p ]] && plugins+=("$p"); done < <(fix_applied_plugins "$fix")
    fix_write_block "$fix" "${plugins[@]}"
    ok "fix removed: $(fix_title_for "$fix")"
  done
}

# Install-time dependencies: plugins whose editor needs a fix applied
# automatically the first time they are installed. Pattern (case-insensitive
# substring) <TAB> fix ids.
known_plugin_fixes() {
  cat <<'FIXDEPS'
CrispyTuner	wine_gui_input	wine_tooltip
FIXDEPS
}

apply_known_fixes_for() {
  local name="$1" pat ids fix
  [[ -n $name ]] || return 0
  while IFS=$'\t' read -r pat ids; do
    [[ -n $pat ]] || continue
    [[ "${name,,}" == *"${pat,,}"* ]] || continue
    for fix in $ids; do fix_apply "$pat" "$fix"; done
    msg "known fixes applied for $pat: $ids"
  done < <(known_plugin_fixes)
}

# propose_fixes_after_install <plugin> — after a successful install, offer the
# catalog's plugin-scope fixes that are not applied yet for the freshly
# installed plugin. Uses the core's own ui_confirm: the interactive
# flag-driven path prompts, while the non-interactive actions backend stubs
# ui_confirm to "no" (so a TUI/headless install never blocks here — the Go
# TUI runs its own tuikit confirm and drives apply-fixes instead). Always
# returns 0 so `set -e` never turns a dismissed prompt into an install error.
propose_fixes_after_install() {
  local plugin="$1" id title scope desc category pfix
  [[ -n $plugin ]] || return 0
  local -a ids=()
  while IFS='|' read -r id title scope desc category pfix; do
    [[ -n $id ]] || continue
    [[ $scope == plugin ]] || continue
    fix_applied_for_plugin "$id" "$plugin" && continue
    ids+=("$id")
  done < <(fixes_catalog)
  if ((${#ids[@]})); then
    ui_confirm "Apply fixes for $(basename "$(fixes_state_path_of "$plugin")") now?" \
      && fix_apply "$plugin" "${ids[@]}" || true
  fi
  return 0
}

# Writes a small README.md into the manager's config directory, reflecting the
# current preferences. Regenerated on every save_prefs() call (any setting
# change) and at install time, so the file is always up-to-date.
write_dir_readme() {
  local dir="$HOME/.config/audio-plugin-manager"
  mkdir -p "$dir" 2>/dev/null || return 0
  local fp fp_label
  fp="$(current_file_picker 2>/dev/null || echo default)"
  if [[ $fp == superfile ]]; then fp_label="Superfile"; else fp_label="Default"; fi
  cat > "$dir/README.md" <<EOF
# mosquito Audio Plugin Manager

This file is regenerated automatically whenever you change a preference
via the TUI (Main menu → Settings).

## Current configuration

- **Default plugin installation file directory**: \`${DOWNLOADS_DIR:-$HOME/Downloads}\`
- **Plugins folder**: \`${PLUGINS_ROOT:-$HOME/Music/Plugins}\`
- **File picker**: ${fp_label}

EOF
}

# Derives every plugin-storage path from PLUGINS_ROOT -- called at the end
# of load_prefs() so every real entry point (the actions script, main())
# picks this up automatically. vst/vst3/clap stay the Windows/wine/
# yabridge-only folders (unchanged mechanism, just relocated under the new
# root); lv2 is native-only (no Windows equivalent in this tool, so no
# collision risk). Native VST3/CLAP get their OWN sibling folders
# (vst3-native/clap-native) rather than sharing the Windows ones:
# yabridgectl's plugin_dirs scan (and our own scan_plugins()) is RECURSIVE
# with no exclude mechanism, so a genuine native Linux .vst3/.clap sitting
# in the same folder as the Windows ones would get picked up and
# mis-treated as a bridgeable Windows plugin (confirmed via a real
# `yabridgectl status` on this machine -- its plugin_dirs already recurses
# into vendor subfolders). Everything still lives under the one
# PLUGINS_ROOT, satisfying "one folder to point every plugin at".
apply_plugins_root() {
  VST_ROOT="${AUDIOSTACK_VST_ROOT:-$PLUGINS_ROOT}"
  VST_VST2="$VST_ROOT/vst"
  VST_VST3="$VST_ROOT/vst3"
  VST_CLAP="$VST_ROOT/clap"
  NATIVE_LV2_DIRS_USER=("$VST_ROOT/lv2")
  NATIVE_CLAP_DIRS_USER=("$VST_ROOT/clap-native")
  NATIVE_VST3_DIRS_USER=("$VST_ROOT/vst3-native")
}

# Rewrites the state log's recorded plugin file paths after a
# migrate_plugins_root() move, so prefix-tracking/reconcile-missing keep
# matching reality instead of pointing at the now-vacated old root.
# Standalone-executable paths are untouched -- those live under the wine
# PREFIX itself (Program Files/...), which migrate_plugins_root() never
# moves, only PLUGINS_ROOT does.
state_rewrite_root() {
  local old="$1" new="$2" tmp
  state_compatible || return 0
  tmp=$(mktemp)
  jq --arg old "$old" --arg new "$new" \
    '.plugins |= with_entries(.value.files |= map(if startswith($old + "/") then ($new + ltrimstr($old)) else . end))' \
    "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

# Moves every plugin file from the CURRENT PLUGINS_ROOT to a new one,
# re-registers yabridgectl's watched directories (it independently tracks
# which folders to scan — plugin_dirs — separately from where the files
# physically live), re-links every wine prefix + re-syncs yabridge via the
# existing post_install(), and rewrites the state log so prefix
# tracking/reconcile-missing survive the move. Non-destructive: `mv -n`
# never overwrites an existing file at the destination.
migrate_plugins_root() {
  local new_root="${1:?new plugins folder required}" old_root="$VST_ROOT"
  new_root="${new_root%/}"
  if [[ $new_root == "$old_root" ]]; then
    ok "already using $new_root"
    return 0
  fi

  local old_vst2="$VST_VST2" old_vst3="$VST_VST3" old_clap="$VST_CLAP"
  local old_lv2="${NATIVE_LV2_DIRS_USER[0]}" old_clapn="${NATIVE_CLAP_DIRS_USER[0]}" old_vst3n="${NATIVE_VST3_DIRS_USER[0]}"
  local new_vst2="$new_root/vst" new_vst3="$new_root/vst3" new_clap="$new_root/clap"
  local new_lv2="$new_root/lv2" new_clapn="$new_root/clap-native" new_vst3n="$new_root/vst3-native"

  msg "Moving plugins: $old_root → $new_root"
  mkdir -p "$new_root"
  set_plugins_root_icon "$new_root"

  local pair src dst
  for pair in "$old_vst2:$new_vst2" "$old_vst3:$new_vst3" "$old_clap:$new_clap" \
              "$old_lv2:$new_lv2" "$old_clapn:$new_clapn" "$old_vst3n:$new_vst3n"; do
    src="${pair%%:*}"; dst="${pair#*:}"
    [[ -d $src ]] || continue
    mkdir -p "$dst"
    find "$src" -mindepth 1 -maxdepth 1 -exec mv -n -t "$dst" -- {} + 2>/dev/null || true
  done

  if command -v yabridgectl >/dev/null; then
    local d
    for d in "$old_vst2" "$old_vst3" "$old_clap"; do
      yabridgectl list 2>/dev/null | grep -qx "$d" && { yabridgectl rm "$d" >/dev/null 2>&1 || true; }
    done
    for d in "$new_vst2" "$new_vst3" "$new_clap"; do
      yabridgectl list 2>/dev/null | grep -qx "$d" || { yabridgectl add "$d" >/dev/null 2>&1 || true; }
    done
  fi

  state_rewrite_root "$old_root" "$new_root"

  PLUGINS_ROOT="$new_root"
  save_prefs
  apply_plugins_root
  post_install

  # setup-audio-stack.sh's optional autosync systemd unit (a SEPARATE
  # module) hardcodes the watched folders at the time it was enabled --
  # only touched here if the user actually has it, same managed-heredoc
  # shape that module itself uses.
  local autosync_unit="$HOME/.config/systemd/user/yabridge-autosync.path"
  if [[ -f $autosync_unit ]]; then
    cat > "$autosync_unit" <<EOF
[Unit]
Description=Watch the VST folders for yabridgectl

[Path]
PathModified=$new_vst2
PathModified=$new_vst3
PathModified=$new_clap

[Install]
WantedBy=default.target
EOF
    if command -v systemctl >/dev/null 2>&1; then
      systemctl --user daemon-reload >/dev/null 2>&1 || true
      systemctl --user restart yabridge-autosync.path >/dev/null 2>&1 || true
    fi
    ok "autosync watch updated to the new folders"
  fi

  ok "Plugins folder is now $new_root"
}

current_file_picker() {
  local m
  m=$(cat "$FILE_PICKER_MODE_FILE" 2>/dev/null || echo default)
  [[ $m == superfile ]] && echo superfile || echo default
}

# switch_file_picker() and pick_file_via_superfile() below never need to
# relaunch/reboot the manager: the file-picker preference is just a
# one-line file re-read fresh every time install_flow() runs — the exact
# same process, same session, picks it up on its very next use with
# nothing to restart. superfile itself needs no daemon/reload either: once
# installed, `spf` is immediately runnable.
switch_file_picker() {
  local mode other other_label
  mode=$(current_file_picker)
  if [[ $mode == superfile ]]; then
    other=default; other_label="Default"
  else
    other=superfile; other_label="Superfile"
  fi
  if [[ $other == superfile ]] && ! command -v spf >/dev/null 2>&1; then
    ui_confirm "Superfile isn't installed. Install it now (pacman, official repo — opens a terminal for the sudo password) and switch to it?" "No" "Yes, install" \
      || { ok "kept the current file picker"; return 0; }
    ensure_superfile_installed || { err "superfile install failed — file picker unchanged."; return 1; }
  fi
  mkdir -p "$(dirname "$FILE_PICKER_MODE_FILE")"
  printf '%s\n' "$other" > "$FILE_PICKER_MODE_FILE"
  ok "File picker set to: $other_label"
}

ensure_superfile_installed() {
  # Runs the actual install in a real, visible terminal (not silently in
  # the background) since it needs the user's sudo password — same
  # foot/xterm pair the rest of this module already relies on for exactly
  # this reason (gui-run.bash, the TUI dispatcher's own terminal spawn).
  # Blocks until that terminal closes, so the caller knows install success/
  # failure before deciding whether to flip the preference.
  local cmd='set -e; echo "Installing superfile (pacman, official repo)…"; sudo pacman -S --needed superfile; echo; echo "Done — press Enter to close."; read -r _'
  if command -v foot >/dev/null 2>&1; then
    foot --app-id=org.omarchy.superfile-install -e bash -c "$cmd"
  elif command -v xterm >/dev/null 2>&1; then
    xterm -e bash -c "$cmd"
  else
    err "no terminal emulator found (foot/xterm) to run the install in."
    return 1
  fi
  command -v spf >/dev/null 2>&1
}

pick_file_via_superfile() {
  # $1 = prompt (unused by superfile itself, kept for call-site symmetry
  # with pick_file_manually). Echoes the chosen path, or nothing if the
  # user quit superfile without picking (Esc/q — --chooser-file is simply
  # never written in that case).
  local chosen_file
  chosen_file="$(mktemp -u)"
  local cmd
  cmd="spf --chooser-file $(printf '%q' "$chosen_file") $(printf '%q' "$HOME")"
  if command -v foot >/dev/null 2>&1; then
    foot --app-id=org.omarchy.superfile-picker -e bash -c "$cmd"
  elif command -v xterm >/dev/null 2>&1; then
    xterm -e bash -c "$cmd"
  else
    err "no terminal emulator found (foot/xterm) to run superfile in."
    return 1
  fi
  if [[ -s $chosen_file ]]; then
    cat "$chosen_file"
    rm -f "$chosen_file"
    return 0
  fi
  rm -f "$chosen_file"
  return 1
}

menu_settings() {
  local opt rc=0 fp_label
  while :; do
    fp_label="File picker: $([[ $(current_file_picker) == superfile ]] && echo "Superfile" || echo "Default")"
    opt=$(ui_select --plain "Settings" \
      "$fp_label"$'\tswitch_file_picker' \
      $'Back\tback') || return 0
    case "$opt" in
      switch_file_picker) switch_file_picker ;;
      back|"")             return 0 ;;
      *)                   return 0 ;;
    esac
  done
}

main_menu() {
  local opt rc=0
  suppress_launch_osd
  while :; do
    opt=
    opt=$(ui_select --plain \
      $'mosquito Audio Plugin Manager — wine plugins' \
      $'Plugin list\tlist' \
      $'Install a plugin\tinstall' \
      $'Uninstall a plugin\tuninstall' \
      $'Manage prefixes\tprefixes' \
      $'Launch a standalone plugin\tstandalone' \
      $'Manage visible executables in Omarchy Menu\texecs' \
      $'Cleanup inconsistencies\tcleanup' \
      $'Settings\tsettings' \
      $'Close\tquit' ) || rc=$?
    if (( rc == 2 )); then ok "bye (input closed)"; return 0; fi
    if [[ -z $opt ]]; then
      # Prompt 1 dismissed (Escape): ask to close, like the Close option.
      ui_confirm "Close the mosquito Audio Plugin Manager?" || { ok "kept open"; rc=0; continue; }
      ok "bye (menu dismissed)"; return 0
    fi
    rc=0
    case "$opt" in
      list)        plugin_list || true ;;
      install)     install_flow || true ;;
      uninstall)   uninstall_plugin || true ;;
      prefixes)    manage_prefixes || true ;;
      standalone)  launch_standalone ;;
      execs)       manage_executables || true ;;
      cleanup)     cleanup || true ;;
      settings)    menu_settings ;;
      quit)        ui_confirm "Close the mosquito Audio Plugin Manager?" || { ok "kept open"; continue; }
                   ok "bye"; return 0 ;;
      *)           ok "bye (unexpected)"; return 0 ;;
    esac
  done
}

install_flow() {
  local file="" attempted_superfile=no
  # A file explorer like the old VST manager: superfile first if that's
  # the chosen preference (Settings — File picker) and it's actually
  # installed, then the native Omarchy chooser, then zenity file-selection,
  # then a tty prompt. superfile is the user's OWN explicit choice, so if
  # they quit it without picking (Esc/q), that's a cancel -- it must NOT
  # silently fall through to a completely different chooser UI underneath
  # (previously did, which looked like "superfile closed and nautilus/a
  # zenity dialog opened instead" — confusing and not what was cancelled).
  if [[ $(current_file_picker) == superfile ]] && command -v spf >/dev/null 2>&1; then
    attempted_superfile=yes
    file=$(pick_file_via_superfile "Install a plugin — pick the installer (exe/msi)")
  fi
  if [[ -n $file || $attempted_superfile == yes ]]; then
    :
  elif command -v omarchy-file-select >/dev/null 2>&1 && { [[ -n ${DISPLAY:-} || -n ${WAYLAND_DISPLAY:-} || -n ${OMARCHY_WL:-} ]]; }; then
    file=$(omarchy-file-select --title "Install a plugin — pick the installer (exe/msi)" --extensions "exe msi" 2>/dev/null | head -1)
  elif command -v omarchy-menu-file >/dev/null 2>&1; then
    file=$(omarchy-menu-file "Install a plugin — pick the installer (exe/msi)" "$HOME/Downloads:$HOME/" "exe msi" 2>/dev/null | head -1)
  elif command -v zenity >/dev/null 2>&1 && { [[ -n ${DISPLAY:-} || -n ${WAYLAND_DISPLAY:-} ]]; }; then
    file=$(zenity --file-selection --title="Install a plugin — pick the installer (exe/msi)" \
      --file-filter='Windows installers | *.exe *.EXE *.msi *.MSI' --filename="$HOME/" 2>/dev/null)
  else
    read -rp "Installer path (exe/msi): " file
  fi
  [[ -n $file && -f $file ]] || { ui_info "No file selected."; return 0; }

  # Re-install? Offer to re-run the installer over an existing plugin.
  local stem already=no
  stem="$(basename "$file")"; stem="${stem%.exe}"; stem="${stem%.msi}"
  local k
  while IFS= read -r k; do
    [[ -n $k ]] || continue
    if [[ $k == *"$stem"* || $stem == *"$(plugin_prefix_label "$k")"* ]]; then already=yes; break; fi
  done <<< "$(state_list_keys)"
  if [[ $already == yes ]]; then
    ui_confirm "'$stem' is already installed — re-install over it?" || { ok "kept as-is."; return 0; }
  fi

  # Same prefix (default) or a new one?
  local prefix
  prefix="$(default_prefix)"
  if ui_confirm "Install into the same wine prefix ($prefix)?"; then
    if [[ ! -d "$prefix/drive_c" ]]; then
      # The dedicated default (~/.wine-vst) does not exist yet — bootstrap it.
      msg "Creating wine prefix: $prefix"
      WINEPREFIX="$prefix" wineboot -u >/dev/null 2>&1 || warn "(wineboot returned a non-zero code — continuing)"
      if [[ -d "$prefix/drive_c" ]]; then WINE_PREFIXES+=("$prefix"); fi
    fi
    install_plugin "$file" "$prefix"
  else
    local name newpf
    name=$(ui_input "Name of the new wine prefix (e.g. 'early' → ~/.wine-early):" "") || { ok "cancelled."; return 0; }
    [[ -n $name ]] || { warn "Empty prefix name — cancelled."; return 0; }
    name="$(printf '%s' "$name" | tr ' ' '-' | tr -cd '[:alnum:]-' | tr '[:upper:]' '[:lower:]')"
    newpf="$HOME/.wine-$name"
    if [[ ! -d "$newpf/drive_c" ]]; then
      msg "Creating wine prefix: $newpf"
      WINEPREFIX="$newpf" wineboot -u >/dev/null 2>&1 || warn "(wineboot returned a non-zero code — continuing)"
    fi
    WINE_PREFIXES+=("$newpf")
    install_plugin "$file" "$newpf" new
  fi
}

usage() {
  sed -n '2,15p' "$0"
  cat <<'HELP'

Usage:
  mosquito-audio-plugin-manager             open the interactive TUI
  mosquito-audio-plugin-manager --replace   close any other open TUI, then open it
  mosquito-audio-plugin-manager status      show the current state
  mosquito-audio-plugin-manager launch EXE  launch a plugin's standalone
  mosquito-audio-plugin-manager install FILE  install a plugin from a file
  mosquito-audio-plugin-manager --help | --version
HELP
}

# ── Entry point ─────────────────────────────────────────────────────────────
main() {
  state_init
  load_prefs
  case "${1:-menu}" in
    --help|-h)   usage; exit 0 ;;
    --version)   echo "mosquito-audio-plugin-manager v0.4.0"; exit 0 ;;
    launch)
      [[ -n ${2:-} ]] || { err "usage: mosquito-audio-plugin-manager launch <exe>"; exit 1; }
      msg "Launching wine $2"; setsid wine start /unix "$2" >/dev/null 2>&1 &
      exit 0 ;;
    install)
      [[ -n ${2:-} ]] || { err "usage: mosquito-audio-plugin-manager install <file>"; exit 1; }
      install_plugin "$2"; exit 0 ;;
    status)
      status_report; exit 0 ;;
    menu|"")
      reconcile || true
      ui_ready_or_die
      main_menu
      ;;
    *) err "Unknown option: $1"; usage >&2; exit 1 ;;
  esac
}

