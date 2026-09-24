#!/usr/bin/env bash
# =============================================================================
# install-tui.sh — Install the mosquitOmarchy Go/Bubble Tea TUI (and ONLY it)
# =============================================================================
# Small standalone installer for the new mosquito manager TUI (Bubble Tea).
# Does the work that used to be bundled inside `mosquitomarchy-setup.sh`, but
# without any of the other modules (apps, fixes, themes, …). Use it when you
# only want the TUI + its menu entry + float rule + post-boot watchdog hook,
# or to reinstall a stale build.
#
# The TUI source ships with the repo (scripts/apps/mosquitomarchy/tui-go/).
# Building needs Go (mise/pacman). The dispatcher bash lives at
# scripts/apps/mosquitomarchy/mosquitomarchy.
#
# Usage:
#   ./install-tui.sh                # build + install + enable (idempotent)
#   ./install-tui.sh --status      # what's deployed and where
#   ./install-tui.sh --remove      # uninstall (the dispatcher, menu entry,
#                                  #   float rule, post-boot hook, binaries)
#   ./install-tui.sh --rebuild-only  # just rebuild the Go binary in place
#   ./install-tui.sh -y            # non-interactive
# Sourcing this file only DEFINES the functions — the installer runs via
# main_tui() at the bottom, guarded on direct execution, so
# mosquitomarchy-setup.sh can reuse install_tui / remove_tui safely.
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/scripts/lib/gui-run.bash"  # gui-run: reopen in a terminal when launched from a file manager
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/scripts/lib/elevate.bash"   # mq_sudo: native pkexec prompt when not root
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TUI_GO="$REPO/scripts/apps/mosquitomarchy/tui-go"
DISPATCHER="$REPO/scripts/apps/mosquitomarchy/mosquitomarchy"
TUI_TMP_OUT="${TUI_TMP_OUT:-}"
BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
TUI_BIN="$BIN_DIR/mosquitomarchy-tui"
DISPATCHER_DST="$BIN_DIR/mosquitomarchy"
HYPR_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/hypr"
HYPRLAND="$HYPR_DIR/hyprland.lua"
FLOAT_BEGIN="-- >>> mosquitomarchy-tui-floating >>> float the mosquitOmarchy TUI"
FLOAT_END="-- <<< mosquitomarchy-tui-floating <<<"
SHELL_JSON="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/shell.json"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/mosquitomarchy"
HOOK_DIR="$HOME/.config/omarchy/hooks/post-boot.d"
HOOK_FILE="$HOOK_DIR/zzz-mosquitomarchy-update-check"
APPS_DIR="$HOME/.local/share/applications"

ok()  { echo -e "\033[32m ●\033[0m $*"; }
info(){ echo -e "\033[34m==>\033[0m $*"; }
warn(){ echo -e "\033[33m ●\033[0m $*" >&2; }
err() { echo -e "\033[31m ✗\033[0m $*" >&2; }

usage() { sed -n '2,30p' "$0"; exit "${1:-0}"; }
YES=0; STATUS=false; REMOVE=false; REBUILD=false
for a in "$@"; do case $a in
  -y|--yes) YES=1 ;;
  --status)  STATUS=true ;;
  --remove|--uninstall) REMOVE=true ;;
  --rebuild-only) REBUILD=true ;;
  -h|--help) usage 0 ;;
  *) usage 1 ;;
esac; done

ensure_go() {
  if command -v go >/dev/null 2>&1; then ok "go present ($(go version | awk '{print $3}'))"; return 0; fi
  err "Go is not installed. Install it (e.g. 'mise use go@latest' or 'sudo pacman -S go')."; return 1
}

ensure_repo_source() {
  [[ -f $TUI_GO/main.go ]] || { err "TUI source not found at $TUI_GO"; return 1; }
  [[ -f $DISPATCHER   ]] || { err "Dispatcher not found at $DISPATCHER";   return 1; }
}

build_tui() {
  ensure_go || return 1
  ensure_repo_source || return 1
  info "Building the TUI (Go/Bubble Tea)…"
  (cd "$TUI_GO" && go build -o "$TUI_BIN" .) || { err "TUI build failed."; return 1; }
  ok "TUI built and deployed: $TUI_BIN"
  install -m 0755 "$DISPATCHER" "$DISPATCHER_DST"
  ok "Dispatcher deployed: $DISPATCHER_DST"
}

install_float_rule() {
  mkdir -p "$HYPR_DIR"
  [[ -f $HYPRLAND ]] || touch "$HYPRLAND"
  if grep -qF -e "$FLOAT_BEGIN" "$HYPRLAND"; then ok "Hyprland float rule already present."; return 0; fi
  {
    printf '\n%s\n' "$FLOAT_BEGIN"
    printf -- '-- (the Bubble Tea TUI is not in Omarchy'\''s floating whitelist — float + center it.)\n'
    printf 'o.window("org.omarchy.mosquitomarchy-tui", { float = true, center = true })\n'
    printf '%s\n' "$FLOAT_END"
  } >> "$HYPRLAND"
  hyprctl reload >/dev/null 2>&1 || true
  ok "Hyprland float rule installed (org.omarchy.mosquitomarchy-tui)."
}

install_post_boot_hook() {
  mkdir -p "$HOOK_DIR"
  cat > "$HOOK_FILE" <<'HOOK'
#!/usr/bin/env bash
# mosquitOmarchy update-check: notify when the GitHub scripts have moved
# ahead of the local clone. The TUI itself can apply the update (Status >
# Update); this hook only keeps the bar badge honest.
command -v omarchy >/dev/null || exit 0
"$HOME/.local/bin/mosquitomarchy" --status 2>/dev/null | jq -e '.updateAvailable' >/dev/null 2>&1 \
  && omarchy-notification-send --urgency low "mosquitOmarchy" "New scripts version available — run Update from the TUI." \
  || true
HOOK
  chmod +x "$HOOK_FILE"
  ok "Post-boot update-check hook installed."
}

