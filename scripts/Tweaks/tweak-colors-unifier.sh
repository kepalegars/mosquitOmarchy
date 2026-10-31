#!/usr/bin/env bash
# tweak-colors-unifier.sh — make GTK4/GTK3 (and via qgtk3, Qt) apps follow the
# active Omarchy theme, with contrast-safe text, and refresh Nautilus fully.
#
# This is a hardened fork of Accord (https://github.com/vonsensey/accord, MIT).
# It writes the same kind of marked block into ~/.config/gtk-{4,3}.0/gtk.css,
# sets the same two gsettings keys, installs a theme-set hook, and disables the
# Accord plugin so two palettes cannot fight. Unlike Accord it never closes a
# visible Nautilus window on its own: it shows a centred prompt that explains
# that closing cancels in-progress copies/moves. Esc/No leaves Nautilus alone;
# the new palette then applies the next time it starts.
#
# Usage:
#   ./tweak-colors-unifier.sh            # apply (idempotent)
#   ./tweak-colors-unifier.sh --status   # read-only report
#   ./tweak-colors-unifier.sh --remove   # remove the hook + CSS, restore settings
#   ./tweak-colors-unifier.sh --quiet    # for the theme-set hook
#   ./tweak-colors-unifier.sh --no-prompt
#
# Environment: COLORS_UNIFIER_NO_PROMPT=1 skips the Nautilus dialog.
set -euo pipefail

G='\033[1;32m'; B='\033[1;34m'; Y='\033[1;33m'; R='\033[1;31m'; N='\033[0m'
msg(){ printf "${B}==>${N} %s\n" "$*"; }
ok(){  printf " ${G}✓${N} %s\n" "$*"; }
warn(){ printf "${Y} !${N} %s\n" "$*"; }
err(){ printf "${R} ✗${N} %s\n" "$*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$SCRIPT_DIR/colors-unifier.py"
STATE_DIR="$HOME/.local/state/mosquitomarchy/colors-unifier"
ACCORD_STATE="$STATE_DIR/accord"
HOOK_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/hooks/theme-set.d"
HOOK_FILE="$HOOK_DIR/colors-unifier"
ACCORD_ID="io.github.vonsensey.accord"
ACCORD_REPO="$HOME/.config/omarchy/plugins/$ACCORD_ID"

STATUS_ONLY=false REMOVE=false QUIET=false NO_PROMPT=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --status) STATUS_ONLY=true; shift ;;
    --remove|--uninstall) REMOVE=true; shift ;;
    --quiet) QUIET=true; shift ;;
    --no-prompt) NO_PROMPT=true; shift ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) err "Unknown option: $1"; exit 1 ;;
  esac
done

[[ -f $ENGINE ]] || { err "engine not found: $ENGINE"; exit 1; }

engine(){ python3 "$ENGINE" "$@"; }

accord_info(){
  command -v omarchy >/dev/null 2>&1 || return 1
  omarchy plugin list --json 2>/dev/null | python3 -c '
import json, sys
want = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for p in data if isinstance(data, list) else []:
    if p.get("id") == want:
        print("enabled" if p.get("enabled") else "disabled")
        sys.exit(0)
sys.exit(1)
' "$ACCORD_ID"
}

disable_accord(){
  local state
  state="$(accord_info || true)"
  mkdir -p "$STATE_DIR"
  # Record what it was BEFORE we disabled it. On a re-apply the plugin now
  # reads "disabled", and overwriting the file with that would make --remove
  # unable to restore the user's original enabled state.
  if [[ $state == enabled || ! -f $ACCORD_STATE ]]; then
    echo "${state:-absent}" > "$ACCORD_STATE"
  fi
  case "$state" in
    enabled)
      if omarchy plugin disable "$ACCORD_ID" >/dev/null 2>&1; then
        ok "Accord disabled (colors-unifier replaces its palette)"
        return 0
      fi
      warn "Could not disable Accord; its block will be stripped, but its service may re-add it"
      ;;
    disabled) ok "Accord already disabled" ;;
    *) ok "Accord not installed — nothing to replace" ;;
  esac
}

restore_accord(){
  local state="absent"
  [[ -f $ACCORD_STATE ]] && state="$(cat "$ACCORD_STATE" 2>/dev/null || echo absent)"
  [[ $state == enabled ]] || return 0
  if ! accord_info >/dev/null 2>&1; then
    warn "Accord was removed meanwhile — not re-enabling it"
    return 0
  fi
  if omarchy plugin enable "$ACCORD_ID" >/dev/null 2>&1; then
    ok "Accord re-enabled"
    if [[ -x $ACCORD_REPO/bin/accord-apply ]]; then
      "$ACCORD_REPO/bin/accord-apply" >/dev/null 2>&1 || true
    fi
  else
    warn "Could not re-enable Accord"
  fi
}

install_hook(){
  mkdir -p "$HOOK_DIR"
  cat > "$HOOK_FILE" <<EOF
#!/usr/bin/env bash
# Installed by mosquitOmarchy (tweak-colors-unifier.sh): keep GTK apps on the
# active Omarchy theme after every theme change. \$1 = the theme's snake-cased
# name; unused — the engine always re-reads the CURRENT theme.
exec "$SCRIPT_DIR/tweak-colors-unifier.sh" --quiet
EOF
  chmod +x "$HOOK_FILE"
  ok "theme-set hook installed ($HOOK_FILE)"
}

remove_hook(){
  if [[ -f $HOOK_FILE ]]; then
    rm -f "$HOOK_FILE"
    ok "theme-set hook removed"
  fi
}

if [[ $STATUS_ONLY == true ]]; then
  msg "colors-unifier status"
  engine --status || true
  if [[ -f $HOOK_FILE ]]; then ok "hook: installed ($HOOK_FILE)"; else warn "hook: not installed"; fi
  local_state="$(accord_info || echo absent)"
  echo "accord: ${local_state}"
  exit 0
fi

if [[ $REMOVE == true ]]; then
  msg "Removing colors-unifier"
  remove_hook
  engine --revert || warn "engine revert reported a problem"
  restore_accord
  rm -f "$ACCORD_STATE"
  ok "colors-unifier removed"
  exit 0
fi

msg "Applying colors-unifier"
disable_accord
args=(--quiet)
[[ $NO_PROMPT == true ]] && args+=(--no-prompt)
if ! engine "${args[@]}"; then
  err "Could not apply the palette"
  restore_accord
  exit 1
fi
install_hook
if [[ $QUIET == false ]]; then
  msg "GTK4/GTK3 palette applied. Nautilus keeps its window unless you accept the prompt."
fi
