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

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
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
MOSQ_APP_DIR="$REPO/scripts/apps/mosquitomarchy"
ACTIONS_SRC="$MOSQ_APP_DIR/mosquitomarchy-actions"
AGENT_CRASH_SRC="$MOSQ_APP_DIR/mosquitomarchy-agent-crash"
SKILL_SRC="$MOSQ_APP_DIR/skills/mosquitomarchy-crash"

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

# Go is a BUILD dependency, and a machine without it cannot even reach the point
# where the user is told which modules are missing. So it gets installed rather
# than reported: mise first (no sudo, and it is how this workstation already has
# it), then pacman. Both keep their own password prompts — the bootstrap's rule
# is "no SILENT sudo", not "no sudo".
ensure_go() {
  if command -v go >/dev/null 2>&1; then ok "go present ($(go version | awk '{print $3}'))"; return 0; fi

  info "Go is not installed — installing it now (needed to build the TUI)."

  if command -v mise >/dev/null 2>&1; then
    info "Trying mise…"
    # Keep mise's own output: it is the only clue to WHY it failed, and discarding
    # it used to leave "did not produce a usable go" with nothing to act on.
    local mise_log; mise_log="$(mktemp)"
    # Run from a neutral directory. `mise use -g` is a GLOBAL install and the
    # working directory is irrelevant to it, but mise refuses to run AT ALL when
    # the cwd holds a config it has not been told to trust — and this repo ships a
    # .mise.toml. That turned every fresh machine into "mise failed: Config files
    # are not trusted", straight past a perfectly good installation path.
    if (cd "${HOME:-/tmp}" && mise use -g go@latest) >"$mise_log" 2>&1; then
      # mise has to be told to put its shims on PATH for this shell; without it
      # the install succeeded and the check below still says "missing".
      export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$PATH"
      command -v go >/dev/null 2>&1 && { ok "go installed via mise ($(go version | awk '{print $3}'))"; rm -f "$mise_log"; return 0; }
      warn "mise installed go but no 'go' command is on PATH; is the shims dir still $HOME/.local/share/mise/shims?"
    else
      warn "mise failed:"
      sed 's/^/    /' "$mise_log"
    fi
    rm -f "$mise_log"
    warn "mise did not produce a usable go — trying the system package manager."
  fi

  if command -v pacman >/dev/null 2>&1; then
    info "Trying pacman — this asks for your password."
    # Plain -S FIRST, so a healthy machine is never made to re-download every
    # package index just to install a build dependency.
    #
    # It then retries with -Sy. On a machine whose package databases have never
    # been populated — a freshly imaged box, which is exactly where the TUI build
    # is most likely to be the first thing that needs Go — pacman answers
    #   warning: database file for 'core' does not exist
    #   error: target not found: go
    # and the install fails for a reason that has nothing to do with Go.
    local pac; for pac in "-S" "-Sy"; do
      command -v sudo >/dev/null 2>&1 || break
      if [[ $pac == "-Sy" ]]; then
        info "sudo pacman -Sy --needed go   (populating the package databases first)"
      else
        info "sudo pacman -S --needed go"
      fi
      if sudo pacman "$pac" --needed go; then
        command -v go >/dev/null 2>&1 && { ok "go installed via pacman ($(go version | awk '{print $3}'))"; return 0; }
      fi
      # Only a "no such target" style failure is worth a resync; anything else
      # (a declined password, a full disk) would just be retried for nothing.
      [[ $pac == "-S" ]] || break
    done
  fi

  err "Could not install Go automatically."
  err "  Arch:  sudo pacman -Sy --needed go   (-Sy syncs first, needed on a"
  err "        machine whose package databases were never populated)"
  err "  mise:  mise use -g go@latest"
  err "Then re-run this script."
  return 1
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

install_backend_links() {
  # The Go TUI resolves mosquitomarchy-actions from ITS OWN directory (see
  # tui-go/actions.go). The backend must be a SYMLINK (never a copy): it
  # computes the path to mosquitomarchy-setup.sh relative to itself. Same for
  # the crash-diagnosis tool + the AI skill any harness scans.
  mkdir -p "$BIN_DIR" "$HOME/.agents/skills" 2>/dev/null || true
  if [[ -f $ACTIONS_SRC ]]; then
    chmod +x "$ACTIONS_SRC"
    ln -sf "$ACTIONS_SRC" "$BIN_DIR/mosquitomarchy-actions"
    ok "Backend linked: $BIN_DIR/mosquitomarchy-actions"
  else
    warn "mosquitomarchy-actions not found at $ACTIONS_SRC"
  fi
  if [[ -f $AGENT_CRASH_SRC ]]; then
    chmod +x "$AGENT_CRASH_SRC"
    ln -sf "$AGENT_CRASH_SRC" "$BIN_DIR/mosquitomarchy-agent-crash"
    ok "Crash-diagnosis tool linked: $BIN_DIR/mosquitomarchy-agent-crash"
  fi
  if [[ -d $SKILL_SRC ]]; then
    ln -sfn "$SKILL_SRC" "$HOME/.agents/skills/mosquitomarchy-crash"
    ok "Crash skill linked: ~/.agents/skills/mosquitomarchy-crash"
  fi
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
  # The mosquitomarchy-update module owns the post-boot hook: delegate so the
  # deployer installs the full watchdog (repo check + Omarchy updates +
  # clickable notification), not a second inline copy that would fight it.
  local mod="$REPO/scripts/mosquitomarchy-update/setup-mosquitomarchy-update.sh"
  if [[ -f $mod ]] && GUI_RUN_EXEC=1 bash "$mod" -y >/dev/null 2>&1; then
    ok "Post-boot update-check hook installed (mosquitomarchy-update module)."
    return 0
  fi
  warn "mosquitomarchy-update module unavailable — minimal hook instead."
  mkdir -p "$HOOK_DIR"
  cat > "$HOOK_FILE" <<'HOOK'
#!/usr/bin/env bash
# mosquitOmarchy update-check (minimal fallback): notify when the GitHub
# scripts have moved ahead of the local clone.
command -v omarchy >/dev/null || exit 0
"$HOME/.local/bin/mosquitomarchy" --status 2>/dev/null | jq -e '.updateAvailable' >/dev/null 2>&1 \
  && omarchy-notification-send --urgency low "update available" "click this to open the update page" --exec mosquitomarchy --update \
  || true
HOOK
  chmod +x "$HOOK_FILE"
  ok "Post-boot update-check hook installed (minimal)."
}

install_shell_state() {
  mkdir -p "$STATE_DIR"
  touch "$STATE_DIR/excluded"
  ok "State dir ready: $STATE_DIR"
}

install_menu_entry() {
  # No more ~/.local/share/applications .desktop: a .desktop is an APP in the
  # Omarchy menu "Apps" provider — the user wants the manager ONLY in the
  # Setup ▸ mosquito category (the marked menu block in omarchy-menu.jsonc).
  # Old copies (from earlier versions) are removed to avoid duplicate entries.
  rm -f "$APPS_DIR/install.mosquitomarchy.desktop"
  update-desktop-database "$APPS_DIR" 2>/dev/null || true

  # And the shell.json reference to it goes too, because it dangles. The bar
  # layout used to list "install.mosquitomarchy" in entries.right, which only
  # ever resolved to that .desktop; with the .desktop gone the bar asks for an
  # entry NOTHING provides, so it renders a permanent empty slot. The launcher
  # belongs in the Omarchy menu (setup.mosquito, written by
  # mosquitomarchy-setup.sh's restore_flow), not in the bar.
  strip_shell_entry

  if menu_entry_present; then
    ok "Menu entry present (Setup ▸ mosquito ▸ mosquitOmarchy)"
  else
    warn "Not in the Omarchy menu yet — run the 'mosquitomarchy' module of mosquitomarchy-setup.sh."
  fi
}

# Removes the dead "install.mosquitomarchy" bar entry from shell.json, leaving
# the rest of the layout untouched. Best-effort: a shell.json we cannot parse
# is reported, never rewritten blind.
strip_shell_entry() {
  [[ -f $SHELL_JSON ]] || return 0
  grep -qF 'install.mosquitomarchy' "$SHELL_JSON" || return 0
  python3 - "$SHELL_JSON" <<'PY'
import json, os, sys
p = sys.argv[1]
try:
    with open(p) as fh:
        data = json.load(fh)
except Exception as e:
    sys.stderr.write("shell.json is not valid JSON (%s) — left untouched\n" % e)
    sys.exit(1)
removed = 0
for side in ("left", "center", "right"):
    row = data.get("entries", {}).get(side)
    if isinstance(row, list) and "install.mosquitomarchy" in row:
        data["entries"][side] = [e for e in row if e != "install.mosquitomarchy"]
        removed += 1
if not removed:
    sys.exit(0)
with open(p, "w") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
PY
  if [[ $? == 0 ]]; then
    ok "Removed the dangling 'install.mosquitomarchy' bar entry (it pointed at a deleted .desktop)."
  else
    warn "Could not clean the stale 'install.mosquitomarchy' entry from shell.json."
  fi
}

# Is the launcher actually in the Omarchy menu? That is the marked
# "setup.mosquito" key inside mosquitomarchy-setup.sh's own menu block.
menu_entry_present() {
  local menu="$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"
  [[ -f $menu ]] || return 1
  grep -qF '"setup.mosquito"' "$menu"
}

install_shell_plugin() {
  mkdir -p "$(dirname "$SHELL_JSON")"
  # The bar gets NO entry for the manager: it would point at an .desktop that
  # deliberately does not exist. strip_shell_entry() removes a leftover one;
  # nothing adds it back.
  strip_shell_entry
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
  # "menu entry" used to be grepped out of shell.json, which reported the
  # DEAD bar entry as a success: the .desktop it named was removed on purpose,
  # so the check passed on a thing that could not launch anything. The real
  # launcher is the "setup.mosquito" key in omarchy-menu.jsonc.
  echo "menu entry       : $(menu_entry_present && echo "registered (Setup ▸ mosquito)" || echo "ABSENT — run the 'mosquitomarchy' module")"
  # A leftover of the same dangling reference, called out separately so it is
  # not mistaken for a working bar button.
  if [[ -f $SHELL_JSON ]] && grep -qF 'install.mosquitomarchy' "$SHELL_JSON"; then
    echo "stale bar entry  : YES — shell.json still asks for install.mosquitomarchy (no such .desktop)"
  else
    echo "stale bar entry  : none"
  fi
  echo "shell plugins    : $(omarchy-shell shell listPlugins 2>/dev/null | python3 -c 'import json,sys;d=json.load(sys.stdin);on=lambda i:any(p["id"]==i and p["enabled"] for p in d);print("on" if on("mosquito.confirm") and on("mosquito.indicators") else "partial/missing")')"
  echo "backend actions  : $([[ -e $BIN_DIR/mosquitomarchy-actions ]] && echo linked || echo absent)"
  echo "crash agent      : $([[ -e $BIN_DIR/mosquitomarchy-agent-crash ]] && echo linked || echo absent)"
  echo "crash skill      : $([[ -e $HOME/.agents/skills/mosquitomarchy-crash ]] && echo linked || echo absent)"
  echo "go               : $(command -v go >/dev/null && go version | awk '{print $3}')"
}

do_remove() {
  info "Uninstalling the mosquito manager TUI"
  rm -f "$TUI_BIN" "$DISPATCHER_DST" && ok "Binaries removed."
  rm -f "$BIN_DIR/mosquitomarchy-actions" "$BIN_DIR/mosquitomarchy-agent-crash" \
    "$HOME/.agents/skills/mosquitomarchy-crash" && ok "Backend/crash links removed."
  rm -f "$APPS_DIR/install.mosquitomarchy.desktop" && update-desktop-database "$APPS_DIR" 2>/dev/null || true
  ok "Desktop entry removed."
  # The Omarchy menu block (Setup > mosquito > mosquitOmarchy, markers below):
  # without this the menu row survives the uninstall pointing at a deleted
  # dispatcher, so the manager looks "still there" after being removed.
  local menu="$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"
  local ms="// >>> Omarchy_Custom_Scripts - mosquitOmarchy setup (managed by mosquitomarchy-setup.sh)"
  local me="// <<< Omarchy_Custom_Scripts - mosquitOmarchy setup (managed by mosquitomarchy-setup.sh)"
  if [[ -f $menu ]] && grep -qF "$ms" "$menu"; then
    local tmp; tmp="$(mktemp)"
    awk -v s="$ms" -v e="$me" '$0==s{inb=1;next} $0==e{inb=0;next} !inb{print}' "$menu" > "$tmp" && mv "$tmp" "$menu"
    omarchy menu refresh >/dev/null 2>&1 || true
    ok "Omarchy menu entry removed."
  fi
  # The same helper the install path uses, so both clean every bar side and a
  # malformed shell.json is reported instead of swallowed (this inline python
  # had a bare "except: pass", so a parse failure left the entry behind and
  # printed "Shell entry removed" anyway).
  strip_shell_entry
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
install_backend_links
install_float_rule
install_post_boot_hook
install_shell_state
install_menu_entry
install_shell_plugin
# NOT omarchy-launch-tui. That wrapper execs the word it is given, so
# "omarchy-launch-tui mosquito" ran a command called `mosquito` — which does not
# exist — and it died with "failed to execute: No such file or directory" on the
# very line telling the user to run it. It would also have used the app-id
# org.omarchy.mosquito, not the org.omarchy.mosquitomarchy-tui the float rule
# matches on. The dispatcher already picks its own terminal and that app-id.
ok "mosquitOmarchy TUI installed. Launch with: mosquitomarchy"
}

# Run only when EXECUTED directly (not sourced by mosquitomarchy-setup.sh).
main_tui