install_shell_state() {
  mkdir -p "$STATE_DIR"
  touch "$STATE_DIR/excluded"
  ok "State dir ready: $STATE_DIR"
}

install_menu_entry() {
  mkdir -p "$APPS_DIR"
  cat > "$APPS_DIR/install.mosquitomarchy.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=mosquitOmarchy
GenericName=Manager TUI
Comment=mosquitOmarchy manager — modules, fixes, backups
Exec=omarchy-launch-tui mosquito
Icon=preferences-system
Terminal=false
Categories=System;Settings;
StartupNotify=true
DESKTOP
  chmod 0644 "$APPS_DIR/install.mosquitomarchy.desktop"
  update-desktop-database "$APPS_DIR" 2>/dev/null || true
  ok "Desktop entry installed: install.mosquitomarchy.desktop"
}

install_shell_plugin() {
  mkdir -p "$(dirname "$SHELL_JSON")"
  if [[ -f "$SHELL_JSON" ]] && grep -qF 'install.mosquitomarchy' "$SHELL_JSON"; then
    ok "Shell entry already registered."
  else
    if [[ -f "$SHELL_JSON" ]]; then
      python3 - "$SHELL_JSON" <<'PY'
import json, sys
p = sys.argv[1]
with open(p) as fh:
    data = json.load(fh)
right = data.setdefault("entries", {}).setdefault("right", [])
if "install.mosquitomarchy" not in right:
    right.append("install.mosquitomarchy")
with open(p, "w") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
PY
    else
      printf '{"entries":{"right":["install.mosquitomarchy"]}}\n' > "$SHELL_JSON"
    fi
    ok "Shell entry registered (install.mosquitomarchy)."
  fi
  # Make sure the plugin is actually enabled (other plugin resets may have
  # disabled it; the update-check watchdog needs it active).
  omarchy plugin enable mosquito.indicators >/dev/null 2>&1 || true
  omarchy plugin enable mosquito.confirm     >/dev/null 2>&1 || true
  ok "mosquitomarchy QML plugins (confirm + indicators) enabled."
}

do_status() {
  echo "tui binary       : $([[ -x $TUI_BIN ]] && echo "present ($(stat -c %Y "$TUI_BIN" 2>/dev/null))" || echo absent)"
  echo "dispatcher      : $([[ -x $DISPATCHER_DST ]] && echo "present" || echo absent)"
  echo "hyprland float   : $(grep -qF -e "$FLOAT_BEGIN" "$HYPRLAND" 2>/dev/null && echo installed || echo absent)"
  echo "post-boot hook   : $([[ -x $HOOK_FILE ]] && echo installed || echo absent)"
  echo "menu entry       : $(grep -qF install.mosquitomarchy "$SHELL_JSON" 2>/dev/null && echo registered || echo absent)"
  echo "shell plugins    : $(omarchy-shell shell listPlugins 2>/dev/null | python3 -c 'import json,sys;d=json.load(sys.stdin);print("on" if any(p["id"] in ("mosquito.confirm","custom.power") and p["enabled"] for p in d) else "partial/missing")')"
  echo "go               : $(command -v go >/dev/null && go version | awk '{print $3}')"
}

do_remove() {
  info "Uninstalling the mosquito manager TUI"
  rm -f "$TUI_BIN" "$DISPATCHER_DST" && ok "Binaries removed."
  rm -f "$APPS_DIR/install.mosquitomarchy.desktop" && update-desktop-database "$APPS_DIR" 2>/dev/null || true
  ok "Desktop entry removed."
  [[ -f $SHELL_JSON ]] && python3 - "$SHELL_JSON" <<'PY' || true
import json, sys
try:
    with open(sys.argv[1]) as fh: d = json.load(fh)
    right = d.get("entries", {}).get("right", [])
    d.setdefault("entries", {})["right"] = [r for r in right if r != "install.mosquitomarchy"]
    with open(sys.argv[1], "w") as fh:
        json.dump(d, fh, indent=2); fh.write("\n")
except Exception: pass
PY
  ok "Shell entry removed."
  rm -f "$HOOK_FILE" && ok "Post-boot hook removed."
  if [[ -f $HYPRLAND ]] && grep -qF -e "$FLOAT_BEGIN" "$HYPRLAND"; then
    local tmp; tmp="$(mktemp)"
    awk -v b="$FLOAT_BEGIN" -v e="$FLOAT_END" '
      $0~b {inb=1; next} $0~e {inb=0; next} !inb {print}
    ' "$HYPRLAND" > "$tmp" && mv "$tmp" "$HYPRLAND"
    hyprctl reload >/dev/null 2>&1 || true
    ok "Hyprland float rule removed."
  fi
}

main_tui(){
case "$REMOVE" in
  true)  do_remove; return 0 ;;
esac
case "$STATUS" in
  true)  do_status; return 0 ;;
esac
case "$REBUILD" in
  true)  build_tui; return 0 ;;
esac

build_tui
install_float_rule
install_post_boot_hook
install_shell_state
install_menu_entry
install_shell_plugin
ok "mosquitOmarchy TUI installed. Launch with: omarchy-launch-tui mosquito"
}

# Run only when EXECUTED directly (not sourced by mosquitomarchy-setup.sh).
main_tui
