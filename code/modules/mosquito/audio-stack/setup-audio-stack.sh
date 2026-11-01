#!/usr/bin/env bash
# =============================================================================
# mosquitOmarchy - mosquito audio stack (install / status / uninstall)
# =============================================================================
# One entry point for the whole audio-stack folder:
#   apm            wine/yabridge + the Audio Plugin Manager
#   mixbay         USB audio bay (core TUI)
#   levels-guard   native audio panel + media-key guard
#   live-mode      performance session mode
#   pipewire       PipeWire sample-rate/buffer panel
#
# Installing this folder means installing all five. Use --skip=... to leave
# components out; each child folder remains installable on its own.
#
# Usage:
#   ./setup-audio-stack.sh
#   ./setup-audio-stack.sh -y
#   ./setup-audio-stack.sh --skip=live-mode,pipewire
#   ./setup-audio-stack.sh --status
#   ./setup-audio-stack.sh --uninstall
#   ./setup-audio-stack.sh --tweaks | --vst-sync | --vst-status | --wine-menu
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YES=0 STATUS_ONLY=0 UNINSTALL=0 SKIP=""
DELEGATE=""
for a in "$@"; do case "$a" in
  -y|--yes) YES=1 ;;
  --status) STATUS_ONLY=1 ;;
  --uninstall|--remove) UNINSTALL=1 ;;
  --skip=*) SKIP="${a#*=}" ;;
  --tweaks|--vst-sync|--vst-status|--wine-menu|--dry-run) DELEGATE="$a" ;;
  -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
  *) echo "Unknown option: $a" >&2; exit 1 ;;
esac; done

info(){ echo -e "\033[1;34m==>\033[0m $*"; }
ok(){ echo -e "\033[1;32m ✓\033[0m $*"; }
warn(){ echo -e "\033[1;33m !\033[0m $*"; }

if [[ -n $DELEGATE ]]; then
  exec bash "$SCRIPT_DIR/apm/setup-yabridge.sh" "$DELEGATE" $([[ $YES == 1 ]] && echo -y)
fi

skipped(){
  local want="$1" s
  IFS=',' read -r -a _skip <<<"$SKIP"
  for s in "${_skip[@]:-}"; do
    [[ -n $s && $s == "$want" ]] && return 0
  done
  return 1
}

apm_status(){
  local tui="$HOME/.local/bin/mosquito-audio-plugin-manager-tui"
  local disp="$HOME/.local/bin/mosquito-audio-plugin-manager"
  if [[ -x $tui || -x $disp ]]; then
    systemctl --user list-unit-files yabridge-autosync.path >/dev/null 2>&1 \
      && echo ok || echo partial
  else
    systemctl --user list-unit-files yabridge-autosync.path 2>/dev/null | grep -q yabridge-autosync \
      && echo partial || echo missing
  fi
}

pipewire_status(){
  [[ -x "$HOME/.local/bin/mosquitomarchy-pipewire-settings" ]] \
    && [[ -d "$HOME/.config/omarchy/plugins/mosquito.pipewire" ]] \
    && echo ok || echo missing
}

live_mode_status(){
  [[ -x "$HOME/.local/bin/live-mode" && -x "$HOME/.local/bin/live-mode-watch" \
     && -x "$HOME/.local/bin/live-mode-root" && -x "$HOME/.local/bin/mosquito-live-mode-tui" ]] \
    || { echo missing; return; }
  local miss=""
  [[ -f "$HOME/.local/state/mosquitomarchy/live-mode-sudoers" ]] || miss="${miss:+$miss, }sudoers"
  [[ -d "$HOME/.config/omarchy/plugins/mosquito.livemode" ]] || miss="${miss:+$miss, }plugin"
  [[ -n $miss ]] && echo "partial:missing ${miss# }" || echo ok
}

if ((STATUS_ONLY)); then
  printf 'apm          %s\n' "$(apm_status)"
  printf 'mixbay       %s\n' "$(bash "$SCRIPT_DIR/mixbay/setup-mosquitomixbay.sh" --status)"
  printf 'levels-guard %s\n' "$(bash "$SCRIPT_DIR/levels-guard/setup-levels-guard.sh" --status)"
  printf 'live-mode    %s\n' "$(live_mode_status)"
  printf 'pipewire     %s\n' "$(pipewire_status)"
  exit 0
fi

if ((UNINSTALL)); then
  info "Uninstalling the mosquito audio stack"
  bash "$SCRIPT_DIR/levels-guard/setup-levels-guard.sh" --uninstall || warn "levels-guard uninstall reported a problem"
  bash "$SCRIPT_DIR/mixbay/setup-mosquitomixbay.sh" --uninstall || warn "mixbay uninstall reported a problem"
  bash "$SCRIPT_DIR/live-mode/setup-live-mode.sh" --uninstall || warn "live-mode uninstall reported a problem"
  bash "$SCRIPT_DIR/pipewire/setup-pipewire-settings.sh" --remove || warn "pipewire remove reported a problem"
  bash "$SCRIPT_DIR/apm/setup-audio-plugin-manager.sh" --uninstall || warn "APM uninstall reported a problem"
  ok "Audio stack removed (VST data and Mixbay state kept)"
  exit 0
fi

fail=0
run(){
  local label="$1"; shift
  info "$label"
  if "$@"; then ok "$label done"; else warn "$label failed"; fail=1; fi
}

if skipped apm; then warn "skip apm"; else
  run "APM — wine/yabridge" bash "$SCRIPT_DIR/apm/setup-yabridge.sh" $([[ $YES == 1 ]] && echo -y)
  run "APM — Audio Plugin Manager" bash "$SCRIPT_DIR/apm/setup-audio-plugin-manager.sh" $([[ $YES == 1 ]] && echo -y)
fi
if skipped mixbay; then warn "skip mixbay"; else
  run "Mixbay" bash "$SCRIPT_DIR/mixbay/setup-mosquitomixbay.sh" $([[ $YES == 1 ]] && echo -y)
fi
if skipped levels-guard; then warn "skip levels-guard"; else
  run "Levels Guard" bash "$SCRIPT_DIR/levels-guard/setup-levels-guard.sh" $([[ $YES == 1 ]] && echo -y)
fi
if skipped live-mode; then warn "skip live-mode"; else
  run "live mode" bash "$SCRIPT_DIR/live-mode/setup-live-mode.sh" $([[ $YES == 1 ]] && echo -y)
fi
if skipped pipewire; then warn "skip pipewire"; else
  run "PipeWire settings" bash "$SCRIPT_DIR/pipewire/setup-pipewire-settings.sh" $([[ $YES == 1 ]] && echo -y)
fi

((fail)) && exit 1
ok "Audio stack installed"
