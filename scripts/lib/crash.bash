# lib/crash.bash — mosquitOmarchy crash reporting (Omarchy-compatible).
#
# When a NON-install mosquitOmarchy script fails, it stores ONE dated log for
# that run in the repo-local log folder (never committed, never archived) and
# raises a clickable Omarchy notification. Clicking the toast opens the default
# coding agent on the mosquitomarchy-crash skill, pointed at that exact log: the
# agent diagnoses the failure and PROPOSES fixes without applying anything, then
# waits for the user to confirm.
#
# Install scripts (setup-*.sh) are deliberately EXEMPT: they run inside the
# installer's own presentation and have a human watching the output.
#
# Usage:
#   source "$(dirname "$0")/../lib/crash.bash"
#   mq_crash_guard "<tool>"          # install an ERR trap that reports on failure
#   mq_crash "<tool>" <file|->       # report explicitly (log body on stdin if "-")
#
# Env:
#   MOSQUITOMARCHY_LOG_DIR   override the log folder (default below)
#   MOSQUITOMARCHY_NO_CRASH=1  disable reporting entirely
#   MOSQUITOMARCHY_CRASH_ACTIVE  internal re-entrancy guard

[[ -n ${MOSQUITOMARCHY_CRASH_LIB_SOURCED:-} ]] && return 0
MOSQUITOMARCHY_CRASH_LIB_SOURCED=1

_MQ_CRASH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_MQ_REPO_DIR="$(cd "$_MQ_CRASH_LIB_DIR/../.." && pwd)"
MQ_LOG_DIR="${MOSQUITOMARCHY_LOG_DIR:-$_MQ_REPO_DIR/.local/crash-logs}"
MQ_AGENT_CRASH="$_MQ_REPO_DIR/scripts/apps/mosquitomarchy/mosquitomarchy-agent-crash"

# nf-md-robot_dead, escaped so this file reads without a Nerd Font.
MQ_CRASH_GLYPH=$'\U000f16a1'

# mq_crash_dir — print (and create) the dedicated log folder.
mq_crash_dir(){
  mkdir -p "$MQ_LOG_DIR" 2>/dev/null || true
  printf '%s\n' "$MQ_LOG_DIR"
}

# mq_crash_log <tool> [file|-] — write one dated log, print its path.
mq_crash_log(){
  local tool="${1:-mosquitomarchy}" src="${2:--}" stamp path
  stamp="$(date +%Y-%m-%d-%H%M%S)"
  path="$(mq_crash_dir)/${stamp}-${tool}.log"
  {
    printf '# mosquitOmarchy crash log\n'
    printf '# tool: %s\n' "$tool"
    printf '# date: %s\n' "$(date -Is)"
    printf '# host: %s\n' "$(hostname 2>/dev/null || echo '?')"
    printf '# user: %s\n' "${USER:-?}"
    printf '# cmd:  %s\n' "${MOSQUITOMARCHY_CMD:-$0}"
    printf '\n'
    if [[ $src == - ]]; then cat; else cat -- "$src" 2>/dev/null; fi
  } >"$path" 2>/dev/null || return 1
  printf '%s\n' "$path"
}

# mq_crash_notify <tool> <logfile> — clickable Omarchy toast → the AI.
mq_crash_notify(){
  local tool="$1" log="$2"
  command -v omarchy-notification-send >/dev/null 2>&1 || return 0
  omarchy-notification-send --urgency critical --glyph "$MQ_CRASH_GLYPH" \
    "mosquitOmarchy: $tool failed" \
    "Click to diagnose with AI" \
    --exec "$MQ_AGENT_CRASH" "$log" "$tool" >/dev/null 2>&1 || true
}

# mq_crash <tool> [file|-] — log a failure and offer the AI diagnosis.
mq_crash(){
  [[ -n ${MOSQUITOMARCHY_NO_CRASH:-} || -n ${MOSQUITOMARCHY_CRASH_ACTIVE:-} ]] && return 0
  MOSQUITOMARCHY_CRASH_ACTIVE=1
  local tool="${1:-mosquitomarchy}" src="${2:--}" log
  log="$(mq_crash_log "$tool" "$src" || true)"
  [[ -n $log ]] || return 0
  mq_crash_notify "$tool" "$log"
  printf 'mosquitOmarchy: crash log → %s\n' "$log" >&2
}

# mq_crash_guard [tool] — report any failing command (set -e or explicit ERR).
mq_crash_guard(){
  MQ_CRASH_TOOL="${1:-$(basename "${0:-mosquitomarchy}")}"
  trap 'mq_crash_trap "$?" "$BASH_COMMAND" "${BASH_LINENO[0]:-?}"' ERR
}

mq_crash_trap(){
  local rc="$1" cmd="$2" line="$3"
  ((rc == 0)) && return 0
  {
    printf 'exit status: %s\n' "$rc"
    printf 'failed command: %s\n' "$cmd"
    printf 'at line: %s\n' "$line"
  } | mq_crash "$MQ_CRASH_TOOL" - || true
}
