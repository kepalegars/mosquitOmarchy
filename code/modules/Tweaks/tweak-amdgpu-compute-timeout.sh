#!/usr/bin/env bash
# =============================================================================
# mosquitOmarchy - AMDGPU: 90 s watchdog for heavy compute
# =============================================================================
# CAUSE
#   amdgpu ships a 2000 ms watchdog per ring on this kernel. On an integrated
#   GPU one heavy Vulkan/OpenCL compute submission can legitimately run longer
#   than that (SpektraFilm's spectral upsampling in DaVinci Resolve is what
#   exposed it here). The kernel then logs
#     amdgpu: ring comp_1.x.x timeout
#   resets the compute queue, and the application gets VK_ERROR_DEVICE_LOST
#   even though the GPU and the shader are fine.
#
# WHAT THIS DOES
#   Adds one marked KERNEL_CMDLINE line to Omarchy's Limine config:
#     amdgpu.lockup_timeout=2000,90000,2000,2000
#   The four values are GFX, Compute, SDMA, Video. Only the compute watchdog is
#   raised (2 s -> 90 s); graphics, DMA and video keep 2 s.
#   It then runs limine-update so the next boot entry carries the parameter.
#
# SCOPE AND RISK
#   This is GPU-WIDE, not per-application and not SpektraFilm-only: every
#   process that submits work to this AMD GPU's compute rings gets the longer
#   watchdog. If a compute job really hangs, the desktop or that application
#   can stay frozen for up to 90 s before the kernel resets the queue instead
#   of about 2 s. It does not make a broken shader or driver complete; it only
#   stops a slow-but-valid job from being killed early. It is a workaround for
#   a watchdog that is too short, not a fix for a GPU hang.
#
# WHEN IT APPLIES
#   Only on a FULL REBOOT. amdgpu is loaded from the initramfs at boot and the
#   parameter is read-only at runtime, so logging out, restarting the graphical
#   session or `systemctl soft-reboot` does not reload it. Removing the
#   parameter also needs a reboot.
#   Check after the reboot:
#     cat /sys/module/amdgpu/parameters/lockup_timeout
#     # 2000,90000,2000,2000
#
# Usage:
#   ./tweak-amdgpu-compute-timeout.sh            # apply (idempotent)
#   ./tweak-amdgpu-compute-timeout.sh --status   # read-only report
#   ./tweak-amdgpu-compute-timeout.sh --remove   # remove the managed block
#   ./tweak-amdgpu-compute-timeout.sh -y         # accepted, no prompt
#   ./tweak-amdgpu-compute-timeout.sh -h
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/gui-run.bash"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/elevate.bash"
set -euo pipefail

CONF="${MQ_LIMINE_CONF:-/etc/default/limine}"    # test override
UPDATE_CMD="${MQ_LIMINE_UPDATE:-limine-update}"  # test override
BACKUP="$CONF.bak.mosquitomarchy-amdgpu"
MARK_BEGIN="# >>> mosquitOmarchy - amdgpu compute watchdog (mosquitOmarchy-amdgpu-compute-timeout)"
MARK_END="# <<< mosquitOmarchy - amdgpu compute watchdog"
PARAM="amdgpu.lockup_timeout=2000,90000,2000,2000"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf ' \033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf ' \033[1;33m!\033[0m %s\n' "$*"; }
err()  { printf ' \033[1;31m✗\033[0m %s\n' "$*" >&2; }

priv(){ mq_sudo "$@"; }

MODE=apply
case "${1:-}" in
  --status) MODE=status ;;
  --remove|--uninstall) MODE=remove ;;
  -y|--yes) : ;;
  -h|--help) sed -n '2,46p' "$0"; exit 0 ;;
  "") : ;;
  *) err "Unknown option: $1 (supported: -y --status --remove)"; exit 2 ;;
esac

# Emit the config without our marked block. `limine-mkinitcpio` sources this
# file with bash, so bash -n is the validation that matters.
render_without_block(){
  [[ -f $CONF ]] || return 0
  awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
    $0 == b { skip=1; next }
    $0 == e { skip=0; next }
    skip     { next }
    { line[++n]=$0 }
    END {
      while (n > 0 && line[n] == "") n--
      for (i=1; i<=n; i++) print line[i]
    }
  ' "$CONF"
}

