#!/usr/bin/env bash
# =============================================================================
# lib-move-manager-core.sh — "mosquito Move Manager" shared core
#
# All the actual Move → Ableton → Bitwig workflow logic — everything that
# doesn't change between entry points. NOT an entry point: sourced by
# `mosquito-move-manager-actions` (a thin, non-interactive backend — see
# that file's own header) on behalf of `mosquito-move-manager-tui`, a real
# Bubble Tea program (Go, tui-go/) that owns every interactive decision
# itself and calls into that backend once a decision is made; and by the
# stable dispatcher `mosquito-move-manager` itself for the flag-driven
# one-shot actions (status, --midi, … — see below). The TUI is the ONLY
# interface: the dispatcher routes no-argument launches straight into it
# (opening a terminal if needed), so there is no interface switch anywhere
# and no separate native-mode entry point.
#
# UI PRIMITIVE CONTRACT — when an interactive prompt is genuinely needed
# (the flag-driven paths that run through the shared core), the ui_*
# functions are defined INSIDE this file, guarded by
# ${MOSQUITO_MOVE_MANAGER_NATIVE_UI} (set by the dispatcher): the native
# Omarchy overlay (mosquito.confirm / omarchy-menu-input/-select), zenity
# as fallback, plain read on a tty. The actions backend pre-defines its own
# stubs and sources this file with the guard unset, so they keep winning —
# the Go TUI never needs a bash-rendered prompt, every decision is made in
# Go before an action is invoked. notify()/notify_dismiss() are NOT part of
# this contract — they live below, unchanged between paths, since neither
# branches on which interactive UI is active (a background desktop
# notification is useful regardless):
#   ui_confirm MSG [NO_LABEL] [YES_LABEL]
#                              0 = yes/second button, 1 = no/cancel
#   ui_input PROMPT [DEFAULT]  echoes the entered text (empty allowed);
#                              return 1 on cancel
#   ui_select [--plain] [--timeout SECS] PROMPT OPTION...
#                              each OPTION is "display<TAB>value"; echoes
#                              the chosen value. return 0 = chosen,
#                              1 = cancelled, 2 = stdin EOF, 3 = timed out
#   ui_ready_or_die            exits with an error if nothing usable to
#                              render with (neither the Omarchy overlay
#                              nor zenity available); a no-op stub in
#                              mosquito-move-manager-actions, since the Go
#                              TUI itself checks its own prerequisites
#                              before ever invoking an action
#
# `is_tty()` is NOT a primitive: it's a plain, literal check of whether fd 0
# is a real terminal (whether to use the Omarchy overlay or a plain tty
# fallback); mosquito-move-manager-actions doesn't care either way,
# decisions are never made there.
#
# `$SELF` must also be set by any source-side caller before sourcing this
# file (its own resolved path) — used for the "pick a file" notification's
# --exec relaunch.
#
# Flags (all entry points):
#   --midi            convert with the MIDI route (skips the route question)
#   --address N       remember move[N].local without asking
#   --skip-manager    open the Move Manager without waiting for it to close
#   --no-bitwig       stop after Ableton (no Bitwig step)
#   --pick-file       go straight to convert, pointing at one specific file
#
# Environment:
#   MOVE_STATE_DIR       state directory (default ~/.local/state/move-session)
#   MOVE_DOWNLOAD_DIR    download folders to auto-deposit from (colon separated,
#                        default ~/Downloads:~/Desktop) — the Move Manager webapp
#                        already saves directly into <projects>/ablbundle
#   MOVE_MUSIC_DIR       music root (default xdg-user-dir MUSIC)
#
# Omarchy integration (ableton-move-converter module of mosquitOmarchy):
#   1. deployed to ~/.local/bin: mosquito-move-manager (dispatcher),
#      mosquito-move-manager-tui, mosquito-move-manager-actions,
#      lib-move-manager-core.sh, move-bundle-to-midi, move-udev-refresh,
#      move-manager-webapp
#   2. <projects folder>/{ablbundle,als,bwproject,bwproject/midi} created
#   3. udev rule 99-ableton-move.rules (optional, sudo)
#   4. one Omarchy menu entry (Exec= the dispatcher), added by
#      setup-ableton-move-manager.sh
# =============================================================================
set -euo pipefail

# Shared privilege-elevation helper (mq_sudo): scripts/lib/elevate.bash from
# the repo checkout. The core is ALSO deployed standalone to ~/.local/bin
# (setup-ableton-move-manager.sh copies elevate.bash next to it), so try the
# deployed location first, then the repo layout. If neither is present (e.g.
# a manual partial copy), fall back to a plain non-interactive sudo so the
# TUI's ydotoold path keeps behaving as before.
_mq_elevate="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/elevate.bash"
[[ -f $_mq_elevate ]] || _mq_elevate="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/elevate.bash"
# shellcheck disable=SC1090
[[ -f $_mq_elevate ]] && source "$_mq_elevate"
unset _mq_elevate
if ! declare -F mq_sudo >/dev/null 2>&1; then
  mq_sudo_noninteractive() { if [[ ${EUID:-$(id -u)} -eq 0 ]]; then "$@"; else sudo -n "$@"; fi; }
  mq_sudo() {
    if [[ ${1:-} == -n ]]; then shift; mq_sudo_noninteractive "$@"; return $?; fi
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then "$@"; else sudo -n "$@"; fi
  }
fi

# Wine's Mono/Gecko installers open a bare white window in the corner of
# the screen when a prefix lacks .NET/HTML support (seen during every
# wine install in setup-ableton.sh and the audio plugin manager). The
# documented ok kill-switch: empty overrides for mscoree (Mono) and
# mshtml (Gecko) — wine never spawns those helper dialogues, and each
# script honors an user-exported override by keeping it.
export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-mscoree,mshtml=}"

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/move-session"
STATE_DIR="${MOVE_STATE_DIR:-$HOME/.local/state/move-session}"
PREFS_FILE="$CONFIG_DIR/prefs"
LOG_FILE="$STATE_DIR/move-session.log"
CONVERTED_LOG="$STATE_DIR/converted.log"
MANAGER_BASELINE_FILE="$STATE_DIR/manager-baseline"
SESSION_START_FILE="$STATE_DIR/session-start"
# Cache of the .als last seen actually finishing a write (inotify
# close_write event) during this Ableton session — see start_als_watch().
# Read by detect_new_als() in preference to the broader mtime-based folder
# scan.
ALS_WATCH_FILE="$STATE_DIR/als-watch"
ALS_INOTIFY_LOG="$STATE_DIR/als-inotify.log"
ALS_WATCH_PIDFILE="$STATE_DIR/als-inotify.pid"

# Per-conversion session log. start_conversion_log() creates one at every
# conversion launch (open-ableton-route / export-als / convert-flow /
# convert-preset / convert-bwpreset) and every progress()/info()/warn()/err()
# line tees into it via log(), so a conversion that appears to hang can be
# diagnosed after the fact. Bounded: only the newest MAX_CONVERSION_LOGS files
# are kept, and the active one is rotated aside once it passes
# MAX_CONVERSION_LOG_BYTES.
#
# conversion-current records the ACTIVE log's path AND its tag, so a follow-up
# step can only continue a log it actually belongs to: finish-bitwig-open may
# reuse an open-ableton-route/export-als file, but never a preset/MIDI file.
CONVERSION_LOG_DIR="$STATE_DIR/conversion-logs"
CONVERSION_LOG=""
CONVERSION_LOG_CURRENT="$STATE_DIR/conversion-current"
MAX_CONVERSION_LOGS=20
MAX_CONVERSION_LOG_BYTES=2097152   # 2 MiB per session segment

mkdir -p "$CONFIG_DIR" "$STATE_DIR"

MUSIC_DIR="${MOVE_MUSIC_DIR:-$(xdg-user-dir MUSIC 2>/dev/null || true)}"
MUSIC_DIR="${MUSIC_DIR:-$HOME/Music}"

# Projects root — resolved by resolve_projects_dir() once the prefs are
# loaded (first run picks default vs custom, remembered in the prefs file).
MOVE_DIR=""
BUNDLE_DIR=""
ALS_DIR=""
BWPROJECT_DIR=""
MIDI_DIR=""

if [[ -n ${MOVE_DOWNLOAD_DIR:-} ]]; then
  IFS=: read -r -a DOWNLOAD_DIRS <<<"$MOVE_DOWNLOAD_DIR"
else
  DOWNLOAD_DIRS=("$HOME/Downloads" "$HOME/Desktop")
fi

ABLETON_VENDOR="2982"
BIN_DIR="$HOME/.local/bin"
TUI_BIN="$BIN_DIR/mosquito-move-manager-tui"
FILE_PICKER_MODE_FILE="$CONFIG_DIR/file-picker"
ABLETON_LIVE_BIN="$BIN_DIR/ableton-live"
MIDI_CONVERTER="move-bundle-to-midi"
ALS_CONVERTER="move-bundle-to-als"
BITWIG_BIN="bitwig-studio"
WEBAPP_ID="ableton-move-manager"
WEBAPP_NAME="Move Manager"
WEBAPP_LAUNCHER="$BIN_DIR/move-manager-webapp"
WEBAPP_ICON_DIR="$HOME/.local/share/icons/hicolor/256x256/apps"
WEBAPP_ICON_FILE="$WEBAPP_ICON_DIR/${WEBAPP_ID}.png"
MAX_WAIT_MANAGER=7200       # 2 h guard on the manager window wait
MAX_WAIT_ABLETON=14400      # 4 h guard on the Ableton session (active editing expected)
MAX_WAIT_BITWIG_SAVE=300    # 5 min guard on the post-handoff Bitwig-save wait — this is
                             # background bookkeeping (marking the set converted), not
                             # something that should keep the script alive for hours;
                             # Bitwig itself is never touched, only this script's own wait
MAIN_MENU_IDLE_TIMEOUT=1800 # 30 min: if the main menu just sits there unanswered this
                             # long, exit rather than pile up in the background forever
                             # (see the 19+-hour-old zombie processes found and cleaned up
                             # this round)

DEMO=false
SKIP_MANAGER=false
DO_BITWIG=true
DO_MIDI=false
FORCE_PICK=false
MANAGER_MODE=false
MANAGER_MODE_BASELINE=0
ABLETON_LAUNCH_PID=""  # set by open_in_ableton(); read by open_ableton_route_phase1
                       # instead of capturing the launch through a command
                       # substitution (see the pipe-trap note in open_in_ableton)
BITWIG_OPENED=false  # set true the moment open_in_bitwig() actually runs — lets
                     # the interactive main menu know not to redraw itself on
                     # top of Bitwig once the user is in there (see main_menu)

# Notification icon vocabulary — a small, coherent set built on the same
# circle motif as the main-menu status dot:
#   - color: connection status (green/red), matching the menu dot exactly
#   - a ring around the dot: an app is open, waiting on you to finish
#     something in it (Manager/Ableton/Bitwig)
#   - a square-framed dot: click this notification to do something
#   - plain colors otherwise: outcome (done/neutral)
ICON_CONNECTED="🟢"  # Move reachable
ICON_BLOCKED="🔴"    # Move unreachable / action refused
ICON_WAITING="◎"     # an app is open, waiting on you
ICON_ACTION="🔳"     # click this notification
ICON_DONE="✅"       # a conversion step completed
ICON_EMPTY="⚪"       # nothing to do, empty state

# ───────────────────────────── Logging ───────────────────────────────────────
# _conversion_log_clip(): bound the active session log. Called from log() so
# it can never grow without limit; when the cap is passed the current
# segment is moved aside to <log>.old and a fresh segment is started.
_conversion_log_clip() {
  [[ -n ${CONVERSION_LOG:-} && -f $CONVERSION_LOG ]] || return 0
  local size
  size=$(stat -c %s "$CONVERSION_LOG" 2>/dev/null || printf '0')
  [[ $size =~ ^[0-9]+$ ]] || size=0
  (( size > MAX_CONVERSION_LOG_BYTES )) || return 0
  mv -f "$CONVERSION_LOG" "$CONVERSION_LOG.old" 2>/dev/null || true
  printf '[%s] log segment rotated (> %s bytes); previous kept as %s.old\n' \
    "$(date '+%H:%M:%S')" "$MAX_CONVERSION_LOG_BYTES" "$CONVERSION_LOG" > "$CONVERSION_LOG" 2>/dev/null || true
}

