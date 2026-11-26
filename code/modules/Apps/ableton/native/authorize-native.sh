#!/usr/bin/env bash
# authorize-native.sh — HWID -> clipboard -> R2R tool -> .auz -> native Live.
#
# The Wine patch reads Unlock.json under ~/.wine-ableton. The native build
# keeps the same file in XDG_DATA_HOME/Ableton, so this script reads THAT
# one — no prefix, no Wine DLL next to the Linux binary.
#
# Flow:
#   1. find the newest native Unlock.json and copy its challenge_code (HWID),
#   2. launch WM_Ableton.r2rwm with Wine (no WINEPREFIX is forced),
#   3. wait for you to close that tool manually,
#   4. copy the newest .auz it produced into the native install folder,
#   5. open that folder in the file manager.
#
# Usage:
#   ./authorize-native.sh            # full flow
#   ./authorize-native.sh --no-run   # HWID + clipboard only (checking)
#   ./authorize-native.sh --help
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="${R2RWM_TOOL:-$HOME/Documents/new patch/WM_Ableton.r2rwm}"
INSTALL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/ableton-live-12"
NO_RUN=0

case ${1:-} in
  "" ) ;;
  --no-run) NO_RUN=1 ;;
  -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
  *) printf 'unknown option: %s (see --help)\n' "$1" >&2; exit 2 ;;
esac

G=$'\033[1;32m'; Y=$'\033[1;33m'; R=$'\033[1;31m'; N=$'\033[0m'
msg(){ printf '==> %s\n' "$*"; }
ok(){ printf ' %s✓%s %s\n' "$G" "$N" "$*"; }
warn(){ printf ' %s!%s %s\n' "$Y" "$N" "$*"; }
err(){ printf ' %s✗%s %s\n' "$R" "$N" "$*" >&2; }

# ── HWID from the native Live install, never from a Wine prefix ─────────────
find_unlock(){
  local -a roots=()
  local root
  for root in "${XDG_DATA_HOME:-$HOME/.local/share}/Ableton" \
              "${XDG_CONFIG_HOME:-$HOME/.config}/Ableton"; do
    [[ -d $root ]] && roots+=("$root")
  done
  ((${#roots[@]})) || return 0
  find "${roots[@]}" -type f -path '*/Unlock/Unlock.json' -printf '%T@ %p\n' 2>/dev/null \
    | sort -nr | head -1 | cut -d' ' -f2-
}

read_hwid(){
  python3 - "$1" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
products = data.get("products") or []
code = products[0].get("challenge_code", "") if products else ""
sys.stdout.write(code)
PY
}

UNLOCK="$(find_unlock || true)"
if [[ -z ${UNLOCK:-} || ! -f $UNLOCK ]]; then
  err "No native Unlock.json found under ${XDG_DATA_HOME:-$HOME/.local/share}/Ableton."
  err "Launch Ableton Live 12 (Native) once, let it create its settings, then quit it and retry."
  exit 1
fi

HWID="$(read_hwid "$UNLOCK" 2>/dev/null || true)"
if [[ ! $HWID =~ ^([0-9A-Fa-f]{4}-){5}[0-9A-Fa-f]{4}$ ]]; then
  err "No usable challenge_code in $UNLOCK (got '${HWID:-empty}')."
  exit 1
fi
HWID="${HWID^^}"
ok "HWID: $HWID  (from $UNLOCK)"

CLIP=""
for c in wl-copy xclip xsel; do
  command -v "$c" >/dev/null 2>&1 && { CLIP="$c"; break; }
done
if [[ -n $CLIP ]]; then
  case $CLIP in
    wl-copy) setsid sh -c 'printf "%s" "$1" | wl-copy' _ "$HWID" </dev/null >/dev/null 2>&1 & ;;
    xclip)   setsid sh -c 'printf "%s" "$1" | xclip -selection clipboard' _ "$HWID" </dev/null >/dev/null 2>&1 & ;;
    xsel)    setsid sh -c 'printf "%s" "$1" | xsel --clipboard --input' _ "$HWID" </dev/null >/dev/null 2>&1 & ;;
  esac
  ok "HWID copied to clipboard ($CLIP)."
else
  warn "No wl-copy/xclip/xsel: copy this manually: $HWID"
fi

(( NO_RUN )) && { msg "Stopping here (--no-run)."; exit 0; }

# ── launch the Windows tool (no prefix forced) ──────────────────────────────
[[ -f $TOOL ]] || { err "Tool not found: $TOOL (override with R2RWM_TOOL=…)"; exit 1; }
WINE_BIN=""
for w in "$HOME"/.local/opt/wine-*/bin/wine; do
  [[ -x $w ]] && WINE_BIN="$w"
done
[[ -n $WINE_BIN ]] || WINE_BIN="$(command -v wine || true)"
[[ -n $WINE_BIN ]] || { err "No Wine binary found — needed to launch $(basename "$TOOL")."; exit 1; }

marker="$(mktemp)"
trap 'rm -f "$marker"' EXIT

msg "Launching $(basename "$TOOL") with $WINE_BIN"
msg "Paste the HWID when the tool asks, save the .auz, then close the tool."
set +e
"$WINE_BIN" "$TOOL" &
tool_pid=$!
wait "$tool_pid"
tool_rc=$?
set -e
[[ $tool_rc -eq 0 ]] || warn "Tool exited with $tool_rc — looking for the .auz anyway."

# ── collect the .auz produced by the tool ───────────────────────────────────
newest_auz(){
  local -a dirs=("$(dirname "$TOOL")" "$HOME/Downloads" "$HOME/Documents")
  local d
  for d in "${dirs[@]}"; do
    [[ -d $d ]] || continue
    find "$d" -maxdepth 3 -type f -name '*.auz' -newer "$marker" -printf '%T@ %p\n' 2>/dev/null
  done | sort -nr | head -1 | cut -d' ' -f2-
}

AUZ="$(newest_auz || true)"
if [[ -z ${AUZ:-} || ! -f $AUZ ]]; then
  warn "No new .auz found in $(dirname "$TOOL")/, ~/Downloads or ~/Documents."
  warn "Save the .auz produced by the tool, then re-run this script (or copy it yourself)."
  exit 0
fi

mkdir -p "$INSTALL_DIR"
cp -f -- "$AUZ" "$INSTALL_DIR/"
ok "Copied $(basename "$AUZ") -> $INSTALL_DIR/"

if command -v xdg-open >/dev/null 2>&1; then
  xdg-open "$INSTALL_DIR" >/dev/null 2>&1 &
  ok "Opened $INSTALL_DIR in the file manager."
else
  msg "Install folder: $INSTALL_DIR"
fi
