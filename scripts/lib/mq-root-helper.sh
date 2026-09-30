#!/bin/bash
# mq-root-helper — privileged executor for mosquitOmarchy.
#
# Started ONCE (by pkexec, so the user sees the native Omarchy polkit prompt),
# it then executes every root command of a run through a pair of FIFOs — so the
# whole install/update/uninstall keeps a single, clean pkexec prompt instead of
# one per step. Behaviour is unchanged: these are the exact same commands
# mq_sudo would have run as root.
#
# Protocol (dir = $XDG_RUNTIME_DIR/mq-root):
#   <dir>/req   NUL-separated argv, terminated by an empty field
#   <dir>/resp  the command's stdout+stderr, then "#__MQ_RC__# <code>"
#   <dir>/ready created once the FIFOs are open
#   <dir>/owner the PID that started the helper; the helper exits when it dies
set -u

dir="${1:?mq-root-helper: missing runtime dir}"
owner="$(cat "$dir/owner" 2>/dev/null || echo 0)"

# O_RDWR on both FIFOs: never blocks on open and never sees a spurious EOF.
exec 3<>"$dir/req" 4<>"$dir/resp"
: > "$dir/ready"

while :; do
  args=()
  # Read one argv list; -t is an inactivity timeout (restart the loop after it).
  while IFS= read -r -d '' -t 300 a <&3; do
    [[ -z $a ]] && break
    args+=("$a")
  done
  if ((${#args[@]})); then
    "${args[@]}" >&4 2>&4
    printf '\n#__MQ_RC__# %d\n' "$?" >&4
  fi
  # Exit once the process that started us is gone.
  [[ $owner =~ ^[0-9]+$ ]] && (( owner > 0 )) && ! kill -0 "$owner" 2>/dev/null && break
done