# _prune_conversion_logs(): keep only the newest MAX_CONVERSION_LOGS files.
_prune_conversion_logs() {
  [[ -d $CONVERSION_LOG_DIR ]] || return 0
  local -a logs=()
  mapfile -t logs < <(ls -1t "$CONVERSION_LOG_DIR"/conversion-*.log 2>/dev/null || true)
  (( ${#logs[@]} > MAX_CONVERSION_LOGS )) || return 0
  local f
  for f in "${logs[@]:MAX_CONVERSION_LOGS}"; do rm -f -- "$f" 2>/dev/null || true; done
}

# start_conversion_log [TAG] [REUSE_FROM]
#   Creates the session log and announces its path on stderr (so it is the
#   first thing the TUI runner shows). REUSE_FROM is "false" (default: always
#   start a NEW file) or a space-separated list of tags whose log this call
#   may continue. finish-bitwig-open passes the predecessor tag(s) of its own
#   conversion so one conversion reads as ONE file — but a log left behind by
#   a DIFFERENT kind of conversion (preset, MIDI, an older project) is never
#   reused. Idempotent within a process. Never fatal: if the directory can't
#   be written the conversion still runs, just without a file.
start_conversion_log() {
  local tag="${1:-conversion}" reuse="${2:-false}"
  [[ -n ${CONVERSION_LOG:-} && -f $CONVERSION_LOG ]] && return 0
  mkdir -p "$CONVERSION_LOG_DIR" 2>/dev/null || true
  if [[ $reuse != false && $reuse != "" && -f $CONVERSION_LOG_CURRENT ]]; then
    # conversion-current is two lines: the path, then the tag that wrote it.
    local -a _cur=()
    mapfile -t _cur < "$CONVERSION_LOG_CURRENT" 2>/dev/null || true
    local prev="${_cur[0]:-}" prev_tag="${_cur[1]:-}" allowed ok=0
    if [[ -n $prev && -f $prev ]]; then
      for allowed in $reuse; do
        [[ $prev_tag == "$allowed" ]] && { ok=1; break; }
      done
      (( ok )) && CONVERSION_LOG="$prev"
    fi
  fi
  if [[ -z ${CONVERSION_LOG:-} ]]; then
    # mktemp guarantees a brand-new file even if a new conversion starts in
    # the same second as the previous one; fall back to the timestamp+pid
    # name only when mktemp is unavailable.
    CONVERSION_LOG="$(mktemp "$CONVERSION_LOG_DIR/conversion-$(date '+%Y%m%d-%H%M%S')-XXXXXX.log" 2>/dev/null || true)"
    if [[ -z ${CONVERSION_LOG:-} ]]; then
      CONVERSION_LOG="$CONVERSION_LOG_DIR/conversion-$(date '+%Y%m%d-%H%M%S')-$$.log"
      : > "$CONVERSION_LOG" 2>/dev/null || CONVERSION_LOG=""
    fi
    if [[ -n ${CONVERSION_LOG:-} ]]; then
      printf '%s\n%s\n' "$CONVERSION_LOG" "$tag" > "$CONVERSION_LOG_CURRENT" 2>/dev/null || true
      _prune_conversion_logs
    fi
  fi
  [[ -n ${CONVERSION_LOG:-} ]] || return 0
  export CONVERSION_LOG
  {
    printf '\n===== conversion session %s (tag %s, pid %s) =====\n' \
      "$(date '+%Y-%m-%d %H:%M:%S')" "$tag" "$$"
    printf 'ALS_DIR=%s\n' "${ALS_DIR:-<unset>}"
    printf 'SESSION_START_FILE=%s\n' "${SESSION_START_FILE:-<unset>}"
  } >> "$CONVERSION_LOG" 2>/dev/null || true
  printf '  … conversion log: %s\n' "$CONVERSION_LOG" >&2
}

stop_conversion_log() {
  [[ -n ${CONVERSION_LOG:-} ]] || return 0
  printf '===== end conversion session %s =====\n' "$(date '+%Y-%m-%d %H:%M:%S')" >> "$CONVERSION_LOG" 2>/dev/null || true
}

log() {
  local line
  line="$(printf '[%s] %s' "$(date '+%H:%M:%S')" "$*")"
  printf '%s\n' "$line" >> "$LOG_FILE"
  if [[ -n ${CONVERSION_LOG:-} ]]; then
    printf '%s\n' "$line" >> "$CONVERSION_LOG" 2>/dev/null || true
    _conversion_log_clip
  fi
}
info() { log "INFO: $*"; }
msg()  { echo "==> $*"; printf '==> %s\n' "$*" >> "$LOG_FILE"; }
ok()   { echo "  ✓ $*"; printf '  ✓ %s\n' "$*" >> "$LOG_FILE"; }
warn() { echo "  !  $*" >&2; printf '  !  %s\n' "$*" >> "$LOG_FILE"; }
err()  { echo "  ✗  $*" >&2; printf '  ✗  %s\n' "$*" >> "$LOG_FILE"; }
# progress(): a step line meant to be seen LIVE in the Go TUI's runner
# viewport, unlike info() (log file only). It goes to STDERR on purpose:
# the runner merges stdout+stderr, but any function called inside a
# command substitution (`NEW_ALS=$(ableton_wait_and_detect)`) must not have
# its human-readable chatter captured alongside the single path it echoes —
# stderr sidesteps that entirely. Also appended to the log as INFO so the
# on-disk trace stays complete.
progress() {
  printf '  … %s\n' "$*" >&2
  log "PROGRESS: $*"
}

# notify()/notify_dismiss() live here, not in the ui_* primitive contract:
# neither branches on is_tty or which interactive UI is active (every path
# fires the same real desktop notification regardless — the interactive
# menu style and whether a background notification is useful are
# orthogonal), so there's nothing to reimplement per entry path.
notify() {
  # $1 = headline, $2 = description, $3 = urgency (low|normal|critical),
  # $4 = glyph, then optionally:
  #   --persist              no auto-expire (for an instruction/blocking
  #                          notice that should stay up until the user acts,
  #                          dismissed explicitly later via notify_dismiss)
  #   --timeout SECONDS      auto-expire after this many seconds instead of
  #                          the default ~6s (e.g. the Ableton-opening
  #                          notice, kept up a full 20s so it doesn't
  #                          disappear before Ableton's own window even
  #                          appears)
  #   --exec <command...>    makes it clickable, implies --persist
  local headline="$1" desc="$2" urgency="${3:-low}" glyph="${4:-◉}"
  shift $(( $# < 4 ? $# : 4 ))
  # Every send is wrapped in `timeout 10`: omarchy-notification-send talks to
  # the notification daemon over the user bus (busctl call) and waits for the
  # method reply. A slow or wedged daemon must never stall the conversion
  # flow — a missed toast is harmless, a blocked launch/wait is not.
  if ! command -v omarchy-notification-send >/dev/null 2>&1; then
    timeout 10 notify-send -i audio-x-generic "$headline" "$desc" 2>/dev/null || true
    return 0
  fi
  local persist=false timeout_ms=""
  while true; do
    case "${1:-}" in
      --persist) persist=true; shift ;;
      --timeout) timeout_ms=$(( $2 * 1000 )); shift 2 ;;
      *) break ;;
    esac
  done
  local -a args=("$headline" "$desc" -g "$glyph" -u "$urgency")
  if (( $# > 0 )); then
    args+=(-t -1 "$@")
  elif $persist; then
    args+=(-t -1)
  elif [[ -n $timeout_ms ]]; then
    args+=(-t "$timeout_ms")
  else
    args+=(-t 6000)
  fi
  timeout 10 omarchy-notification-send "${args[@]}" >/dev/null 2>&1 || true
}

notify_dismiss() {
  # $1 = headline substring used to send it. Best-effort, silent if the
  # notification daemon or omarchy-notification-dismiss isn't available.
  command -v omarchy-notification-dismiss >/dev/null 2>&1 && omarchy-notification-dismiss "$1" >/dev/null 2>&1 || true
}

# ───────────────────────────── Preferences ───────────────────────────────────
load_prefs() {
  MOVE_ADDRESS=""
  LEARNED_ABLETON_EXE=""
  AUTO_BITWIG="ask"
  MOVE_PROJECTS_DIR=""
  HIDE_BWPROJECT_CONVERTED="true"
  OPEN_ALS_WITH_YDOTOOL="true"
  [[ -f $PREFS_FILE ]] && source "$PREFS_FILE" || true
}

save_prefs() {
  cat > "$PREFS_FILE" <<EOF
MOVE_ADDRESS="$MOVE_ADDRESS"
LEARNED_ABLETON_EXE="$LEARNED_ABLETON_EXE"
AUTO_BITWIG="$AUTO_BITWIG"
MOVE_PROJECTS_DIR="$MOVE_PROJECTS_DIR"
HIDE_BWPROJECT_CONVERTED="$HIDE_BWPROJECT_CONVERTED"
OPEN_ALS_WITH_YDOTOOL="$OPEN_ALS_WITH_YDOTOOL"
EOF
  info "prefs saved ($PREFS_FILE)"
}

# ───────────────────────────── Native Omarchy UI ─────────────────────────────
# Same convention as mega-caffeine: native Omarchy widgets when available
# (respecting the current theme), zenity as fallback, plain read on a tty.
# The ui_* prompts are defined ONLY when ${MOSQUITO_MOVE_MANAGER_NATIVE_UI}
# is non-empty — that's the flag-driven path, where the stable dispatcher
# routes one-shot flag actions here (status, --midi, --pick-file, …) and the
# shared core's own functions still need real prompts. The non-interactive
# actions backend (mosquito-move-manager-actions) sources this file with the
# flag unset and pre-defines its own stubs, so they must keep winning there —
# the Go TUI makes every decision in Go before an action is ever invoked.
is_tty() { [[ -t 0 ]] && [[ -n ${TERM:-} && ${TERM:-} != dumb ]]; }

if [[ -n ${MOSQUITO_MOVE_MANAGER_NATIVE_UI:-} ]]; then

ui_confirm() {
  # $1 = message, $2 = optional "no"-button label (default "No"), $3 =
  # optional "yes"-button label (default "Yes") — labels only, the
  # returned meaning is unchanged: 0 for yes/the second button, 1 for
  # no/cancel. Native square overlay (mosquito.confirm), zenity as a
  # fallback, plain read on a tty.
  local msg="$1" no_label="${2:-No}" yes_label="${3:-Yes}"
  if is_tty; then
    local ans
    read -r -p "$msg [Y/N] " ans || return 1
    [[ $ans =~ ^[yYoO]$ ]]
    return
  fi
  if command -v omarchy-shell >/dev/null 2>&1; then
    local sel done payload
    sel=$(mktemp); done=$(mktemp); rm -f "$done"
    payload=$(jq -cn --arg message "$msg" --arg selectionFile "$sel" --arg doneFile "$done" \
      --arg noLabel "$no_label" --arg yesLabel "$yes_label" \
      '{message:$message, selectionFile:$selectionFile, doneFile:$doneFile, noLabel:$noLabel, yesLabel:$yesLabel}')
    omarchy-shell shell summon mosquito.confirm "$payload" >/dev/null 2>&1 || true
    while [[ ! -e $done ]]; do sleep 0.05; done
    local ret=1
    [[ $(cat "$sel" 2>/dev/null) == yes ]] && ret=0
    rm -f "$sel" "$done"
    return $ret
  fi
  if command -v zenity >/dev/null 2>&1; then
    zenity --question --title="Move Session" --text="$msg" 2>/dev/null || return 1
    return 0
  fi
  warn "No GUI to ask — continuing as 'no'."
  return 1
}

ui_input() {
  # $1 = prompt (no trailing dots: the menu appends "…"), $2 = default text.
  # Echoes the entered text (empty allowed), returns 1 on cancel.
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
  # Usage: ui_select [--plain] [--timeout SECONDS] <prompt> <option>...
  # Each option is "display<TAB>value". --plain omits the value from the
  # native overlay's subtext (the grey line under each label) — for
  # prompts where the value is an internal routing tag, not useful info.
  # --timeout bounds how long the native-overlay prompt waits for the user
  # before giving up on its own (an abandoned session shouldn't sit in the
  # background forever) — rc 3 signals a timeout specifically, distinct
  # from a real cancel (rc 1) or stdin EOF (rc 2), so a caller can tell
  # "nobody answered" apart from "the user actively dismissed this".
  # Echoes the value of the chosen option, returns 1 on cancel.
  local plain=false to=""
  while [[ ${1:-} == --plain || ${1:-} == --timeout ]]; do
    if [[ $1 == --plain ]]; then plain=true; shift
    else to="$2"; shift 2
    fi
  done
  local prompt="$1"; shift
  local -a displays=() values=() native_opts=()
  local opt d v i
  for opt in "$@"; do
    d="${opt%%$'\t'*}"
    if [[ $opt == *$'\t'* ]]; then v="${opt#*$'\t'}"; else v="$d"; fi
    displays+=("$d"); values+=("$v")
    if $plain; then
      native_opts+=($'\t'"$d")
    else
      native_opts+=($'\t'"$d"$'\t'"$v")
    fi
  done

  if is_tty; then
    echo "$prompt" >&2
    for i in "${!displays[@]}"; do echo "  $((i+1)). ${displays[$i]}" >&2; done
    local n
    if [[ -n $to ]]; then
      read -rt "$to" -rp "> " n; local rrc=$?
      (( rrc > 128 )) && return 3           # read -t timeout
      (( rrc != 0 )) && return 2            # stdin closed = EOF, not a cancel
    else
      read -rp "> " n || return 2           # stdin closed = EOF, not a cancel
    fi
    if [[ $n =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#displays[@]} )); then
      printf '%s\n' "${values[$((n-1))]}"
      return 0
    fi
    return 1
  fi

  if command -v omarchy-menu-select >/dev/null 2>&1; then
    local out label rc=0
    if [[ -n $to ]]; then
      out=$(timeout "$to" omarchy-menu-select "$prompt" "${native_opts[@]}" -- --width 720 --maxheight 520 2>/dev/null) || rc=$?
      (( rc == 124 )) && return 3           # timeout: nobody answered
    else
      out=$(omarchy-menu-select "$prompt" "${native_opts[@]}" -- --width 720 --maxheight 520 2>/dev/null || true)
    fi
    if [[ -n $out ]]; then
      # Look the value up by display label rather than trusting the
      # returned subtext verbatim — with --plain there is none, and even
      # without it the label is the more robust key.
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
  # From the Omarchy launcher stdin is not a tty: the menu then uses the
  # native overlay widgets (omarchy-menu-select / mosquito.confirm).
  is_tty && return 0
  command -v omarchy-menu-select >/dev/null 2>&1 && return 0
  command -v zenity >/dev/null 2>&1 && return 0
  err "no interactive UI available (not a tty, no Omarchy menu, no zenity)."
  usage >&2
  exit 1
}

fi

ui_input_number() {
  # $1 = prompt, $2 = default. Validates 1..99, empty means "plain".
  local answer
  answer=$(ui_input "$1" "${2:-}") || return 1
  [[ -n $answer ]] || { echo ""; return 0; }
  if [[ $answer =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= 99 )); then
    echo "$answer"
  else
    warn "Invalid address: $answer (digits 1…99) — keeping move.local"
    echo ""
  fi
}

# ───────────────────────────── Detection ─────────────────────────────────────
detect_move() {
  # Canonical connectivity check — backs the main-menu status dot, gates
  # opening the Manager, and is used by `status`. Answers "is the Manager
  # actually reachable right now", which needs the network check regardless
  # of USB (the webapp is only ever accessed over http://move*.local — this
  # is distinct from the USB-only auto-detect *notification* feature, which
  # only cares about the unambiguous, zero-cost udev plug event, not general
  # reachability). USB is near-instant; the ping is scoped to the
  # *configured* address (a hardcoded "move.local" would miss a Move set to
  # a different address) and wrapped in a hard `timeout` — `-W` only bounds
  # the wait for a reply, not a stalled DNS/mDNS resolution for a wrong or
  # unreachable address, which was found to hang well past that on its own
  # and was the main cause of a sluggish menu.
  if command -v lsusb >/dev/null 2>&1 && lsusb -d "${ABLETON_VENDOR}:" 2>/dev/null | grep -q .; then
    info "Move detected via USB (lsusb ${ABLETON_VENDOR}:)"
    return 0
  fi
  if timeout 1.5 ping -c 1 -W 1 "$(move_host)" >/dev/null 2>&1; then
    info "Move detected via network ($(move_host))"
    return 0
  fi
  return 1
}

move_url() { printf 'http://move%s.local' "${MOVE_ADDRESS:+$MOVE_ADDRESS}"; }
move_host() { printf 'move%s.local' "${MOVE_ADDRESS:+$MOVE_ADDRESS}"; }

hyprland_session_active() {
  # True when this process is running inside a Hyprland session. The
  # instance signature is the authoritative signal (Hyprland exports it to
  # every child); the hyprctl + running-Hyprland pair is a fallback for the
  # rare case where the variable isn't inherited (e.g. a detached launcher).
  [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] && return 0
  command -v hyprctl >/dev/null 2>&1 || return 1
  pgrep -x Hyprland >/dev/null 2>&1
}

# ───────────────────────────── Folders ───────────────────────────────────────
expand_path() {
  # Expands a leading ~ and makes the path absolute (non-interactive).
  local p="${1//\~/$HOME}"
  [[ $p == /* ]] || p="$PWD/$p"
  printf '%s\n' "$p"
}

DEFAULT_PROJECTS_DIR_NAME="Ableton Move Projects"

resolve_projects_dir() {
  # Recomputes MOVE_DIR + subfolders from MOVE_PROJECTS_DIR (pref) or default.
  MOVE_DIR="${MOVE_PROJECTS_DIR:-$MUSIC_DIR/$DEFAULT_PROJECTS_DIR_NAME}"
  MOVE_DIR="$(expand_path "$MOVE_DIR")"
  BUNDLE_DIR="$MOVE_DIR/ablbundle"
  ALS_DIR="$MOVE_DIR/als"
  BWPROJECT_DIR="$MOVE_DIR/bwproject"
  MIDI_DIR="$BWPROJECT_DIR/midi"
}

migrate_projects_dir_name() {
  # One-time migration: the folder used to default to "Move Projects" — if
  # the saved pref still points at a folder literally named that, rename it
  # (same parent) and update the pref. No-op for anyone already on the new
  # name, and never overwrites an existing "Ableton Move Projects" folder.
  [[ -n ${MOVE_PROJECTS_DIR:-} ]] || return 0
  [[ "$(basename "$MOVE_PROJECTS_DIR")" == "Move Projects" ]] || return 0
  local new_dir
  new_dir="$(dirname "$MOVE_PROJECTS_DIR")/$DEFAULT_PROJECTS_DIR_NAME"
  [[ -e $new_dir ]] && return 0
  if [[ -d $MOVE_PROJECTS_DIR ]]; then
    mv "$MOVE_PROJECTS_DIR" "$new_dir" 2>/dev/null || return 0
    info "projects folder renamed: $MOVE_PROJECTS_DIR -> $new_dir"
  fi
  MOVE_PROJECTS_DIR="$new_dir"
  save_prefs
}

write_projects_readme() {
  # Dropped once, only into a freshly-created projects folder.
  cat > "$MOVE_DIR/README.md" <<EOF
# Ableton Move Projects

This folder **is** the working directory for the Ableton Move → Ableton Live →
Bitwig conversion (managed by \`mosquito-move-manager\`). Its location can be
changed any time from **Settings → Change working directory location**.

| Folder | Content |
|---|---|
| \`ablbundle\` | Sets downloaded from the Move Manager webapp |
| \`als\` | Ableton Live projects saved while converting a set |
| \`bwproject\` | Bitwig Studio projects converted from an \`als\` export |
| \`bwproject/midi\` | MIDI exports (the MIDI route skips Ableton/Bitwig) |
| \`Presets\` | Converted device presets (.adg + .ablpresetbundle), incl. Bitwig .bwpreset conversions |

**Save and quit Ableton yourself when you're done.** After a set opens in
Ableton, the manager only waits: save the project (ideally in the \`als\` folder
above) and then QUIT Ableton. It detects the \`.als\` this session saved wherever
you put it and opens that exact file in Bitwig — nothing is copied or backed up.
EOF
}

ensure_projects_dir() {
  # Runs whenever the resolved projects folder isn't on disk yet — a true
  # first run, or a previously-configured folder that went missing. Offers
  # to create it (default path, stated explicitly, or a custom one) or to
  # locate an already-existing folder elsewhere. Never prompts in
  # demo/status mode.
  resolve_projects_dir
  [[ -d $MOVE_DIR ]] && return 0
  local def="$MUSIC_DIR/$DEFAULT_PROJECTS_DIR_NAME"
  if $DEMO; then
    MOVE_PROJECTS_DIR="$def"
    resolve_projects_dir
    return 0
  fi

  local choice
  choice=$(ui_select "The $DEFAULT_PROJECTS_DIR_NAME folder isn't there yet." \
    $'Create it\tcreate' \
    $'Locate an existing folder\tlocate') || choice="create"

  if [[ $choice == locate ]]; then
    local custom
    custom=$(ui_input "Path to the existing $DEFAULT_PROJECTS_DIR_NAME folder") || choice="create"
    if [[ -n ${custom:-} ]]; then
      MOVE_PROJECTS_DIR="$(expand_path "$custom")"
      save_prefs
      resolve_projects_dir
      return 0
    fi
  fi

  if ui_confirm "Create it at the default path « $def » ?"; then
    MOVE_PROJECTS_DIR="$def"
  else
    local custom
    custom=$(ui_input "Custom projects folder path (e.g. ~/Music/Bitwig/Projects)") || { MOVE_PROJECTS_DIR="$def"; save_prefs; resolve_projects_dir; return 0; }
    custom="$(expand_path "$custom")"
    MOVE_PROJECTS_DIR="${custom:-$def}"
  fi
  save_prefs
  resolve_projects_dir
}

ensure_folders() {
  local fresh=false
  [[ -d $MOVE_DIR ]] || fresh=true
  mkdir -p "$BUNDLE_DIR" "$ALS_DIR" "$BWPROJECT_DIR" "$MIDI_DIR" "$MOVE_DIR/Presets"
  if $fresh && [[ ! -f "$MOVE_DIR/README.md" ]]; then
    write_projects_readme
  fi
  info "folders ready: $MOVE_DIR/{ablbundle,als,bwproject,bwproject/midi,Presets}"
}

# ───────────────────────────── Webapp ────────────────────────────────────────
normalize_webapp_name() {
  # The webapp id (filename) and its displayed Name are decoupled: the desktop
  # entry must show "Move Manager" (no hyphens, no "Ableton" prefix) while the
  # file keeps the stable id-derived name omarchy-webapp-install generated.
  local file="$1"
  sed -i "s|^Name=.*|Name=$WEBAPP_NAME|" "$file"
  sed -i "s|^Comment=.*|Comment=$WEBAPP_NAME|" "$file"
  ok "webapp shown as « $WEBAPP_NAME » ($(basename "$file"))"
}

ensure_webapp() {
  # The Move Manager runs in a dedicated Chromium profile (move-manager-webapp)
  # so its downloads land straight into <projects>/ablbundle — no per-origin
  # control possible with a shared profile. The .desktop entry points at that
  # launcher when deployed, else falls back to omarchy-launch-webapp.
  local desktop="$HOME/.local/share/applications/${WEBAPP_ID}.desktop"
  local url
  url="$(move_url)"
  local exec_line
  if [[ -x $WEBAPP_LAUNCHER ]]; then
    exec_line="Exec=$WEBAPP_LAUNCHER"
  else
    exec_line="Exec=omarchy-launch-webapp \"$url\""
  fi

  if [[ -f $desktop ]]; then
    local current
    current=$(grep -oP 'Exec=.*?"\K[^"]+' "$desktop" 2>/dev/null || true)
    if [[ -n $current && $current != "$url" && $current != "$WEBAPP_LAUNCHER" ]]; then
      sed -i "s|^Exec=.*|$exec_line|" "$desktop"
      ok "webapp launcher updated"
    else
      ok "webapp already installed ($desktop)"
    fi
    normalize_webapp_name "$desktop"
    return 0
  fi

  msg "Installing the Move Manager webapp…"
  # Icon is fixed (a custom Move Manager icon shipped with this module,
  # placed at WEBAPP_ICON_FILE by the setup script) rather than fetched from the
  # Move's own favicon — that device-served .ico was unreliable (some
  # loaders choked on its structure) and pointless to re-fetch on every
  # run. Passed here by *name* (not a URL), so omarchy-webapp-install just
  # references the already-placed file instead of downloading anything.
  if command -v omarchy-webapp-install >/dev/null 2>&1; then
    if omarchy-webapp-install "$WEBAPP_ID" "$url" "$WEBAPP_ID" >/dev/null 2>&1 \
       && [[ -f $desktop ]]; then
      ok "Move Manager webapp installed (omarchy-webapp-install)"
      sed -i "s|^Exec=.*|$exec_line|" "$desktop"
      normalize_webapp_name "$desktop"
      return 0
    fi
    warn "omarchy-webapp-install failed — manual desktop entry"
  fi

  local icon_ref="$WEBAPP_ID"
  [[ -f $WEBAPP_ICON_FILE ]] || icon_ref="audio-x-generic"

  mkdir -p "$HOME/.local/share/applications"
  cat > "$desktop" <<DESKTOP
[Desktop Entry]
Version=1.0
Name=$WEBAPP_NAME
Comment=$WEBAPP_NAME
$exec_line
Terminal=false
Type=Application
Icon=$icon_ref
StartupNotify=true
Categories=AudioVideo;Audio;
DESKTOP
  chmod +x "$desktop"
  ok "Move Manager webapp installed (manual desktop entry)"
}

open_webapp() {
  # Prefer the dedicated webapp launcher (dedicated profile + downloads in
  # ablbundle); fall back to the omarchy webapp runner, then xdg-open.
  info "opening manager → $(move_url)"
  # 3>&- on every background launch: the actions wrapper keeps fd 3 as the
  # machine-readable sentinel (the TUI's stdout pipe). A long-lived child
  # that inherits it keeps the pipe open after this process exits, so the
  # Go runner never sees EOF and its RunnerDoneMsg is never delivered (the
  # .als was found, but finish-bitwig-open was never started). Close it on
  # every child that can outlive us.
  if [[ -x $WEBAPP_LAUNCHER ]]; then
    "$WEBAPP_LAUNCHER" >/dev/null 2>&1 3>&- &
  elif command -v omarchy-launch-webapp >/dev/null 2>&1; then
    omarchy-launch-webapp "$(move_url)" >/dev/null 2>&1 3>&- &
  else
    xdg-open "$(move_url)" >/dev/null 2>&1 3>&- &
  fi
}

manager_running() {
  # Matches on the dedicated Chromium profile path — the same identifier
  # move-manager-webapp's own close_existing_instance() uses — rather than
  # the URL/host: that string only reliably survives in the *launching*
  # process's argv, and a false-negative here was found to dismiss the
  # "close to continue" notification while the window was still open.
  local profile="${XDG_CACHE_HOME:-$HOME/.cache}/move-manager"
  pgrep -f -- "--user-data-dir=$profile" >/dev/null 2>&1
}

close_manager_now() {
  # Same mechanism move-manager-webapp's own close_existing_instance() uses.
  local profile="${XDG_CACHE_HOME:-$HOME/.cache}/move-manager"
  pkill -f -- "--user-data-dir=$profile" >/dev/null 2>&1 || true
}

newest_downloaded_bundle() {
  # $1 = only report a file newer than this reference file (mtime-compared,
  # standard find -newer usage). A completed Chromium download has already
  # been renamed from "<name>.ablbundle.crdownload" to "<name>.ablbundle" by
  # the time it matches these extensions at all — an in-progress download
  # never does, so no separate "is it still downloading" check is needed.
  local since="$1" f t newest="" newest_t=0
  [[ -d $BUNDLE_DIR ]] || return 1
  while IFS= read -r -d '' f; do
    t=$(stat -c %Y "$f" 2>/dev/null || echo 0)
    if (( t > newest_t )); then newest_t=$t; newest="$f"; fi
  done < <(find "$BUNDLE_DIR" -maxdepth 1 \( -iname "*.abletonbundle" -o -iname "*.ablbundle" -o -iname "*.abl" \) -newer "$since" -print0 2>/dev/null)
  [[ -n $newest ]] || return 1
  printf '%s\n' "$newest"
}

wait_manager_close() {
  $SKIP_MANAGER && { ok "manager wait skipped (--skip-manager)"; return 0; }

  local headline="Move Manager"
  notify "$headline" "Download a set, wait for the download to finish, then close the Manager to continue" normal "$ICON_WAITING" --persist

  local seen=0 elapsed=0
  while (( elapsed < 60 )); do
    manager_running && { seen=1; break; }
    sleep 2; elapsed=$((elapsed + 2))
  done

  if (( seen == 0 )); then
    if ui_confirm "Is the Move Manager already closed?"; then
      notify_dismiss "$headline"
      ok "Move Manager closed"
      return 0
    fi
    warn "Waiting for the Move Manager to close…"
  fi

  # Actively prompts the moment a new set finishes downloading, instead of
  # only passively waiting for the window to close — answering yes closes
  # the Manager for you and continues; no leaves it open, exactly as
  # before, and the same set won't be asked about again.
  local prompted_for=""
  elapsed=0
  while (( elapsed < MAX_WAIT_MANAGER )); do
    if ! manager_running; then
      notify_dismiss "$headline"
      ok "Move Manager closed"
      return 0
    fi
    local newest
    if newest=$(newest_downloaded_bundle "$MANAGER_BASELINE_FILE" 2>/dev/null) && [[ $newest != "$prompted_for" ]]; then
      prompted_for="$newest"
      if ui_confirm "$(basename "$newest") finished downloading — close the Manager and continue?"; then
        close_manager_now
        sleep 1
        notify_dismiss "$headline"
        ok "Move Manager closed (confirmed after download)"
        return 0
      else
        ok "kept open — will ask again if another set finishes downloading"
      fi
    fi
    sleep 2; elapsed=$((elapsed + 2))
  done
  notify_dismiss "$headline"
  warn "Wait time exceeded — moving on anyway."
}

# ───────────────────────────── Bundle import ─────────────────────────────────
scan_bundles() {
  # All sets in <projects>/ablbundle (the folder the Move Manager webapp
  # populates directly), newest first. Sets already converted to a Bitwig
  # project (marked "-converted-bwproject") are hidden when Settings' "Hide
  # sets converted to Bitwig" is on; MIDI-converted ones ("-converted-midi")
  # always stay visible. MANAGER_MODE further restricts the list to only
  # what was downloaded in the current Manager session (by mtime vs.
  # MANAGER_MODE_BASELINE) — used right after the Manager closes, so the
  # picker doesn't also offer older, unrelated sets already sitting there.
  BUNDLES=()
  [[ -d $BUNDLE_DIR ]] || return
  local f ft
  while IFS= read -r -d '' f; do
    if [[ $HIDE_BWPROJECT_CONVERTED == true && $(basename "$f") == *-converted-bwproject* ]]; then continue; fi
    if $MANAGER_MODE; then
      ft=$(stat -c %Y "$f" 2>/dev/null || echo 0)
      (( ft >= MANAGER_MODE_BASELINE )) || continue
    fi
    BUNDLES+=("$f")
  done \
    < <(find "$BUNDLE_DIR" -maxdepth 1 \
        \( -iname "*.abletonbundle" -o -iname "*.ablbundle" -o -iname "*.abl" \) \
        -printf '%T@\t%p\0' | sort -t$'\t' -k1,1nr -z | sed -z 's/^[^\t]*\t//' 2>/dev/null)
}

deposit_downloads() {
  # Auto-deposit: move sets the webapp saved outside ablbundle (older setups,
  # e.g. ~/Downloads) into <projects>/ablbundle. Files newer than the session
  # baseline are considered "fresh from this manager window".
  local baseline=0
  [[ -f $MANAGER_BASELINE_FILE ]] && baseline=$(cat "$MANAGER_BASELINE_FILE" 2>/dev/null || 0)
  local moved=0 dir f base
  for dir in "${DOWNLOAD_DIRS[@]}"; do
    [[ -d $dir ]] || continue
    while IFS= read -r -d '' f; do
      [[ -f $f ]] || continue
      base="$(basename "$f")"
      if [[ -f "$BUNDLE_DIR/$base" ]]; then
        warn "already imported: $base (skipped)"
        continue
      fi
      mv -f "$f" "$BUNDLE_DIR/$base" 2>/dev/null \
        || { cp -f "$f" "$BUNDLE_DIR/$base" 2>/dev/null && rm -f "$f"; }
      moved=$((moved + 1))
    done < <(find "$dir" -maxdepth 2 \
        \( -iname "*.abletonbundle" -o -iname "*.ablbundle" -o -iname "*.abl" \) \
        -newermt "@$baseline" -print0 2>/dev/null || true)
  done
  if (( moved > 0 )); then ok "$moved set(s) deposited into $BUNDLE_DIR"; fi
}

# Same superfile-vs-default file-picker preference as the sibling VST
# Manager (Settings — File picker) — never needs a relaunch/reboot: it's a
# one-line file re-read fresh every time pick_file_manually() runs, same
# process, nothing to restart.
current_file_picker() {
  local m
  m=$(cat "$FILE_PICKER_MODE_FILE" 2>/dev/null || echo default)
  [[ $m == superfile ]] && echo superfile || echo default
}

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
  # Real, visible terminal (needs the sudo password) — same foot/xterm pair
  # this module already relies on elsewhere. Blocks until it closes.
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
  # Echoes the chosen path, or nothing if the user quit superfile without
  # picking (Esc/q — --chooser-file is simply never written in that case).
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

pick_file_manually() {
  # $1 = dialog title. Lets the user point to one specific set file — a
  # one-off selection for this run only, never remembered for next time.
  # superfile first if that's the chosen preference (Settings — File
  # picker) and it's installed — the user's own explicit choice, so if they
  # quit it without picking (Esc/q), that's a cancel, not a fall-through to
  # zenity/a typed path underneath (same fix as the sibling VST Manager).
  local title="$1" chosen=""
  if [[ $(current_file_picker) == superfile ]] && command -v spf >/dev/null 2>&1; then
    chosen=$(pick_file_via_superfile "$title") || true
    [[ -n $chosen && -f $chosen ]] || return 1
    printf '%s\n' "$chosen"
    return 0
  fi
  if command -v zenity >/dev/null 2>&1; then
    chosen=$(zenity --file-selection --title="$title" \
      --file-filter="Ableton sets | *.ablbundle *.abletonbundle *.abl" 2>/dev/null || true)
  fi
  if [[ -z $chosen ]]; then
    chosen=$(ui_input "$title — full path to the file") || chosen=""
  fi
  [[ -n $chosen && -f $chosen ]] || return 1
  printf '%s\n' "$chosen"
}

converted_label() {
  # $1 = base label text to mark as converted. Real green ANSI in a
  # terminal; a plain " ✓" suffix in the native overlay (can't render color
  # in plain label text) — same convention as the Omarchy menu's own
  # checked-item indicator (mega-caffeine's toggle when active:
  # MenuModel.js's `labelFor()` appends exactly " ✓").
  if is_tty; then
    printf '\033[32m%s ✓\033[0m' "$1"
  else
    printf '%s ✓' "$1"
  fi
}

# A file/folder marked "-converted" with no "-<type>" suffix predates the
# type-specific marker scheme (see mark_converted below) — recognize it too,
# generically, so a conversion done before that rename doesn't silently
# vanish from the picker's converted-state tracking. Never hidden (we can't
# tell MIDI from Bitwig for these), just labeled so it isn't mistaken for an
# unconverted set.
is_legacy_converted() {
  local base="$1"
  [[ $base == *-converted-midi* || $base == *-converted-bwproject* ]] && return 1
  [[ $base == *-converted.* || $base == *-converted ]]
}

choose_bundle() {
  local -a opts=()
  local f base label
  for f in "${BUNDLES[@]}"; do
    [[ -f $f ]] || continue
    base="$(basename "$f")"
    label="$base"
    if [[ $base == *-converted-midi* ]]; then
      label="$(converted_label "$base (converted to MIDI)")"
    elif [[ $base == *-converted-bwproject* ]]; then
      label="$(converted_label "$base (converted to Bitwig)")"
    elif is_legacy_converted "$base"; then
      label="$(converted_label "$base (converted)")"
    fi
    opts+=("$label"$'\t'"$f")
  done
  (( ${#opts[@]} > 0 )) || return 1
  if (( ${#opts[@]} == 1 )); then
    printf '%s\n' "${opts[0]#*$'\t'}"
    return 0
  fi
  ui_select "Which ablbundle set?" "${opts[@]}"
}

# ───────────────────────────── Ableton Live ──────────────────────────────────
open_in_ableton() {
  # Opens the original bundle directly — Ableton Live reads .abletonbundle/
  # .ablbundle by content, no extraction or renaming needed. Version choice
  # is Settings' job (LEARNED_ABLETON_EXE); this never prompts live.
  #
  # Always launches through the same `ableton-live` wrapper the Omarchy menu
  # itself uses — never a raw .exe directly. The wrapper does real setup
  # (selects the patched Wine runtime under ~/.local/opt, the right
  # WINEPREFIX, syncs preferences) that invoking the .exe file directly
  # skips entirely; without it, running the exe is at the mercy of whatever
  # Wine a bare `.exe` file resolves to on this system (binfmt_misc's
  # default association, which can silently be a different runtime/prefix
  # altogether) — the likely real cause of "always launches the wrong
  # version". LEARNED_ABLETON_EXE (Settings' choice) is passed through as
  # ABLETON_LIVE_EXE so the wrapper still launches that specific install
  # when more than one exists — just correctly, through the wrapper.
  # THE PIPE TRAP — read before changing any launch line below. This
  # function used to be consumed as `pid=$(open_in_ableton …)`. A command
  # substitution doesn't see EOF on its stdout pipe until *every* process
  # holding a copy of that pipe closes it, including a background child:
  # an unredirected Wine/Ableton launch inherits and holds the
  # substitution's stdout open for the whole session, so `$(...)` blocked
  # (a ~36s gap in the real session log was the tell). The redirects below
  # (</dev/null >/dev/null 2>&1 3>&-) close every inherited copy up front,
  # including fd 3 — the actions wrapper's sentinel fd, which is a dup of
  # the TUI runner's stdout pipe and therefore just as fatal to leave open.
  #
  # To remove the trap entirely rather than merely mitigate it, callers no
  # longer wrap this in a command substitution: it sets the global
  # ABLETON_LAUNCH_PID (and still prints it on stdout purely so a legacy
  # `pid=$(open_in_ableton …)` caller keeps working — the actions TUI path
  # redirects this stdout to /dev/null and reads the global instead).
  # `disown` detaches the wrapper so the calling action shell exiting after
  # its phase cannot take Ableton down with it.
  local bundle="$1" exe

  if [[ -x $ABLETON_LIVE_BIN ]]; then
    if [[ -n ${LEARNED_ABLETON_EXE:-} && -f $LEARNED_ABLETON_EXE ]]; then
      info "launching ableton-live (ABLETON_LIVE_EXE=$(basename "$LEARNED_ABLETON_EXE")) with $bundle"
      ABLETON_LIVE_EXE="$LEARNED_ABLETON_EXE" "$ABLETON_LIVE_BIN" "$bundle" </dev/null >/dev/null 2>&1 3>&- &
    else
      info "launching ableton-live with $bundle"
      "$ABLETON_LIVE_BIN" "$bundle" </dev/null >/dev/null 2>&1 3>&- &
    fi
    ABLETON_LAUNCH_PID=$!
    disown 2>/dev/null || true
    printf '%s\n' "$ABLETON_LAUNCH_PID"
    return 0
  fi

  exe=$(choose_ableton_exe) || return 1
  info "launching Ableton ($(basename "$exe")) directly with $bundle — ableton-live wrapper not found"
  "$exe" "$bundle" </dev/null >/dev/null 2>&1 3>&- &
  ABLETON_LAUNCH_PID=$!
  disown 2>/dev/null || true
  printf '%s\n' "$ABLETON_LAUNCH_PID"
}

# +───────────────────────────── ALS (beta) export ───────────────────────────
# Straight to a native Live .als, no Ableton involved (move-bundle-to-als
# re-emits the Live XML structure a Move import produces). The set is NOT
# marked converted here — the .als is an intermediate for review, and the
# bundle stays in the picker so it can still take the Ableton → Bitwig route.
# $ALS_EXPORTED_PATH is set for the caller (the "open in Bitwig?" decision
# happens call-site-side, interactive ui_confirm or the TUI's own confirm).
export_als() {
  local bundle="$1"
  ALS_EXPORTED_PATH=""
  if ! command -v "$ALS_CONVERTER" >/dev/null 2>&1; then
    err "ALS converter not found ($ALS_CONVERTER)."
    return 1
  fi
  ALS_EXPORTED_PATH=$("$ALS_CONVERTER" -o "$ALS_DIR" "$bundle") || { ALS_EXPORTED_PATH=""; return 1; }
  ok "ALS saved (beta): $ALS_EXPORTED_PATH"
  notify "Move → .als (beta)" "Set converted to Live format — $(basename "$ALS_EXPORTED_PATH")" normal "$ICON_DONE"
}

# +───────────────────────────── MIDI export ──────────────────────────────────
export_midi() {
  local bundle="$1" out
  if ! command -v "$MIDI_CONVERTER" >/dev/null 2>&1; then
    err "MIDI converter not found ($MIDI_CONVERTER)."
    return 1
  fi
  out=$("$MIDI_CONVERTER" -o "$MIDI_DIR" "$bundle") || return 1
  ok "MIDI saved: $out"
  mark_converted "$bundle" midi >/dev/null
  notify "Move → Ableton → Bitwig" "Set exported as MIDI — $(basename "$out")" normal "$ICON_DONE"
  if ui_confirm "Open the MIDI folder ($MIDI_DIR)?"; then
    xdg-open "$MIDI_DIR" >/dev/null 2>&1 3>&- &
    ok "opened $MIDI_DIR"
  fi
}

is_ableton_running() {
  # Delegates to ableton_pids() (defined below) rather than a bare pgrep -f
  # here — that matches on the whole command line, so a shell merely
  # mentioning these strings (a grep, a debug command referencing this
  # module's own files) matches too, confirmed live; ableton_pids() filters
  # those out by process name.
  [[ -n $(ableton_pids) ]]
}

ableton_live_image() {
  # The image name of the Live build Settings configured, used as the one
  # exact string a real Live process must contain. Falls back to the generic
  # "Ableton Live" when nothing is configured (any edition/version matches).
  if [[ -n ${LEARNED_ABLETON_EXE:-} ]]; then
    basename "$LEARNED_ABLETON_EXE"
  else
    printf '%s\n' 'Ableton Live'
  fi
}

ableton_prefix_dir() {
  # The Wine prefix the configured Live install lives in, derived from the
  # exe path Settings picked (…/<prefix>/drive_c/ProgramData/Ableton/…), so a
  # custom WINEPREFIX is honored. Falls back to the module's default prefix.
  if [[ -n ${LEARNED_ABLETON_EXE:-} && ${LEARNED_ABLETON_EXE} == */drive_c/* ]]; then
    printf '%s\n' "${LEARNED_ABLETON_EXE%%/drive_c/*}"
  else
    printf '%s\n' "$HOME/.wine-ableton"
  fi
}

_ableton_pid_cmdline() {
  # $1 = pid. Full argv with NULs turned into spaces, so consecutive argv
  # fields can't run together into a false match. A PID can vanish between
  # the caller listing it and this read; the shell prints a redirection
  # error for a missing /proc/$pid/cmdline BEFORE tr executes, so the old
  # `< file 2>/dev/null` order did not suppress it ("No such file" spill).
  # Guard for readability AND put the stderr redirect first so even a
  # check→read race stays silent.
  [[ -r /proc/$1/cmdline ]] || return 0
  tr '\0' ' ' 2>/dev/null < "/proc/$1/cmdline" || true
}

_ableton_deny_image() {
  # $1 = a process image/comm name (any case). True (0) when the name belongs
  # to a tool, interpreter, Wine-infrastructure process or wrapper script that
  # must NEVER be counted as the running Live build — no matter what its
  # command line happens to mention. Wine truncates comm to 15 chars, so the
  # real Live process's comm ("Ableton Live 1") is deliberately not here.
  local n="${1,,}"
  [[ -n $n ]] || return 1
  case "$n" in
    # shells / text tools / watchers
    bash|sh|dash|zsh|ksh|fish|\
    grep|pgrep|egrep|fgrep|rg|sed|awk|gawk|cat|find|env|timeout|watch|xargs|\
    sort|uniq|tr|tee|inotifywait|inotifywatch|ps|kill|sleep|head|tail) return 0 ;;
    # Wine infrastructure (its argv names a Windows path, never a Live exe)
    wine|wine64|wine-preloader|wine64-preloader|.wine-wrapped|\
    wineserver|wineserver64) return 0 ;;
    services.exe|winedevice.exe|plugplay.exe|svchost.exe|rpcss.exe|\
    explorer.exe|winemenubuilder.exe|start.exe|conhost.exe|wineboot.exe|\
    rundll32.exe) return 0 ;;
    # the Ableton launcher/helpers, never the Live exe itself
    ableton-live|ableton-linkd) return 0 ;;
  esac
  return 1
}

ableton_pid_is_live() {
  # $1 = pid, $2 = image name (defaults to the configured one). True when the
  # process is a real Live build for the chosen version: its command line —
  # or its comm (Wine truncates comm to 15 chars, so this is only a fallback)
  # — contains the exact image name CASE-INSENSITIVELY, and neither its comm
  # nor its argv identifies it as one of the shells/tools/watchers/wrappers
  # that merely mention an Ableton path. The ableton-live theme watcher's
  # `inotifywait … Ableton/Live NN/…Preferences.cfg` and the wrapper's own
  # `tee -a …/live.log` were the specific offenders that kept the old
  # detector "running" forever; both are denied by comm here.
  local pid="$1" needle="${2:-$(ableton_live_image)}" cmd lcmd comm lcomm
  [[ $pid =~ ^[0-9]+$ ]] || return 1
  needle="${needle,,}"
  [[ -n $needle ]] || return 1
  comm="$(ps -p "$pid" -o comm= 2>/dev/null || true)"
  _ableton_deny_image "$comm" && return 1
  cmd="$(_ableton_pid_cmdline "$pid")"
  lcmd="${cmd,,}"
  # Wrapper/manager scripts: their argv names one of our own files (or the
  # ableton-live launcher), which is never the Live exe.
  case "$lcmd" in
    *"/ableton-live"*|*"ableton-live "*) return 1 ;;
    *move-manager*|*move-session*|*lib-move-manager*) return 1 ;;
  esac
  lcomm="${comm,,}"
  [[ $lcmd == *"$needle"* || $lcomm == *"$needle"* ]]
}

ableton_pids() {
  # Enumerate EVERY live PID of the configured Live build — never a single
  # representative pid. This is the proven native detector, ported: generate
  # candidates with the same three pgrep patterns the working native version
  # used (its own wrapper, the raw image name, and any Wine command line
  # mentioning Ableton), then keep a candidate only when ableton_pid_is_live()
  # confirms it is the real Live exe — the literal image match plus the
  # shell/tool/watcher/Wine-infrastructure deny-list. pgrep's regex is only a
  # candidate generator, so a `.`/metachar over-match can never be reported.
  #
  # Deliberately NOT the old /proc/*/environ WINEPREFIX scan: that walked
  # every process on the box on every poll, and any Wine helper that kept the
  # prefix in its environment could keep the detector "running" forever — the
  # class of false positive that made the wait look hung. The comm-based
  # filter here is what the native version relied on and it is enough.
  local p
  {
    pgrep -f "Ableton Live" 2>/dev/null
    pgrep -f "ableton-live" 2>/dev/null
    pgrep -f "wine.*Ableton" 2>/dev/null
  } | sort -u | while IFS= read -r p; do
    [[ -n $p ]] || continue
    ableton_pid_is_live "$p" || continue
    printf '%s\n' "$p"
  done
}

ableton_live_pids() {
  # Explicit "all matching PIDs" helper. The close gate, the conflict report
  # and close_configured_ableton_and_wait() all consume the full list, never a
  # single pid. Named after the wrapper's own lifecycle.sh so the intent is
  # obvious at every call site.
  ableton_pids
}

ableton_close_all() {
  # SIGTERM (never SIGKILL) every PID linked to the configured Live build.
  # Called only when closing is actually needed and the user has confirmed
  # (the "an instance is already open — close it to continue?" path). Live is
  # given time to shut down; a hung one is left to the outer wait's guard
  # rather than force-killed. Returns 0 even when nothing matched.
  local p pids
  pids="$(ableton_pids)" || true
  [[ -n $pids ]] || return 0
  for p in $pids; do
    kill -TERM "$p" 2>/dev/null && info "sent SIGTERM to Ableton pid $p" || true
  done
  return 0
}

ableton_launcher_alive() {
  # Supporting signal only: the wrapper PID open_in_ableton() captured.
  # The launcher can hand off to a setsid child and exit early (live-log
  # confirmed: the captured pid was already gone while Live was still up),
  # so a dead launcher pid is never treated as proof on its own — it is only
  # allowed to agree with the process/window checks, never to force a close.
  [[ -n ${ABLETON_LAUNCH_PID:-} ]] && kill -0 "$ABLETON_LAUNCH_PID" 2>/dev/null
}

ableton_pid_matches_configured() {
  # $1 = pid. Kept for callers that already hold a pid; the real prefix/image
  # logic lives in ableton_pid_is_live(). A DIFFERENT edition/version than the
  # one configured is deliberately not "ours" — separate instances are
  # expected to be able to coexist.
  ableton_pid_is_live "$1"
}

configured_ableton_running() {
  # ableton_pids() is already scoped to the configured image (and falls back
  # to the generic "Ableton Live" when Settings has no version yet), so this
  # is exactly "are any of our Live PIDs alive right now".
  [[ -n $(ableton_pids) ]]
}

bitwig_pids() {
  # Same comm-based filter as ableton_pids() (see there for why): -f
  # matches the whole command line, so a shell merely mentioning
  # "bitwig-studio"/"BitwigStudio" matches too — reproduced live while
  # testing this exact function, not hypothetical.
  local p comm
  { pgrep -f "$BITWIG_BIN" 2>/dev/null; pgrep -f "BitwigStudio" 2>/dev/null; } | sort -u | \
  while IFS= read -r p; do
    comm=$(ps -p "$p" -o comm= 2>/dev/null)
    case "$comm" in
      bash|sh|dash|zsh|grep|sed|awk|cat|find|env) ;;
      *) printf '%s\n' "$p" ;;
    esac
  done
}

bitwig_running() {
  [[ -n $(bitwig_pids) ]]
}

ensure_ableton_not_already_open() {
  # If the specific Ableton install Settings has configured is already
  # running right when we're about to launch a *different* set into it,
  # offer to close it first — opening a second project on top of an
  # existing session is exactly the kind of thing that could silently
  # misbehave. Wait-only: the user closes it themselves; the manager never
  # sends synthetic keys.
  configured_ableton_running || return 0
  if ! ui_confirm "Ableton is already open. Continuing will force-quit Ableton, so any unsaved work is lost — save your project first. Continue?"; then
    return 1
  fi
  close_configured_ableton_and_wait
}

# The mechanical part of the above, split out so the TUI's actions script
# can call it directly once Go's own Confirm screen has already answered
# "yes". No synthetic keys are ever sent: every PID linked to the configured
# Live image gets SIGTERM (ableton_close_all), then the wait ends once
# ableton_pids() has been empty for ABLETON_CLOSE_STABLE consecutive checks —
# the same process-only signal ableton_wait_and_detect() uses. Windows are
# intentionally not consulted: the proven native detector never did, and a
# stale/misreported X window keeping the gate open is what made the old wait
# appear to hang.
close_configured_ableton_and_wait() {
  local elapsed=0 stable=0 need_stable="${ABLETON_CLOSE_STABLE:-3}" pids
  pids="$(ableton_pids)" || true
  if [[ -z $pids ]]; then
    ok "no matching Ableton process to close"
    return 0
  fi
  progress "closing the already-open Ableton instance (PIDs: $(printf '%s ' $pids))…"
  ableton_close_all
  while (( elapsed < MAX_WAIT_ABLETON )); do
    pids="$(ableton_pids)" || true
    if [[ -z $pids ]]; then
      stable=$((stable + 1))
      info "post-Ableton(close): all-clear ${stable}/${need_stable} (pids=none)"
      if (( stable >= need_stable )); then
        ok "existing Ableton instance closed"
        return 0
      fi
    else
      stable=0
      (( elapsed % 15 == 0 )) && progress "waiting for the open Ableton to exit… (${elapsed}s; pids=$(printf '%s ' $pids))"
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  warn "Ableton is still open after ${MAX_WAIT_ABLETON}s — cannot continue."
  return 1
}

focus_existing_bitwig() {
  # Switches to Bitwig's already-open window (whatever workspace/monitor
  # it's on) instead of launching a second instance or ever asking Bitwig
  # to close — per explicit request, Bitwig is never blocked or closed for
  # this flow, only Ableton is (ensure_ableton_not_already_open). Uses
  # Omarchy's own `omarchy-hyprland-focus-app` (ships system-wide,
  # confirmed present) — matches by window class, case-insensitive
  # regex, against Bitwig's own StartupWMClass
  # (com.bitwig.BitwigStudio). Falls back to the same `hl.dsp.focus`
  # dispatch inline if that helper isn't found for some reason.
  bitwig_running || return 1
  if command -v omarchy-hyprland-focus-app >/dev/null 2>&1; then
    omarchy-hyprland-focus-app bitwig >/dev/null 2>&1 && return 0
  fi
  command -v hyprctl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || return 1
  local clients p addr
  clients=$(hyprctl clients -j 2>/dev/null) || return 1
  for p in $(bitwig_pids); do
    addr=$(jq -r --arg p "$p" '[.[] | select((.pid|tostring) == $p) | .address] | first // empty' <<<"$clients" 2>/dev/null)
    if [[ -n $addr ]]; then
      hyprctl dispatch "hl.dsp.focus({ window = \"address:$addr\" })" >/dev/null 2>&1 && return 0
    fi
  done
  return 1
}

# ─── Ableton phase — launch, wait for the user to save & close ──────────────
# No automation: Ableton is launched (open_in_ableton) and the manager only
# waits for the user to save and close it, then detects the .als that session
# saved. ableton_wait_and_detect below is the whole phase: no Ctrl+Q, no
# Return, no xdotool key-sending, no assisted save/close, no auto-save, no
# timer and no OSC. WORKDIR is the manager's configurable als folder ($ALS_DIR).

ableton_win_class() {
  # The Wine WM_CLASS is the lowercased exe basename Ableton itself exports
  # (StartupWMClass in ableton-live.desktop is exactly that). Derived from
  # ableton_live_image(), which follows LEARNED_ABLETON_EXE — never a
  # hardcoded Live version. With no version configured the generic
  # "ableton live" is used, which xdotool matches as a substring of any
  # edition's real class.
  printf '%s\n' "$(ableton_live_image | tr '[:upper:]' '[:lower:]')"
}

ableton_get_main_win() {
  local id name
  for id in $(xdotool search --class "$(ableton_win_class)" 2>/dev/null || true); do
    name=$(xdotool getwindowname "$id" 2>/dev/null || true)
    if echo "$name" | grep -qi "Ableton Live"; then
      echo "$id"
      return
    fi
  done
  # Fallback for a WM_CLASS that doesn't match the exe basename: the same
  # visible "<title> Ableton Live" search ableton_window_ids() uses. Without
  # this, a mis-derived class made the phase wait 40s then fail with "main
  # window not found" even though Live was clearly up.
  ableton_window_ids | head -n1
}

hypr_dispatch() {
  # $1 = a hyprctl dispatcher expression; $2 = optional classic-syntax
  # fallback. Omarchy's current Hyprland (0.5x) uses Lua dispatcher syntax
  # (hl.dsp.*); older builds use the classic one-token form. Runs $1, and
  # only if the compositor rejected it does it try $2. Returns 0 when a
  # dispatcher was accepted. Never prints, never fatal.
  local out
  command -v hyprctl >/dev/null 2>&1 || return 1
  out=$(hyprctl dispatch "$1" 2>&1) || true
  case "$out" in
    *error*|*unknown*|*"nil value"*|*"expected a dispatcher"*|*"window not found"*) ;;
    *) return 0 ;;
  esac
  [[ -n ${2:-} ]] || return 1
  out=$(hyprctl dispatch "$2" 2>&1) || true
  case "$out" in
    *error*|*unknown*|*"nil value"*|*"expected a dispatcher"*) return 1 ;;
  esac
  return 0
}

# ─── Manager window visibility (Hyprland) ───────────────────────────────────
# The conversion's Ableton phase can take a long time (the user edits and
# saves in Live), and the Bitwig phase that follows is background bookkeeping;
# neither should leave the manager's foot window sitting on top of the desktop.
# When Ableton is launched, the manager window is moved to a silent special
# workspace (so its process keeps running but nothing is on screen) and it
# stays hidden for the whole Ableton + Bitwig sequence. It is moved back ONLY
# on an error, so the user can read what failed. All of this is best-effort
# and a no-op without Hyprland/hyprctl/jq or when the TUI runs in a plain
# (non-foot) terminal.
MANAGER_WINDOW_SPECIAL="special:mosquito-move-manager"

manager_win_address() {
  # Hyprland address of the manager's own window, matched by the app-id the
  # dispatcher launches foot with (org.omarchy.mosquito-move-manager-tui).
  # Empty when hyprctl/jq are missing or the window isn't mapped.
  command -v hyprctl >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  hyprctl clients -j 2>/dev/null | jq -r '
    [ .[]
      | select(((.class // "")        | ascii_downcase | contains("mosquito-move-manager-tui"))
            or ((.initialClass // "") | ascii_downcase | contains("mosquito-move-manager-tui")))
      | .address ] | first // empty' 2>/dev/null
}

manager_window_hide() {
  # Move the manager's own window to its silent special workspace. hypr_dispatch
  # covers both the Lua dispatcher syntax Omarchy's current Hyprland (0.5x)
  # uses and the classic movetoworkspacesilent older builds use.
  command -v hyprctl >/dev/null 2>&1 || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local addr ws
  addr="$(manager_win_address)" || return 0
  [[ -n $addr ]] || return 0
  hypr_dispatch \
    "hl.dsp.window.move({ workspace = \"$MANAGER_WINDOW_SPECIAL\", follow = false, window = \"address:$addr\" })" \
    "movetoworkspacesilent $MANAGER_WINDOW_SPECIAL,address:$addr" || true
  # Verify it actually left the normal workspace; some Hyprland builds ignore
  # the window selector on window.move. Fall back to focus-the-window then
  # move the (now active) window, which every build honors.
  ws=$(hyprctl clients -j 2>/dev/null | jq -r --arg a "$addr" '.[] | select(.address == $a) | (.workspace.name // "")' 2>/dev/null)
  if [[ $ws != special:* ]]; then
    hypr_dispatch "hl.dsp.focus({ window = \"address:$addr\" })" "focuswindow address:$addr" || true
    hypr_dispatch \
      "hl.dsp.window.move({ workspace = \"$MANAGER_WINDOW_SPECIAL\", follow = false })" \
      "movetoworkspacesilent $MANAGER_WINDOW_SPECIAL" || true
  fi
  return 0
}

manager_window_show() {
  # Bring the manager window back onto the active workspace and focus it (the
  # error path). No-op when it isn't hidden/mapped.
  command -v hyprctl >/dev/null 2>&1 || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local addr ws_id
  addr="$(manager_win_address)" || return 0
  [[ -n $addr ]] || return 0
  ws_id=$(hyprctl activeworkspace -j 2>/dev/null | jq -r '.id // empty' 2>/dev/null)
  [[ -n $ws_id ]] || ws_id=1
  hypr_dispatch \
    "hl.dsp.window.move({ workspace = \"$ws_id\", follow = true, window = \"address:$addr\" })" \
    "movetoworkspace $ws_id,address:$addr" || true
  hypr_dispatch "hl.dsp.focus({ window = \"address:$addr\" })" "focuswindow address:$addr" || true
  return 0
}

ableton_als_roots() {
  # Every folder a saved .als can land in, one per line, deduplicated:
  #   - the manager's own als working folder ($ALS_DIR);
  #   - Ableton Live's documented default save locations (Documents,
  #     Music, Desktop, Downloads, and the Ableton subfolders Live itself
  #     creates: Documents/Ableton, Music/Ableton);
  #   - the chosen Ableton install's Wine prefix Documents/Ableton, so a
  #     custom WINEPREFIX or a version whose default save folder lives in
  #     the prefix is covered too (normally that path is a symlink back to
  #     the host Documents, but a real prefix may not be).
  # detect_new_als(), start_als_watch() and ableton_wait_and_detect() all
  # read this one list, so no path can ever see a narrower set of folders.
  local -a roots=(
    "$ALS_DIR"
    "$MUSIC_DIR"
    "$HOME/Documents/Ableton"
    "$HOME/Music/Ableton"
    "$HOME/Music"
    "$HOME/Documents"
    "$HOME/Desktop"
    "$HOME/Downloads"
  )
  local prefix win_user d
  if [[ -n ${LEARNED_ABLETON_EXE:-} && ${LEARNED_ABLETON_EXE} == */drive_c/* ]]; then    prefix="${LEARNED_ABLETON_EXE%%/drive_c/*}"
  fi
  prefix="${prefix:-$HOME/.wine-ableton}"
  if [[ -d $prefix/drive_c/users ]]; then
    while IFS= read -r win_user; do
      [[ -n $win_user ]] || continue
      roots+=("$win_user/Documents/Ableton" "$win_user/Music/Ableton")
    done < <(find "$prefix/drive_c/users" -maxdepth 1 -mindepth 1 -type d ! -name Public 2>/dev/null)
  fi
  local -A seen=()
  for d in "${roots[@]}"; do
    [[ -n $d && -z ${seen[$d]:-} ]] || continue
    seen[$d]=1
    printf '%s\n' "$d"
  done
}

# Wait-only Ableton phase. There is no automation here: the manager never
# sends Ctrl+Q/Return (or any other synthetic key), never runs an "assisted
# save/close", never auto-saves, and never uses a timer or OSC. It waits for
# the user to save the project and close Ableton, watching the .als roots
# (kernel-level inotify + the mtime scan) the whole time, and only trusts the
# close once the version's real Live PIDs (ableton_pids — the configured
# image, matched case-insensitively across the Wine process tree) are GONE
# and zero Ableton windows have existed for ABLETON_CLOSE_STABLE consecutive
# checks. It then resolves the saved .als in $ALS_DIR, waits for it to stop
# changing on disk, and echoes its path on stdout. Every step emits a
# progress() line on stderr (visible in the TUI runner). Return codes:
#   0 = saved .als found (path echoed on stdout)
#   1 = Ableton's main window never appeared — a real launch failure
#   2 = window was there but no saved .als was detected
ableton_wait_and_detect() {
  # Wait-only Ableton phase, rebuilt on the proven native detector: the ONLY
  # thing that decides "Ableton is running" / "Ableton closed" is
  # is_ableton_running() — a pgrep of the real Live process filtered by
  # ableton_pids(). Windows/xdotool are never consulted; the old arm/window
  # gate could keep the loop spinning to the 4 h guard (a stale or
  # misreported X window, or an over-eager /proc environ match) and that is
  # exactly the "it hangs after launching" symptom.
  #
  # Flow: wait (bounded) for the Live process to appear → arm the .als watch
  # → tell the user where to save + that they must quit → poll until the
  # process has been gone for ABLETON_CLOSE_STABLE consecutive checks →
  # resolve the saved .als in ALS_DIR (falling back outward) → echo its path.
  #
  # stdout: exactly one path on success. Everything else goes to stderr via
  # progress()/warn()/err() so a caller's `$(...)` capture stays clean.
  # Return codes: 0 = found, 1 = Ableton never started, 2 = closed but no .als.
  local bundle="${1:-}" i seen last_seen="" elapsed=0 gone=0 new_file=""
  local need_gone="${ABLETON_CLOSE_STABLE:-3}"
  local start_timeout="${ABLETON_START_TIMEOUT:-90}"
  local min_session="${ABLETON_MIN_SESSION:-8}"

  progress "waiting for Ableton to start (up to ${start_timeout}s)…"
  for ((i = 0; i < start_timeout; i++)); do
    is_ableton_running && break
    sleep 1
  done
  if ! is_ableton_running; then
    stop_als_watch 2>/dev/null || true
    err "Ableton never started — no « $(ableton_live_image) » process appeared within ${start_timeout}s. Check the ableton-live wrapper/Wine prefix, then retry."
    return 1
  fi
  info "post-Ableton: live PID(s) for « $(ableton_live_image) »: $(printf '%s ' $(ableton_pids))"
  progress "Ableton is up — PID(s): $(printf '%s ' $(ableton_pids))"

  # Kernel-level watch for the whole session (best-effort; the mtime scan in
  # detect_als_during_session/detect_session_als is the fallback without
  # inotifywait).
  rm -f "$ALS_WATCH_FILE" 2>/dev/null || true
  if start_als_watch; then
    info "post-Ableton: inotify close_write watch armed on: $(ableton_als_roots | paste -sd, -)"
    progress "watching the .als folders while you work in Ableton…"
  else
    warn "inotifywait unavailable — falling back to the mtime scan only"
  fi

  ableton_save_progress
  while (( elapsed < MAX_WAIT_ABLETON )); do
    # (1) Kernel-level close_write hit, checked every tick: any .als the
    # watch saw finish writing was written during THIS session, so a strong
    # hit (inside $ALS_DIR or named exactly like the set) advances directly —
    # no need to wait for the close gate that used to stall the flow.
    if seen=$(latest_watched_als 2>/dev/null) && [[ -n $seen ]]; then
      printf '%s\n' "$seen" > "$ALS_WATCH_FILE"
      if [[ $seen != "$last_seen" ]]; then
        info "post-Ableton: .als finished writing (inotify): $seen"
        last_seen="$seen"
        if _als_candidate_strong "$seen" "$bundle"; then
          progress "new saved .als detected — advancing: $seen"
          new_file="$seen"
          break
        fi
      fi
    fi

    # (2) mtime poll across $ALS_DIR + the broad Ableton roots, throttled to
    # keep the poll cheap. Only a strong candidate auto-advances; anything
    # else is left for the post-close scan.
    if (( elapsed % 3 == 0 )); then
      if seen=$(detect_als_during_session "$bundle") && [[ -n $seen ]]; then
        progress "new saved .als detected this session — advancing: $seen"
        new_file="$seen"
        break
      fi
    fi

    if is_ableton_running; then
      gone=0
    elif (( elapsed >= min_session )); then
      # Never trust a close in the first seconds (a Wine re-exec during
      # startup can briefly clear the process list).
      gone=$((gone + 1))
      info "post-Ableton: all-clear ${gone}/${need_gone} (no « $(ableton_live_image) » PID)"
      if (( gone >= need_gone )); then
        info "post-Ableton: Ableton closed (${gone} consecutive clear checks)"
        break
      fi
    fi

    elapsed=$((elapsed + 1))
    if (( elapsed % 15 == 0 )); then
      progress "waiting for Ableton to close… (${elapsed}s; PIDs: $(printf '%s ' $(ableton_pids) 2>/dev/null || printf 'none'))"
      ableton_save_progress
    fi
  done

  # One last read right as Ableton exits — a save immediately followed by a
  # close can otherwise land between two poll ticks.
  if seen=$(latest_watched_als 2>/dev/null) && [[ -n $seen ]]; then
    printf '%s\n' "$seen" > "$ALS_WATCH_FILE"
    last_seen="$seen"
  fi
  stop_als_watch

  # A candidate already advanced this session is used directly (disk-
  # stabilized first); it is the exact file the user just saved.
  if [[ -n $new_file && -f $new_file ]]; then
    wait_for_als_stable "$new_file" || true
    progress "detected saved ALS: $new_file"
    printf '%s\n' "$new_file"
    return 0
  fi

  if (( elapsed >= MAX_WAIT_ABLETON )) && is_ableton_running; then
    warn "Ableton was still open after the maximum ${MAX_WAIT_ABLETON}s wait"
  fi
  progress "scanning $ALS_DIR (and the Ableton roots) for the saved .als…"
  new_file=$(detect_session_als "$bundle") || new_file=""
  new_file="${new_file%%$'\n'*}"
  if [[ -z $new_file || ! -f $new_file ]]; then
    err "No .als was found in $ALS_DIR after Ableton closed — save the project there, name it like the set${bundle:+ (« $(ableton_set_name "$bundle") »)}, then retry"
    return 2
  fi
  progress "detected saved ALS: $new_file"
  printf '%s\n' "$new_file"
}

ableton_window_ids() {
  # Lists Ableton windows, best-effort and deduplicated:
  #   - by the REAL Wine WM_CLASS (hyprctl live-confirmed: "ableton live 12
  #     suite.exe"), which also covers Live's helper windows (DXGI/JUCE/IME);
  #   - by the "<title> Ableton Live" name as a fallback for a mis-derived
  #     class.
  # Deliberately NOT `--onlyvisible`: on Hyprland a mapped Wine window can be
  # reported as not-visible (live bug: ableton_get_main_win found the window
  # with a plain `search --class` while ableton_window_count, using
  # `--onlyvisible`, said 0 — so the close gate fired while Live was still
  # open). A closed Live destroys its X windows, so a plain search is safe;
  # the N-consecutive-checks gate absorbs any brief teardown flicker.
  # Empty when xdotool is missing or no window is up yet.
  command -v xdotool >/dev/null 2>&1 || return 0
  {
    xdotool search --class "$(ableton_win_class)" 2>/dev/null
    xdotool search --name "Ableton Live" 2>/dev/null
  } | sort -un | head -n50
}

ableton_window_count() {
  # How many Ableton windows exist right now — the same detection
  # ableton_window_ids() uses everywhere else, reduced to a count. For the
  # post-save phase the only question is zero vs. not zero, so the exact
  # number doesn't matter. Best-effort by design: when xdotool is
  # unavailable this is always 0, so callers that also gate on
  # ableton_pids() stay correct.
  local n=0 w
  while IFS= read -r w; do
    [[ -n $w ]] && n=$((n + 1))
  done < <(ableton_window_ids 2>/dev/null || true)
  printf '%s\n' "$n"
}

start_als_watch() {
  # Kernel-level (inotify), not process-based: catches the exact moment any
  # .als anywhere under the same folders detect_session_als scans finishes
  # being written (close_write — not create, which fires before the write
  # is done, and not modify, which fires repeatedly mid-write). This sees
  # Wine's own file I/O exactly like any other process's, since Wine
  # ultimately does real POSIX writes to the host filesystem — no
  # dependency on correctly identifying *which* Wine/wineserver PID owns
  # the write, which is what made an earlier lsof-based attempt fragile.
  # Runs for the whole Ableton session (started here, stopped once
  # ableton_wait_and_detect sees the session close); detect_session_als()
  # reads whatever this last saw.
  command -v inotifywait >/dev/null 2>&1 || return 1
  local -a roots=()
  local d
  while IFS= read -r d; do
    [[ -d $d ]] && roots+=("$d")
  done < <(ableton_als_roots)
  (( ${#roots[@]} > 0 )) || return 1
  : > "$ALS_INOTIFY_LOG"
  # 3>&-: inotifywait -m is long-lived; inheriting the actions sentinel fd
  # (fd 3) would keep the runner's stdout pipe open for the whole session.
  inotifywait -m -r -e close_write --format '%w%f' "${roots[@]}" >> "$ALS_INOTIFY_LOG" 2>/dev/null 3>&- &
  echo $! > "$ALS_WATCH_PIDFILE"
}

stop_als_watch() {
  [[ -f $ALS_WATCH_PIDFILE ]] || return 0
  local p
  p=$(cat "$ALS_WATCH_PIDFILE" 2>/dev/null)
  [[ -n $p ]] && kill "$p" 2>/dev/null || true
  rm -f "$ALS_WATCH_PIDFILE"
}

latest_watched_als() {
  [[ -f $ALS_INOTIFY_LOG ]] || return 1
  local hit
  hit=$(grep -i '\.als$' "$ALS_INOTIFY_LOG" 2>/dev/null | tail -1)
  [[ -n $hit && -f $hit ]] || return 1
  printf '%s\n' "$hit"
}

# ───────────────────────────── ALS → Bitwig ──────────────────────────────────
scan_als() {
  # Used for `status` reporting only — the interactive flow uses
  # detect_session_als (below), which prefers ALS_DIR then falls back outward.
  ALS_FILES=()
  [[ -d $ALS_DIR ]] || return
  local f
  while IFS= read -r -d '' f; do ALS_FILES+=("$f"); done \
    < <(find "$ALS_DIR" -iname "*.als" -newer "$SESSION_START_FILE" -print0 2>/dev/null || true)
}

wait_for_als_stable() {
  # Disk-stabilization gate: an .als can be detected the instant it first
  # appears (or its mtime first ticks) while Wine/Ableton is still writing
  # it. Poll size + mtime and return 0 only once both are unchanged across
  # two consecutive short polls (~0.8s), so the file handed to the
  # copy/Bitwig step is the finished write, not a partial one. Never blocks
  # forever — bounded at ~20s; on timeout it returns 1 and the caller uses
  # the file anyway (better a possibly-partial file than none).
  local f="$1" prev="" sig stable=0 tries=0
  [[ -f $f ]] || return 1
  while (( tries < 50 )); do
    sig="$(stat -c '%s %Y' "$f" 2>/dev/null || true)"
    if [[ -n $sig && $sig == "$prev" ]]; then
      stable=$((stable + 1))
      (( stable >= 2 )) && { progress "disk stabilized: $f (size+mtime unchanged)"; return 0; }
    else
      stable=0
    fi
    prev="$sig"
    sleep 0.4; tries=$((tries + 1))
  done
  progress "disk never stabilized within the wait — using $f anyway"
  return 1
}

ableton_set_name() {
  # $1 = bundle path. The conversion's set/project name: the bundle's basename
  # with a known bundle suffix stripped. Live saves the project as
  # "<set name>.als" or "<set name> Project/<set name>.als" (live-confirmed:
  # "Set 10 (1).ablbundle" -> "Set 10 (1).als").
  local base
  base="$(basename "$1")"
  base="${base%.ablbundle}"
  base="${base%.ablbundle.download}"
  base="${base%.bundle}"
  printf '%s\n' "$base"
}

_als_pick_in_dir() {
  # $1 = dir, $2 = lowercased set name (may be empty). Echoes, in priority
  # order:
  #   (a) the .als in dir whose basename matches the conversion's set name
  #       (case-insensitively) — regardless of mtime, since a name match is
  #       the strongest signal and a set re-saved over an existing file may
  #       not be newer than the session stamp;
  #   (b) else the newest .als created/modified during this session (newer
  #       than $SESSION_START_FILE, which catches both a fresh create and a
  #       save-over).
  # Else nothing. The name pass deliberately scans every .als, not only the
  # new ones, so requirement (a) holds even when the timestamp says old.
  local dir="$1" lset="$2" cand base ts newest="" newest_t=0
  [[ -d $dir ]] || return 0
  if [[ -n $lset ]]; then
    while IFS= read -r -d '' cand; do
      base="$(basename "$cand" .als)"
      if [[ ${base,,} == "$lset" ]]; then
        printf '%s\n' "$cand"
        return 0
      fi
    done < <(find "$dir" -iname '*.als' -print0 2>/dev/null || true)
  fi
  while IFS= read -r -d '' cand; do
    ts=$(stat -c %Y "$cand" 2>/dev/null || echo 0)
    (( ts > newest_t )) && { newest_t=$ts; newest="$cand"; }
  done < <(find "$dir" -iname '*.als' -newer "$SESSION_START_FILE" -print0 2>/dev/null || true)
  printf '%s\n' "$newest"
}

_als_candidate_strong() {
  # $1 = .als path, $2 = bundle (optional). True when the file is a strong
  # signal that the user deliberately saved the conversion: it lives inside
  # $ALS_DIR, or its basename equals the converted set name. Live's own
  # autosave/Backup copies (timestamped names under a Backup folder) are
  # deliberately NOT strong, so a background backup can never auto-advance a
  # conversion that is still in progress.
  local path="$1" bundle="${2:-}" base lset
  [[ -f $path ]] || return 1
  [[ -n ${ALS_DIR:-} ]] || return 1
  case "$path" in
    "$ALS_DIR"/*) return 0 ;;
    */Backup/*|*/backup/*) return 1 ;;
  esac
  [[ -n $bundle ]] || return 1
  lset="$(ableton_set_name "$bundle")"
  lset="${lset,,}"
  [[ -n $lset ]] || return 1
  base="$(basename "$path" .als)"
  [[ ${base,,} == "$lset" ]]
}

_als_pick_new_in_dir() {
  # $1 = dir. Echoes the newest .als in dir modified after the session stamp
  # (a fresh create or a save-over), or nothing. Unlike _als_pick_in_dir()
  # this deliberately ignores name-only matches so a stale same-named file
  # from an earlier conversion can never count as "new this session".
  local dir="$1" cand ts newest="" newest_t=0
  [[ -d $dir && -f $SESSION_START_FILE ]] || return 0
  while IFS= read -r -d '' cand; do
    ts=$(stat -c %Y "$cand" 2>/dev/null || printf '0')
    [[ $ts =~ ^[0-9]+$ ]] || ts=0
    (( ts > newest_t )) && { newest_t=$ts; newest="$cand"; }
  done < <(find "$dir" -iname '*.als' -newer "$SESSION_START_FILE" -print0 2>/dev/null || true)
  printf '%s\n' "$newest"
}

newest_als_in_dir() {
  # $1 = dir. Echoes the most recently modified .als anywhere under dir, or
  # nothing. Deliberately session-agnostic: used when a caller has no specific
  # path and just wants whatever .als is in the als working folder right now —
  # even one saved before this session.
  local dir="${1:-}" cand ts newest="" newest_t=0
  [[ -n $dir && -d $dir ]] || return 0
  while IFS= read -r -d '' cand; do
    ts=$(stat -c %Y "$cand" 2>/dev/null || printf '0')
    [[ $ts =~ ^[0-9]+$ ]] || ts=0
    (( ts > newest_t )) && { newest_t=$ts; newest="$cand"; }
  done < <(find "$dir" -iname '*.als' -print0 2>/dev/null || true)
  printf '%s\n' "$newest"
}

detect_als_during_session() {
  # $1 = bundle (optional). The DURING-session probe: called while Ableton
  # is still open, every few seconds. Echoes the
  # first STRONG session-new .als it finds (inotify close_write first, then
  # $ALS_DIR, then the broad Ableton roots), or nothing. Every root it
  # checks is logged, so a miss is diagnosable from the session log. Weak
  # candidates (Backup/broad-root files not named like the set) are left
  # for the post-close detect_session_als().
  local bundle="${1:-}" watched d hit
  [[ -f $SESSION_START_FILE ]] || { info "detect_als_during_session: no session stamp yet"; return 1; }

  if [[ -f $ALS_WATCH_FILE ]]; then
    watched=$(cat "$ALS_WATCH_FILE" 2>/dev/null || true)
    if [[ -n $watched && -f $watched ]]; then
      info "detect_als_during_session: inotify close_write candidate: $watched"
      if _als_candidate_strong "$watched" "$bundle"; then
        printf '%s\n' "$watched"; return 0
      fi
      info "detect_als_during_session: inotify candidate is weak; not advancing: $watched"
    fi
  fi

  while IFS= read -r d; do
    [[ -d $d ]] || { info "detect_als_during_session: root missing: $d"; continue; }
    hit=$(_als_pick_new_in_dir "$d")
    if [[ -n $hit ]]; then
      info "detect_als_during_session: session-new in $d: $hit"
      if _als_candidate_strong "$hit" "$bundle"; then
        printf '%s\n' "$hit"; return 0
      fi
      info "detect_als_during_session: weak (backup/broad) candidate; not advancing: $hit"
    fi
  done < <(ableton_als_roots)
  info "detect_als_during_session: no strong session-new .als yet"
  return 1
}

detect_session_als() {
  # $1 = bundle path (for the set-name match; optional).
  #
  # The post-close detector. It looks in the manager's own working folder
  # ($ALS_DIR) FIRST, preferring a .als whose name matches the converted set,
  # then any .als created/modified in $ALS_DIR during this session. Only when
  # nothing is there does it fall back to the broad roots (a user who pointed
  # Ableton's Save dialog elsewhere), name-first there too so a stale,
  # unrelated .als cannot win. inotify's last close_write is honored as a
  # strong signal for a file that landed outside ALS_DIR. Echoes exactly one
  # path, or returns 1 (the caller prints the clear error). No copy, no
  # backup — the file is used exactly where it lies.
  local bundle="${1:-}" set_name="" lset="" detected="" d watched
  [[ -n $bundle ]] && set_name="$(ableton_set_name "$bundle")"
  lset="${set_name,,}"

  detected="$(_als_pick_in_dir "$ALS_DIR" "$lset")"
  if [[ -n $detected ]]; then
    info "detect_session_als: matched in $ALS_DIR: $detected"
  else
    if [[ -f $ALS_WATCH_FILE ]]; then
      watched="$(cat "$ALS_WATCH_FILE" 2>/dev/null || true)"
      if [[ -n $watched && -f $watched ]]; then
        info "detect_session_als: using inotify-watched file outside ALS_DIR: $watched"
        detected="$watched"
      fi
    fi
  fi

  if [[ -z $detected ]]; then
    while IFS= read -r d; do
      [[ $d == "$ALS_DIR" ]] && continue
      [[ -d $d ]] || continue
      detected="$(_als_pick_in_dir "$d" "$lset")"
      [[ -n $detected ]] && { warn "no .als in $ALS_DIR — using one found in $d"; break; }
    done < <(ableton_als_roots)
  fi

  [[ -n $detected && -f $detected ]] || return 1
  wait_for_als_stable "$detected" || true
  printf '%s\n' "$detected"
}

detect_new_als() {
  # Prefers ALS_WATCH_FILE — the last .als inotify actually saw finish
  # being written during this session (start_als_watch/latest_watched_als,
  # kernel-level close_write events) — over guessing from folder mtimes.
  # Falls back to the broad scan (Ableton's Save dialog can land wherever
  # the user points it, not just our als folder) only when inotifywait
  # wasn't available or never caught a write — logs which roots were
  # checked and what (if anything) was found in each, so a future miss is
  # diagnosable instead of a mystery. Either way the chosen file then goes
  # through wait_for_als_stable() before it is handed on, so a still-being-
  # written .als is never used.
  local detected=""
  if [[ -f $ALS_WATCH_FILE ]]; then
    local watched
    watched=$(cat "$ALS_WATCH_FILE" 2>/dev/null)
    if [[ -n $watched && -f $watched ]]; then
      info "detect_new_als: using lsof-watched file: $watched"
      detected="$watched"
    fi
  fi

  if [[ -z $detected ]]; then
    # Save locations Ableton actually uses: the shared ableton_als_roots()
    # list — the manager's own als working folder, Ableton Live's default
    # save roots (Documents, Music, Desktop, Downloads, plus the Ableton
    # subfolders Live creates) and the chosen Wine prefix's Documents/
    # Ableton. `-newer` on the session stamp catches both a freshly CREATED
    # .als and an existing one MODIFIED (saved over) during this session.
    local d f t newest="" newest_t=0 count
    while IFS= read -r d; do
      if [[ ! -d $d ]]; then
        info "detect_new_als: root missing, skipped: $d"
        continue
      fi
      count=0
      while IFS= read -r -d '' f; do
        count=$((count + 1))
        t=$(stat -c %Y "$f" 2>/dev/null || echo 0)
        if (( t > newest_t )); then newest_t=$t; newest="$f"; fi
      done < <(find "$d" -iname "*.als" -newer "$SESSION_START_FILE" -print0 2>/dev/null)
      info "detect_new_als: scanned $d — $count candidate(s) newer than session start"
    done < <(ableton_als_roots)
    if [[ -z $newest ]]; then
      info "detect_new_als: no candidate found in any root"
      return 1
    fi
    progress "broad .als scan picked: $newest"
    detected="$newest"
  fi

  wait_for_als_stable "$detected" || true
  printf '%s\n' "$detected"
}

detect_new_bwproject() {
  # $1 = unix timestamp to search newer than.
  local since="$1" d f
  local -a roots=("$BWPROJECT_DIR" "$MUSIC_DIR" "$HOME/Documents/Ableton" "$HOME/Music/Ableton" "$HOME/Desktop" "$HOME/Documents" "$HOME/Downloads")
  for d in "${roots[@]}"; do
    [[ -d $d ]] || continue
    f=$(find "$d" -iname "*.bwproject" -newermt "@$since" -print -quit 2>/dev/null)
    [[ -n $f ]] && { printf '%s\n' "$f"; return 0; }
  done
  return 1
}

# ── (backup/copy of the saved .als removed) ─────────────────────────────────
# The old move_als_into_alsdir_backup() copied a detected .als into a sibling
# "<name> - backup/" folder under $ALS_DIR. It is gone: after the close is
# detected the manager now opens the saved .als exactly where Ableton wrote
# it — in $ALS_DIR if the user saved there, otherwise wherever it landed.
# No copy, no backup, no renamed duplicate.

import_if_outside() {
  # $1 = a saved project file (.als or .bwproject) detected outside its
  # target folder, $2 = target dir (ALS_DIR or BWPROJECT_DIR). Already
  # inside the target: nothing to do. Otherwise copies the whole containing
  # project folder (Ableton/Bitwig both save one when using "Save As" to a
  # new location) — or, if it was saved loose directly into a broad root we
  # scanned (Music/Desktop/Documents/Downloads, not its own folder), just
  # the file — into the target with a "- backup" suffix, since it's a copy
  # of what's really saved elsewhere. Echoes the path to use from here on.
  local src="$1" target_dir="$2" src_dir dest base n
  src_dir="$(dirname "$src")"
  case "$src_dir" in
    "$target_dir"|"$target_dir"/*) printf '%s\n' "$src"; return 0 ;;
  esac

  local is_broad_root=false r
  for r in "$MUSIC_DIR" "$HOME/Desktop" "$HOME/Documents" "$HOME/Downloads" "$HOME"; do
    [[ $src_dir == "$r" ]] && { is_broad_root=true; break; }
  done

  if $is_broad_root; then
    base="$(basename "$src")"
  else
    src="$src_dir"
    base="$(basename "$src_dir")"
  fi

  dest="$target_dir/$base - backup"
  n=2
  while [[ -e $dest ]]; do dest="$target_dir/$base - backup $n"; ((n++)); done

  if [[ -d $src ]]; then
    cp -a "$src" "$dest" 2>/dev/null || { printf '%s\n' "$1"; return 0; }
    info "project copied into $target_dir ($(basename "$dest"))"
    local ext="${1##*.}" new_file
    new_file=$(find "$dest" -maxdepth 1 -iname "*.$ext" -print -quit 2>/dev/null)
    printf '%s\n' "${new_file:-$1}"
  else
    cp -f "$src" "$dest" 2>/dev/null || { printf '%s\n' "$1"; return 0; }
    info "copied into $target_dir ($(basename "$dest"))"
    printf '%s\n' "$dest"
  fi
}

mark_converted() {
  # $1 = a file or folder whose conversion just completed (the source
  # bundle in ablbundle/, or its als/ copy), $2 = conversion type ("midi" or
  # "bwproject") — renamed in place with a "-converted-<type>" marker.
  # MIDI-converted sets always stay visible in future pickers; bwproject
  # ones are hidden when Settings' "Hide sets converted to Bitwig" is on.
  # Idempotent; echoes the new path (or the original, unchanged, if
  # anything about the rename didn't work).
  local path="$1" type="$2" dir base name ext new
  [[ -e $path ]] || { printf '%s\n' "$path"; return 0; }
  base="$(basename "$path")"
  if [[ $base == *-converted-* ]]; then printf '%s\n' "$path"; return 0; fi
  dir="$(dirname "$path")"
  if [[ -d $path ]]; then
    new="$dir/$base-converted-$type"
  else
    name="${base%.*}"; ext="${base##*.}"
    if [[ $name == "$base" ]]; then new="$dir/$base-converted-$type"; else new="$dir/$name-converted-$type.$ext"; fi
  fi
  if mv "$path" "$new" 2>/dev/null; then
    info "marked converted ($type): $(basename "$new")"
    mkdir -p "$STATE_DIR" 2>/dev/null
    printf '%s\t%s\t%s\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$type" "$base" "$(basename "$new")" >> "$CONVERTED_LOG" 2>/dev/null || true
    printf '%s\n' "$new"
  else
    printf '%s\n' "$path"
  fi
}

# ───── "Open the .als in Bitwig" driven by ydotoold (Hyprland-only) ───────────
# Integrated from the standalone open-als-in-bitwig script: it temporarily
# disables every real keyboard/mouse through Hyprland (so only its own
# synthetic events reach Bitwig), then drives Bitwig with ydotool/evdev key
# codes — Ctrl+O → wait for the "Select Project to Open" dialog → Ctrl+L →
# paste the path via wl-copy → Ctrl+V → Enter → wait for the dialog to close
# → restore the input devices. Enabled only when the Settings toggle "Open
# the converted .als directly with Bitwig using ydotool" is On; every
# prerequisite gap or timeout returns 1 so the caller falls back to the plain
# launch (finish_bitwig_open). Bitwig is only ever launched/focused here,
# never closed. Requires Hyprland, jq, ydotool, wl-copy and passwordless sudo
# (for ydotoold).

_als_bitwig_restore_inputs() {
  # $1 = newline-separated keyboard names, $2 = newline-separated mouse
  # names. Called from the main flow and from the watchdog subshell.
  local d
  while IFS= read -r d; do
    [[ -n $d ]] || continue
    hyprctl eval "hl.device({ name = $(printf '%q' "$d"), enabled = true })" >/dev/null 2>&1 || true
  done <<< "$1"
  while IFS= read -r d; do
    [[ -n $d ]] || continue
    hyprctl eval "hl.device({ name = $(printf '%q' "$d"), enabled = true })" >/dev/null 2>&1 || true
  done <<< "$2"
}

_als_bitwig_stop_ydotoold() {
  # Only ever called with a PID we started ourselves (empty = reuse of an
  # already-running daemon, left untouched).
  local pid="$1"
  [[ -n $pid ]] || return 0
  mq_sudo -n kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

_als_bitwig_dialog_address() {
  # $1 = dialog window title. Echoes the Hyprland address, or nothing.
  hyprctl clients -j 2>/dev/null |
    jq -r --arg title "$1" '.[] | select(.title == $title) | .address' |
    head -n 1 || true
}

_als_bitwig_ydokey() {
  # $1 = ydotool socket, rest = ydotool args. Best-effort: a dropped key
  # must not abort the whole sequence.
  local socket="$1"; shift
  mq_sudo -n env YDOTOOL_SOCKET="$socket" ydotool "$@" 2>/dev/null || true
}

open_als_in_bitwig_via_ydotool() {
  # $1 = .als path. Returns 0 only once the path was handed to Bitwig's Open
  # dialog; otherwise 1 (caller falls back to a plain launch).
  local als="$1"
  local bitwig_class="com.bitwig.BitwigStudi"
  local dialog_title="Select Project to Open"
  local socket="/tmp/.ydotool_socket"
  local lock_file="/tmp/open-als.lock"
  local max_lock_time=15
  local ydotoold_pid="" watchdog_pid="" found="" keyboards="" mice="" d working=0 i

  [[ -f $als ]] || { warn "ydotool open: .als not found: $als"; return 1; }

  for d in hyprctl jq ydotool wl-copy; do
    command -v "$d" >/dev/null 2>&1 || {
      warn "ydotool open: $d is required but not installed"
      return 1
    }
  done
  hyprland_session_active || { warn "ydotool open: this only works in a Hyprland session"; return 1; }
  # The TUI runs this action over pipes with no terminal, so an interactive
  # `sudo -v` password prompt can never be answered. The setup installs
  # /etc/sudoers.d/mosquito-move-manager-ydotoold granting NOPASSWD for
  # exactly the commands below (ydotoold, `env … ydotool`, rm of the socket,
  # kill of the daemon we start). Probe it here so a missing rule fails
  # loudly with the one-time fix, instead of silently falling back to a
  # plain Bitwig launch that cannot open a file via its CLI.
  if mq_sudo -n true 2>/dev/null; then
    progress "ydotool: passwordless sudo OK"
  else
    warn "ydotool open: passwordless sudo for ydotoold is NOT installed (the TUI cannot type a password)"
    warn "ydotool open: run once:  sudo bash <module>/setup-ableton-move-manager.sh -y"
    return 1
  fi

  if [[ -e $lock_file ]]; then
    warn "ydotool open: another ydotool open is already in progress"
    return 1
  fi
  : > "$lock_file" 2>/dev/null || true

  # Reuse a healthy ydotoold; otherwise (re)start one. A pre-existing daemon
  # is never killed at the end — only one we started ourselves.
  if [[ -S $socket ]] \
     && mq_sudo -n env YDOTOOL_SOCKET="$socket" ydotool key 125:1 125:0 >/dev/null 2>&1; then
    working=1
    progress "ydotool: reusing the running ydotoold"
  else
    progress "ydotool: starting ydotoold"
    mq_sudo -n rm -f "$socket" 2>/dev/null || true
    # setsid: the daemon is DETACHED from the manager's session/process group,
    # so quitting the manager (or closing its terminal) can never take it down.
    # sudo is still invoked with exactly /usr/bin/ydotoold so the installed
    # NOPASSWD rule matches. 3>&-: ydotoold is long-lived; it must not inherit
    # the actions sentinel fd (the runner's stdout pipe) or the TUI never sees
    # the action finish. </dev/null + disown finish the detachment.
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
      setsid /usr/bin/ydotoold </dev/null >/tmp/open-als-ydotoold.log 2>&1 3>&- &
    else
      setsid sudo -n /usr/bin/ydotoold </dev/null >/tmp/open-als-ydotoold.log 2>&1 3>&- &
    fi
    ydotoold_pid=$!
    disown 2>/dev/null || true
    for i in $(seq 1 200); do
      if [[ -S $socket ]] \
         && mq_sudo -n env YDOTOOL_SOCKET="$socket" ydotool key 125:1 125:0 >/dev/null 2>&1; then
        working=1
        break
      fi
      sleep 0.025
    done
  fi
  if (( working != 1 )); then
    warn "ydotool open: ydotoold did not respond (see /tmp/open-als-ydotoold.log)"
    _als_bitwig_stop_ydotoold "$ydotoold_pid"
    rm -f "$lock_file" 2>/dev/null || true
    return 1
  fi

  # Everything that only injects/maintains input: same exclusions as the
  # original script, so virtual/IME devices and our own uinput node stay on.
  keyboards=$(hyprctl devices -j 2>/dev/null |
    jq -r '.keyboards[]?.name // empty' |
    grep -ivE 'virtual|uinput|ydotool|fcitx|ibus|wvkbd|onboard|virtual-keyboard|input-method|wayland|video-bus|power-button|sleep-button|thinkpad-extra-buttons' |
    sort -u || true)
  mice=$(hyprctl devices -j 2>/dev/null |
    jq -r '.mice[]?.name // empty' |
    grep -ivE 'ydotool|virtual|uinput' |
    sort -u || true)

  # Safety net: if any poll below hangs, the inputs come back on their own.
  ( sleep "$max_lock_time"; _als_bitwig_restore_inputs "$keyboards" "$mice" ) 3>&- &
  watchdog_pid=$!

  while IFS= read -r d; do
    [[ -n $d ]] || continue
    hyprctl eval "hl.device({ name = $(printf '%q' "$d"), enabled = false })" >/dev/null 2>&1 || true
  done <<< "$keyboards"
  while IFS= read -r d; do
    [[ -n $d ]] || continue
    hyprctl eval "hl.device({ name = $(printf '%q' "$d"), enabled = false })" >/dev/null 2>&1 || true
  done <<< "$mice"

  # Focus an existing Bitwig, or launch it bare and wait for its window —
  # the project is opened through the dialog below, not a CLI argument.
  found=$(hyprctl clients -j 2>/dev/null |
    jq -r --arg c "$bitwig_class" '.[] | select(.class == $c) | .address' |
    head -n 1 || true)
  if [[ -z $found ]]; then
    info "ydotool open: launching Bitwig"
    progress "ydotool: launching Bitwig"
    # setsid + </dev/null + disown: Bitwig gets its OWN session/process group.
    # Quitting the manager (or closing its terminal) therefore never takes
    # Bitwig down with it. 3>&-: never hold the runner pipe open either.
    setsid "$BITWIG_BIN" </dev/null >/dev/null 2>&1 3>&- &
    disown 2>/dev/null || true
    for i in $(seq 1 300); do
      found=$(hyprctl clients -j 2>/dev/null |
        jq -r --arg c "$bitwig_class" '.[] | select(.class == $c) | .address' |
        head -n 1 || true)
      [[ -n $found ]] && break
      sleep 0.05
    done
  else
    progress "ydotool: focusing the running Bitwig"
  fi

  local cleanup_needed=0
  if [[ -z $found ]]; then
    warn "ydotool open: could not find or launch Bitwig"
    cleanup_needed=1
  fi

  if (( cleanup_needed == 0 )); then
    hyprctl dispatch "hl.dsp.focus({ window = \"class:$bitwig_class\" })" >/dev/null 2>&1 || true
    sleep 0.05
    _als_bitwig_ydokey "$socket" key 29:1 24:1 24:0 29:0   # Ctrl+O

    local dialog_addr=""
    for i in $(seq 1 200); do
      dialog_addr=$(_als_bitwig_dialog_address "$dialog_title")
      [[ -n $dialog_addr ]] && break
      sleep 0.025
    done
    if [[ -z $dialog_addr ]]; then
      warn "ydotool open: Bitwig's Open dialog did not appear"
      cleanup_needed=1
    else
      progress "ydotool: Open dialog found"
      hyprctl dispatch "hl.dsp.focus({ window = \"address:$dialog_addr\" })" >/dev/null 2>&1 || true
      sleep 0.05
      _als_bitwig_ydokey "$socket" key 29:1 24:1 24:0 29:0   # Ctrl+L (location bar)
      sleep 0.05
      printf '%s' "$als" | wl-copy 2>/dev/null || true
      sleep 0.03
      _als_bitwig_ydokey "$socket" key 29:1 47:1 47:0 29:0   # Ctrl+V
      progress "ydotool: path pasted, confirming"
      sleep 0.05
      _als_bitwig_ydokey "$socket" key 28:1 28:0             # Enter
      for i in $(seq 1 200); do
        [[ -z $(_als_bitwig_dialog_address "$dialog_title") ]] && break
        sleep 0.025
      done
      hyprctl dispatch "hl.dsp.focus({ window = \"class:$bitwig_class\" })" >/dev/null 2>&1 || true
    fi
  fi

  kill "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true
  _als_bitwig_restore_inputs "$keyboards" "$mice"
  _als_bitwig_stop_ydotoold "$ydotoold_pid"
  rm -f "$lock_file" 2>/dev/null || true

  if (( cleanup_needed == 1 )); then
    return 1
  fi
  progress "ydotool: done — .als handed to Bitwig"
  ok "opened $(basename "$als") in Bitwig"
}

open_in_bitwig() {
  local als="$1"
  info "launching Bitwig with $als"
  progress "launching Bitwig with $(basename "$als")…"
  # setsid + </dev/null + disown: Bitwig runs in its OWN session/process group,
  # fully detached from the manager. Quitting the manager (or closing its
  # terminal) must NEVER quit Bitwig. 3>&- keeps the runner pipe free.
  setsid "$BITWIG_BIN" "$als" </dev/null >/dev/null 2>&1 3>&- &
  disown 2>/dev/null || true
  ok "Bitwig opened ($!)"
  # Bitwig's own .desktop entry (unlike every other app on this system) has
  # no %f/%U file-argument placeholder, its declared MimeType list has no
  # .als/Ableton entry either, and its own launcher binary has zero CLI
  # file-open support at any level (confirmed: `strings` on the binary
  # shows only test/build/headless-related flags, no open/import flag) —
  # strong, multi-angle evidence its CLI doesn't actually support opening a
  # file passed as a bare argument the way most apps do (Bitwig's own docs
  # only describe importing an .als via File > Open / Cmd-O inside the
  # app). The argument above is still passed, in case some invocation path
  # does honor it, but no separate fallback notification is fired here
  # anymore — the single notification already sent right before this call
  # (open_ableton_route) covers the "open the .als yourself" guidance, so
  # this would just be a second, redundant one saying the same thing twice.
}

wait_bitwig_saved() {
  # Polls for the project to actually be (re)saved — Bitwig exposes no
  # "saved" signal to hook. Capped much shorter than the Ableton-session
  # wait: this is background bookkeeping (marking the set converted), not
  # something that should keep the script running for hours in the
  # background — Bitwig itself is never touched, here or on timeout, only
  # this script's own wait ends. Also bails out immediately (not the full
  # MAX_WAIT_BITWIG_SAVE) the moment Bitwig itself is no longer running —
  # closing it quickly after opening (without saving) used to leave this
  # polling uselessly for the whole timeout before the script could move
  # on, reported directly as "the script comes back after a while".
  # No notification lives here anymore: the single Bitwig notification now
  # fires earlier — at close-detection, right before the .als is handed to
  # Bitwig (see open_ableton_route_phase1) — so this function is only the
  # background save-wait that follows the handoff.
  local start elapsed=0 found=""
  start=$(date +%s)
  while (( elapsed < MAX_WAIT_BITWIG_SAVE )); do
    found=$(detect_new_bwproject "$start") && break
    bitwig_running || { info "post-Bitwig: Bitwig closed before a save was detected"; break; }
    sleep 5; elapsed=$((elapsed + 5))
  done
  if [[ -z $found ]]; then
    warn "no saved Bitwig project detected — leaving it as-is, script moving on."
    return 1
  fi
  import_if_outside "$found" "$BWPROJECT_DIR" >/dev/null
  ok "Bitwig project saved"
}

# ───────────────────────────── Summary/status ────────────────────────────────
print_status() {
  local addr="move.local"
  [[ -n ${MOVE_ADDRESS:-} ]] && addr="move${MOVE_ADDRESS}.local"
  msg "mosquito-move-manager"
  msg "  address:      $addr"
  msg "  folders:      $MOVE_DIR → {ablbundle, als, bwproject, bwproject/midi}"
  msg "  ableton exe:  ${LEARNED_ABLETON_EXE:-auto}"
  msg "  downloads:    ${DOWNLOAD_DIRS[*]}"
  scan_bundles
  printf '  sets:           %d (newest first)\n' "${#BUNDLES[@]}"
  scan_als
  printf '  als (session): %d\n' "${#ALS_FILES[@]}"
  if [[ -f $CONVERTED_LOG ]]; then
    printf '  converted log: %d entries (%s)\n' "$(wc -l < "$CONVERTED_LOG" 2>/dev/null || echo 0)" "$CONVERTED_LOG"
  fi
}

usage() {
  cat <<HELP
mosquito-move-manager — Ableton Move → Ableton Live → Bitwig Studio workflow

Usage:
  mosquito-move-manager       interactive menu (🟢/🔴 connection dot + address):
                                  1. Set the Move address (move.local)
                                  2. Open the Move Manager and convert (needs
                                     a connection — downloads → ablbundle)
                                  3. Convert a Move set (MIDI or Bitwig)
  mosquito-move-manager status   current state (address, folders, files)
  mosquito-move-manager --demo   simulation (no Move required)
  mosquito-move-manager --address N   address 1..99 without asking
  mosquito-move-manager --midi   convert with the MIDI route (no route question)
  mosquito-move-manager --skip-manager   don't wait for the Move Manager to close
  mosquito-move-manager --no-bitwig   stop after Ableton (no Bitwig step)
  mosquito-move-manager --pick-file   convert, pointing at one specific file
  mosquito-move-manager --replace   close any other open TUI, then open it
  mosquito-move-manager --help | --version

Folders (chosen at first launch, or if missing, in your Music folder):
  …/ablbundle          sets (the Move Manager webapp downloads straight here)
  …/als                Ableton Live projects (auto-detected wherever saved)
  …/bwproject          converted Bitwig projects (same auto-detect)
  …/bwproject/midi     MIDI exports (move-bundle-to-midi)
HELP
}

# ───────────────────────────── Ableton version ───────────────────────────────
find_ableton_exes() {
  # Same search shape as the real `ableton-live` wrapper's own discovery
  # (ProgramData/Ableton/<edition>/Program/Ableton Live*.exe) — matching it
  # exactly is what makes ABLETON_LIVE_EXE (passed to that same wrapper in
  # open_in_ableton) resolve to a real, wrapper-recognized install. Also
  # checks any sibling folder whose name suggests a staged update (Ableton's
  # updater has been seen to drop a fresh install next to the original,
  # under a folder name containing "updated") so a newer version parked
  # there isn't silently missed even though the wrapper itself doesn't look
  # there either.
  local prefix="$HOME/.wine-ableton/drive_c/ProgramData/Ableton"
  [[ -d $prefix ]] || return
  find "$prefix" -mindepth 3 -maxdepth 3 -ipath "*/Program/Ableton Live*.exe" -print0 2>/dev/null
  local d
  while IFS= read -r -d '' d; do
    find "$d" -iname "Ableton Live*.exe" -print0 2>/dev/null
  done < <(find "$prefix" -maxdepth 1 -iname "*updated*" -type d -print0 2>/dev/null)
}

ableton_exe_label() {
  # $1 = exe path. Best-effort friendly label using the real embedded
  # version (PE VERSIONINFO: ProductName + ProductVersion, e.g. "Live" +
  # "12.4.5") combined with the edition word from the install folder name
  # (".../Live 12 Suite" -> "Suite") — "Live Suite 12.4.5". Falls back to
  # the bare filename (extension stripped, so no raw ".exe" ever shown) if
  # python3/pefile is unavailable or the exe can't be parsed — that fallback
  # keeps the "Ableton" wording, since we don't know the real version then.
  local exe="$1" product="" version="" edition=""
  if command -v python3 >/dev/null 2>&1; then
    local info
    info=$(python3 - "$exe" <<'PYEOF' 2>/dev/null
import sys
try:
    import pefile
    pe = pefile.PE(sys.argv[1], fast_load=True)
    pe.parse_data_directories(directories=[pefile.DIRECTORY_ENTRY['IMAGE_DIRECTORY_ENTRY_RESOURCE']])
    info = {}
    if hasattr(pe, 'FileInfo'):
        for fi in pe.FileInfo:
            for entry in fi:
                if entry.Key == b'StringFileInfo':
                    for st in entry.StringTable:
                        for k, v in st.entries.items():
                            info[k.decode(errors='replace')] = v.decode(errors='replace')
    product = info.get('ProductName', '').strip()
    version = (info.get('ProductVersion') or info.get('FileVersion') or '').strip()
    if product and version:
        print(f"{product}\t{version}")
except Exception:
    pass
PYEOF
) || info=""
    product="${info%%$'\t'*}"
    version="${info#*$'\t'}"
    [[ $info == *$'\t'* ]] || { product=""; version=""; }
  fi
  if [[ -n $product && -n $version ]]; then
    edition="$(basename "$(dirname "$(dirname "$exe")")" 2>/dev/null | grep -oE '[A-Za-z]+$')"
    if [[ -n $edition ]]; then
      printf '%s %s %s\n' "$product" "$edition" "$version"
    else
      printf '%s %s\n' "$product" "$version"
    fi
    return 0
  fi
  local base="$(basename "$exe")"
  printf '%s\n' "${base%.*}"
}

choose_ableton_exe() {
  # Version selection lives in Settings ("Select Ableton version for
  # conversion") — this is only a fallback for when open_in_ableton() found
  # neither an explicit LEARNED_ABLETON_EXE nor the generic ableton-live
  # wrapper: auto-picks a lone install, otherwise asks the user to
  # configure one instead of prompting live.
  local -a exes=()
  while IFS= read -r -d '' exe; do exes+=("$exe"); done < <(find_ableton_exes)
  (( ${#exes[@]} > 0 )) || { err "No Ableton installation found."; return 1; }

  if (( ${#exes[@]} == 1 )); then
    LEARNED_ABLETON_EXE="${exes[0]}"
    save_prefs
    # info(), not ok(): this function's stdout is captured by the caller
    # via $(choose_ableton_exe) — anything but the exe path here would
    # corrupt that value.
    info "Only one Ableton install found — using it: $(ableton_exe_label "${exes[0]}")"
    printf '%s\n' "${exes[0]}"
    return 0
  fi

  err "Several Ableton versions found — pick one in Settings > Select Ableton version for conversion."
  return 1
}

select_ableton_version() {
  # Settings action: lists installed Ableton Live versions and saves the
  # choice to LEARNED_ABLETON_EXE, used directly by open_in_ableton() from
  # then on — no more picking at conversion time.
  local -a exes=()
  while IFS= read -r -d '' exe; do exes+=("$exe"); done < <(find_ableton_exes)
  if (( ${#exes[@]} == 0 )); then
    warn "No Ableton installation found."
    return 1
  fi
  if (( ${#exes[@]} == 1 )); then
    LEARNED_ABLETON_EXE="${exes[0]}"
    save_prefs
    ok "Only one Ableton install found — using it: $(ableton_exe_label "${exes[0]}")"
    notify "Ableton version" "Only one install found — using it: $(ableton_exe_label "${exes[0]}")" normal "$ICON_DONE"
    return 0
  fi
  local -a opts=()
  for exe in "${exes[@]}"; do opts+=("$(ableton_exe_label "$exe")"$'\t'"$exe"); done
  local chosen
  chosen=$(ui_select "Which Ableton version should conversions use?" "${opts[@]}") || return 1
  LEARNED_ABLETON_EXE="$chosen"
  save_prefs
  ok "Ableton version set: $(ableton_exe_label "$chosen")"
}

# ───────────────────────────── Session flow ──────────────────────────────────
phase_detect() {
  msg "mosquito-move-manager — detecting the Move"
  if ! $DEMO && ! detect_move; then
    err "No Ableton Move detected."
    warn "Plug the Move in via USB-C or connect it to Wi-Fi."
    notify "Move → Ableton → Bitwig" "Move not detected — plug it in and rerun" normal "$ICON_BLOCKED" --persist
    return 1
  fi
  $DEMO && { ok "demo: Move simulated"; return 0; }
  ok "Move detected"
}

phase_address() {
  local saved="${MOVE_ADDRESS:-}"
  if [[ -n ${OPT_ADDRESS:-} ]]; then
    MOVE_ADDRESS="$OPT_ADDRESS"
  else
    local current="move.local"
    [[ -n $saved ]] && current="move${saved}.local"
    if [[ -n $saved ]] && ui_confirm "Saved address: $current — keep it?"; then
      :
    else
      local n
      n=$(ui_input_number "Move address number (1…99, empty = move.local)" "$saved") || return 0
      MOVE_ADDRESS="$n"
    fi
  fi
  save_prefs
  msg "address: $(move_url)"
}

phase_webapp() {
  if $DEMO; then msg "demo: webapp « $WEBAPP_NAME » → $(move_url)"; return 0; fi
  ensure_webapp
}

select_route() {
  # $1 = the set's actual name, shown in the prompt instead of a generic
  # "the chosen set" — always asked *after* the set is picked, never before.
  local set_name="${1:-the chosen set}"
  ui_select "Convert \"$set_name\" — which route?" \
    $'MIDI export (move-bundle-to-midi)\tmidi' \
    $'Bitwig project (Ableton Live → .als → Bitwig)\tbitwig' \
    $'Convert to .als (beta, no Ableton)\tals'
}

open_ableton_route() {
  # Interactive entry point (the flag-driven interactive flow): owns the
  # "already open?" decision itself via the real ui_confirm. The TUI takes a
  # different path (open_ableton_route_phase1, orchestrated by Go) because
  # that conflict decision is PRIMARY — silently auto-declining it (as the
  # actions script's stubbed ui_confirm always does) would abort the whole
  # convert flow with no visible explanation. Bitwig is opened immediately
  # once the .als is detected — no confirm; the only remaining Bitwig-open
  # decision is the ydotool setting (finish_bitwig_open).
  local bundle="$1"
  ensure_ableton_not_already_open || { ok "canceled — an existing Ableton instance is still open"; return 1; }
  # PHASE1_ALS_RESULT (global, not a command-substitution return value): a
  # captured `als=$(open_ableton_route_phase1 ...)` would swallow every
  # info/ok/warn line phase1 prints along the way into the capture instead
  # of them reaching this real interactive terminal live, same way they
  # always have.
  PHASE1_ALS_RESULT=""
  open_ableton_route_phase1 "$bundle" || return $?
  [[ -n $PHASE1_ALS_RESULT ]] || return 0
  finish_bitwig_open "$bundle" "$PHASE1_ALS_RESULT"
}

# The "save + quit" instruction. Used by BOTH surfaces so they can never
# drift, but split so each surface gets the shape it renders correctly:
#   - the desktop notification HEADLINE is ableton_save_headline(), and its
#     BODY is ableton_save_notice(). The Omarchy toast caps its body at 3
#     text lines and an absolute $ALS_DIR regularly wraps to 2, so the phrase
#     goes in the headline and the path on the body's first line — with the
#     old "Save your project in:/<path>/Then QUIT" body the long path ate all
#     three lines and the path itself (or the quit line) was elided;
#   - the TUI runner gets one progress() line per line (progress() emits
#     line-by-line, so one multi-line string would lose its "  … " prefix
#     after the first line).
# Both resolve ALS_DIR on the spot if a caller ever got here before
# resolve_projects_dir() ran, so the folder is never shown empty.
ableton_save_headline() {
  printf '%s\n' "Save your project in:"
}

ableton_save_notice() {
  [[ -n ${ALS_DIR:-} ]] || resolve_projects_dir
  printf '%s\nThen QUIT Ableton to continue.' "$ALS_DIR"
}

ableton_save_progress() {
  [[ -n ${ALS_DIR:-} ]] || resolve_projects_dir
  progress "Save your project in:"
  progress "  $ALS_DIR"
  progress "Then QUIT Ableton to continue."
}

# Launches Ableton, tells the user where to save (using the manager's
# configurable working dir, $ALS_DIR), then waits — no synthetic keys, no
# timer, no OSC — until the user saves and QUITS Ableton. It then detects the
# .als this session saved across every known root, disk-stabilizes it, and
# uses it exactly where it is (no copy, no backup). Sets PHASE1_ALS_RESULT to
# the resolved path on success. Returns 1 when the Ableton process never
# appeared (a real launch failure). Echoes nothing on stdout.
open_ableton_route_phase1() {
  local bundle="$1" pid NEW_ALS als detect_rc=0
  PHASE1_ALS_RESULT=""
  # The working folder must be resolved before anything quotes it — a caller
  # that skipped load_prefs/resolve_projects_dir would otherwise emit the
  # notice with an empty $ALS_DIR. resolve_projects_dir() is idempotent.
  [[ -n ${ALS_DIR:-} ]] || resolve_projects_dir
  start_conversion_log "open-ableton-route"
  # Tell the user exactly where to save and that they must quit Ableton
  # afterwards — the path is the notification body's first line (see
  # ableton_save_notice) and is repeated, wrapped, on the runner log. No
  # mention of backups: there are none anymore.
  notify "$(ableton_save_headline)" "$(ableton_save_notice)" normal "$ICON_WAITING" --timeout 30
  ableton_save_progress
  # Session floor FIRST: any .als created/modified from this instant on is
  # this session's, so the detector can tell a fresh save from a pre-existing
  # file even if the baseline scan is empty or slow.
  date +%s > "$SESSION_START_FILE"
  progress "launching Ableton with $(basename "$bundle")…"
  # The manager's own window is no longer useful while the user works in
  # Ableton: hide it (silent special workspace) for the whole Ableton + Bitwig
  # phase. It is only brought back on an error below, so the failure is
  # readable. No-op without Hyprland or when running in a non-foot terminal.
  manager_window_hide || true
  # Deliberately NOT `pid=$(open_in_ableton …)` — see the pipe-trap note on
  # open_in_ableton: the background Wine/Ableton launch must never be able
  # to hold a command substitution's stdout pipe open. The function sets
  # ABLETON_LAUNCH_PID and its own pid print is sent to /dev/null here.
  ABLETON_LAUNCH_PID=""
  open_in_ableton "$bundle" >/dev/null || { err "could not open the set in Ableton"; manager_window_show || true; return 1; }
  pid="${ABLETON_LAUNCH_PID:-}"
  progress "Ableton launcher started (wrapper pid ${pid:-?}) — waiting for the Live process to appear"

  # The wait-only phase: launch/notify already done, now wait for close,
  # detect, stabilize. The bundle is forwarded so detect_session_als() can
  # prefer the .als whose name matches the converted set (not merely the
  # newest one) — dropping it here made the TUI path ignore the set name.
  if NEW_ALS=$(ableton_wait_and_detect "$bundle"); then
    detect_rc=0
  else
    detect_rc=$?
    NEW_ALS=""
  fi
  if (( detect_rc == 1 )); then
    # The Live process never appeared: a real launch failure, not a save
    # miss. Surface it as a failed phase so the TUI shows the retry
    # prompt instead of silently offering "no .als" (which implies
    # Ableton at least opened).
    notify "Move → Ableton → Bitwig" "Ableton never started — the conversion stopped" normal "$ICON_BLOCKED" --persist
    manager_window_show || true
    return 1
  fi
  # Never use a multi-line / log-polluted capture as a path: the detector
  # echoes exactly one path, but guard against a stray line here so a
  # malformed capture can't reach the ALS_PATH= sentinel.
  NEW_ALS="${NEW_ALS%%$'\n'*}"
  [[ -f $NEW_ALS ]] || NEW_ALS=""

  if ! $DO_BITWIG; then
    ok "Bitwig step skipped (--no-bitwig)"
    [[ -n $NEW_ALS ]] || manager_window_show || true
    return 0
  fi

  if [[ -z $NEW_ALS ]]; then
    # A silent return here used to be the only trace of this — if nothing is
    # found, the user gets a clear error and a non-zero status so the TUI
    # shows the dedicated "no set detected" screen (never a false success).
    err "no .als found in $ALS_DIR after Ableton closed${bundle:+ — save the set as « $(ableton_set_name "$bundle") » there, then retry}"
    notify "Move → Ableton → Bitwig" "No new .als detected in $(basename "$ALS_DIR") — save the project there, then retry" normal "$ICON_BLOCKED" --persist
    manager_window_show || true
    return 2
  fi
  progress "found saved ALS: $NEW_ALS"
  # Ableton has closed and the saved .als is in hand: this is the one Bitwig
  # notification, fired HERE — the moment of close-detection, right before the
  # set is handed to Bitwig — never at Ableton launch (too early) and never
  # during the post-handoff save wait (too late). Bounded to 10s; the runner
  # line says exactly the same thing (progress() streams live to the TUI).
  progress "Opening your saved set in Bitwig — conversion complete."
  notify "Bitwig Studio" "Opening your saved set in Bitwig — conversion complete." normal "$ICON_DONE" --timeout 10
  # No copy, no backup: the detected .als is used exactly where Ableton
  # saved it — in $ALS_DIR when the instruction was followed, otherwise
  # wherever it landed. Bitwig is handed the original file.
  als="$NEW_ALS"
  progress "using $als"
  PHASE1_ALS_RESULT="$als"
}

# The actual mechanical part (focus-or-open + wait for the save + mark
# converted) once the .als is resolved — called by open_ableton_route (the
# interactive flag-driven path) or directly by the actions script (the TUI,
# which opens Bitwig immediately after the .als is detected; there is no
# confirm screen anymore).
finish_bitwig_open() {
  local bundle="$1" als="${2:-}" opened_directly=false
  # Continue the session log opened by the Ableton/export phase this follow-up
  # belongs to — but ONLY that phase's log (tag-scoped reuse), never a log
  # from a different conversion kind. One conversion reads as ONE file.
  start_conversion_log "finish-bitwig-open" "open-ableton-route export-als"
  # An empty path means "open whatever is newest in als/ now".
  if [[ -z $als || ! -f $als ]]; then
    als="$(newest_als_in_dir "$ALS_DIR")"
    [[ -n $als ]] && progress "using the newest .als in $ALS_DIR: $als"
  fi
  [[ -n $als && -f $als ]] || { err "no .als found in ${ALS_DIR:-the als folder} to open in Bitwig"; return 2; }
  progress "opening $(basename "$als") in Bitwig…"
  if [[ ${OPEN_ALS_WITH_YDOTOOL:-true} == true ]]; then
    # Settings On: hand the .als straight to Bitwig's Open dialog via the
    # ydotoold routine (which launches/focuses Bitwig itself). Any failure
    # falls through to the plain launch below, with the usual notification.
    progress "handing off to Bitwig (ydotool direct-open)…"
    if open_als_in_bitwig_via_ydotool "$als"; then
      opened_directly=true
    else
      warn "ydotool open failed — launching Bitwig normally instead (the .als won't be loaded automatically)"
    fi
  else
    progress "ydotool direct-open is Off in Settings — using the plain Bitwig launch"
  fi
  if ! $opened_directly; then
    if bitwig_running; then
      # Never asked to close, never relaunched — just switch to its
      # existing window (whatever workspace/monitor it's on) and let the
      # user open the .als themselves; still polls for the save below.
      progress "Bitwig already open — focusing its window"
      focus_existing_bitwig || warn "could not focus the existing Bitwig window — switch to it manually"
    else
      progress "launching Bitwig normally"
      open_in_bitwig "$als"
    fi
    # Secondary fallback ONLY: with the direct-open setting off (or the
    # ydotoold path unavailable, or Bitwig already open and unfocusable)
    # Bitwig can't reliably be handed the file, so tell the user to open it
    # themselves. The primary "Opening your saved set in Bitwig" notification
    # already fired at close-detection above; this guidance is not it.
    notify "Bitwig Studio" "Open $(basename "$als") in Bitwig Studio to load your set" normal "$ICON_WAITING" --timeout 20
  fi
  BITWIG_OPENED=true
  if wait_bitwig_saved; then
    mark_converted "$bundle" bwproject >/dev/null
    # With no copy anymore the detected .als usually lives outside $ALS_DIR
    # (wherever the user saved it), and mark_converted RENAMES its target —
    # so only mark it when it is actually inside our working folder. Never
    # touch a project file the user saved elsewhere.
    case "$(dirname "$als")" in
      "$ALS_DIR"|"$ALS_DIR"/*) mark_converted "$als" bwproject >/dev/null ;;
    esac
  else
    info "post-Ableton: wait_bitwig_saved returned no saved project"
  fi
}

convert_flow() {
  # Always pick the set first, then the route — never the other way
  # around. If none are found (or --pick-file forced it, or MANAGER_MODE
  # scoped the list down to nothing), offer to point to one specific file
  # instead — a one-off pick, not remembered for next time.
  local bundle="" route
  scan_bundles
  start_conversion_log "convert-flow"

  if $DEMO; then
    if (( ${#BUNDLES[@]} == 0 )); then
      warn "demo: no set in $BUNDLE_DIR — populate it from the Move Manager first."
      return 1
    fi
    warn "demo: no conversion (route question skipped)"
    for f in "${BUNDLES[@]}"; do printf '    · %s\n' "$(basename "$f")"; done
    return 0
  fi

  if (( ${#BUNDLES[@]} == 0 )) || $FORCE_PICK; then
    if ! $FORCE_PICK; then
      warn "no set in $BUNDLE_DIR"
      if ! ui_confirm "No set found in $BUNDLE_DIR — point to a specific file instead?"; then
        notify "Move" "No set found in $BUNDLE_DIR" normal "$ICON_EMPTY"
        return 1
      fi
    fi
    bundle=$(pick_file_manually "Select an Ableton Move set") || { ok "no file chosen"; return 1; }
  fi

  if [[ -z $bundle ]]; then
    msg "$((${#BUNDLES[@]})) set(s) in $BUNDLE_DIR (newest first)"
    bundle=$(choose_bundle) || { ok "set selection canceled"; return 1; }
  fi
  msg "set: $(basename "$bundle")"

  if [[ -n ${OPT_ROUTE:-} ]]; then
    route="$OPT_ROUTE"
  elif $DO_MIDI; then
    route=midi
  elif [[ $DO_BITWIG == false ]]; then
    route=bitwig
  else
    route=$(select_route "$(basename "$bundle")") || { ok "conversion canceled"; return 1; }
  fi
  [[ $route == midi || $route == bitwig || $route == als ]] || { ok "conversion canceled"; return 1; }

  if [[ $route == midi ]]; then
    export_midi "$bundle"
    return 0
  fi
  if [[ $route == als ]]; then
    if export_als "$bundle" && [[ -n $ALS_EXPORTED_PATH ]]; then
      finish_bitwig_open "$bundle" "$ALS_EXPORTED_PATH"
    fi
    return 0
  fi
  open_ableton_route "$bundle"
}

open_manager_and_convert() {
  if ! $DEMO && ! detect_move; then
    warn "Move not detected (USB 2982 / move.local) — still opening the Move Manager."
  fi
  phase_webapp
  if $DEMO; then
    msg "demo: opening the Move Manager → $(move_url) (dedicated profile, downloads in $BUNDLE_DIR)"
    return 0
  fi
  msg "Opening the Move Manager…"
  msg "  $(move_url)"
  date +%s > "$MANAGER_BASELINE_FILE"
  open_webapp
  wait_manager_close
  deposit_downloads

  local baseline=0 f ft downloaded=false
  [[ -f $MANAGER_BASELINE_FILE ]] && baseline=$(cat "$MANAGER_BASELINE_FILE" 2>/dev/null || echo 0)
  scan_bundles
  for f in "${BUNDLES[@]}"; do
    ft=$(stat -c %Y "$f" 2>/dev/null || echo 0)
    if (( ft >= baseline )); then downloaded=true; break; fi
  done

  if $downloaded; then
    ok "set(s) downloaded — choosing which to convert"
    MANAGER_MODE=true
    MANAGER_MODE_BASELINE=$baseline
    convert_flow
    return 0
  fi

  ok "nothing downloaded this session"
  notify "Move Manager" "No set downloaded — click to pick a file and convert" normal "$ICON_ACTION" \
    --exec "$SELF" --pick-file
  # End here rather than looping back to the main menu: the notification
  # stays up (clicking it re-invokes this script with --pick-file) instead
  # of a fresh menu prompt appearing on top of it.
  exit 0
}

menu_address() {
  phase_address
  if ui_confirm "Open the Move Manager now ($(move_url))?"; then
    open_manager_and_convert
  else
    ok "address saved — the Move Manager can be opened later from the menu"
  fi
}

clear_als_folder() {
  # Empties ALS_DIR (the Ableton Live projects saved during conversion) —
  # never the ablbundle/bwproject folders, just the intermediate .als
  # working copies. Confirmation-gated; reports how many files were removed
  # (or that there was nothing to clear) rather than staying silent either
  # way.
  if [[ ! -d $ALS_DIR ]]; then
    notify "Move → Ableton → Bitwig" "No als folder to clear" normal "$ICON_EMPTY"
    return 0
  fi
  local count
  count=$(find "$ALS_DIR" -mindepth 1 -maxdepth 1 | wc -l)
  if (( count == 0 )); then
    notify "Move → Ableton → Bitwig" "als folder is already empty" normal "$ICON_EMPTY"
    return 0
  fi
  ui_confirm "Delete all $count item(s) in « $ALS_DIR »? This can't be undone." || { ok "cleanup canceled"; return 0; }
  rm -rf -- "${ALS_DIR:?}"/* "${ALS_DIR:?}"/.[!.]* 2>/dev/null || true
  notify "Move → Ableton → Bitwig" "als folder cleared ($count item(s) removed)" normal "$ICON_DONE"
  ok "als folder cleared: $ALS_DIR"
}

change_working_directory() {
  # Opens a native folder picker (zenity's directory chooser — the same
  # GTK file-browser family as Nautilus, and the only folder-picker widget
  # this module has available; there's no dedicated Omarchy overlay
  # equivalent) to pick a new PARENT folder. The working directory itself
  # keeps its current name (e.g. "Ableton Move Projects") and is
  # created/moved inside that parent — the selected folder is never
  # replaced by the working directory itself, only ever its container.
  command -v zenity >/dev/null 2>&1 || { err "zenity not available — can't open a folder picker"; return 1; }
  local new_parent
  new_parent=$(zenity --file-selection --directory \
    --title="Choose the parent folder for the working directory" 2>/dev/null) || { ok "canceled"; return 0; }
  [[ -n $new_parent ]] || { ok "canceled"; return 0; }
  new_parent="$(expand_path "$new_parent")"

  local base_name
  base_name="$(basename "$MOVE_DIR")"
  local new_dir="$new_parent/$base_name"

  if [[ $new_dir == "$MOVE_DIR" ]]; then
    ok "already there — nothing to do"
    return 0
  fi

  if [[ -d $new_dir ]]; then
    if [[ -d $MOVE_DIR ]]; then
      ui_confirm "« $new_dir » already exists. Merge the current working directory into it?" || { ok "canceled"; return 0; }
      if command -v rsync >/dev/null 2>&1; then
        rsync -a --remove-source-files "$MOVE_DIR"/ "$new_dir"/ 2>/dev/null || true
        find "$MOVE_DIR" -depth -type d -empty -delete 2>/dev/null || true
      else
        cp -an -- "$MOVE_DIR"/. "$new_dir"/ 2>/dev/null || true
        rm -rf -- "$MOVE_DIR"
      fi
      ok "merged into $new_dir"
    fi
  elif [[ -d $MOVE_DIR ]]; then
    mkdir -p -- "$new_parent"
    mv -- "$MOVE_DIR" "$new_dir" || { err "move failed"; return 1; }
    ok "working directory moved to $new_dir"
  else
    mkdir -p -- "$new_dir"
  fi

  MOVE_PROJECTS_DIR="$new_dir"
  save_prefs
  resolve_projects_dir
  ensure_folders
  ok "working directory is now: $MOVE_DIR"
}

menu_settings() {
  local opt rc hc_label ya_label av_label wd_label fp_label
  while true; do
    rc=0
    hc_label="Hide sets converted to Bitwig: $([[ $HIDE_BWPROJECT_CONVERTED == true ]] && echo On || echo Off)"
    ya_label="Open the converted .als directly with Bitwig using ydotool: $([[ ${OPEN_ALS_WITH_YDOTOOL:-true} == true ]] && echo On || echo Off)"
    av_label="Select Ableton version for conversion"
    [[ -n ${LEARNED_ABLETON_EXE:-} && -f ${LEARNED_ABLETON_EXE:-} ]] && av_label+=": $(ableton_exe_label "$LEARNED_ABLETON_EXE")"
    wd_label="Change working directory location: $MOVE_DIR"
    fp_label="File picker: $([[ $(current_file_picker) == superfile ]] && echo "Superfile" || echo "Default")"

    opt=$(ui_select --plain "Settings" \
      "$hc_label"$'\thide_converted' \
      "$ya_label"$'\topen_als_ydotool' \
      "$av_label"$'\tableton_version' \
      "$wd_label"$'\tworking_dir' \
      "$fp_label"$'\tswitch_file_picker' \
      $'Clear the als working folder\tclear_als' \
      $'Back\tback') || rc=$?
    (( rc == 2 )) && return 0
    if [[ -z $opt ]]; then
      is_tty && continue
      return 0
    fi
    case "$opt" in
      hide_converted)
        [[ $HIDE_BWPROJECT_CONVERTED == true ]] && HIDE_BWPROJECT_CONVERTED=false || HIDE_BWPROJECT_CONVERTED=true
        save_prefs
        ;;
      open_als_ydotool)
        [[ ${OPEN_ALS_WITH_YDOTOOL:-true} == true ]] && OPEN_ALS_WITH_YDOTOOL=false || OPEN_ALS_WITH_YDOTOOL=true
        save_prefs
        ;;
      ableton_version) select_ableton_version || true ;;
      working_dir) change_working_directory ;;
      switch_file_picker) switch_file_picker ;;
      clear_als) clear_als_folder ;;
      back) return 0 ;;
      *) return 0 ;;
    esac
  done
}

refresh_connected() {
  # Sets the caller's `connected` variable (relies on dynamic scoping —
  # only ever called from within main_menu, which declares it `local`).
  # Called on every menu redraw (main_menu's loop) as well as after actions
  # that could plausibly change it — detect_move() checks USB first, which
  # is cheap and local (no network round-trip), so the common case (Move
  # actually plugged in, or genuinely absent) stays fast; only a
  # disconnected-but-still-configured address falls through to the bounded
  # 1.5s ping. Worth it: a stale dot after unplugging while the menu just
  # sits there open was a real, reported bug.
  if $DEMO; then connected=true; else detect_move && connected=true || connected=false; fi
}

main_menu() {
  # Connection status is checked exactly once per redraw, right before the
  # prompt is shown — never continuously while it's sitting open (native
  # overlays here are one-shot blocking calls with no live-update channel;
  # see the module README's "not achievable" note). Only this top-level
  # menu checks it at all: submenus (Settings, Convert, address) don't need
  # a Move connection to do their own job, so they never call
  # refresh_connected — same reasoning "Refresh connection status" below
  # exists as its own explicit action rather than something automatic.
  local opt rc connected dot manager_label
  while true; do
    rc=0
    refresh_connected
    dot="🔴"; $connected && dot="🟢"
    manager_label="Open the Move Manager & convert"

    opt=$(ui_select --plain --timeout "$MAIN_MENU_IDLE_TIMEOUT" "mosquito Move Manager — $(move_host) $dot" \
      $'Refresh connection status\trefresh' \
      $'Set the Move address\taddress' \
      "$manager_label"$'\tmanager' \
      $'Convert a Move set\tconvert' \
      $'Settings\tsettings' \
      $'Close\tquit' ) || rc=$?
    # rc 2 = stdin reached EOF (launcher closed it): leave quietly.
    if (( rc == 2 )); then ok "bye (input closed)"; return 0; fi
    # rc 3 = nobody answered within MAIN_MENU_IDLE_TIMEOUT — an abandoned
    # session shouldn't sit in the background indefinitely (see the
    # zombie-process cleanup this same round). Exits silently, no
    # confirmation: if no one is there to have cancelled on purpose,
    # no one is there to answer "quit?" either.
    if (( rc == 3 )); then info "main menu idle for ${MAIN_MENU_IDLE_TIMEOUT}s — exiting"; ok "bye (idle timeout)"; return 0; fi
    if [[ -z $opt ]]; then
      # Cancel (tty: invalid key · native overlay: Escape/dismissed). This
      # is the top level — cancelling here means leaving the script
      # entirely, not going back to a previous page — so it gets the same
      # confirmation as the explicit "Close" option, never a silent exit.
      if is_tty; then
        continue
      fi
      if ui_confirm "Quit mosquito Move Manager?"; then
        ok "bye"
        return 0
      fi
      continue
    fi
    case "$opt" in
      # No explicit refresh_connected in the other branches below — every
      # loop iteration already calls it at the top before redrawing.
      address) menu_address || true ;;
      manager)
        if $connected; then
          open_manager_and_convert || true
        else
          warn "Move not connected — change address or plug in USB."
          notify "Move" "Not connected — change address or plug in USB" normal "$ICON_BLOCKED" --persist
        fi ;;
      convert) convert_flow || true ;;
      refresh) ok "connection status refreshed: $([[ $connected == true ]] && echo connected || echo not connected) — will show on the next redraw" ;;
      settings) menu_settings || true ;;
      quit)
        ui_confirm "Close the menu?" || { ok "kept open"; continue; }
        ok "bye"
        return 0 ;;
      *) ok "bye (unexpected)"; return 0 ;;
    esac
    # Once Bitwig is open (either path above — direct "Convert" or via the
    # Move Manager — funnels through convert_flow/open_ableton_route),
    # don't loop back and redraw the menu on top of it: the user just
    # closing Bitwig quickly used to bring the menu back on its own after
    # a while, reported directly as unwanted.
    if $BITWIG_OPENED; then
      ok "Bitwig is open — leaving it to you, not reopening the menu"
      return 0
    fi
  done
}

enforce_single_instance() {
  # A fresh interactive launch always wins over any other running copy —
  # there's one interface now, the TUI — kills it, without touching Ableton
  # or Bitwig at all. Found 4 such zombies piled up from repeated launches
  # (one 19+ hours old, nested 3 levels deep, holding a badly stale prompt)
  # in an earlier round; this stops that from accumulating again.
  #
  # Matching is deliberately strict: $TUI_BIN must appear as its OWN, EXACT
  # argv field in /proc/<pid>/cmdline — not merely as a substring anywhere
  # in the command line. A plain `pgrep -f` + substring
  # check on `ps -o args=` (tried first, for the single-flavor case) once
  # matched — and killed — an unrelated process whose command line just
  # happened to *mention* the path as text inside a larger argument (e.g.
  # a `bash -c "...text containing the path..."` wrapper), which is
  # exactly the same self-matching pitfall this project has hit several
  # times for other patterns, just recurring with worse consequences (it
  # can take down something unrelated, not just misreport a process as
  # running). A real invocation of the TUI always has its own path as a
  # whole, standalone argv field (either argv[0] when run via its shebang,
  # or argv[1] after `bash <path>`); confirmed live
  # against both shapes before shipping this (for the single-flavor
  # version this generalizes from).
  local p comm field match
  while IFS= read -r p; do
    [[ -n $p && $p != "$$" ]] || continue
    comm=$(ps -p "$p" -o comm= 2>/dev/null)
    [[ $comm == bash ]] || continue
    [[ -r /proc/$p/cmdline ]] || continue
    match=false
    while IFS= read -r -d '' field; do
      if [[ $field == "$TUI_BIN" ]]; then match=true; break; fi
    done < "/proc/$p/cmdline"
    $match || continue
    kill "$p" 2>/dev/null && info "stopped a previous TUI instance (pid $p)"
  done < <(pgrep -f -- 'mosquito-move-manager-tui' 2>/dev/null)
}

# ───────────────────────────── Entry point ───────────────────────────────────
main() {
  local OPT_ADDRESS="" OPT_ROUTE=""

  while (($#)); do
    case "$1" in
      --help|-h)     usage; exit 0 ;;
      --version)     echo "mosquito-move-manager v0.4.0"; exit 0 ;;
      --demo)        DEMO=true ;;
      --skip-manager) SKIP_MANAGER=true ;;
      --no-bitwig)   DO_BITWIG=false ;;
      --midi)        DO_MIDI=true ;;
      --pick-file)   FORCE_PICK=true ;;
      --address)     OPT_ADDRESS="${2:-}"; shift ;;
      status)        load_prefs; resolve_projects_dir; print_status; exit 0 ;;
      *)             err "Unknown option: $1"; usage >&2; exit 1 ;;
    esac
    shift
  done

  if $DEMO && [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    warn "demo mode — no real changes"
  fi

  load_prefs
  migrate_projects_dir_name
  ensure_projects_dir
  ensure_folders

  if $DEMO; then
    msg "demo: simulating the menu flow — 'Open Move Manager' then 'Convert'"
    open_manager_and_convert
    convert_flow
    msg "demo session finished"
    return 0
  fi

  if [[ -n $OPT_ADDRESS && $OPT_ADDRESS != "${MOVE_ADDRESS:-}" ]]; then
    phase_address
  fi

  if $DO_MIDI || [[ $DO_BITWIG == false ]] || $FORCE_PICK; then
    # A conversion-oriented flag was given: go straight to the convert step
    # (--midi, --no-bitwig and --pick-file only make sense there).
    convert_flow || true
    return 0
  fi

  # Only for the interactive main menu — quick flag-driven actions above
  # (status, --midi, --no-bitwig, --pick-file) are one-off and shouldn't
  # kill a main menu the user might have open elsewhere.
  enforce_single_instance

  # ui_ready_or_die is the interactive-primitive gate (is_tty, or the
  # Omarchy overlay, or zenity) — guaranteed by the dispatcher's flag
  # routing; exits with an error itself if nothing's usable.
  ui_ready_or_die
  main_menu
}

# mosquito-move-manager-actions (the Go TUI's non-interactive backend)
# sources this file for its functions only, without wanting the
# interactive `main` entry point to run at source time — set before
# sourcing to skip it. Unset (the normal case: the dispatcher's flag path
# and any direct invocation), `main "$@"` runs, exactly as before.
[[ -n ${MOSQUITO_MOVE_MANAGER_LIB_ONLY:-} ]] || main "$@"