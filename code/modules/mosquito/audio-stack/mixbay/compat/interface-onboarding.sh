#!/usr/bin/env bash
# =============================================================================
# mosquito-mixbay-compat — first-connection setup prompt for an interface
# =============================================================================
# Mixbay can drive an interface over ALSA/USB, but some interfaces need a
# one-time system step before their real controls work (EVO: the evo_raw
# kernel module + the USB capture udev rule). This helper makes that step
# visible at the moment the interface is first used, instead of leaving the
# bay silently in DEMO mode:
#
#   mosquito-mixbay-compat --needs evo8     # pending? print why, exit 0
#   mosquito-mixbay-compat --prompt evo8    # gum/read prompt until accepted
#   mosquito-mixbay-compat --apply evo8     # install what is missing
#   mosquito-mixbay-compat --status evo8    # ok | offline | missing: …
#   mosquito-mixbay-compat --accept evo8    # stop asking for this interface
#
# State lives in ~/.config/mosquitomixbay/onboarding.json. "Later" is not
# recorded, so the prompt comes back on the next launch — by design.
#
# The patterns worth keeping for future interfaces (douze/SSL 12, RME, …):
#   • a udev rule must be numbered < 73 if it uses TAG+="uaccess",
#   • a Pro Audio 8-channel sink is split into stereo loopbacks with
#     libpipewire-module-loopback + target.object + node.passive,
#   • a WirePlumber rule keeps the card from suspending (passive loopbacks),
#   • the device must be present before writing a node-name-specific config.
# =============================================================================
set -euo pipefail

# Baked by setup-mosquitomixbay.sh; the fallback keeps the script runnable
# straight from the repo checkout.
ROOT_DIR="${MOSQUITOMIXBAY_ROOT:-@MIXBAY_ROOT@}"
if [[ ! -d $ROOT_DIR ]]; then
  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
