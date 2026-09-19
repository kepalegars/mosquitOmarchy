#!/usr/bin/env bash
# lib/elevate.bash — shared privilege-elevation helper (mq_sudo).
#
# Goal: when a mosquitOmarchy script needs root but is NOT already running as
# root, prefer the native Omarchy polkit agent prompt (pkexec) over a terminal
# sudo password prompt. `mq_sudo CMD [ARGS...]` behaves exactly like
# `sudo CMD [ARGS...]`; it only changes *how* the password is asked for:
#   1. EUID == 0                      -> run "$@" directly.
#   2. `sudo -n true` succeeds        -> sudo "$@"   (passwordless / cached).
#   3. pkexec + a usable polkit agent -> pkexec "$@" (native GUI prompt).
#   4. otherwise                      -> sudo "$@"   (terminal prompt).
#
# pkexec prompts once per invocation (polkit does not cache credentials the
# way sudo does), so callers that need several root steps should batch them
# into a single elevated `mq_sudo bash -c '...'` where practical.
#
# This file is functions-only and safe to source repeatedly.
[[ -n ${MQ_ELEVATE_SOURCED:-} ]] && return 0
MQ_ELEVATE_SOURCED=1

# True only when pkexec could actually reach an authentication agent: a
# session bus and a graphical session must both be present, otherwise pkexec
# fails with "No authentication agent found" instead of showing a prompt.
mq_polkit_agent_usable() {
  command -v pkexec >/dev/null 2>&1 || return 1
  [[ -n ${DBUS_SESSION_BUS_ADDRESS:-} ]] || return 1
  [[ -n ${WAYLAND_DISPLAY:-} || -n ${DISPLAY:-} ]] || return 1
  return 0
}

# mq_sudo_noninteractive CMD [ARGS...] — never prompt: root runs directly,
# everyone else gets `sudo -n` (for NOPASSWD / already-cached credentials).
mq_sudo_noninteractive() {
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    "$@"
  else
    sudo -n "$@"
  fi
}

# mq_sudo CMD [ARGS...] — run a command as root (see the header above).
# Also accepts the two sudo-compatible forms used in this repo:
#   mq_sudo -v      check that elevation is possible (no command run)
#   mq_sudo -n CMD  non-interactive (same as mq_sudo_noninteractive CMD)
mq_sudo() {
  case ${1:-} in
    -v)
      [[ ${EUID:-$(id -u)} -eq 0 ]] && return 0
      sudo -n true 2>/dev/null && return 0
      mq_polkit_agent_usable && return 0
      sudo -v
      return $?
      ;;
    -n)
      shift
      mq_sudo_noninteractive "$@"
      return $?
      ;;
  esac
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    "$@"
  elif sudo -n true 2>/dev/null; then
    sudo "$@"
  elif mq_polkit_agent_usable; then
    pkexec "$@"
  else
    sudo "$@"
  fi
}
