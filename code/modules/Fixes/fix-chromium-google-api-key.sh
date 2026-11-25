#!/usr/bin/env bash
# =============================================================================
# mosquitOmarchy — Chromium "Google API keys are missing" infobar
# =============================================================================
# Omarchy's Chromium is an unbranded build: no Google API keys are compiled in,
# so at every launch it shows a permanent infobar — "Google API keys are
# missing. Some functionality of Chromium will be disabled." — in the browser
# AND in every --app webapp (WhatsApp, Move Manager, OscMix...). It is harmless:
# only Google-integrated features are disabled.
#
# Unbranded Chromium accepts API keys from the environment. A dummy
# GOOGLE_API_KEY makes HasAPIKeyConfigured() true, so the infobar is never
# created. No real Google service is enabled (the key is not a valid one).
#
# What this script does (idempotent):
#   1. Writes ~/.config/environment.d/90-chromium-google-api-key.conf with
#      GOOGLE_API_KEY=no, marked so --remove can find exactly this file.
#   2. LOGOUT / LOGIN (or reboot) is required for the session and its GUI apps
#      to inherit the variable. Until then, export it in a shell to test.
#
# Usage:
#   ./fix-chromium-google-api-key.sh            # apply (idempotent)
#   ./fix-chromium-google-api-key.sh --status   # report
#   ./fix-chromium-google-api-key.sh --remove   # undo
# =============================================================================
set -euo pipefail

ENV_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/environment.d"
FILE="$ENV_DIR/90-chromium-google-api-key.conf"
MARK="mosquitomarchy-chromium-google-api-key"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m !\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m ✗\033[0m %s\n' "$*" >&2; }

status(){
  info "Chromium Google API key fix — status"
  printf '    file  : %s\n' "$FILE"
  if [[ -f $FILE ]] && grep -qFx 'GOOGLE_API_KEY=no' "$FILE"; then
    printf '    state : applied\n'
  else
    printf '    state : absent\n'
  fi
  printf '    note  : logout/login needed for GUI apps to inherit the variable\n'
}

apply(){
  mkdir -p "$ENV_DIR"
  if [[ -f $FILE ]] && grep -qF "$MARK" "$FILE" && grep -qFx 'GOOGLE_API_KEY=no' "$FILE"; then
    ok "Already applied — dummy API key is set in $(basename "$FILE")."
    return 0
  fi
  # We own this file: rewrite it so a stale/partial version cannot linger.
  cat > "$FILE" <<EOF
# $MARK
# Unbranded Chromium shows "Google API keys are missing" in every window when
# no key is configured; any value other than its "dummytoken" sentinel counts
# as configured. This is a dummy value — no Google service is activated.
GOOGLE_API_KEY=no
EOF
  ok "Dummy API key written to $FILE."
  warn "Log out and back in (or reboot) for Chromium and its webapps to pick it up."
}

remove(){
  if [[ ! -f $FILE ]]; then
    ok "Nothing to remove — $FILE does not exist."
    return 0
  fi
  if ! grep -qF "$MARK" "$FILE"; then
    warn "$FILE exists but is not ours — left untouched."
    return 0
  fi
  rm -f "$FILE"
  ok "Removed $FILE — the infobar returns after the next login."
}

case "${1:-apply}" in
  apply|--apply|-y)           apply ;;
  --status|status)            status ;;
  --remove|--uninstall|remove) remove ;;
  -h|--help)                  sed -n '2,/^set -euo pipefail/p' "$0" | sed 's/^# \{0,1\}//; /^set -euo pipefail/d' ;;
  *) err "Unknown option: $1 (apply --status --remove)"; exit 1 ;;
esac