STATE="${XDG_CONFIG_HOME:-$HOME/.config}/mosquitomixbay/onboarding.json"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf ' \033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf ' \033[1;33m!\033[0m %s\n' "$*" >&2; }

usage() {
  sed -n '2,28p' "$0"
}

usb_present() { # device id -> 0 when its USB vendor/product is plugged
  local dev="$1" vid pid f p
  case $dev in
    evo8) vid=2708; pid=0007 ;;
    evo4) vid=2708; pid=0006 ;;
    *) return 1 ;;
  esac
  for f in /sys/bus/usb/devices/*/idVendor; do
    [[ -r $f ]] || continue
    [[ "$(cat "$f" 2>/dev/null)" == "$vid" ]] || continue
    p="$(cat "${f%idVendor}idProduct" 2>/dev/null || true)"
    [[ $p == "$pid" ]] && return 0
  done
  return 1
}

accepted() {
  [[ -f $STATE ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  jq -e --arg dev "$1" '.[$dev].accepted == true' "$STATE" >/dev/null 2>&1
}

needs_for() { # device id -> newline-separated missing pieces (empty = none)
  local dev="$1"
  case $dev in
    evo8|evo4)
      [[ -e "/dev/$dev" ]] || printf '%s\n' "evo_raw kernel module (real hardware control instead of DEMO)"
      # The capture rule is EVO 8-specific (six capture channels, EU51).
      if [[ $dev == evo8 && ! -f /etc/udev/rules.d/99-evo8-capture.rules ]]; then
        printf '%s\n' "EVO 8 USB capture udev rule (mic capture in every app, DAW included)"
      fi
      # The audio foundation owns udev seat access, WirePlumber rules, the
      # EVO 8 split and the default sink/source. Reuse its answer here so the
      # onboarding prompt and the foundation can never disagree.
      if command -v mixbay-audio-foundation >/dev/null 2>&1; then
        mixbay-audio-foundation --needs "$dev" 2>/dev/null || true
      fi
      ;;
    ssl12)
      # Not in drivers.Registry() yet: this case documents the douze pattern
      # for the day the SSL 12 control backend lands in Mixbay.
      [[ -f /etc/udev/rules.d/70-douze.rules ]] || printf '%s\n' "SSL 12 control udev rule (31e9:0024, TAG+=uaccess before 73)"
      [[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/pipewire/pipewire.conf.d/99-ssl12-sinks.conf" ]] \
        || printf '%s\n' "PipeWire playback-pair split (ssl12.pb12 … pb78)"
      ;;
    *) return 1 ;;
  esac
}

apply() {
  local dev="$1"
  # The full installer is idempotent and already owns the kmod + udev steps.
  # Reusing it keeps ONE source of truth for what "installed" means.
  if [[ -x "$ROOT_DIR/setup-mosquitomixbay.sh" ]]; then
    info "Running the Mixbay installer for $dev (one-time system steps)"
    bash "$ROOT_DIR/setup-mosquitomixbay.sh" -y
  else
    warn "setup-mosquitomixbay.sh not found under $ROOT_DIR — cannot apply."
    return 1
  fi
  # Re-check: a failed kmod install must not be recorded as accepted.
  local missing
  missing="$(needs_for "$dev")"
  if [[ -n $missing ]]; then
    warn "Still missing:"
    printf '%s\n' "$missing" | sed 's/^/    - /' >&2
    return 1
  fi
}

record() {
  local dev="$1"
  mkdir -p "$(dirname "$STATE")"
  if command -v jq >/dev/null 2>&1; then
    local tmp; tmp="$(mktemp)"
    if [[ -f $STATE ]]; then
      jq --arg dev "$dev" '.[$dev] = {accepted: true, version: 1}' "$STATE" > "$tmp"
    else
      jq -n --arg dev "$dev" '{($dev): {accepted: true, version: 1}}' > "$tmp"
    fi
    mv "$tmp" "$STATE"
  else
    printf '{"%s":{"accepted":true,"version":1}}\n' "$dev" > "$STATE"
  fi
}

MODE="" DEV=""
while (($#)); do
  case "$1" in
    --needs|--status|--prompt|--apply|--accept) MODE="${1#--}"; shift ;;
    -h|--help) usage; exit 0 ;;
    evo4|evo8|ssl12) DEV="$1"; shift ;;
    *) warn "Unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done
[[ -n $MODE && -n $DEV ]] || { usage >&2; exit 2; }

if ! usb_present "$DEV"; then
  [[ $MODE == status ]] && echo offline
  exit 1
fi

missing="$(needs_for "$DEV" || true)"
if accepted "$DEV"; then
  [[ $MODE == status ]] && echo ok
  exit 1
fi

case $MODE in
  needs)
    [[ -n $missing ]] || exit 1
    printf '%s\n' "$missing"
    ;;
  status)
    if [[ -n $missing ]]; then printf 'missing: %s\n' "$(tr '\n' ';' <<< "$missing")"; else echo ok; fi
    ;;
  apply)
    [[ -n $missing ]] || { ok "Nothing to install for $DEV"; exit 0; }
    apply "$DEV" && { record "$DEV"; ok "$DEV setup recorded"; }
    ;;
  prompt)
    [[ -n $missing ]] || exit 1
    info "$DEV is connected and needs a one-time setup:"
    printf '%s\n' "$missing" | sed 's/^/    - /'
    echo "    The prompt comes back on every launch until this is accepted."
    answer=0
    if command -v gum >/dev/null 2>&1; then
      gum confirm "Set up $DEV now?" \
        --affirmative "Set up" --negative "Later" --default=true && answer=1
    else
      read -rp "Set up $DEV now? [Y/n] " r
      [[ ${r:-y} =~ ^[oOyY] ]] && answer=1
    fi
    if (( answer )); then
      apply "$DEV" && { record "$DEV"; ok "$DEV setup recorded"; exit 0; }
      exit 1
    fi
    warn "Later — $DEV stays in DEMO mode; you will be asked again next launch."
    exit 1
    ;;
  accept)
    record "$DEV"; ok "$DEV marked as set up"
    ;;
esac