block_present(){ grep -qxF -- "$MARK_BEGIN" "$CONF" 2>/dev/null; }

foreign_param(){
  render_without_block | grep -F -- "amdgpu.lockup_timeout=" | head -n 1 || true
}

running_value(){
  local v
  v="$(cat /sys/module/amdgpu/parameters/lockup_timeout 2>/dev/null || true)"
  printf '%s' "${v:-default (unset)}"
}

status(){
  local foreign val
  [[ -f $CONF ]] || { echo "missing: $CONF not found"; return 0; }
  val="$(running_value)"
  foreign="$(foreign_param)"
  if block_present; then
    if tr ' ' '\n' < /proc/cmdline | grep -qxF -- "$PARAM"; then
      echo "ok: compute watchdog 90 s is configured and active in the running kernel"
    else
      echo "pending-reboot: configured in $CONF, not active in the running kernel - reboot"
    fi
  elif [[ -n $foreign ]]; then
    echo "external: amdgpu.lockup_timeout is set outside this tweak: $foreign"
  else
    echo "missing: compute watchdog not configured"
  fi
  echo "running value: $val"
  echo "config: $CONF"
}

if [[ $MODE == status ]]; then
  status
  exit 0
fi

if [[ ! -f $CONF ]]; then
  err "$CONF not found - this tweak expects Omarchy's Limine setup."
  exit 1
fi
if ! command -v "$UPDATE_CMD" >/dev/null 2>&1; then
  err "$UPDATE_CMD not found; refusing to edit the boot config without a way to regenerate it."
  exit 1
fi

foreign="$(foreign_param)"
if [[ -n $foreign ]]; then
  err "amdgpu.lockup_timeout is already set outside this tweak:"
  printf '  %s\n' "$foreign" >&2
  err "Edit or remove that line first; this script will not fight another setting."
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
TMP="$WORK/limine.conf"
PRERUN="$WORK/previous.conf"

if [[ $MODE == remove ]]; then
  if ! block_present; then
    ok "Nothing to remove: the managed block is not in $CONF."
    exit 0
  fi
  info "Removing the managed compute-watchdog block"
else
  info "Setting the AMDGPU compute watchdog to 90 s"
fi

if [[ ! -e $BACKUP ]]; then
  priv cp -p "$CONF" "$BACKUP" || { err "Could not back up $CONF; refusing to edit it."; exit 1; }
  ok "First backup kept at $BACKUP (not restored by --remove; it may be stale)."
fi
cp -p "$CONF" "$PRERUN"

if [[ $MODE == remove ]]; then
  render_without_block > "$TMP"
else
  { render_without_block
    printf '\n%s\nKERNEL_CMDLINE[default]+=" %s"\n%s\n' "$MARK_BEGIN" "$PARAM" "$MARK_END"
  } > "$TMP"
fi

if ! bash -n "$TMP"; then
  err "Generated $CONF is not valid bash; nothing was written."
  exit 1
fi

if ! priv install -m 0644 "$TMP" "$CONF"; then
  err "Could not write $CONF."
  exit 1
fi

info "Regenerating the Limine boot entry ($UPDATE_CMD)"
if ! priv "$UPDATE_CMD"; then
  err "$UPDATE_CMD failed; restoring the previous $CONF and rebuilding it."
  priv install -m 0644 "$PRERUN" "$CONF" || warn "Could not restore $CONF from the pre-run copy."
  priv "$UPDATE_CMD" >/dev/null 2>&1 || warn "Could not rebuild the previous boot entry; run 'sudo $UPDATE_CMD' by hand."
  exit 1
fi

if [[ $MODE == remove ]]; then
  ok "Compute-watchdog block removed. Reboot to return to the kernel default (2 s)."
else
  ok "Compute watchdog 90 s configured. Reboot to apply it."
  echo "  The running kernel is still using: $(running_value)"
  echo "  Only a full reboot reloads amdgpu; a logout does not."
fi
echo "  Check after reboot: cat /sys/module/amdgpu/parameters/lockup_timeout"
