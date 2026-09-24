#!/usr/bin/env bash
# mosquitomarchy-setup.sh — Single entry point for all mosquitOmarchy.
#
# Asks a few questions up front, applies everything chosen, then prints
# a final report stating whether everything went well (and what remains manual).
# Works on any Omarchy installation: it detects what is
# already in place and only installs what is missing.
#
# Usage:
#   ./mosquitomarchy-setup.sh            # interactive: STATUS/UPDATE/SETUP/REMOVE/BACKUP-RESTORE menu
#   ./mosquitomarchy-setup.sh -y         # apply everything with the default choices (auto backup)
#   ./mosquitomarchy-setup.sh --update   # also re-runs the already-installed modules (idempotent)
#   ./mosquitomarchy-setup.sh --status   # status of all modules, without modifying anything
#   ./mosquitomarchy-setup.sh --include=<mod>  # re-offer a module you previously uninstalled
#   ./mosquitomarchy-setup.sh --uninstall # per-module uninstall (interactive [--purge: also the data])
#   ./mosquitomarchy-setup.sh --backup   # dated backup now, then exit
#   ./mosquitomarchy-setup.sh --backup --vst-backup=full   # idem + full VST archive (~/VST)
#   ./mosquitomarchy-setup.sh --list     # chronological list of the backups
#   ./mosquitomarchy-setup.sh --restore[=FILE]  # restore a backup (chronological choice)
#   ./mosquitomarchy-setup.sh --update-repo     # git pull the scripts from GitHub (see "Updating")
#
# Backup / restore / per-module uninstall are integrated here: there is no
# separate backup-mosquitomarchy.sh or uninstall-mosquitomarchy.sh anymore.
#
# Uninstalled modules are remembered (state file): if you uninstall a module
# it is NOT re-proposed by this master (unless re-enabled with --include=).
#
# "Updating": the update zone checks GitHub for a newer version of the scripts.
#   • PRIMARY use: the OWNER updates the repo as fast as possible.
#   • Available on GitHub so any user can self-update in an EMERGENCY.
#   • RECOMMENDED: wait for the owner's update instead of pulling yourself.
# The same check runs at each boot via the mosquitomarchy-update module: the
# scripts update is checked FIRST, and only if there is none do we notify
# about the pending Omarchy updates.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/./scripts/lib/gui-run.bash"  # gui-run: reopen in a terminal when launched from a file manager
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/lib/elevate.bash"  # mq_sudo: native pkexec prompt when not root
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/lib/keybindings.bash"  # kb_*: SUPER keybindings managed block in bindings.lua
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Library mode: when MOSQUITOMARCHY_LIB_ONLY=1 this file is SOURCED (by the
# mosquitomarchy-actions backend of the Go TUI) to expose its functions without
# parsing the caller's arguments or auto-running main() at the bottom.
LIB_ONLY="${MOSQUITOMARCHY_LIB_ONLY:-0}"
YES=0 STATUS_ONLY=0 UPDATE_OK=0 UNINSTALL_DELEGATE=0 PURGE=0
MODE=""          # "" = normal ; backup | list | restore | update-repo
RESTORE_FILE=""
VST_MODE=""
INCLUDES=()
if (( ! LIB_ONLY )); then
  for a in "$@"; do case "$a" in
    -y|--yes) YES=1 ;;
    --status) STATUS_ONLY=1 ;;
    --update) UPDATE_OK=1 ;;
    --uninstall) UNINSTALL_DELEGATE=1 ;;
    --purge) PURGE=1 ;;
    --include=*) INCLUDES+=("${a#*=}") ;;
    --backup) MODE=backup ;;
    --vst-backup=*) VST_MODE="${a#*=}" ;;
    --list) MODE=list ;;
    --restore) MODE=restore ;;
    --restore=*) MODE=restore; RESTORE_FILE="${a#*=}" ;;
    --update-repo) MODE=update-repo ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "Unknown option: $a (supported: -y --status --update --uninstall --include=<mod> --backup [--vst-backup=list|full|none] --list --restore[=FILE] --update-repo)" >&2; exit 1 ;;
  esac; done
fi

COMPOSE="$HOME/.config/windows/docker-compose.yml"

G='\033[1;32m'; B='\033[1;34m'; Y='\033[1;33m'; R='\033[1;31m'; D='\033[2m'; N='\033[0m'
msg(){ printf "${B}==>${N} %s\n" "$*"; }
ok(){ printf " ${G}✓${N} %s\n" "$*"; }
warn(){ printf " ${Y}!${N} %s\n" "$*"; }
err(){ printf " ${R}✗${N} %s\n" "$*" >&2; }
info(){ msg "$*"; }
hr(){ printf '%.0s─' {1..72}; echo; }
pkg_has(){ pacman -Q "$1" &>/dev/null; }

# Omarchy themes export a GREY GUM_CHOOSE_SELECTED_BACKGROUND (#918f93): the
# selected multi-select rows then show as a big grey box. Clearing it leaves
# only the "[x]" checkmark, which is all we want (also inherited by children).
export GUM_CHOOSE_SELECTED_BACKGROUND=""
export GUM_FILTER_SELECTED_BACKGROUND=""

ask(){
  local q="$1" def="${2:-y}" r
  ((YES)) && { ok "(auto) $q -> yes"; return 0; }
  if command -v gum >/dev/null; then
    gum confirm "$q" --default=$([[ $def == y ]] && echo true || echo false) && return 0 || return 1
  fi
  read -rp "$q [$([ $def = y ] && echo Y/n || echo y/N)] " r
  r="${r:-$def}"; [[ $r =~ ^[oOyY] ]]
}

# ───────────────────────── Excluded modules (state) ─────────────────────────
# Modules voluntarily uninstalled are remembered so this master does not
# re-propose / re-install them. They can be re-offered with --include=<module>
# or interactively.
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-custom-scripts"
EXCLUDED_FILE="$STATE_DIR/excluded"

load_excluded(){
  EXCLUDED=()
  [[ -f "$EXCLUDED_FILE" ]] || return 0
  local m
  while IFS= read -r m || [[ -n $m ]]; do
    [[ -z $m ]] && continue
    [[ $m == keys ]] && m=keybindings                # renamed module id (old state files)
    [[ $m == davinci ]] && m=davinci-resolve       # renamed module id (old state files)
    EXCLUDED+=("$m")
  done < "$EXCLUDED_FILE"
}

is_excluded(){
  ((${#EXCLUDED[@]})) || return 1
  local m; for m in "${EXCLUDED[@]}"; do [[ $m == "$1" ]] && return 0; done; return 1
}

# --include=<module>: temporarily re-offer excluded modules (in-memory only;
# uninstalling again re-persists them as excluded).
apply_includes(){
  local inc m new
  ((${#INCLUDES[@]})) || return 0
  for inc in "${INCLUDES[@]}"; do
    if is_excluded "$inc"; then
      new=()
      for m in "${EXCLUDED[@]}"; do [[ $m == "$inc" ]] || new+=("$m"); done
      EXCLUDED=("${new[@]}")
      ok "Module '$inc' re-offered (--include)."
    fi
  done
}

unexclude(){
  local m new=() rest
  for m in "${EXCLUDED[@]:-}"; do [[ -n $m && $m == "$1" ]] || new+=("$m"); done
  EXCLUDED=("${new[@]}")
  if ((${#EXCLUDED[@]})); then
    printf '%s\n' "${EXCLUDED[@]}" > "$EXCLUDED_FILE"
  else
    rm -f "$EXCLUDED_FILE"
  fi
  ok "Module '$1' re-offered (removed from the excluded state)."
}

record_excluded(){ # $1 = module id: adds it to the excluded state (dedup)
  local m
  if [[ -f "$EXCLUDED_FILE" ]]; then
    while IFS= read -r m || [[ -n $m ]]; do [[ $m == "$1" ]] && return 0; done < "$EXCLUDED_FILE"
  fi
  mkdir -p "$(dirname "$EXCLUDED_FILE")"
  printf '%s\n' "$1" >> "$EXCLUDED_FILE"
}

# ───────────────────────── Repo update ("update zone") ─────────────────────────
# Checks GitHub for a newer version of the scripts than the local checkout.
# Documented roles:
#   • OWNER  → update the repo as fast as possible (commit + push).
#   • USERS  → self-update in an emergency via the same mechanism on GitHub.
#   • RECOMMENDED → wait for the owner's update rather than pulling yourself.
# Run at each boot by the mosquitomarchy-update module (priority: scripts update
# first; only if there is none do we notify about pending Omarchy updates).
REPO_DIR="${OMARCHY_SCRIPTS_REPO:-$SCRIPT_DIR}"
REPO_REMOTE="${OMARCHY_SCRIPTS_REMOTE:-origin}"
REPO_BRANCH="master"

# ── Displayed script versions ──────────────────────────────────────────────
# The version shown next to a module is the version of its SCRIPT (the
# installer), NOT of the application it installs. Everything is v1.0.0 except
# the four v0.1.0 scripts (DaVinci Resolve setup, bootstrap, handbrake, keybindings).
# The main script — the whole repo — is v0.1.0 (the root VERSION file).
REPO_VERSION="$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || echo 0.1.0)"
module_version(){
  case "$1" in
    davinci|davinci-resolve|handbrake|keybindings|bootstrap) echo "0.1.0" ;;
    *) echo "1.0.0" ;;
  esac
}

repo_update_avail(){ # 0 if a GitHub version is newer than the local one
  command -v git >/dev/null 2>&1 || return 1
  [[ -d "$REPO_DIR/.git" ]] || return 1
  local local_head remote_head
  local_head="$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || true)"
  [[ -n "$local_head" ]] || return 1
  remote_head="$(timeout 15 git -C "$REPO_DIR" ls-remote "$REPO_REMOTE" "refs/heads/$REPO_BRANCH" 2>/dev/null | awk '{print $1}' | head -1)"
  [[ -n "$remote_head" ]] || return 1
  [[ "$remote_head" != "$local_head" ]]
}

update_repo_ff(){
  # Proper install: fast-forward pull, then re-run the modules in their latest form.
  # The update is strictly a fast-forward merge: never `git clean`, `reset --hard`
  # or `rebase` — folders that the repository does not track are never touched
  # or deleted, so anything stored locally next to the scripts survives updates.
  # Uses `fetch` + `merge --ff-only` instead of `git pull` so an owner machine
  # with `pull.rebase=true` configured cannot make the update fall back to a
  # rebase (which would refuse on a dirty tree, or rewrite local commits).
  local out rc
  out="$(git -C "$REPO_DIR" fetch "$REPO_REMOTE" "$REPO_BRANCH" 2>&1)" \
    rc=$? || rc=$?
  if ((rc == 0)); then
    out="$(git -C "$REPO_DIR" merge --ff-only FETCH_HEAD 2>&1)" \
      rc=$? || rc=$?
  fi
  if ((rc == 0)); then
    ok "Repo updated (git fetch + merge --ff-only)."
    return 0
  fi
  err "Update failed: $out"
  err "Nothing changed — your local checkout is kept as-is."
  return 1
}

check_repo_update(){
  if repo_update_avail; then
    msg "Update zone"
    warn "The GitHub repo has a newer version than the local one ($REPO_DIR)."
    echo "  • Owner mode: updates the repo as fast as possible (recommended)."
    echo "  • Emergency : a user may self-update from GitHub — do it with care."
    echo "  • Recommended: wait for the owner's update instead of pulling yourself."
    if ((YES)); then
      warn "(auto) not updating without confirmation — run ./mosquitomarchy-setup.sh --update-repo to pull."
      return 0
    fi
    if ask "Apply the update now (git pull, then re-run the modules)?" n; then
      if update_repo_ff; then
        ok "Update applied — run ./mosquitomarchy-setup.sh --update to re-apply the modules in their latest form."
      fi
    else
      ok "Kept as-is (check later, or --update-repo)."
    fi
  fi
}

# ───────────────────────── Per-module detection ─────────────────────────
st_reaper(){
  pkg_has reaper || { echo missing; return; }
  [[ -x "$HOME/.local/bin/reaper-launch" ]] && echo ok || echo partial
}
st_audio(){
  # Bitwig installed? (flatpak OR AUR/pacman)
  local bw_installed=0
  if flatpak list 2>/dev/null | grep -q com.bitwig.BitwigStudio; then
    bw_installed=1
  elif pkg_has bitwig-studio; then
    bw_installed=1
  fi
  if ((bw_installed)); then echo ok; else echo missing; fi
}
st_windows_vm(){
  [[ -x "$HOME/.local/bin/windows-vm-usb" ]] || { echo missing; return; }
  [[ -x "$HOME/.local/bin/winvm" ]] || { echo partial; return; }
  local debloat_ok=1
  if [[ -f $COMPOSE ]] && ! grep -q ":/oem" "$COMPOSE"; then debloat_ok=0; fi
  ((debloat_ok)) && echo ok || echo partial
}
st_macos_vm(){
  [[ -x "$HOME/.local/bin/osx-kvm-installer.sh" ]] || { echo missing; return; }
  [[ -x "$HOME/.local/bin/macos-vm-tui.sh" ]] || { echo partial; return; }
  [[ -x "$HOME/.local/bin/launch-macos-tui.sh" ]] || { echo partial; return; }
  local block_ok=1
  if [[ -f $MENU ]] && ! grep -qF "Omarchy_Custom_Scripts_MacosVm" "$MENU"; then block_ok=0; fi
  # Keybinding is owned by mosquitOmarchy (its marker block) → look for the
  # macOS entry inside that block instead of a dedicated marker.
  if [[ -f $BINDINGS ]] && ! grep -qF 'Omarchy_Custom_Scripts_Keys' "$BINDINGS"; then block_ok=0; fi
  if [[ -f $BINDINGS ]] && ! grep -qF '"macOS VM Manager"' "$BINDINGS"; then block_ok=0; fi
  if [[ -f $HYPRLAND ]] && ! grep -qF "Omarchy_Custom_Scripts_MacosVm" "$HYPRLAND"; then block_ok=0; fi
  ((block_ok)) && echo ok || echo partial
}
st_omarchy_vm(){
  [[ -x "$HOME/.local/bin/omarchy-vm" ]] || { echo missing; return; }
  [[ -x "$HOME/.local/bin/omarchy-vm-tui.sh" ]] || { echo partial; return; }
  [[ -x "$HOME/.local/bin/launch-omarchy-tui.sh" ]] || { echo partial; return; }
  local block_ok=1
  if [[ -f $MENU ]] && ! grep -qF "Omarchy_Custom_Scripts_OmarchyVm" "$MENU"; then block_ok=0; fi
  if [[ -f $HYPRLAND ]] && ! grep -qF "Omarchy_Custom_Scripts_OmarchyVm" "$HYPRLAND"; then block_ok=0; fi
  if [[ -f $BINDINGS ]] && ! grep -qF '"Omarchy VM Manager"' "$BINDINGS"; then block_ok=0; fi
  ((block_ok)) && echo ok || echo partial
}
st_ableton(){
  # Native Linux Ableton Live (ableton-linux project): launcher + dedicated wine prefix
  [[ -x "$HOME/.local/bin/ableton-live" ]] || { echo missing; return; }
  local links_ok=1
  for l in "$HOME/.wine-ableton/drive_c/Program Files/Common Files/VST3" \
           "$HOME/.wine-ableton/drive_c/Program Files (x86)/Common Files/VST3" \
           "$HOME/.wine-ableton/drive_c/Program Files/Steinberg/VSTPlugins"; do
    [[ -L $l ]] || links_ok=0
  done
  ((links_ok)) && echo ok || echo partial
}
st_ableton_move_converter(){
  # Ableton Move → Move Manager → Ableton → Bitwig workflow (native prompts, MIDI export)
  [[ -x "$HOME/.local/bin/mosquito-move-manager" ]] || { echo missing; return; }
  [[ -x "$HOME/.local/bin/move-bundle-to-midi" ]] || { echo partial; return; }
  [[ -x "$HOME/.local/bin/move-udev-refresh" ]] || { echo partial; return; }
  [[ -x "$HOME/.local/bin/move-manager-webapp" ]] || { echo partial; return; }
  echo ok
}
st_ollama(){
  command -v ollama >/dev/null || { echo missing; return; }
  systemctl is-enabled ollama &>/dev/null && echo ok || echo partial
}
st_battery(){
  [[ -x "$HOME/.local/bin/ultra-save" ]] || { echo missing; return; }
  [[ -x "$HOME/.local/bin/power-helper" ]] || { echo partial; return; }
  # Coffee mode (laptop closed without sleeping): binary deployed + valid syntax.
  [[ -x "$HOME/.local/bin/mega-caffeine" ]] || { echo partial; return; }
  bash -n "$HOME/.local/bin/mega-caffeine" 2>/dev/null || { echo partial; return; }
  # The parent widget is the custom.power plugin: if enabled, the module is "ok".
  omarchy plugin list 2>/dev/null | grep -qE '^\s*custom\.power\s+enabled' && echo ok || echo partial
}
st_brightness(){
  [[ -x "$HOME/.local/bin/backlight" ]] || { echo missing; return; }
  [[ -f "$HOME/.config/hypr/bindings.lua" ]] \
    && grep -qF -- "Omarchy_Custom_Scripts_Brightness" "$HOME/.config/hypr/bindings.lua" \
    && echo ok || echo partial
}
st_achraff(){
  # achraff-67 theme: files present + applied
  local tdir="$HOME/.config/omarchy/themes/achraff-67"
  [[ -f "$tdir/colors.toml" && -f "$tdir/unlock.png" ]] || { echo missing; return; }
  [[ "$(omarchy theme current 2>/dev/null || true)" == "Achraff 67" ]] \
    && echo ok || echo partial
}
st_keyboard_backlight(){
  # Keyboard backlight: kbd-toggle helper + Trigger > Hardware menu entry
  [[ -x "$HOME/.local/bin/kbd-toggle" ]] || { echo missing; return; }
  [[ -f "$HOME/.config/omarchy/extensions/omarchy-menu.jsonc" ]] \
    && grep -qF -- "kbd-toggle" "$HOME/.config/omarchy/extensions/omarchy-menu.jsonc" \
    && echo ok || echo partial
}
st_touchpad(){
  # Touchpad: generated per-device file + require registered in hyprland.lua
  [[ -f "$HOME/.config/hypr/touchpad.lua" && -f "$HOME/.config/hypr/hyprland.lua" ]] \
    || { echo missing; return; }
  grep -qF -- "Omarchy_Custom_Scripts_Touchpad" "$HOME/.config/hypr/touchpad.lua" \
    && grep -qF -- "hypr.touchpad" "$HOME/.config/hypr/hyprland.lua" \
    && echo ok || echo partial
}
st_mx_master(){
  # MX Master thumb→SUPER: logiops installed + our /etc/logid.cfg + service
  command -v logid >/dev/null 2>&1 || { echo missing; return; }
  [[ -f /etc/logid.cfg ]] || { echo missing; return; }
  grep -qF -- "mosquitOmarchy-mx-master" /etc/logid.cfg || { echo partial; return; }
  systemctl is-enabled logid >/dev/null 2>&1 || { echo partial; return; }
  echo ok
}
st_keepassxc(){
  # KeePassXC secret service: dbus override + autostart shadow + user mask
  # + keepassxc.ini [FdoSecrets] Enabled=true
  [[ -x /usr/bin/keepassxc ]] || { echo missing; return; }
  local f="$HOME/.local/share/dbus-1/services/org.freedesktop.secrets.service"
  [[ -f $f ]] && grep -q '^Exec=/usr/bin/keepassxc' "$f" || { echo partial; return; }
  [[ -f "$HOME/.config/autostart/gnome-keyring-secrets.desktop" ]]     && grep -q '^Hidden=true' "$HOME/.config/autostart/gnome-keyring-secrets.desktop"     || { echo partial; return; }
  # NOTE: `systemctl is-enabled` prints "masked" but EXITS 1 — under pipefail
  # the pipeline would fail; read the stdout instead of piping.
  [[ $(systemctl --user is-enabled gnome-keyring-daemon.service 2>/dev/null || true) == masked ]] \
    || { echo partial; return; }
  python3 - <<'PY' || { echo partial; return; }
import configparser, os, sys
c = configparser.ConfigParser(); c.read(os.path.expanduser("~/.config/keepassxc/keepassxc.ini"))
raise SystemExit(0 if c.getboolean("FdoSecrets", "Enabled", fallback=False) else 1)
PY
  echo ok
}

st_keybindings(){
  # SUPER keybindings managed by mosquitOmarchy (marker block in bindings.lua)
  [[ -f "$HOME/.config/hypr/bindings.lua" ]] || { echo missing; return; }
  grep -qF -- "Omarchy_Custom_Scripts_Keys" "$HOME/.config/hypr/bindings.lua" \
    && echo ok || echo partial
}
st_mosquitomarchy_update(){
  # Update watchdog: post-boot hook installed + review banner available
  [[ -d "$HOME/.config/omarchy/hooks/post-boot.d" ]] || { echo missing; return; }
  grep -rlq -e "mosquitomarchy" "$HOME/.config/omarchy/hooks/post-boot.d" 2>/dev/null \
    && echo ok || echo partial
}
st_superfile(){
  # SuperFile is now an app you launch (menu entry), no longer a system
  # default-file-manager replacement: installed = the .desktop entry exists.
  [[ -f "$HOME/.local/share/applications/superfile.desktop" ]] && echo ok || echo missing
}
# Resolves the ACTIVE Zen profile (path relative to ~/.config/zen):
#   1. the [Install...] block of profiles.ini — what zen-bin actually runs,
#   2. fallback: the [Profile...] block marked Default=1,
#   3. fallback: the profile with the most recently modified places.sqlite.
# Prints the profile path or nothing.
zen_active_profile(){
  [[ -f "$HOME/.config/zen/profiles.ini" ]] || return 1
  local prof cfg="$HOME/.config/zen/profiles.ini"
  prof="$(awk -v FS='=' '
    /^\[/ { in_install = ($0 ~ /^\[Install/) }
    in_install && /^Default=/ { print $2; exit }
  ' "$cfg")"
  if [[ -n $prof && -d "$HOME/.config/zen/$prof" ]]; then printf '%s' "$prof"; return 0; fi
  prof="$(awk -v FS='=' '
    /^\[/ { in_profile = ($0 ~ /^\[Profile/); default_after = 0 }
    in_profile && /^Default=1$/ { default_after = 1 }
    in_profile && default_after && /^Path=/ { print $2; exit }
  ' "$cfg")"
  if [[ -n $prof && -d "$HOME/.config/zen/$prof" ]]; then printf '%s' "$prof"; return 0; fi
  local newest p
  newest="$(cd "$HOME/.config/zen" 2>/dev/null && ls -td */*/places.sqlite 2>/dev/null | head -1 || true)"
  [[ -n $newest ]] && { printf '%s' "${newest%/*/places.sqlite}"; return 0; }
  return 1
}

st_zen(){
  # Zen browser config: zen-browser-bin installed + active profile has at
  # least the seed extensions deployed. "partial" = browser present but the
  # seed config not (yet) applied.
  pkg_has zen-browser-bin || { echo missing; return; }
  compgen -G "$ZEN_DIR/seed/extensions/*.xpi" >/dev/null 2>&1 || { echo partial; return; }
  [[ -d "$HOME/.config/zen" ]] || { echo partial; return; }
  local prof
  prof="$(zen_active_profile 2>/dev/null || true)"
  [[ -n $prof && -d "$HOME/.config/zen/$prof/extensions" ]] || { echo partial; return; }
  local missing=0 x
  for x in "$ZEN_DIR/seed/extensions"/*.xpi; do
    [[ -f $HOME/.config/zen/$prof/extensions/${x##*/} ]] || missing=1
  done
  ((missing == 0)) && echo ok || echo partial
}
st_jamjamjam_plugin(){
  # JamJamJam bar plugin: installed copy + bar entry present
  local plug="$HOME/.config/omarchy/plugins/jamjamjam-plugin"
  [[ -d "$plug" && -f "$plug/manifest.json" ]] || { echo missing; return; }
  compgen -G "$plug/backend/*.py" >/dev/null 2>&1 || { echo partial; return; }
  if [[ -f "$HOME/.config/omarchy/shell.json" ]] \
     && grep -q '"jamjamjam-plugin"' "$HOME/.config/omarchy/shell.json"; then
    echo ok
  else
    echo partial
  fi
}
st_live_mode(){
  # Live mode: the whole set is 4 binaries + the sudoers root helper + the
  # QML overlay plugin + the Trigger > Music entries.
  [[ -x "$HOME/.local/bin/live-mode" ]] || { echo missing; return; }
  [[ -x "$HOME/.local/bin/live-mode-watch" ]] || { echo partial; return; }
  [[ -x "$HOME/.local/bin/live-mode-root" ]] || { echo partial; return; }
  [[ -x "$HOME/.local/bin/mosquito-live-mode-tui" ]] || { echo partial; return; }
  [[ -f /etc/sudoers.d/live-mode ]] || { echo partial; return; }
  [[ -d "$HOME/.config/omarchy/plugins/mosquito.livemode" ]] || { echo partial; return; }
  echo ok
}
st_mosquitomarchy(){
  # The manager TUI itself (former install-tui.sh): dispatcher + built binary
  # + desktop entry + float rule + post-boot update hook.
  [[ -x "$HOME/.local/bin/mosquitomarchy" ]] || { echo missing; return; }
  [[ -x "$HOME/.local/bin/mosquitomarchy-tui" ]] || { echo missing; return; }
  local miss=0
  [[ -f "$HOME/.local/share/applications/install.mosquitomarchy.desktop" ]] || miss=$((miss+1))
  grep -qF -e "mosquitomarchy-tui-floating" "$HOME/.config/hypr/hyprland.lua" 2>/dev/null || miss=$((miss+1))
  [[ -x "$HOME/.config/omarchy/hooks/post-boot.d/zzz-mosquitomarchy-update-check" ]] || miss=$((miss+1))
  if ((miss)); then echo partial; else echo ok; fi
}

st_guitarpro(){
  # Guitar Pro 8 via wine: dedicated prefix + GuitarPro.exe + launcher
  [[ -f "$HOME/.wine-guitarpro8/drive_c/Program Files/Arobas Music/Guitar Pro 8/GuitarPro.exe" ]] \
    || { echo missing; return; }
  [[ -x "$HOME/.local/bin/guitarpro" ]] && echo ok || echo partial
}
st_davinci(){
  # DaVinci Resolve in /opt/resolve (Studio or free) + launcher
  [[ -x /opt/resolve/bin/resolve ]] || { echo missing; return; }
  [[ -x "$HOME/.local/bin/davinci-resolve" ]] && echo ok || echo partial
}
st_handbrake(){
  # HandBrake GUI installed + Hyprland rules block present
  pkg_has handbrake || { echo missing; return; }
  [[ -f "$HOME/.config/hypr/hyprland.lua" ]] \
    && grep -qF -- "Omarchy_Custom_Scripts_Handbrake" "$HOME/.config/hypr/hyprland.lua" \
    && echo ok || echo partial
}
st_apps(){
  # "apps" module: no single binary — reports how many apps/tuis from the
  # catalogs (per type) are not installed (webapps are tracked by omarchy).
  local catfiles=("$SCRIPT_DIR/scripts/apps/gui/guis.catalog" "$SCRIPT_DIR/scripts/apps/tui-tools/tuis.catalog")
  local found=0 f
  for f in "${catfiles[@]}"; do [[ -f $f ]] && found=1; done
  ((found)) || { echo missing; return; }
  local missing=0 kind name line
  for f in "${catfiles[@]}"; do
    [[ -f $f ]] || continue
    while IFS= read -r line || [[ -n $line ]]; do
      line="${line%%$'\r'}"
      [[ -z $line || $line == \#* ]] && continue
      kind="${line%%[ |]*}"
      [[ $kind == APP || $kind == TUI ]] || continue
      name="${line#*[ ]}"; name="${name%%|*}"
      pkg_has "$name" || missing=$((missing+1))
    done < "$f"
  done
  ((missing == 0)) && echo ok || echo "partial:$missing"
}

MODULES=(
  "mosquitomarchy:mosquitomarchy TUI — the manager interface itself (dispatcher + menu entry + float rule + post-boot update hook) — installed first"
  "reaper:REAPER + Hyprland/Wayland integration"
  "audio:yabridge stack + Bitwig 6.0 Beta 6 (local .deb) + local VST folders + cautions"
  "windows-vm:VM launcher + winvm (RAM/CPU/disk) + OEM debloat (auto-detected)"
  "macos-vm:macOS VMs in QEMU/KVM (OSX-For-Omarchy) — installer + TUI manager + shared folders + USB passthrough"
  "omarchy-vm:Omarchy in QEMU/KVM from the official ISO — launcher + TUI manager + shared folder + USB/GPU passthrough"
  "ableton:Native Linux Ableton Live 12 (ableton-linux) + multi-DAW VST sharing"
  "guitarpro:Guitar Pro 8 via wine (dedicated prefix + launcher + menu shortcut)"
  "davinci-resolve:DaVinci Resolve (Studio or free) + H.264/H.265 (FFmpeg encoder / libav patch) + SpectraFilm OFX option"
  "ableton-move-manager:mosquito Move Manager — Ableton Move → Ableton Live → Bitwig (menu: address / Move Manager / convert — native Omarchy prompts, MIDI export)"
  "handbrake:HandBrake (Qt GUI + CLI) + H.264/H.265 encoders + preset sync + Hyprland rules"
  "apps:Apps, tuis & webapps (catalog per type gui/tui/webapps + backup selection via setup-apps.sh)"
  "ollama:Local AI Ollama + REAPER models (~14 GB of downloads)"
  "remove-ai:remove omarchy's agentic stuff (removes agents, AI-diag toasts, ollama loaders; Setup reverts it 'bring back omarchy's agentic stuff')"
  "battery:Battery backend (ultra-save + Lenovo charge-control + custom.power plugin) + coffee mode (mega-caffeine)"
  "brightness:Display brightness — Omarchy default, plus 0% = screen off"
  "achraff:'Achraff 67' visual theme + unlock/Plymouth logo (lock screen left stock)"
  "keyboard-backlight:Keyboard backlight toggle + Trigger > Hardware entry"
  "touchpad:Touchpad (pointer acceleration + sensitivity — external mouse is not affected)"
  "mx-master:MX Master (any model) — thumb gesture button → SUPER (logiops daemon, system service)"
  "keepassxc:KeePassXC secret service (apps module) — REPLACES gnome-keyring completely (existing keyring secrets must be migrated manually; package removal optional & asked). On FIRST KeePassXC launch choose YOUR .kdbx: the install pins it into keepassxc.ini (Remember*/LastOpened*) so EVERY web app's browser extension and secret service uses it — no more 'create a new database?' prompts. 'i' info below; pin a DIFFERENT file manually with scripts/apps/keepassxc/keepassxc-default-database.sh FILE.kdbx (README in that folder lists a manual select)"
  "keybindings:SUPER keybindings manager (app launches + quick functions — bindings.lua marker block)"
  "mosquitomarchy-update:Update watchdog (scripts update first, then Omarchy updates — notification + opencode conflict review)"
  "superfile:SuperFile — terminal file manager (menu entry + keybind + Omarchy theme)"
  "zen:Zen Browser config — plugins + settings + chrome theme (deployed into the active profile)"
  "jamjamjam-plugin:JamJamJam bar plugin — key/BPM/chord detection, chord progression grid, guitar fretboard scale, MIDI chord mode + synth"
  "live-mode:Live mode — performance session mode (stay-awake + thermal guard + routing tool in scratchpad: live-mode / live-mode-watch / live-mode-root + Trigger > Music entries + QML overlay)"
)

# ───────────────────────── Quick system fixes ─────────────────────────
# Small idempotent one-shot fixes, proposed at startup (multi-select).
# Each entry: id:micro explanation.
FIXES=(
  "keepassxc-window:KeePassXC window floats/centers in Hyprland instead of misbehaving when tiled next to other windows"
  "tui-theme:Force-adapt the TUIs' theme to the current Omarchy theme (regenerate the palette + rebuild both Go TUIs; the dynamic theme already ships with tui-kit)"
  "omarchy-menu:Recover the Omarchy menu when clones leave blank rows / an empty Apps list (remove menu-plugin clones, re-enable omarchy.menu, restart the shell)"
  "hyprland-crash:Recover a Hyprland desktop after a crash (broken/truncated hyprland.lua, fatal Lua escapes, lost keyboard layout, missing Omarchy shell) — self-heals at every boot via a post-boot hook"
  "ableton-wine-scroll:Ableton/Wine: stop the patched Wine's optional pointer features (XInput2 grab) from freezing trackpad scrolling in other apps while Live is open (persistent master switch in the prefix, reversible)"
  "1px-seam:Hair-thin transparent 1px line between the Omarchy bar and a window in borderless/no-gaps tiling — switch the blur to its legacy path (helps when blur is enabled; reversible)"
  "ableton-fullscreen:Ableton Live Full Screen is shifted/broken (content sits off where you click) — launches Live with WINE_WIN32_FULLSCREEN_CLASS=off (documented ableton-linux cure; drag-the-window alternative): (reversible)"
  "omarchy-bar:The Omarchy toolbar disappeared (toggled off / slid off-screen) — clear the bar-off toggle and re-sync the shell"
)

fix_desc(){ # id -> description
  local f
  for f in "${FIXES[@]:-}"; do
    [[ "${f%%:*}" == "$1" ]] && { printf '%s' "${f#*:}"; return 0; }
  done
  return 1
}

# Category shown as a "folder" row in the quick-fixes multi-select, so a fix
# can be picked alone or its whole category in one keystroke.
fix_category(){
  case $1 in
    keepassxc-window) echo "Windows & input" ;;
    tui-theme)        echo "Appearance" ;;
    omarchy-menu)     echo "Omarchy" ;;
    omarchy-bar)      echo "Omarchy" ;;
    hyprland-crash)   echo "Recovery" ;;
    ableton-wine-scroll) echo "Windows & input" ;;
    ableton-fullscreen) echo "Windows & input" ;;
    *)                echo "Other" ;;
  esac
}

fixes_pick(){ # fill FIXES_SELECTED with the chosen ids (global)
  FIXES_SELECTED=()
  local -a labels=() values=() cats=() e id c x
  local seen
  for e in "${FIXES[@]:-}"; do
    id="${e%%:*}"; c="$(fix_category "$id")"; seen=0
    for x in "${cats[@]:-}"; do [[ $x == "$c" ]] && seen=1; done
    ((seen)) || cats+=("$c")
  done
  # Fixes under their category, indented with a file-tree angle so the
  # grouping is visually obvious (pick a whole ▾ category or one fix).
  local -a catfx=() j
  for c in "${cats[@]}"; do
    labels+=("▾ $c"); values+=("CAT:$c")
    catfx=()
    for e in "${FIXES[@]:-}"; do
      id="${e%%:*}"
      [[ "$(fix_category "$id")" == "$c" ]] && catfx+=("$e")
    done
    for j in "${!catfx[@]}"; do
      e="${catfx[$j]}"; id="${e%%:*}"
      if (( j == ${#catfx[@]} - 1 )); then
        labels+=("    └─ $id  —  ${e#*:}")
      else
        labels+=("    ├─ $id  —  ${e#*:}")
      fi
      values+=("FIX:$id")
    done
  done
  # Print every description FULL and wrapped, so a narrow default window
  # never hides the end of a fix's explanation (gum rows are single-line
  # and get truncated to the window width).
  local cols="${COLUMNS:-}"
  [[ -z $cols ]] && cols="$(tput cols 2>/dev/null || echo 100)"
  (( cols < 40 )) && cols=100
  echo
  msg "Quick fixes (full descriptions):"
  for e in "${FIXES[@]:-}"; do
    printf '  %s — %s\n' "${e%%:*}" "${e#*:}" | fold -s -w "$cols" | sed 's/^/    /'
  done
  echo
  local -a chosen=()
  local p i
  if command -v gum >/dev/null 2>&1; then
    local -a picks=()
    mapfile -t picks < <(gum choose --no-limit "${labels[@]}" \
      --header "Quick fixes to apply (Tab/x = toggle a group or a fix, Enter = confirm):" \
      --cursor-prefix "[ ] " --selected-prefix "[x] " --unselected-prefix "[ ] ")
    for p in "${picks[@]}"; do
      for ((i=0; i<${#labels[@]}; i++)); do
        [[ "${labels[$i]}" == "$p" ]] || continue
        chosen+=("${values[$i]}"); break
      done
    done
  else
    echo "Quick fixes available (pick a whole group or individual fixes):"
    for ((i=0; i<${#labels[@]}; i++)); do printf '  %2d) [ ] %s\n' "$((i+1))" "${labels[$i]}"; done
    local n idx
    read -rp "  Numbers to apply (empty = none) : " n
    for idx in $n; do
      [[ "$idx" =~ ^[0-9]+$ ]] && ((idx >= 1 && idx <= ${#labels[@]})) || continue
      chosen+=("${values[$((idx-1))]}")
    done
  fi
  # Expand picked folder rows to every fix in that category, then dedup.
  local v c2 e2 id2 k have
  for v in "${chosen[@]:-}"; do
    if [[ $v == CAT:* ]]; then
      c2="${v#CAT:}"
      for e2 in "${FIXES[@]:-}"; do
        id2="${e2%%:*}"
        [[ "$(fix_category "$id2")" == "$c2" ]] || continue
        have=0; for k in "${FIXES_SELECTED[@]:-}"; do [[ $k == "$id2" ]] && have=1; done
        ((have)) || FIXES_SELECTED+=("$id2")
      done
    else
      id2="${v#FIX:}"
      have=0; for k in "${FIXES_SELECTED[@]:-}"; do [[ $k == "$id2" ]] && have=1; done
      ((have)) || FIXES_SELECTED+=("$id2")
    fi
  done
}

run_fix(){ # single fix by id
  local id="$1"
  case $id in
    keepassxc-window) bash "$SCRIPT_DIR/scripts/fixes/fix-keepassxc-window.sh" ;;
    tui-theme) bash "$SCRIPT_DIR/scripts/fixes/fix-tui-theme.sh" ;;
    omarchy-menu) bash "$SCRIPT_DIR/scripts/fixes/fix-omarchy-menu.sh" ;;
    hyprland-crash) bash "$SCRIPT_DIR/scripts/fixes/fix-hyprland-crash.sh" ;;
    ableton-wine-scroll) bash "$SCRIPT_DIR/scripts/fixes/fix-wine-scroll.sh" ;;
    ableton-fullscreen) bash "$SCRIPT_DIR/scripts/fixes/fix-ableton-fullscreen.sh" ;;
    1px-seam) bash "$SCRIPT_DIR/scripts/fixes/fix-1px-seam.sh" ;;
    omarchy-bar) bash "$SCRIPT_DIR/scripts/fixes/fix-omarchy-bar.sh" ;;
    *) err "Unknown fix: $id"; return 1 ;;
  esac
}

run_fixes(){ # loop over FIXES_SELECTED, log results
  mq_sudo_prime >/dev/null 2>&1 || true   # one prompt for the whole fix batch
  local id
  for id in "${FIXES_SELECTED[@]:-}"; do
    hr
    if run_fix "$id"; then RESULTS+=("quick-fix/$id:ok")
    else RESULTS+=("quick-fix/$id:fail"); MODULE_FAILURES=$((MODULE_FAILURES + 1)); fi
  done
  hr
}

module_state(){
  local s
  case $1 in
    reaper) st_reaper ;; audio) st_audio ;; windows-vm) st_windows_vm ;;
    macos-vm) st_macos_vm ;;
    omarchy-vm) st_omarchy_vm ;;
    ableton) st_ableton ;; guitarpro) st_guitarpro ;;
    ableton-move-manager) st_ableton_move_converter ;;
    davinci-resolve) st_davinci ;;
    handbrake) st_handbrake ;;
    apps) s="$(st_apps)"; s="${s%%:*}"; echo "$s" ;;
    ollama) st_ollama ;; battery) st_battery ;; brightness) st_brightness ;;
    achraff) st_achraff ;; keyboard-backlight) st_keyboard_backlight ;;
    touchpad) st_touchpad ;;
    mx-master) st_mx_master ;;
    keybindings) st_keybindings ;;
    keepassxc) st_keepassxc ;; mosquitomarchy-update) st_mosquitomarchy_update ;;
    superfile) st_superfile ;;
    zen) st_zen ;;
    jamjamjam-plugin) st_jamjamjam_plugin ;;
    live-mode) st_live_mode ;;
    mosquitomarchy) st_mosquitomarchy ;;
    remove-ai) ai_state_on && echo missing || echo ok ;;
  esac
}

# Maps a repo-relative file path to the module id that owns it (used by the
# update zone to know WHICH installed modules a change actually affects).
# Empty output = the change does not belong to any module (e.g. this master
# script itself, docs, README…).
module_of_path(){
  case "$1" in
    scripts/apps/reaper/*)                                   echo reaper ;;
    scripts/apps/bitwig/*|scripts/apps/audio-plugin-manager/*) echo audio ;;
    scripts/windows-vm/*)                                    echo windows-vm ;;
    scripts/macos-vm/*)                                      echo macos-vm ;;
    scripts/omarchy-vm/*)                                    echo omarchy-vm ;;
    scripts/apps/ableton/*)                                  echo ableton ;;
    scripts/apps/guitarpro/*)                                echo guitarpro ;;
    scripts/apps/davinci/*)                                  echo davinci ;;
    scripts/apps/ableton-move-*|scripts/apps/ableton-move/*) echo ableton-move-manager ;;
    scripts/apps/handbrake/*)                                echo handbrake ;;
    scripts/apps/gui/*|scripts/apps/tui-tools/*|scripts/apps/webapps/*|\
    scripts/apps/setup-apps.sh|scripts/apps/uninstall-apps.sh|scripts/lib/common.bash) echo apps ;;
    scripts/LLM/*)                                           echo ollama ;;
    scripts/plugins/power-management/*)                      echo battery ;;
    scripts/fixes/fix-optimized-brightness.sh)               echo brightness ;;
    scripts/theme/*)                                         echo achraff ;;
    scripts/fixes/backlight/*|scripts/fixes/fix-keyboard-backlight-menu.sh) echo keyboard-backlight ;;
    scripts/fixes/fix-touchpad.sh)                           echo touchpad ;;
    scripts/fixes/fix-mx-master.sh)                          echo mx-master ;;
    scripts/fixes/fix-ableton-fullscreen.sh)                 echo ableton-fullscreen ;;
    scripts/apps/keepassxc/*)                                echo keepassxc ;;
    scripts/mosquitomarchy-update/*)                            echo mosquitomarchy-update ;;
    scripts/apps/superfile/*)                                echo superfile ;;
    scripts/apps/zen/*)                                      echo zen ;;
    scripts/plugins/jamjamjam/*)                             echo jamjamjam-plugin ;;
    scripts/plugins/live-mode/*)                             echo live-mode ;;
    scripts/apps/mosquitomarchy/install-tui.sh|scripts/apps/mosquitomarchy/mosquitomarchy|scripts/apps/mosquitomarchy/mosquitomarchy-actions) echo mosquitomarchy ;;
  esac
}

status_report(){
  hr; msg "mosquitOmarchy module status"
  load_excluded
  apply_includes
  local row state sym color label
  for row in "${MODULES[@]}"; do
    local id="${row%%:*}" label="${row#*:}"
    state="$(module_state "$id")"
    if is_excluded "$id"; then
      printf " ${D}—${N} %-9s %s ${D}(excluded — you uninstalled it; --include to re-offer)${N}\n" "$id" "$label"
      continue
    fi
    case $state in
      ok)      printf " ${G}✓${N} %-9s %s\n" "$id" "$label" ;;
      partial) printf " ${Y}!${N} %-9s %s ${D}(partial — rerun to complete)${N}\n" "$id" "$label" ;;
      missing) printf " ${R}✗${N} %-9s %s\n" "$id" "$label" ;;
      na)      printf " ${D}—${N} %-9s %s ${D}(not applicable here)${N}\n" "$id" "$label" ;;
    esac
  done
  hr
}

# ───────────────────────── Backup / Restore (integrated) ─────────────────────────
# Each backup is stored as a dated FILE in a dedicated folder:
#   ~/omarchy-backups/omarchy-backup-<YYYYMMDD-HHMMSS>.tar.gz
# The archive is optionally encrypted in place with a passphrase (AES-256,
# gpg --symmetric --cipher-algo AES256 — same cipher LUKS/Omarchy uses, file
# level, no sudo needed). An encrypted backup keeps the same dated name plus a
# .gpg suffix: omarchy-backup-<YYYYMMDD-HHMMSS>.tar.gz.gpg. The restore
# prompts for that passphrase to decrypt it first. The passphrase can also be
# provided non-interactively via OMARCHY_BACKUP_PASSPHRASE (see do_backup).
# Contents: config-backup.tar.gz (config + Omarchy bar + menus + wrappers +
# yabridgectl + autosync units + REAPER), pkglist.txt, aurlist.txt, RESTORE.md,
# and optionally plugins/manifest.txt (inventory) and plugins/plugins-vst.tar.gz
# (full VST archive). All paths are relative to $HOME: a restore puts them
# back exactly in the same place.
BACKUP_DIR="${OMARCHY_BACKUP_DIR:-$HOME/omarchy-backups}"
BACKUP_GLOB="$BACKUP_DIR/omarchy-backup-*.tar.gz*"
BACKUP_DECRYPTED_RE='.*\.tar\.gz(\.gpg)?$'
has_backups(){ compgen -G "$BACKUP_GLOB" >/dev/null 2>&1; }

existing_config(){
  [[ -d "$HOME/.config/REAPER" || -d "$HOME/.config/windows" \
  || -f "$HOME/.local/bin/winvm" || -f "$HOME/.local/bin/reaper-launch" ]]
}

# Most recent available backup (path based on $BACKUP_DIR, so testable).
latest_backup_file(){
  ls -t "$BACKUP_DIR"/omarchy-backup-*.tar.gz* 2>/dev/null | head -1
}

# ─── VST source folder detection (local, separate from the VM) ───
# Root resolution mirrors the audio stack's resolve_vst_root(): explicit
# override, then the modern default $HOME/Music/Audio Plugins when it holds
# plugin files, then the legacy $HOME/VST (always the fallback — restores of
# old archives extract there with the uppercase folder names intact).
VST_SRC_BASE="${AUDIOSTACK_VST_ROOT:-}"
if [[ -z "$VST_SRC_BASE" ]]; then
  if find "$HOME/Music/Audio Plugins" -mindepth 2 \( -iname '*.dll' -o -iname '*.vst3' -o -iname '*.clap' \) 2>/dev/null | grep -q .; then
    VST_SRC_BASE="$HOME/Music/Audio Plugins"
  elif find "$HOME/VST" -mindepth 2 \( -iname '*.dll' -o -iname '*.vst3' -o -iname '*.clap' \) 2>/dev/null | grep -q .; then
    VST_SRC_BASE="$HOME/VST"
  else
    VST_SRC_BASE="$HOME/VST"
  fi
fi
VST_DIRS=()
for sub in VST2 VST3 CLAP vst vst3 clap; do
  [[ -d "$VST_SRC_BASE/$sub" ]] && VST_DIRS+=("$VST_SRC_BASE/$sub")
done
has_vst_sources=$(( ${#VST_DIRS[@]} > 0 && 1 ))

# ───- Apps / tuis / webapps ("apps" module) ───
# Modular catalogs: one per type under apps/gui, apps/tui-tools, apps/webapps.
# Note: catalog PATHS use CAT_FILE_* — CAT_APP/CAT_TUI/CAT_WEB are the loaded
# entry ARRAYS (a name collision would clobber the paths).
CAT_FILE_GUI="$SCRIPT_DIR/scripts/apps/gui/guis.catalog"
CAT_FILE_TUI="$SCRIPT_DIR/scripts/apps/tui-tools/tuis.catalog"
CAT_FILE_WEB="$SCRIPT_DIR/scripts/apps/webapps/webapps.catalog"

# Loads the three catalogs into CAT_APP / CAT_TUI / CAT_WEB.
load_catalog(){
  CAT_APP=(); CAT_TUI=(); CAT_WEB=()
  local line kind f
  for f in "$CAT_FILE_GUI" "$CAT_FILE_TUI" "$CAT_FILE_WEB"; do
    [[ -f $f ]] || continue
    while IFS= read -r line || [[ -n $line ]]; do
      line="${line%%$'\r'}"
      [[ -z $line || $line == \#* ]] && continue
      kind="${line%%[ |]*}"
      case $kind in
        APP) CAT_APP+=("${line#*[ ]}") ;;
        TUI) CAT_TUI+=("${line#*[ ]}") ;;
        WEB) CAT_WEB+=("${line#*[ ]}") ;;
      esac
    done < "$f"
  done
  [[ -f $CAT_FILE_GUI || -f $CAT_FILE_TUI || -f $CAT_FILE_WEB ]]
}

is_webapp_installed(){
  [[ -f "$HOME/.local/share/applications/$1.desktop" ]] \
    && grep -qE '^Exec=.*(omarchy-launch-webapp|omarchy-webapp-handler)' "$HOME/.local/share/applications/$1.desktop"
}

# Loads the apps selection of the most recent backup (if it has one) → PREV_APP /
# PREV_TUI / PREV_WEB: arrays of NAMES (first field before "|").
# Returns 0 if a non-empty selection was found, 1 otherwise.
load_previous_selection(){
  PREV_APP=(); PREV_TUI=(); PREV_WEB=()
  local last; last="$(latest_backup_file)"; [[ -n $last ]] || return 1
  local -a entries lines
  mapfile -t entries < <(tar -tzf "$last" 2>/dev/null | grep -E '(^|/)apps\.selected$' | head -1)
  ((${#entries[@]})) || return 1
  local f="${entries[0]}"
  mapfile -t lines < <(tar -xOzf "$last" "$f" 2>/dev/null | grep -vE '^#|^[[:space:]]*$' || true)
  local l kind rest name
  for l in "${lines[@]:-}"; do
    kind="${l%% *}"; rest="${l#* }"; name="${rest%%|*}"
    case $kind in
      APP) PREV_APP+=("$name") ;;
      TUI) PREV_TUI+=("$name") ;;
      WEB) PREV_WEB+=("$name") ;;
    esac
  done
  [[ ${#PREV_APP[@]} -gt 0 || ${#PREV_TUI[@]} -gt 0 || ${#PREV_WEB[@]} -gt 0 ]]
}

# Detects the catalog entries CURRENTLY installed → INSTALLED_APP / _TUI / _WEB
detect_installed_apps(){
  INSTALLED_APP=(); INSTALLED_TUI=(); INSTALLED_WEB=()
  local e name
  for e in "${CAT_APP[@]:-}"; do name="${e%%|*}"; pkg_has "$name" && INSTALLED_APP+=("$e"); done
  for e in "${CAT_TUI[@]:-}"; do name="${e%%|*}"; pkg_has "$name" && INSTALLED_TUI+=("$e"); done
  for e in "${CAT_WEB[@]:-}"; do name="${e%%|*}"; is_webapp_installed "$name" && INSTALLED_WEB+=("$e"); done
}

# Multiple selection (gum multi-select with tab/space) of an array of entries.
# Takes: title, displayed prefix (App/Tui/Web), array (by reference), then a
# variable number of NAMES to pre-check by default (everything else stays unchecked).
multi_select(){
  local header="$1" prefix="$2"; shift 2
  local -n arr="$1"
  shift
  local -a presel=("$@")
  local -a labels=() pre_labels=() e label name p
  for e in "${arr[@]:-}"; do
    name="${e%%|*}"
    case $prefix in
      App) label="App   $name  —  ${e#*|}" ;;
      Tui) label="Tui   $name  —  ${e#*|}" ;;
      Web) label="Web   $name" ;;
    esac
    label="${label//,/;}"   # commas would break gum's --selected list
    labels+=("$label")
    for p in "${presel[@]:-}"; do
      [[ "$p" == "$name" ]] && pre_labels+=("$label") && break
    done
  done
  SELECTED_PICK=()
  if command -v gum >/dev/null; then
    local -a picks sel=() s
    if ((${#pre_labels[@]})); then
      local IFS=","; s="${pre_labels[*]}"; unset IFS
      sel=(--selected "$s")
    fi
    mapfile -t picks < <(gum choose --no-limit --header "$header" "${sel[@]}" \
      --cursor-prefix "[ ] " --selected-prefix "[x] " --unselected-prefix "[ ] " "${labels[@]}")
    for e in "${picks[@]}"; do
      local pname="${e#*  }"; pname="${pname%%  —*}"
      pname="${pname#"${pname%%[![:space:]]*}"}"   # trims leading spaces (short pattern)
      # finds the matching canonical entry
      local cand
      for cand in "${arr[@]:-}"; do [[ "${cand%%|*}" == "$pname" ]] && SELECTED_PICK+=("$cand") && break; done
    done
    # Empty output → user unchecked/cancelled everything: the empty selection is kept.
  else
    echo "$header :"
    local i=1 idx n default_nums=""
    for e in "${labels[@]}"; do
      local nm="${arr[$((i-1))]%%|*}" mark=" "
      for p in "${presel[@]:-}"; do
        [[ "$p" == "$nm" ]] && { mark="x"; default_nums="$default_nums $i"; }
      done
      printf '  %2d) %s  [%s]\n' "$i" "$e" "$mark"; i=$((i+1))
    done
    read -rp "  Numbers to save${default_nums:+ (default: $default_nums, empty entry)} : " n
    [[ -z $n ]] && n="$default_nums"
    for idx in $n; do
      [[ "$idx" =~ ^[0-9]+$ ]] && ((idx >= 1 && idx <= ${#arr[@]})) && SELECTED_PICK+=("${arr[$((idx-1))]}")
    done
  fi
}

# Builds apps.selected for the backup: selection (interactive or full-with-y from
# the installed catalog) of apps + tuis + webapps.
backup_apps_selection(){
  # A pre-made selection (the Go TUI's checkbox tree) takes precedence: copy
  # it verbatim and skip every prompt.
  if [[ -n ${BACKUP_APPS_SELECTION_FILE:-} && -f $BACKUP_APPS_SELECTION_FILE ]]; then
    cp "$BACKUP_APPS_SELECTION_FILE" "$1/apps.selected"
    ok "apps.selected saved from the TUI selection ($(grep -vcE '^#|^[[:space:]]*$' "$1/apps.selected" 2>/dev/null || echo 0) entries)"
    return 0
  fi
  load_catalog || { warn "apps catalogs missing (gui/guis.catalog, tui/tuis.catalog, webapps/webapps.catalog) — apps not backed up."; return 1; }
  detect_installed_apps
  local total=$(( ${#INSTALLED_APP[@]} + ${#INSTALLED_TUI[@]} + ${#INSTALLED_WEB[@]} ))
  [[ $total == 0 ]] && { warn "No catalog app/tui/webapp installed — nothing to back up."; return 1; }

  # Default pre-checked selection: the previous backup's selection (if it
  # exists) ∩ still installed, + sone-bin (always). Without a previous backup →
  # everything detected is pre-checked. Apps also found on the system
  # (detected but outside this set) stay unchecked.
  local had_prev=0 name
  load_previous_selection && had_prev=1
  local -a pre_app=() pre_tui=() pre_web=()
  if ((had_prev)); then
    for name in "${PREV_APP[@]:-}"; do pkg_has "$name" && pre_app+=("$name"); done
    for name in "${PREV_TUI[@]:-}"; do pkg_has "$name" && pre_tui+=("$name"); done
    for name in "${PREV_WEB[@]:-}"; do is_webapp_installed "$name" && pre_web+=("$name"); done
  else
    for name in "${INSTALLED_APP[@]:-}"; do pre_app+=("${name%%|*}"); done
    for name in "${INSTALLED_TUI[@]:-}"; do pre_tui+=("${name%%|*}"); done
    for name in "${INSTALLED_WEB[@]:-}"; do pre_web+=("${name%%|*}"); done
  fi
  # sone always pre-checked when installed.
  if pkg_has sone-bin; then
    local has_sone=0 n2
    for n2 in "${pre_app[@]:-}"; do [[ $n2 == sone-bin ]] && has_sone=1; done
    ((has_sone == 0)) && pre_app+=("sone-bin")
  fi

  # No apps catalog? nothing is written.
  local sel_file="$1/apps.selected"
  : > "$sel_file"
  { echo "# apps.selected — apps/tuis/webapps selection saved by mosquitomarchy-setup.sh (backup)"
    echo "# readable by apps/setup-apps.sh (all checked by default)."
  } > "$sel_file"

  local n=0
  # Apps
  if ((${#INSTALLED_APP[@]})); then
    if ((YES)); then
      local e; for e in "${INSTALLED_APP[@]}"; do SELECTED_PICK+=("$e"); done
    else
      if ask "Save the installed APPS (${#INSTALLED_APP[@]})? (multiple choice — $((${#pre_app[@]})) pre-checked)" y; then
        multi_select "Apps to save (Tab/x = toggle, Enter = confirm):" App INSTALLED_APP "${pre_app[@]}"
      fi
    fi
    for e in "${SELECTED_PICK[@]:-}"; do [[ -z $e ]] && continue; echo "APP ${e%%|*}" >> "$sel_file"; n=$((n+1)); done
    SELECTED_PICK=()
  fi
  # Tuis
  if ((${#INSTALLED_TUI[@]})); then
    if ((YES)); then
      local e2; for e2 in "${INSTALLED_TUI[@]}"; do SELECTED_PICK+=("$e2"); done
    else
      if ask "Save the installed TUIS (${#INSTALLED_TUI[@]})? (multiple choice — $((${#pre_tui[@]})) pre-checked)" y; then
        multi_select "Tuis to save (Tab/x = toggle, Enter = confirm):" Tui INSTALLED_TUI "${pre_tui[@]}"
      fi
    fi
    for e in "${SELECTED_PICK[@]:-}"; do [[ -z $e ]] && continue; echo "TUI ${e%%|*}" >> "$sel_file"; n=$((n+1)); done
    SELECTED_PICK=()
  fi
  # Webapps (always saved if present, multiple choice)
  if ((${#INSTALLED_WEB[@]})); then
    if ((YES)); then
      local e3; for e3 in "${INSTALLED_WEB[@]}"; do SELECTED_PICK+=("$e3"); done
    else
      if ask "Save the Omarchy WEBAPPS (${#INSTALLED_WEB[@]})? (multiple choice — $((${#pre_web[@]})) pre-checked)" y; then
        multi_select "Webapps to save (Tab/x = toggle, Enter = confirm):" Web INSTALLED_WEB "${pre_web[@]}"
      fi
    fi
    for e in "${SELECTED_PICK[@]:-}"; do
      # WEB name|url|icon
      [[ -z $e ]] && continue
      echo "WEB $e" >> "$sel_file"; n=$((n+1))
    done
    SELECTED_PICK=()
  fi

  if ((n == 0)); then
    warn "No app/tui/webapp selected — apps.selected empty (apps module inactive)."
    rm -f "$sel_file"
  else
    ok "apps.selected ($n entries) — for reinstall via apps/setup-apps.sh"
  fi
}

# ───────────────────────── 1. Backup ─────────────────────────
# Hidden passphrase entry. The typed value is stored in the global
# ASK_PASSPHRASE (never printed): the interactive TUI must NOT run inside a
# command substitution — that is what made gum input unusable from the
# launcher. gum is used only when all three standard streams are a real
# terminal; otherwise (or when gum returns nothing) it falls back to a hidden
# `read -rs`, so a first empty attempt is re-asked instead of being final.
ask_passphrase(){
  local prompt="$1" tmp="" used_gum=0
  ASK_PASSPHRASE=""
  [[ -t 0 ]] || return 0
  if [[ -t 1 && -t 2 ]] && command -v gum >/dev/null 2>&1; then
    used_gum=1
    tmp="$(mktemp)"
    if gum input --password --header "$prompt" > "$tmp" 2>/dev/tty; then
      ASK_PASSPHRASE="$(cat "$tmp")"
    fi
    rm -f "$tmp"
  fi
  if [[ $used_gum == 0 || -z $ASK_PASSPHRASE ]]; then
    printf '%s: ' "$prompt"
    IFS= read -rs ASK_PASSPHRASE || ASK_PASSPHRASE=""
    printf '\n'
  fi
  return 0
}

# Encrypts a freshly-created backup archive in place (removes the plain
# .tar.gz, keeps the .tar.gz.gpg). Passphrase sources, in order:
#   1. "$OMARCHY_BACKUP_PASSPHRASE" (non-interactive / -y mode, CI-safe)
#   2. gum TUI (hidden input, twice) when gum is available
#   3. hidden read on a bare terminal (twice)
# Skipped with a warning otherwise. The passphrase goes to gpg via stdin
# (--passphrase-fd, never argv) so it can't leak into the process list.
backup_encrypt(){
  local src="$1" pass="${2:-}"
  local confirm
  # If the passphrase was already decided by the caller (2nd arg present — even
  # empty = "user chose no encryption"), don't ask again.
  if (($# < 2)); then
    if [[ -n ${OMARCHY_BACKUP_PASSPHRASE:-} ]]; then
      pass="$OMARCHY_BACKUP_PASSPHRASE"
    else
      ask_passphrase "Encrypt the backup? (AES-256 — contains KeePassXC passwords) — passphrase"
      pass="$ASK_PASSPHRASE"
      [[ -n $pass ]] || { warn "Empty passphrase — backup left UNENCRYPTED ($(basename "$src"))."; return 0; }
      ask_passphrase "Confirm passphrase"
      confirm="$ASK_PASSPHRASE"
      [[ $pass == "$confirm" ]] || { warn "Passphrases don't match — backup left UNENCRYPTED ($(basename "$src"))."; return 0; }
    fi
  fi
  [[ -n $pass ]] || { warn "Backup left UNENCRYPTED ($(basename "$src"))."; return 0; }
  if ! command -v gpg >/dev/null 2>&1; then
    warn "gpg not found — backup left UNENCRYPTED ($(basename "$src"))."
    return 0
  fi
  # Encrypt to a fresh file, then atomically replace the plain archive.
  local plain gpgout
  plain=$(basename "$src")              # omarchy-backup-<ts>.tar.gz
  gpgout="$BACKUP_DIR/${plain}.gpg"
  if printf '%s' "$pass" | gpg --batch --yes --symmetric --cipher-algo AES256 \
      --passphrase-fd 0 -o "$gpgout" "$src" 2>/dev/null; then
    rm -f "$src"
    ok "Encrypted: $(basename "$gpgout") (AES-256)"
    [[ -n ${OMARCHY_BACKUP_PASSPHRASE:-} ]] && msg "  (passphrase from OMARCHY_BACKUP_PASSPHRASE)"
  else
    rm -f "$gpgout"
    warn "Encryption failed — backup left UNENCRYPTED ($(basename "$src"))."
  fi
  unset pass confirm 2>/dev/null || true
}

do_backup(){
  msg "Backup mosquitOmarchy (dated file in $BACKUP_DIR)"
  mkdir -p "$BACKUP_DIR"
  local ts dest tmp
  ts="$(date +%Y%m%d-%H%M%S)"
  dest="$BACKUP_DIR/omarchy-backup-$ts.tar.gz"
  tmp="$(mktemp -d)"

  # Encryption decision FIRST — before asking what to back up — so the
  # passphrase (entered twice, hidden) is set once and the rest of the flow
  # runs without further prompts. Empty → the archive stays unencrypted.
  local backup_pass="" _conf
  if [[ -n ${OMARCHY_BACKUP_PASSPHRASE:-} ]]; then
    backup_pass="$OMARCHY_BACKUP_PASSPHRASE"
  elif (( ! YES )); then
    if ask "Encrypt the archive (AES-256)? — it contains your KeePassXC passwords" y; then
      ask_passphrase "Backup passphrase"
      backup_pass="$ASK_PASSPHRASE"
      if [[ -z $backup_pass ]]; then
        warn "Empty passphrase — backup cancelled (returning to the menu)."
        rm -rf "$tmp"; return 1
      else
        ask_passphrase "Confirm passphrase"
        _conf="$ASK_PASSPHRASE"
        if [[ $backup_pass != "$_conf" ]]; then
          warn "Passphrases don't match — backup cancelled (returning to the menu)."
          rm -rf "$tmp"; return 1
        fi
      fi
    fi
  fi

  # --- 1. Core config files (paths relative to $HOME) ---
  local -a paths=()
  local p
  for p in .config/hypr .config/REAPER .config/windows .config/opencode \
           .config/omarchy/extensions .config/omarchy/shell.json .config/omarchy/menu \
           .config/omarchy/themes/achraff-67 .config/omarchy/plugins/custom.power \
           .config/omarchy/plugins/mosquito.indicators .config/omarchy/plugins/mosquito.confirm \
           .config/omarchy/plugins/jamjamjam-plugin .local/share/jamjamjam-plugin \
           .config/yabridgectl \
           .local/bin/reaper-launch .local/bin/windows-vm-usb \
           .local/bin/winvm .local/bin/ableton-live \
           .local/bin/ultra-save \
           .local/bin/power-helper \
           .local/state/ultra-save \
.config/systemd/user/yabridge-autosync.path \
            .config/systemd/user/yabridge-autosync.service \
            .local/bin/omagrab .config/omagrab \
            .local/bin/osx-kvm-installer.sh .local/bin/macos-vm-tui.sh \
            .local/bin/launch-macos-tui.sh \
            .local/bin/omarchy-vm .local/bin/setup-omarchy-vm.sh \
            .local/bin/omarchy-vm-tui.sh .local/bin/launch-omarchy-tui.sh \
            .local/share/icons/hicolor \
            .local/share/applications \
            .local/share/applications/omagrab.desktop; do
    [[ -e "$HOME/$p" ]] && paths+=("$p")
  done
  # Zen browser config (the ACTIVE profile's plugins + settings + chrome;
  # the profile is machine-scoped — the seed stays in the repo as the
  # canonical copy, this mirrors the live state).
  local zen_prof
  if zen_prof="$(zen_active_profile 2>/dev/null || true)"; then
    paths+=(".config/zen/profiles.ini")
    [[ -e "$HOME/.config/zen/installs.ini" ]] && paths+=(".config/zen/installs.ini")
    paths+=(".config/zen/$zen_prof/extensions")
    paths+=(".config/zen/$zen_prof/extension-preferences.json")
    paths+=(".config/zen/$zen_prof/extension-settings.json")
    [[ -e "$HOME/.config/zen/$zen_prof/chrome" ]] && paths+=(".config/zen/$zen_prof/chrome")
  fi
  # reaper-vstplugins*.ini may contain custom blacklist/paths
  local ini rel
  for ini in "$HOME"/.config/REAPER/reaper-vstplugins*.ini; do
    [[ -f $ini ]] && { rel="${ini#"$HOME/"}"; [[ -e "$HOME/$rel" ]] || paths+=("$rel"); }
  done
  # KeePassXC passwords + settings — ONLY if the app is installed, and the
  # tar archive goes to $BACKUP_DIR (outside the repo, $HOME/omarchy-backups):
  # password files must NEVER enter the repository. BACKUP_SKIP_KEEPASS=1
  # (the TUI's "KeePassXC: skip") leaves them out.
  if [[ -z ${BACKUP_SKIP_KEEPASS:-} ]] && pkg_has keepassxc; then
    if [[ -d "$HOME/.config/keepassxc" ]]; then
      paths+=(".config/keepassxc")
    fi
    if [[ -f "$HOME/Documents/Passwords.kdbx" ]]; then
      paths+=("Documents/Passwords.kdbx")
    fi
    ok "keepassxc passwords + settings included (writes only to $BACKUP_DIR, never the repo)"
  fi
  if ((${#paths[@]})); then
    ( cd "$HOME" && tar czf "$tmp/config-backup.tar.gz" "${paths[@]}" )
    ok "config-backup.tar.gz (${#paths[@]} items: config + bar + menus + yabridgectl + REAPER + Zen config + omagrab + keepassxc)"
  fi

  pacman -Qqe > "$tmp/pkglist.txt" 2>/dev/null && ok "pkglist.txt ($(wc -l < "$tmp/pkglist.txt") packages)"
  pacman -Qqm > "$tmp/aurlist.txt" 2>/dev/null && ok "aurlist.txt ($(wc -l < "$tmp/aurlist.txt") AUR packages)"

  # --- 3. Apps / tuis / webapps (selection for the "apps" module) ---
  # Offers to save the list of apps/tuis (catalogs: guis.catalog, tuis.catalog) and of the
  # installed Omarchy webapps. Fills apps.selected in the backup, which
  # apps/setup-apps.sh re-reads to reinstall the same selection (all checked).
  backup_apps_selection "$tmp"

  # --- 2. VST plugins (optional) ---
  local mode="${VST_MODE:-list}"
  if [[ $mode != "none" && $has_vst_sources == 1 ]]; then
    mkdir -p "$tmp/plugins"
    local sub total_files=0 total_bytes=0
    for sub in "${VST_DIRS[@]}"; do
      local sub_rel="${sub#"$HOME/"}"
      find "$sub" -type f -printf '%s\t%T@\t%p\n' 2>/dev/null >> "$tmp/plugins/manifest.txt" || true
    done
    total_files=$(wc -l < "$tmp/plugins/manifest.txt" 2>/dev/null || echo 0)
    total_bytes=$(awk '{s+=$1} END{printf "%.0f", s/1048576}' "$tmp/plugins/manifest.txt" 2>/dev/null || echo 0)
    { echo "# VST plugins detected: $total_files files (~${total_bytes} MB)"
      echo "# Source: $VST_SRC_BASE"
      echo "# Paths in yabridgectl:"
      [[ -f "$HOME/.config/yabridgectl/config.toml" ]] && cat "$HOME/.config/yabridgectl/config.toml"
    } | cat - "$tmp/plugins/manifest.txt" > "$tmp/plugins/manifest.txt.tmp" 2>/dev/null \
      && mv "$tmp/plugins/manifest.txt.tmp" "$tmp/plugins/manifest.txt" || true
    ok "plugins/manifest.txt ($total_files files, ~${total_bytes} MB)"
    if [[ $mode == "full" ]]; then
      local parent relbase
      parent="$(dirname "$VST_SRC_BASE")"
      relbase="$(basename "$VST_SRC_BASE")"
      if ((total_bytes > 500)); then
        warn "Size: ~${total_bytes} MB — archiving..."
      fi
      local -a tar_targets=()
      for sub in "${VST_DIRS[@]}"; do
        tar_targets+=("$relbase/${sub#"$VST_SRC_BASE/"}")
      done
      ( cd "$parent" && tar czf "$tmp/plugins/plugins-vst.tar.gz" "${tar_targets[@]}" 2>/dev/null )
      if [[ -f "$tmp/plugins/plugins-vst.tar.gz" ]]; then
        local arc_size; arc_size=$(du -h "$tmp/plugins/plugins-vst.tar.gz" | cut -f1)
        ok "plugins/plugins-vst.tar.gz ($arc_size) — full VST archive"
      else
        err "Failed to create plugins/plugins-vst.tar.gz (disk space?)"
      fi
    else
      warn "Inventory-only mode: rerun with --backup --vst-backup=full to include the real files (~${total_bytes} MB)."
    fi
  fi

  # --- 3. RESTORE.md (embedded help: manual OR via ./mosquitomarchy-setup.sh --restore) ---
  cat > "$tmp/RESTORE.md" <<EOF
# mosquitOmarchy restore

Dated backup: $(basename "$dest")
Created on: $(date '+%d/%m/%Y %H:%M:%S')

> This backup store is encrypted (AES-256, gpg --symmetric — see
> omarchy-backup-...tar.gz.gpg). Restoring asks for the passphrase you
> chose when creating the backup, and decrypts it before applying.

Recommended method:

    cd ~/mosquitOmarchy && ./mosquitomarchy-setup.sh --restore

(chronological choice of the backups; restores the config, and offers to
reinstall the packages and to put back the VST plugins).

## Manual method

If the backup file ends in .tar.gz.gpg, decrypt it first:

    gpg --batch --decrypt -o backup.tar.gz backup.tar.gz.gpg

## 1. Configuration

    tar xzf config-backup.tar.gz -C \$HOME
    systemctl --user daemon-reload
    systemctl --user enable yabridge-autosync.path

> Includes: Omarchy bar (shell.json), extensions menus, hypr, REAPER, windows,
> yabridgectl (registered VST folders), autosync units, ~/.local/bin wrappers,
> Zen config, and — when KeePassXC is installed — its settings + the
> Passwords.kdbx database (restored to their original places).

## 2. Official packages

    sudo pacman -S --needed - < pkglist.txt

## 3. AUR packages

    for pkg in \$(cat aurlist.txt); do yay -S "\$pkg"; done
EOF
  if [[ -f "$tmp/plugins/plugins-vst.tar.gz" ]]; then
    cat >> "$tmp/RESTORE.md" <<'EOF'

## 4. VST plugins (full archive)

    tar xzf plugins/plugins-vst.tar.gz -C $HOME   # restores the VST folders from the archive
    yabridgectl sync

> The DAW config files (REAPER reaper-vstplugins*.ini) are in
> config-backup.tar.gz. Open the DAW and rerun the plugin scan.
EOF
  elif [[ -f "$tmp/plugins/manifest.txt" ]]; then
    cat >> "$tmp/RESTORE.md" <<EOF

## 4. VST plugins (inventory only)

    # Inventory kept in plugins/manifest.txt — reinstall the plugins
    # from their official sites or re-copy the license archives into
    # the agreed folders ($VST_SRC_BASE's vst/vst3/clap, or the legacy
    # uppercase VST2/VST3/CLAP).
EOF
  else
    echo "" >> "$tmp/RESTORE.md"
    echo "No VST folder found to back up." >> "$tmp/RESTORE.md"
  fi
  cat >> "$tmp/RESTORE.md" <<'EOF'

## 5. Custom scripts

    cd ~/mosquitOmarchy && ./mosquitomarchy-setup.sh --status

> Re-read the report to see what still needs to be installed manually
> (plugins in the VM, iLok licenses, realtime re-login, DAW scan...).
EOF
  ok "RESTORE.md written"

  # --- 4. Final assembly: dated file, paths relative to $BACKUP_DIR ---
  ( cd "$tmp" && tar czf "$dest" . )
  rm -rf "$tmp"
  # --- 5. Encryption (passphrase already chosen at the start of do_backup) ---
  backup_encrypt "$dest" "$backup_pass"
  local final="${dest}.gpg"
  [[ -f $final ]] || final="$dest"
  local sz; sz=$(du -h "$final" | cut -f1)
  msg "Backup finished: $final ($sz)"
  echo "  Dedicated folder: $BACKUP_DIR      (list: ./mosquitomarchy-setup.sh --list)"
}

# ───────────────────────── 2. Chronological list ─────────────────────────
# Reads the date embedded in a backup name (works for .tar.gz and
# .tar.gz.gpg), prints "YYYY-MM-DD HH:MM" plus an [encrypted] marker.
backup_desc(){
  local name="$1" date enc=""
  if [[ $name == *.tar.gz.gpg ]]; then
    date="${name%.tar.gz.gpg}"; enc=" [encrypted]"
  else
    date="${name%.tar.gz}"
  fi
  date="${date#omarchy-backup-}"
  date="${date:0:4}-${date:4:2}-${date:6:2} ${date:9:2}:${date:11:2}"
  printf '%s%s' "$date" "$enc"
}

list_backups(){
  local -a files=()
  local f
  # lexicographically-sorted glob == chronological order (dated names)
  for f in "$BACKUP_DIR"/omarchy-backup-*.tar.gz*; do
    [[ -f $f ]] && files+=("$f")
  done
  if ((${#files[@]} == 0)); then
    warn "No backup in $BACKUP_DIR (./mosquitomarchy-setup.sh --backup to create one)."
    return 0
  fi
  msg "Dated backups in $BACKUP_DIR (most recent first):"
  local i
  for ((i=${#files[@]}-1; i>=0; i--)); do
    f="${files[$i]}"
    local name sz
    name="$(basename "$f")"
    sz=$(du -h "$f" | cut -f1)
    printf "  %s  %6s  %s\n" "$(backup_desc "$name")" "$sz" "$name"
  done
  echo ""
  echo "  Restore: ./mosquitomarchy-setup.sh --restore"
}

# ───────────────────────── 3. Restore ─────────────────────────
pick_backup(){
  # Returns the full path of the chosen file (interactive, chronological)
  local -a files=()
  local f
  for f in "$BACKUP_DIR"/omarchy-backup-*.tar.gz*; do
    [[ -f $f ]] && files+=("$f")
  done
  ((${#files[@]})) || { err "No backup found in $BACKUP_DIR."; return 1; }
  if command -v gum >/dev/null; then
    local -a display=()
    local name
    for ((i=${#files[@]}-1; i>=0; i--)); do
      name="$(basename "${files[$i]}")"
      [[ $name == *.gpg ]] && name="$name (encrypted)"
      display+=("$name")
    done
    local choice
    choice="$(gum choose "${display[@]}" --header "Which backup to restore? (chronological, most recent first)" --height 10)"
    [[ -n $choice ]] || return 1
    echo "$BACKUP_DIR/${choice% (encrypted)}"
  else
    echo "Available backups:"
    local i
    for ((i=${#files[@]}-1; i>=0; i--)); do
      f="${files[$i]}"
      printf "  %2d) %s\n" $(( ${#files[@]} - i )) "$(basename "$f")"
    done
    local n
    read -rp "Backup number [default 1 = the most recent]: " n
    n="${n:-1}"
    local idx=$(( ${#files[@]} - n ))
    echo "${files[$idx]}"
  fi
}

restore_backup(){
  local file="$1"
  [[ -f $file ]] || { err "Backup file not found: $file"; return 1; }
  msg "Restoring from $(basename "$file")"
  local tmp
  tmp="$(mktemp -d)"

  # --- Decrypt first if the backup is an encrypted .tar.gz.gpg ---
  # Same passphrase it was created with; OMARCHY_BACKUP_PASSPHRASE can supply
  # it non-interactively (avoids the prompt in CI / -y mode).
  local arc="$file"
  if [[ $file == *.tar.gz.gpg ]]; then
    if ! command -v gpg >/dev/null 2>&1; then
      err "Encrypted backup needs gpg (pacman -S gnupg) to decrypt."
      rm -rf "$tmp"; return 1
    fi
    local pass=""
    if [[ -n ${OMARCHY_BACKUP_PASSPHRASE:-} ]]; then
      pass="$OMARCHY_BACKUP_PASSPHRASE"
    elif [[ -t 0 ]]; then
      ask_passphrase "Passphrase for $(basename "$file") (the one you chose when creating the backup)"
      pass="$ASK_PASSPHRASE"
      [[ -n $pass ]] || {
        err "Empty passphrase — nothing was restored."
        rm -rf "$tmp"; return 1
      }
    else
      err "Encrypted backup and no OMARCHY_BACKUP_PASSPHRASE set — nothing to restore."
      rm -rf "$tmp"; return 1
    fi
    arc="$tmp/omarchy-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
    if ! printf '%s' "$pass" | gpg --batch --yes --decrypt --cipher-algo AES256 \
        --passphrase-fd 0 -o "$arc" "$file" 2>/dev/null; then
      err "Decryption failed (wrong passphrase?) — nothing was restored."
      rm -rf "$tmp"; return 1
    fi
    ok "Decrypted backup (AES-256)"
  fi

  tar xzf "$arc" -C "$tmp"

  # --- Configuration ---
  if [[ -f "$tmp/config-backup.tar.gz" ]]; then
    if ask "Restore the configuration (~/.config, ~/.local/bin wrappers, Omarchy bar)?" y; then
      # The battery plugins (custom.power, mosquito.indicators, mosquito.confirm) are recreated by the
      # battery module (setup-battery-management.sh): they are excluded
      # here to avoid restoring frozen copies, then the module reinstalls them.
      tar xzf "$tmp/config-backup.tar.gz" -C "$HOME" \
        --exclude='.config/omarchy/plugins/custom.power' \
        --exclude='.config/omarchy/plugins/mosquito.indicators' \
        --exclude='.config/omarchy/plugins/mosquito.confirm'
      systemctl --user daemon-reload 2>/dev/null || true
      if [[ -f "$HOME/.config/systemd/user/yabridge-autosync.path" ]]; then
        systemctl --user enable yabridge-autosync.path 2>/dev/null || true
      fi
      # The battery plugins are recreated via the battery script (idempotent).
      if [[ -d "$HOME/.config/omarchy/plugins/custom.power" ]] \
         && [[ -d "$HOME/.config/omarchy/plugins/mosquito.indicators" ]] \
         && [[ -d "$HOME/.config/omarchy/plugins/mosquito.confirm" ]]; then
        ok "Battery plugins restored as-is (re-adopted)"
      elif [[ -f "$SCRIPT_DIR/scripts/plugins/power-management/setup-battery-management.sh" ]] \
           && ([[ -x "$HOME/.local/bin/ultra-save" ]] || [[ -x "$HOME/.local/bin/power-helper" ]]); then
        warn "Battery plugins missing from the backup — recreated by the battery module."
        bash "$SCRIPT_DIR/scripts/plugins/power-management/setup-battery-management.sh" || \
          warn "Rerun 'battery' via ./mosquitomarchy-setup.sh to recreate the plugins."
      else
        warn "Battery plugins not restored — rerun the 'battery' module."
      fi
      ok "Configuration restored"
    fi
  fi

  # --- VST plugins ---
  if [[ -f "$tmp/plugins/plugins-vst.tar.gz" ]]; then
    if ask "Restore the VST plugins (archive extracts into this HOME)?" y; then
      tar xzf "$tmp/plugins/plugins-vst.tar.gz" -C "$HOME"
      if command -v yabridgectl >/dev/null; then
        yabridgectl sync 2>/dev/null && ok "yabridgectl sync done" || warn "yabridgectl sync to run yourself"
      fi
      ok "VST plugins restored"
    fi
  elif [[ -f "$tmp/plugins/manifest.txt" ]]; then
    warn "Plugin inventory kept in the archive (plugins/manifest.txt) —"
    warn "reinstall the plugins from their sources ($VST_SRC_BASE)."
  fi

  # --- Packages (interactive only; not in -y mode) ---
  if ((YES == 0)) && [[ -f "$tmp/pkglist.txt" ]]; then
    if ask "Reinstall the official packages (pkglist.txt, sudo + network)?" n; then
      mq_sudo pacman -S --needed - < "$tmp/pkglist.txt"
      ok "Official packages reinstalled"
    fi
    if [[ -s "$tmp/aurlist.txt" ]] && ask "Reinstall the AUR packages (aurlist.txt, yay)?" n; then
      local pkg
      while IFS= read -r pkg; do
        [[ -n $pkg ]] && yay -S "$pkg"
      done < "$tmp/aurlist.txt"
      ok "AUR packages reinstalled"
    fi
  fi

  # --- 4. Module dependencies (auto-installed from deps manifests in scripts/) ---
  # Reads every scripts/*/deps file, checks which packages are missing, and
  # installs them. Covers external scripts (omagrab: yt-dlp / ffmpeg / wl-clipboard),
  # browser configs (zen: zen-browser-bin) and anything future.
  install_module_deps

  rm -rf "$tmp"
  msg "Restore finished."
  echo "  Rerun ./mosquitomarchy-setup.sh --status to see what remains to install/complete."
}

# Restore-time deps manifest mechanism: every module/script may declare a
# `deps` file (one package per line, '#' = comment) listing the official
# packages it needs. On restore these are installed automatically (missing
# ones only), so scripts — e.g. omagrab (yt-dlp/ffmpeg/wl-clipboard), the zen
# module (zen-browser-bin) — always find their runtime requirements present.
collect_deps(){
  MODULE_DEPS=()
  local f line
  while IFS= read -r -d '' f; do
    while IFS= read -r line || [[ -n $line ]]; do
      line="${line%%$'\r'}"
      [[ -z $line || $line == \#* ]] && continue
      pkg_has "$line" || MODULE_DEPS+=("$line")
    done < "$f"
  done < <(find "$SCRIPT_DIR/scripts" -name deps -type f -print0 2>/dev/null)
}

install_module_deps(){
  collect_deps
  ((${#MODULE_DEPS[@]})) || { ok "Module deps: all present (manifest mechanism)."; return 0; }
  local uniq=() p found
  for p in "${MODULE_DEPS[@]}"; do
    found=0
    local q
    for q in "${uniq[@]:-}"; do [[ $q == "$p" ]] && found=1 && break; done
    ((found)) || uniq+=("$p")
  done
  if ((YES)); then
    mq_sudo pacman -S --needed --noconfirm "${uniq[@]}" \
      && ok "Module deps installed: ${uniq[*]}" || err "Module deps failed: ${uniq[*]}"
  else
    if ask "Install the missing module dependencies (${uniq[*]})?" y; then
      mq_sudo pacman -S --needed --noconfirm "${uniq[@]}" \
        && ok "Module deps installed: ${uniq[*]}" || err "Module deps failed: ${uniq[*]}"
    fi
  fi
}

restore_flow(){
  if [[ -n $RESTORE_FILE ]]; then
    local p="$RESTORE_FILE"
    [[ -f $p ]] || p="$BACKUP_DIR/$RESTORE_FILE"
    restore_backup "$p"
  else
    local picked
    if picked="$(pick_backup)"; then
      restore_backup "$picked"
    fi
  fi
}

# ───────────────────────── Per-module UNINSTALL (integrated) ─────────────────────────
# Cleanly removes what a module installed, with an INDIVIDUAL choice per module.
# Personal data (VST plugins, Windows VM, Ollama models) is NOT deleted without
# explicit confirmation (--purge). Uninstalled modules are recorded as excluded.
BIN_DIR="$HOME/.local/bin"
MOSQUITOMARCHY_APP_DIR="$SCRIPT_DIR/scripts/apps/mosquitomarchy"
APPS_DIR="$HOME/.local/share/applications"
MENU_DIR="$HOME/.config/omarchy/extensions"
MENU="$MENU_DIR/omarchy-menu.jsonc"
MENU_MOSQUITO_START="// >>> Omarchy_Custom_Scripts - mosquitOmarchy setup (managed by mosquitomarchy-setup.sh)"
MENU_MOSQUITO_END="// <<< Omarchy_Custom_Scripts - mosquitOmarchy setup (managed by mosquitomarchy-setup.sh)"
HYPR_DIR="$HOME/.config/hypr"
HYPRLAND="$HYPR_DIR/hyprland.lua"
BINDINGS="$HYPR_DIR/bindings.lua"
SHELL="$HOME/.config/omarchy/shell.json"
PLUG="$HOME/.config/omarchy/plugins"
SYSU="$HOME/.config/systemd/user"

bin_list(){ grep -l '' "$BIN_DIR"/$1 2>/dev/null | sed "s|$BIN_DIR/||"; }
custom_menu_blocks(){ grep -qF 'Omarchy_Custom_Scripts' "$MENU" 2>/dev/null; }

# Removes all blocks delimited by the Omarchy_Custom_Scripts markers.
# SAFE by design: it only drops marker-delimited zones (plus any stray marker
# line) and re-balances a trailing comma — it never deletes object keys by name,
# which previously orphaned their bodies and corrupted the JSON. Only for a full
# teardown; per-module uninstalls remove their own block.
remove_menu_blocks(){
  [[ -f $MENU ]] || return 0
  grep -qF 'Omarchy_Custom_Scripts' "$MENU" || return 0
  local tmp; tmp=$(mktemp)
  awk '
    />>>[[:space:]]*Omarchy_Custom_Scripts/ {skip=1}
    skip==0 {print}
    /<<<[[:space:]]*Omarchy_Custom_Scripts/ {skip=0}
  ' "$MENU" > "$tmp"
  # Any remaining lone marker comment (a block that lacked its closing marker).
  sed -i -E '/^[[:space:]]*\/\/[[:space:]]*(>>>|<<<)[[:space:]]*Omarchy_Custom_Scripts/d' "$tmp"
  # Re-balance a trailing comma left before the closing brace.
  sed -i -E ':a;N;$!ba;s/,([[:space:]]*)}/\1}/g' "$tmp"
  mv "$tmp" "$MENU"
  ok "Custom blocks removed from omarchy-menu.jsonc"
}

# ── Omarchy "Install" menu entry (mosquitOmarchy) ──
# Registers install.mosquitomarchy in omarchy-menu.jsonc (the Omarchy menu's
# Install submenu) with the same marked-block mechanism as the module setup
# scripts. Idempotent: the old block is replaced first. The menu row uses a
# Nerd Font glyph (Omarchy rows render font glyphs, not images); the mosquito
# PNG found in the repo is referenced as the icon asset.
mosquitomarchy_icon(){
  local f
  for f in "$SCRIPT_DIR/scripts/apps/ableton-move-manager/move-manager-icon.png" \
           "$SCRIPT_DIR/scripts/apps/audio-plugin-manager/audio-plugin-manager-icon.png"; do
    [[ -f $f ]] && { printf '%s' "$f"; return 0; }
  done
  return 1
}

menu_entry_block(){
  local icon_asset="${1:-}"
  cat <<MENU_EOF
$MENU_MOSQUITO_START
  // icon asset: ${icon_asset:-none found in the repo}
  "install.mosquitomarchy": {
    "icon": "\uf188",
    "label": "mosquitOmarchy",
    "description": "Configure this Omarchy machine (audio stack, VMs, themes, apps) — mosquitomarchy-setup launcher",
    "aliases": ["mosquito", "mosquitomarchy", "mosquitomarchy"],
    "when": "test -x $BIN_DIR/mosquitomarchy",
    "action": "$BIN_DIR/mosquitomarchy"
  },
$MENU_MOSQUITO_END
MENU_EOF
}

# ── mosquitOmarchy Go TUI (dispatcher + binary + actions backend) ──
# The Go/Bubble Tea TUI (scripts/apps/mosquitomarchy/tui-go/) replaced the old
# gum-based launcher_menu; the menu entry now launches the `mosquitomarchy`
# dispatcher, which opens the TUI in a terminal. Everything the menu entry
# needs must therefore exist: the compiled TUI, the dispatcher next to it,
# and the mosquitomarchy-actions backend beside them (the TUI resolves the
# backend from its own directory — see tui-go/actions.go).
#
# The backend is SYMLINKED, never copied: it computes the path to
# mosquitomarchy-setup.sh relative to itself (../../../), so a copy in
# ~/.local/bin would look for the source tree in ~/. A symlink also keeps the
# backend current with the repo. The TUI itself is compiled (a copy), like
# the other mosquito TUIs.
ensure_mosquitomarchy_tui(){
  mkdir -p "$BIN_DIR" 2>/dev/null || { warn "Cannot create $BIN_DIR"; return 1; }
  if command -v go >/dev/null 2>&1; then
    local tmp_out
    # Build to a temp file, then move into place (go build -o refuses to
    # clobber a destination that isn't a Go build output — see the same
    # pattern in setup-ableton-move-manager.sh).
    tmp_out="$(mktemp "$BIN_DIR/.mosquitomarchy-tui.XXXXXX")"
    if (cd "$MOSQUITOMARCHY_APP_DIR/tui-go" && go build -o "$tmp_out" .); then
      chmod +x "$tmp_out"
      mv -f "$tmp_out" "$BIN_DIR/mosquitomarchy-tui"
      ok "mosquitomarchy-tui built and deployed ($BIN_DIR/mosquitomarchy-tui)"
    else
      rm -f "$tmp_out"
      warn "mosquitomarchy-tui build failed — the menu can't launch until it builds (re-run after fixing the cause)."
    fi
  else
    warn "go not found — mosquitomarchy-tui (Go/Bubble Tea) won't be built. The TUI is the ONLY interface, so the menu can't launch until it is. Install go (e.g. via mise, or sudo pacman -S go) and re-run."
  fi
  ln -sf "$MOSQUITOMARCHY_APP_DIR/mosquitomarchy-actions" "$BIN_DIR/mosquitomarchy-actions"
  if [[ -f $MOSQUITOMARCHY_APP_DIR/mosquitomarchy ]]; then
    cp -f "$MOSQUITOMARCHY_APP_DIR/mosquitomarchy" "$BIN_DIR/mosquitomarchy"
    chmod +x "$BIN_DIR/mosquitomarchy"
    bash -n "$BIN_DIR/mosquitomarchy" || { err "Invalid syntax: mosquitomarchy dispatcher"; return 1; }
  else
    warn "mosquitomarchy dispatcher not found in $MOSQUITOMARCHY_APP_DIR — the menu entry can't launch."
  fi
  # Crash diagnosis: the tool the notification clicks, plus the skill any AI
  # reads (symlinked so every harness scanning ~/.agents/skills finds it).
  if [[ -f $MOSQUITOMARCHY_APP_DIR/mosquitomarchy-agent-crash ]]; then
    chmod +x "$MOSQUITOMARCHY_APP_DIR/mosquitomarchy-agent-crash"
    ln -sf "$MOSQUITOMARCHY_APP_DIR/mosquitomarchy-agent-crash" "$BIN_DIR/mosquitomarchy-agent-crash"
  fi
  if [[ -d $MOSQUITOMARCHY_APP_DIR/skills/mosquitomarchy-crash ]]; then
    mkdir -p "$HOME/.agents/skills"
    ln -sfn "$MOSQUITOMARCHY_APP_DIR/skills/mosquitomarchy-crash" "$HOME/.agents/skills/mosquitomarchy-crash"
  fi
  ensure_mosquitomarchy_float_rule
}

# ── mosquitOmarchy TUI window rule ──
# The TUI's foot window uses app-id org.omarchy.mosquitomarchy-tui, which is
# not in Omarchy's floating-window whitelist, so it would open TILED and
# reflow the workspace. Float + center it (the mosquito managers' convention).
ensure_mosquitomarchy_float_rule(){
  [[ -f $HYPRLAND ]] || return 0
  grep -qF -- 'mosquitomarchy-tui-floating' "$HYPRLAND" && return 0
  cat >> "$HYPRLAND" <<'HYPR'

-- >>> mosquitomarchy-tui-floating >>> float the mosquitOmarchy TUI
-- (its app-id isn't in Omarchy's floating whitelist, so it would open tiled)
o.window("org.omarchy.mosquitomarchy-tui", { float = true, center = true })
-- <<< mosquitomarchy-tui-floating <<<
HYPR
  hyprctl reload >/dev/null 2>&1 || true
  ok "mosquitOmarchy TUI float rule added to hyprland.lua"
}

remove_mosquitomarchy_float_rule(){
  [[ -f $HYPRLAND ]] || return 0
  grep -qF -- 'mosquitomarchy-tui-floating' "$HYPRLAND" || return 0
  local tmp; tmp=$(mktemp)
  awk '
    /-- >>> mosquitomarchy-tui-floating/ {skip=1; next}
    /-- <<< mosquitomarchy-tui-floating/ {skip=0; next}
    !skip {print}
  ' "$HYPRLAND" > "$tmp" && mv "$tmp" "$HYPRLAND"
  hyprctl reload >/dev/null 2>&1 || true
}

# JSONC validation (comments + trailing commas stripped): python3 when present,
# jq otherwise. Read-only — never rewrites the file.
menu_json_valid(){
  [[ -f $MENU ]] || return 1
  local cleaned rc=0
  if command -v python3 >/dev/null 2>&1; then
    cleaned="$(mktemp)"
    python3 - "$MENU" > "$cleaned" 2>/dev/null <<'PY' || rc=$?
import json, re, sys
t = open(sys.argv[1], encoding="utf-8").read()
t = re.sub(r'^\s*//[^\n]*', '', t, flags=re.M)
t = re.sub(r',(\s*[}\]])', r'\1', t)
json.dump(json.loads(t), sys.stdout)
PY
    ((rc == 0)) && command -v jq >/dev/null 2>&1 \
      && { jq -e . "$cleaned" >/dev/null 2>&1 || rc=$?; }
    rm -f "$cleaned"
  elif command -v jq >/dev/null 2>&1; then
    jq -e . "$MENU" >/dev/null 2>&1 || rc=$?
  fi
  return $rc
}

# Removes every mosquitOmarchy menu entry: the managed marked block AND any
# legacy unmarked "install.mosquitomarchy" object left by an older installer.
# Duplicate JSON keys are legal-ish but the LAST one wins silently, so a
# stale unmarked entry (e.g. the old xdg-terminal-exec action) would shadow
# the dispatcher. Called before install_menu_entry re-adds the fresh block.
# The unmarked object is matched by brace counting (the key line opens `{`;
# the object ends when the depth returns to zero), so its multiline aliases
# array is handled correctly.
strip_mosquitomarchy_menu_entry(){
  [[ -f $MENU ]] || return 0
  local tmp; tmp=$(mktemp)
  awk -v s="$MENU_MOSQUITO_START" -v e="$MENU_MOSQUITO_END" '
    $0 == s {inblock=1; next}
    $0 == e {inblock=0; next}
    inblock {next}
    !skip && $0 ~ /^[[:space:]]*"install\.mosquitomarchy"[[:space:]]*:[[:space:]]*\{/ {
      o=gsub(/\{/,"{"); c=gsub(/\}/,"}");
      depth=o-c;
      if (depth<=0) next
      skip=1; next
    }
    skip {
      o=gsub(/\{/,"{"); c=gsub(/\}/,"}");
      depth+=o-c;
      if (depth<=0) skip=0
      next
    }
    {print}
  ' "$MENU" > "$tmp" && mv "$tmp" "$MENU"
}

install_menu_entry(){
  mkdir -p "$MENU_DIR" 2>/dev/null || { warn "Menu directory not writable: $MENU_DIR"; return 1; }
  # The menu entry launches the mosquitomarchy dispatcher, so the TUI +
  # dispatcher + actions backend must be in place first.
  ensure_mosquitomarchy_tui || true
  strip_mosquitomarchy_menu_entry
  local icon_asset block open_line start_line end_line tmp
  icon_asset="$(mosquitomarchy_icon || true)"
  if [[ -n $icon_asset ]]; then
    ok "Mosquito icon found: $icon_asset"
  else
    warn "No mosquito icon in the repo — using the generic Nerd Font bug glyph."
  fi
  block="$(menu_entry_block "$icon_asset")"

  if [[ ! -f $MENU ]]; then
    printf '{\n%s\n}\n' "$block" > "$MENU"
  elif grep -qF "$MENU_MOSQUITO_START" "$MENU"; then
    start_line=$(grep -nF "$MENU_MOSQUITO_START" "$MENU" | cut -d: -f1 | head -1)
    end_line=$(grep -nF "$MENU_MOSQUITO_END" "$MENU" | cut -d: -f1 | head -1)
    if [[ -z $start_line || -z $end_line || $end_line -le $start_line ]]; then
      warn "Inconsistent mosquitOmarchy markers in $MENU — manual fix needed."
      return 1
    fi
    tmp=$(mktemp)
    head -n $((start_line - 1)) "$MENU" > "$tmp"
    printf '%s\n' "$block" >> "$tmp"
    tail -n +$((end_line + 1)) "$MENU" >> "$tmp"
    mv "$tmp" "$MENU"
  else
    open_line=$(grep -nE '^[[:space:]]*\{[[:space:]]*$' "$MENU" | cut -d: -f1 | head -1 || true)
    if [[ -z $open_line ]]; then
      warn "Could not find the opening brace in $MENU — entry not added."
      return 1
    fi
    tmp=$(mktemp)
    head -n "$open_line" "$MENU" > "$tmp"
    printf '%s\n' "$block" >> "$tmp"
    tail -n +$((open_line + 1)) "$MENU" >> "$tmp"
    mv "$tmp" "$MENU"
  fi

  if menu_json_valid; then
    ok "Omarchy Install menu: mosquitOmarchy entry ensured"
  else
    warn "omarchy-menu.jsonc no longer validates — fix $MENU manually."
  fi
  return 0
}

# Removes one or more .desktop entries
rm_desktops(){ local d; for d in "$@"; do rm -f "$APPS_DIR/$d"; done
  command -v update-desktop-database >/dev/null && update-desktop-database "$APPS_DIR" 2>/dev/null || true; }

# Removes a user systemd unit
rm_unit(){ local u="$1"; systemctl --user disable --now "$u" 2>/dev/null || true
  rm -f "$SYSU/$u.service" "$SYSU/$u.timer" "$SYSU/$u.path"; }

un_reaper(){
  info "Uninstalling REAPER"
  rm -f "$BIN_DIR/reaper-launch" "$BIN_DIR/reaper-satellite"  # reaper-satellite: leftover from older installs
  rm_desktops cockos-reaper.desktop reaper.desktop
  [[ -f "$APPS_DIR/cockos-reaper.desktop" ]] || ok "REAPER wrapper + entry removed"
  if (( YES || PURGE )); then
    mq_sudo pacman -Rns --noconfirm reaper 2>/dev/null \
      && ok "reaper package removed" || warn "package not removed (sudo required or already absent)"
    mq_sudo pacman -Rns --noconfirm xwayland-satellite 2>/dev/null || true  # leftover from older installs, best-effort
  fi
}

un_audio(){
  info "Uninstalling the audio stack (yabridge / autosync)"
  rm_unit yabridge-autosync
  ok "yabridge autosync removed"

  # mosquito Audio Plugin Manager: dispatcher + TUI + actions + shared core
  # (today's manager), every pre-rename binary (vst-manager / mosquito-vst-manager),
  # the menu entries, the hicolor icon and the Hyprland float rule for the TUI.
  rm -f "$BIN_DIR/vst-install" "$BIN_DIR/vst-manager" "$BIN_DIR/vst-manager-native" "$BIN_DIR/vst-manager-tui"
  rm -f "$BIN_DIR/mosquito-vst-manager" "$BIN_DIR/mosquito-vst-manager-native" "$BIN_DIR/mosquito-vst-manager-tui"
  rm -f "$BIN_DIR/mosquito-audio-plugin-manager" "$BIN_DIR/mosquito-audio-plugin-manager-tui" \
        "$BIN_DIR/mosquito-audio-plugin-manager-actions" "$BIN_DIR/lib-audio-plugin-manager-core.sh"
  rm_desktops mosquito-audio-plugin-manager.desktop mosquito-vst-manager.desktop \
               vst-manager.desktop vst-install.desktop
  rm -f "$HOME/.local/share/icons/hicolor/256x256/apps/mosquito-audio-plugin-manager.png"
  if [[ -f "$HYPRLAND" ]] && grep -qF -- 'mosquito-audio-plugin-manager-tui-setup' "$HYPRLAND"; then
    local tmp=$(mktemp)
    awk '
      /-- >>> mosquito-audio-plugin-manager-tui-setup/ {skip=1; next}
      /-- <<< mosquito-audio-plugin-manager-tui-setup/ {skip=0; next}
      !skip {print}
    ' "$HYPRLAND" > "$tmp" && mv "$tmp" "$HYPRLAND"
    hyprctl reload >/dev/null 2>&1 || true
    ok "Audio manager Hyprland float rule removed"
  fi
  ok "Audio Plugin Manager (binaries + menu + icon + Hyprland rule) removed"

  # custom bitwig.jar -> restores .stock if present (sudo)
  if [[ $((YES||PURGE)) -eq 1 ]] && [[ -f /opt/bitwig-studio/bin/bitwig.jar.stock ]]; then
    mq_sudo cp -f /opt/bitwig-studio/bin/bitwig.jar.stock /opt/bitwig-studio/bin/bitwig.jar 2>/dev/null \
      && ok "bitwig.jar restored (stock)" || warn "bitwig.jar restore not done (sudo required)"
  fi

  # Resolve the ACTUAL plugins root (same logic the audio stack uses — the
  # reorg moved the default from ~/VST to ~/Music/Audio Plugins; purging
  # only the old legacy folder would silently leave every real plugin).
  local purge_root=""
  if [[ -n "${AUDIOSTACK_VST_ROOT:-}" ]]; then
    purge_root="$AUDIOSTACK_VST_ROOT"
  elif find "$HOME/Music/Audio Plugins" -mindepth 2 \( -iname '*.dll' -o -iname '*.vst3' -o -iname '*.clap' \) 2>/dev/null | grep -q .; then
    purge_root="$HOME/Music/Audio Plugins"
  elif find "$HOME/VST" -mindepth 2 \( -iname '*.dll' -o -iname '*.vst3' -o -iname '*.clap' \) 2>/dev/null | grep -q .; then
    purge_root="$HOME/VST"
  elif [[ -d "$HOME/Music/Audio Plugins/vst3" ]]; then
    purge_root="$HOME/Music/Audio Plugins"
  else
    purge_root="$HOME/VST"
  fi

  if (( PURGE )); then
    mq_sudo pacman -Rns --noconfirm bitwig-studio yabridge yabridgectl wine-staging winetricks realtime-privileges lib32-glibc lib32-libxcb 2>/dev/null \
      && ok "audio packages removed" || warn "audio packages not removed (sudo required)"
    if [[ -d "$purge_root" ]]; then
      warn "Deleting local VST plugins (purge): rm -rf $purge_root"
      rm -rf "$purge_root" 2>/dev/null && ok "$purge_root deleted"
    fi
    rm -rf "$HOME/.config/audio-plugin-manager" "$HOME/.local/state/audio-plugin-manager" \
      && ok "Audio manager prefs/state removed (purge)"
  else
    warn "Data kept: $purge_root (plugins) and the audio packages. Rerun with --purge to remove everything."
  fi
}

un_windows_vm(){
  info "Uninstalling Windows VM (launcher / winvm / menus)"
  rm -f "$BIN_DIR/windows-vm-usb" "$BIN_DIR/winvm"
  rm_desktops windows-vm.desktop windows-vm-usb.desktop
  ok "launcher + winvm manager removed"
  if (( PURGE )) && [[ -d "$HOME/.config/windows" ]]; then
    rm -rf "$HOME/.config/windows" && ok "VM config (~/.config/windows) deleted"
  fi
}

un_macos_vm(){
  info "Uninstalling macOS VM (helpers / menu / keybinding / window rule)"
  bash "$MACOS_VM_DIR/setup-macos-vm.sh" --remove || warn "setup-macos-vm.sh --remove reported a problem"
  ok "macOS VM helpers + menu + keybinding removed"
  if (( PURGE )) && [[ -d "$HOME/OSX-KVM" ]]; then
    rm -rf "$HOME/OSX-KVM" && ok "VMs (~/OSX-KVM) deleted"
  fi
}

un_omarchy_vm(){
  info "Uninstalling Omarchy VM (helpers / menu / keybinding / window rule)"
  if (( PURGE )); then
    bash "$OMARCHY_VM_DIR/setup-omarchy-vm.sh" --remove --purge || warn "setup-omarchy-vm.sh --remove reported a problem"
  else
    bash "$OMARCHY_VM_DIR/setup-omarchy-vm.sh" --remove || warn "setup-omarchy-vm.sh --remove reported a problem"
  fi
  ok "Omarchy VM helpers + menu + keybinding removed"
}

un_ableton(){
  local title="Ableton Live"
  if [[ -f "$HOME/.local/bin/ableton-live" || -d "$HOME/.wine-ableton" ]]; then
    title="Native Linux Ableton Live (ableton-linux)"
    info "Uninstalling $title"
    if (( PURGE )); then
      # asks the official installer to remove runtime + prefix (--delete-prefix)
      # otherwise runtime only (--keep-prefix keeps Live, licenses and projects)
      local run=""
      for f in "$HOME"/mosquitOmarchy/scripts/apps/ableton/install-ableton-latest.run; do
        [[ -f $f ]] && run=$f
      done
      if [[ -n $run ]]; then
        sh "$run" uninstall --delete-prefix
      else
        warn "install-ableton-latest.run not found — partial manual removal."
      fi
      rm -f "$HOME/.local/share/applications/ableton-live.desktop"
      ok "Native Ableton removed (--delete-prefix)"
    else
      warn "Prefix ~/.wine-ableton, Live, licenses and projects KEPT (--purge to remove everything)."
      rm -f "$BIN_DIR/ableton-live"
      rm_desktops ableton-live.desktop
      ok "Launcher and menu entries removed (prefix and Live kept)"
    fi
  fi
  # RemoteApp VM (old workflow)
  if [[ -f "$BIN_DIR/ableton-vm" || -f "$APPS_DIR/ableton-vm.desktop" ]]; then
    info "Uninstalling Ableton Live (RemoteApp VM — old workflow)"
    rm -f "$BIN_DIR/ableton-vm"
    rm_desktops ableton-vm.desktop
    rm -f "$HOME/.config/windows/ableton.conf"
    ok "Ableton RemoteApp removed"
  fi
}

un_ableton_move_converter(){
  info "Uninstalling ableton-move-manager module"
  # Menu entry (+ udev rule when root): delegated to the module setup.
  bash "$MOVE_CONVERTER_DIR/setup-ableton-move-manager.sh" --uninstall || true
  rm -f "$BIN_DIR"/{mosquito-move-manager,move-bundle-to-midi,move-udev-refresh,move-manager-webapp}
  rm -f "$BIN_DIR"/{mosquito-move-manager-tui,mosquito-move-manager-actions,lib-move-manager-core.sh}
  rm -f "$BIN_DIR/ableton-move-converter"  # stale pre-rename binary, if still present
  rm -f "$HOME/.local/share/icons/hicolor/256x256/apps/ableton-move-manager.png"
  rm -f "$HOME/.local/share/applications/move-session.desktop"
  ok "menu entry + binaries + webapp icon removed (mosquito-move-manager[-tui/-actions], move-bundle-to-midi, move-udev-refresh, move-manager-webapp)"
  if (( PURGE )); then
    rm -rf "$HOME/.config/move-session" "$HOME/.local/state/move-session"
    ok "move-session prefs + state removed (purge)"
  else
    warn "Data kept: ~/.config/move-session (prefs) and ~/.local/state/move-session (log/state). --purge to remove."
  fi
}

un_ollama(){
  info "Uninstalling Ollama / REAPER helpers / OpenCode commands"
  rm -f "$BIN_DIR"/ollama-{load-small,load-big,unload,status}
  rm -rf "$HOME/.config/opencode/commands"
  systemctl disable ollama 2>/dev/null || true
  if (( PURGE )); then
    mq_sudo systemctl stop ollama 2>/dev/null || true
    mq_sudo pacman -Rns --noconfirm ollama 2>/dev/null || true
    rm -rf "$HOME/.ollama" && ok "~/.ollama (models) deleted (purge)"
  else
    warn "Data kept: ~/.ollama (models) and the ollama package. --purge to remove everything."
  fi
  ok "helpers + OpenCode commands removed"
}

# ─── remove-all-ai (a REVERSABLE uninstall entry) ────────────────────────
# Strips the AI surface from Omarchy:
#   • ollama loaders / REAPER models / opencode commands,
#   • the Omarchy menu "Agents" plugin (icon, bar entry, panel),
#   • the mosquito AI-diagnosis crash notifications (crash-notify off).
# REVERSIBLE from Setup by re-applying run_restore_ai (nothing is deleted
# except what the user explicitly purged — the agents plugin and the
# crash-notify flag are toggles, so the restore is a flip back).
ai_state_on(){
  [[ -f "$HOME/.local/state/mosquitomarchy/remove-all-ai" ]]
}

un_remove_ai() {
  info "Removing every AI integration from this Omarchy (reversible from Setup)"
  # 1) the ollama helpers + OpenCode commands (the ollama module's pieces)
  un_ollama >/dev/null 2>&1 || true
  mark_excluded ollama
  # 2) the Omni Agents plugin in the Omarchy menu (QML plugin: icon + panel)
  omarchy plugin disable omarchy.agents >/dev/null 2>&1 || true
  ok "omarchy.agents plugin disabled in the Omarchy menu/bar"
  # 3) Crash AI-diagnosis toasts off (crash-notify state file)
  "$SCRIPTS/apps/mosquitomarchy/mosquitomarchy-actions" crash-notify off &&
    ok "Crash notifications with AI diagnosis: OFF" || true
  mkdir -p "$HOME/.local/state/mosquitomarchy"
  printf '1\n' > "$HOME/.local/state/mosquitomarchy/remove-all-ai"
  ok "AI removed from this Omarchy: agents hidden, AI-diag toasts gone, ollama loaders gone"
}

run_restore_ai() {
  info "Re-enabling AI pieces removed by 'remove-all-ai'"
  rm -f "$HOME/.local/state/mosquitomarchy/remove-all-ai"
  "$SCRIPTS/apps/mosquitomarchy/mosquitomarchy-actions" crash-notify on &&
    ok "Crash notifications with AI diagnosis: RE-ENABLED" || true
  omarchy plugin enable omarchy.agents >/dev/null 2>&1 || true
  ok "Agents plugin re-enabled in the Omarchy menu/bar"
  warn "ollama loaders were NOT restored — re-run the 'ollama' module to bring them back."
}

un_guitarpro(){
  info "Uninstalling Guitar Pro 8 (wine)"
  rm -f "$BIN_DIR/guitarpro"
  rm_desktops guitarpro.desktop
  ok "launcher + menu shortcut removed"
  # Dedicated wine prefix: kept by default (data/scores) — deleted on --purge.
  if (( PURGE )) && [[ -d "$HOME/.wine-guitarpro8" ]]; then
    rm -rf "$HOME/.wine-guitarpro8" && ok "wine prefix ~/.wine-guitarpro8 deleted (purge)"
  else
    [[ -d "$HOME/.wine-guitarpro8" ]] && warn "wine prefix ~/.wine-guitarpro8 kept (--purge to delete it)."
  fi
}

un_davinci(){
  # Delegates to davinci/uninstall-davinci.sh: removes launcher + menu + libav
  # patch + /opt/resolve (sudo) + OFX SpectraFilm, without the project data.
  if [[ -x /opt/resolve/bin/resolve || -x "$BIN_DIR/davinci-resolve" ]]; then
    info "Uninstalling DaVinci Resolve"
    if command -v sudo >/dev/null && [[ -d /opt/resolve ]] \
       && [[ $EUID -eq 0 || -n ${SUDO_USER:-} || $(mq_sudo -v 2>/dev/null; echo $?) -eq 0 ]]; then
      bash "$SCRIPT_DIR/scripts/apps/davinci/uninstall-davinci.sh" -y || warn "uninstall-davinci.sh ran into problems"
    else
      bash "$SCRIPT_DIR/scripts/apps/davinci/uninstall-davinci.sh" -y || true
      warn "System part (/opt/resolve) not removed: run  sudo bash \"$SCRIPT_DIR/scripts/apps/davinci/uninstall-davinci.sh\""
    fi
  else
    ok "DaVinci Resolve not installed — nothing to do"
  fi
}

un_handbrake(){
  info "Uninstalling HandBrake (module handbrake)"
  # Hyprland rules block
  if [[ -f "$HYPRLAND" ]] && grep -qF -- 'Omarchy_Custom_Scripts_Handbrake' "$HYPRLAND"; then
    local tmp=$(mktemp)
    awk '
      /-- >>> Omarchy_Custom_Scripts_Handbrake/ {skip=1; next}
      /-- <<< Omarchy_Custom_Scripts_Handbrake/ {skip=0; next}
      !skip {print}
    ' "$HYPRLAND" > "$tmp" && mv "$tmp" "$HYPRLAND"
    ok "HandBrake block removed from hyprland.lua"
  else
    ok "No HandBrake block in hyprland.lua"
  fi
  [[ -f "$HYPRLAND" ]] && hyprctl reload >/dev/null 2>&1 || true
  # Presets: only the "Omarchy" category is removed; the user's presets stay.
  if [[ -f "$HOME/.config/ghb/presets.json" ]] && command -v python3 >/dev/null 2>&1; then
    python3 - "$HOME/.config/ghb/presets.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
d = [r for r in d if r.get("PresetName") != "Omarchy"]
open(p, "w", encoding="utf-8").write(json.dumps(d, indent=2))
PY
    ok "Omarchy preset category removed (user presets kept)"
  fi
  if (( PURGE )); then
    mq_sudo pacman -Rns --noconfirm handbrake handbrake-cli 2>/dev/null \
      && ok "handbrake/handbrake-cli packages removed" \
      || warn "packages not removed (sudo required or already absent)"
  else
    warn "handbrake packages kept (--purge to remove them)."
  fi
}

un_apps(){
  # Delegates to apps/uninstall-apps.sh: removes the apps / tuis / webapps of the
  # catalogs (per type: gui/ tui/ webapps/) — packages via pacman -Rns +
  # webapps via omarchy webapp remove.
  if [[ -f "$SCRIPT_DIR/scripts/apps/gui/guis.catalog" || -f "$SCRIPT_DIR/scripts/apps/tui-tools/tuis.catalog" \
     || -f "$SCRIPT_DIR/scripts/apps/webapps/webapps.catalog" ]] \
     && [[ -x "$SCRIPT_DIR/scripts/apps/uninstall-apps.sh" ]]; then
    info "Uninstalling the apps / tuis / webapps ("apps" module)"
    bash "$SCRIPT_DIR/scripts/apps/uninstall-apps.sh" --all -y || warn "uninstall-apps.sh ran into problems"
  else
    ok "apps module not present — nothing to do"
  fi
}

un_battery(){
  info "Uninstalling battery (ultra-save / power-helper / mega-caffeine / custom.power)"

  # Full uninstall path of the battery module: stops an active coffee mode,
  # clears its state, removes the menu entry
  # (also removes udev+sudoers when run as root).
  if [[ -f "$SCRIPT_DIR/scripts/plugins/power-management/setup-battery-management.sh" ]]; then
    bash "$SCRIPT_DIR/scripts/plugins/power-management/setup-battery-management.sh" --remove || true
  else
    warn "setup-battery-management.sh not found — menu/sudoers/udev not cleaned by it."
  fi

  rm_unit ultra-save-monitor
  rm -f "$BIN_DIR/ultra-save" "$BIN_DIR/ultra-save-monitor" "$BIN_DIR/power-helper" \
        "$BIN_DIR/mega-caffeine" \
        "$BIN_DIR/ultra-save-setup" "$BIN_DIR/ultra-save.sudoers"
  rm -rf "$HOME/.local/state/ultra-save" "$HOME/.local/state/caffeine"
  ok "binaries + battery/caffeine state removed (ultra-save, power-helper, mega-caffeine)"

  # Omarchy custom plugins (custom.power, mosquito.indicators, mosquito.confirm)
  omarchy plugin disable custom.power 2>/dev/null || true
  omarchy plugin disable "$USER.power" 2>/dev/null || true
  omarchy plugin disable mosquito.indicators 2>/dev/null || true
  omarchy plugin disable mosquito.confirm 2>/dev/null || true
  rm -rf "$PLUG/custom.power" "$PLUG/$USER.power" "$PLUG/mosquito.indicators" "$PLUG/mosquito.confirm"
  ok "custom plugins removed (custom.power / mosquito.indicators / mosquito.confirm)"

  # Normalize shell.json back to the stock power/lock widgets — done HERE (the
  # module that owns the plugins), never in un_shared_menu on every uninstall.
  clean_plugins

  # System (sudo): sudoers, udev, /usr/local/bin helper
  if (( YES || PURGE )) && [[ $EUID -eq 0 || -n ${SUDO_USER:-} ]]; then
    rm -f /etc/sudoers.d/battery-management /etc/udev/rules.d/99-lenovo-charge-threshold.rules /usr/local/bin/power-helper
    udevadm control --reload 2>/dev/null || true
    ok "sudoers + udev rule + /usr/local/bin helper removed"
  else
    warn "System part (sudoers/udev) not removed: run  sudo bash $0"
  fi
}

un_brightness(){
  info "Uninstalling brightness (backlight + bindings)"
  rm -f "$BIN_DIR/backlight"
  if [[ -f $BINDINGS ]] && grep -qF -- 'Omarchy_Custom_Scripts_Brightness' "$BINDINGS"; then
    local tmp=$(mktemp)
    awk '
      /-- >>> Omarchy_Custom_Scripts_Brightness/ {skip=1; next}
      /-- <<< Omarchy_Custom_Scripts_Brightness/ {skip=0; next}
      !skip {print}
    ' "$BINDINGS" > "$tmp" && mv "$tmp" "$BINDINGS"
    ok "Brightness block removed from bindings.lua (Omarchy gets its default bindings back)"
  else
    ok "no Brightness block in bindings.lua"
  fi
  [[ -f "$BINDINGS" ]] && hyprctl reload >/dev/null 2>&1 || true
}

un_keyboard_backlight(){
  info "Uninstalling keyboard backlight (kbd-toggle) "
  rm -f "$BIN_DIR/kbd-toggle"
  rm -f "${XDG_RUNTIME_DIR:-/tmp}/mosquito-kbd-toggle.level" "${XDG_RUNTIME_DIR:-/tmp}/kbd-toggle.level"
  ok "kbd-toggle helper removed"
}

un_touchpad(){
  info "Uninstalling touchpad config (per-device)"
  [[ -f "$HYPR_DIR/touchpad.lua" ]] && { rm -f "$HYPR_DIR/touchpad.lua"; ok "touchpad.lua deleted"; } \
                                   || ok "touchpad.lua already absent."
  if [[ -f "$HYPRLAND" ]] && grep -qF -- 'Omarchy_Custom_Scripts_Touchpad' "$HYPRLAND"; then
    local start_line end_line tmp
    start_line=$(grep -nF -- '-- >>> Omarchy_Custom_Scripts_Touchpad' "$HYPRLAND" | cut -d: -f1 | head -1)
    end_line=$(grep -nF -- '-- <<< Omarchy_Custom_Scripts_Touchpad' "$HYPRLAND" | cut -d: -f1 | head -1)
    if [[ -n $start_line && -n $end_line && $end_line -gt $start_line ]]; then
      tmp=$(mktemp)
      head -n $((start_line - 1)) "$HYPRLAND" > "$tmp"
      tail -n +$((end_line + 1)) "$HYPRLAND" >> "$tmp"
      mv "$tmp" "$HYPRLAND"
      ok "hypr.touchpad require block removed from hyprland.lua (check: hyprctl reload)"
    else
      warn "Inconsistent markers in $HYPRLAND, manual cleanup needed."
    fi
  else
    ok "No touchpad block in hyprland.lua."
  fi
  [[ -f "$HYPRLAND" ]] && hyprctl reload >/dev/null 2>&1 || true
}
un_superfile(){
  info "Uninstalling SuperFile default-file-manager wiring"
  if [[ -x "$SUPERFILE_DIR/setup-superfile.sh" ]]; then
    bash "$SUPERFILE_DIR/setup-superfile.sh" --remove
  else
    warn "$SUPERFILE_DIR/setup-superfile.sh not found — nothing to revert."
  fi
}
un_zen(){
  # Removes ONLY what the zen module deployed (seed extensions + settings +
  # chrome). The browser and its profile stay — the browser itself is managed
  # by the "apps" module (zen-browser-bin).
  info "Uninstalling the Zen config module (seed plugins + settings + chrome)"
  if [[ -x "$ZEN_DIR/setup-zen.sh" ]]; then
    bash "$ZEN_DIR/setup-zen.sh" --remove ${YES:+-y}
  else
    warn "$ZEN_DIR/setup-zen.sh not found — nothing to revert."
  fi
  warn "zen-browser-bin itself stays: uninstall it via the 'apps' module (sudo pacman -Rns zen-browser-bin)."
}
un_jamjamjam_plugin(){
  info "Uninstalling the JamJamJam plugin (jamjamjam-plugin)"
  if [[ -x "$JAMJAMJAM_PLUGIN_DIR/setup-jamjamjam-plugin.sh" ]]; then
    bash "$JAMJAMJAM_PLUGIN_DIR/setup-jamjamjam-plugin.sh" --remove \
      || warn "setup-jamjamjam-plugin.sh --remove reported a problem"
  else
    warn "setup-jamjamjam-plugin.sh not found — cleaning up directly."
    rm -rf "$HOME/.config/omarchy/plugins/jamjamjam-plugin"
  fi
  if (( PURGE )); then
    rm -rf "$HOME/.local/share/jamjamjam-plugin"
    ok "JamJamJam plugin + data dir removed."
  else
    rm -rf "$HOME/.local/state/jamjamjam-plugin" 2>/dev/null || true
    warn "Data kept: ~/.local/share/jamjamjam-plugin. --purge to remove."
  fi
}
un_live_mode(){
  info "Uninstalling the live mode (live-mode)"
  if [[ -x "$LIVE_MODE_DIR/setup-live-mode.sh" ]]; then
    bash "$LIVE_MODE_DIR/setup-live-mode.sh" --uninstall \
      || warn "setup-live-mode.sh --uninstall reported a problem"
  else
    warn "setup-live-mode.sh not found — cleaning up directly."
    rm -f "$BIN_DIR/live-mode" "$BIN_DIR/live-mode-watch" "$BIN_DIR/live-mode-root" "$BIN_DIR/mosquito-live-mode-tui"
  fi
}
un_mx_master(){
  info "Uninstalling MX Master thumb→SUPER (logiops)"
  if command -v logid >/dev/null 2>&1 && systemctl is-enabled logid >/dev/null 2>&1; then
    mq_sudo systemctl disable --now logid >/dev/null 2>&1 && ok "logid.service disabled+stopped" \
      || warn "logid.service not running/enabled."
  else
    ok "logid.service already absent."
  fi
  if [[ -f /etc/logid.cfg.bak ]]; then
    if mq_sudo mv /etc/logid.cfg.bak /etc/logid.cfg; then ok "/etc/logid.cfg restored from backup"; fi
  elif [[ -f /etc/logid.cfg ]]; then
    if mq_sudo rm -f /etc/logid.cfg; then ok "/etc/logid.cfg removed"; fi
  else
    ok "/etc/logid.cfg already absent."
  fi
}

un_keepassxc(){
  # KeePassXC secret service uninstall: hand the D-Bus Secret Service name
  # back to gnome-keyring (the omarchy default). The keepassxc DATABASE and
  # settings are NEVER touched, and this does NOT reinstall the gnome-keyring
  # package if the user had asked setup to uninstall it — `sudo pacman -S
  # gnome-keyring` restores the package (its settings were kept on disk).
  info "Uninstalling the KeePassXC secret service (restores gnome-keyring)"
  bash "$SCRIPTS/apps/keepassxc/setup-keepassxc-integration.sh" --remove
}

un_keybindings(){
  # SUPER keybindings managed by mosquitOmarchy: removes the whole marker block
  # (same block format as the brightness module).
  info "Uninstalling the SUPER keybindings (mosquitOmarchy block)"
  if [[ -f "$BINDINGS" ]] && grep -qF -- 'Omarchy_Custom_Scripts_Keys' "$BINDINGS"; then
    local tmp=$(mktemp)
    awk '
      /-- >>> Omarchy_Custom_Scripts_Keys/ {skip=1; next}
      /-- <<< Omarchy_Custom_Scripts_Keys/ {skip=0; next}
      !skip {print}
    ' "$BINDINGS" > "$tmp" && mv "$tmp" "$BINDINGS"
    ok "Keybindings block removed from bindings.lua (Omarchy defaults back)"
  else
    ok "No Omarchy_Custom_Scripts keybindings block in bindings.lua"
  fi
  [[ -f "$BINDINGS" ]] && hyprctl reload >/dev/null 2>&1 || true
}

un_mosquitomarchy_update(){
  info "Uninstalling the update watchdog (post-boot hook)"
  local hookd="$HOME/.config/omarchy/hooks/post-boot.d" removed=0 h
  for h in "$hookd"/*; do
    [[ -f $h ]] || continue
    if rg -q -e 'mosquitomarchy' "$h" 2>/dev/null; then
      rm -f "$h" && { ok "Hook removed: $(basename "$h")"; removed=1; }
    fi
  done
  ((removed)) || warn "No mosquitomarchy post-boot hook found."
  rm -rf "$HOME/.local/state/omarchy-update-check" 2>/dev/null || true
}

un_achraff(){
  info "Uninstalling the Achraff 67 theme (theme / unlock logo / plymouth)"
  drop_locktitle   # leftovers of the old lock/theme sync (if present)
  if mq_sudo -n true 2>/dev/null; then
    omarchy-plymouth-set-by-theme default 2>/dev/null || true
  else
    warn "Plymouth: run  omarchy-plymouth-set-by-theme default  (password)"
  fi
  omarchy-plymouth-set --refresh-default 2>/dev/null || true
  # Removes the custom lock plugin (or residual <user>.lock clone)
  omarchy plugin disable custom.lock 2>/dev/null || true
  omarchy plugin disable "$USER.lock" 2>/dev/null || true
  rm -rf "$PLUG/custom.lock" "$PLUG/$USER.lock"
  # Restores the default Omarchy theme
  omarchy theme set "Default" >/dev/null 2>&1 || true
  ok "theme + unlock logo + plymouth restored (default theme)"
}

# Removes the leftovers of the old lock/theme sync (daemon + scripts).
# The lock screen then uses the stock Omarchy lock (password bar only).
drop_locktitle(){
  systemctl --user disable --now omarchy-lock-title 2>/dev/null || true
  rm -f "$HOME/.config/systemd/user/omarchy-lock-title.service"
  rm -rf "$HOME/.config/omarchy/lock-title"
  rm -f "$HOME/.config/omarchy/lock-title-daemon.sh" "$HOME/.config/omarchy/lock-title.sh"
  systemctl --user daemon-reload 2>/dev/null || true
}

clean_plugins(){
  # Normalizes the Omarchy plugin state in shell.json to go back to stock:
  # removes our clones (custom./<user>. power/lock) from bars/plugins/disabled
  # and re-enables the original Omarchy plugins (omarchy.lock, omarchy.power).
  [[ -f $SHELL ]] || return 0
  command -v jq >/dev/null 2>&1 || { warn "jq missing — Omarchy plugin state not normalized"; return 0; }
  local ours='custom\.(power|lock)|mosquito\.(indicators|confirm)|'"$USER"'\.(power|lock)'
  # Null-safe: .plugins and .disabledPlugins may be absent (null) — the old jq
  # then failed with "Cannot iterate over null" and aborted the uninstall (and
  # tripped the crash reporter). Guard both, and never abort on a jq error.
  if jq '
    ( .. | objects | select(has("moduleList")) )
      |= ( .moduleList = ((.moduleList // []) | map(select(.id != "custom.power" and .id != "'"$USER"'.power"))) )
    | .plugins = ((.plugins // []) | map(select(
        (if type == "object" then (.id // "") else (. | tostring) end)
        | test("^(custom|mosquito|'$USER')\\.(power|lock|indicators|confirm)$") | not)))
    | .disabledPlugins = ((.disabledPlugins // []) | map(select(
        (if type == "object" then (.id // "") else (. | tostring) end)
        | test("^(custom|mosquito|'$USER')\\.(power|lock|indicators|confirm)$") | not)))
  ' "$SHELL" > "$SHELL.tmp" 2>/dev/null; then
    mv "$SHELL.tmp" "$SHELL"
  else
    rm -f "$SHELL.tmp"
    warn "jq normalization skipped (shell.json unexpected shape) — left unchanged."
  fi

  command -v omarchy >/dev/null 2>&1 && {
    omarchy plugin enable omarchy.lock >/dev/null 2>&1 || true
    omarchy plugin enable omarchy.power >/dev/null 2>&1 || true
    omarchy plugin enable omarchy.indicators >/dev/null 2>&1 || true
  }
  ok "Omarchy plugin state (power/lock) restored to stock"
}

un_shared_menu(){
  # Called after EVERY module uninstall. It must NOT touch shell.json: doing so
  # (clean_plugins below) removed the custom.power widget from the bar on any
  # module uninstall — the "battery plugin disappeared" bug. Plugin state is
  # normalized by the module that owns the plugins (battery), not here.
  return 0
}

uninstall_module(){
  local id="$1"
  mq_sudo_prime >/dev/null 2>&1 || true   # one prompt for the whole uninstall
  case $id in
    reaper) un_reaper ;;
    audio) un_audio ;;
    windows-vm) un_windows_vm ;;
    macos-vm) un_macos_vm ;;
    omarchy-vm) un_omarchy_vm ;;
    ableton) un_ableton ;;
    guitarpro) un_guitarpro ;;
    davinci-resolve) un_davinci ;;
    ableton-move-manager) un_ableton_move_converter ;;
    handbrake) un_handbrake ;;
    apps) un_apps ;;
    ollama) un_ollama ;;
    remove-ai) un_remove_ai ;;
    battery) un_battery ;;
    brightness) un_brightness ;;
    keyboard-backlight) un_keyboard_backlight ;;
    achraff) un_achraff ;;
    touchpad) un_touchpad ;;
    mx-master) un_mx_master ;;
    keepassxc) un_keepassxc ;;
    keybindings) un_keybindings ;;
    mosquitomarchy-update) un_mosquitomarchy_update ;;
    superfile) un_superfile ;;
    zen) un_zen ;;
    jamjamjam-plugin) un_jamjamjam_plugin ;;
    live-mode) un_live_mode ;;
    mosquitomarchy) un_mosquitomarchy ;;
    *) err "Unknown module: $id"; return 1 ;;
  esac
  # Remember the module as voluntarily uninstalled → not re-proposed
  # (unless --include=<module>).
  record_excluded "$id"
  hr
}

uninstall_chooser(){
  info "Selection of the modules to uninstall (Tab/x = check, Enter = validate)"
  local -a selected=()
  if command -v gum >/dev/null; then
    local line
    while IFS= read -r line; do
      [[ -z $line ]] && continue
      selected+=("${line%%:*}")
    done < <(gum choose --no-limit --header "Modules to UNINSTALL (Tab/x = check, Enter = confirm):" "${MODULES[@]}" | cut -d: -f1)
  else
    echo "Available modules:"
    local i=1
    for row in "${MODULES[@]}"; do printf "  %d) %s\n" "$i" "${row#*:}"; i=$((i+1)); done
    echo "  a) Uninstall EVERYTHING"
    echo "  q) Quit"
    read -rp "Numbers to uninstall (e.g.: 1 3 6) : " nums
    if [[ $nums == a ]]; then { for row in "${MODULES[@]}"; do selected+=("${row%%:*}"); done; }
    elif [[ $nums != q ]]; then
      local n
      for n in $nums; do
        row="${MODULES[$((n-1))]:-}"; [[ -n $row ]] && selected+=("${row%%:*}")
      done
    fi
  fi
  [[ ${#selected[@]} == 0 ]] && { warn "Nothing selected."; return 1; }
  echo "Uninstalling: ${selected[*]}"
  read -rp "Confirm? [y/N] " r
  [[ ${r:-n} =~ ^[oOyY] ]] || { warn "Cancelled."; return 1; }
  local id
  for id in "${selected[@]}"; do uninstall_module "$id"; done
  un_shared_menu
}

uninstall_all(){
  info "Uninstalling ALL modules"
  if (( ! PURGE )); then warn "Data (VST/VM/Ollama/prefixes) kept. Add --purge to delete everything."; fi
  local row
  for row in "${MODULES[@]}"; do uninstall_module "${row%%:*}"; done
  un_shared_menu
}

# ───────────────────────── Module execution ─────────────────────────
RESULTS=()
# Counts every failed module/fix/catalog install. The non-interactive backend
# reads it to exit non-zero on failure, so the TUI can never report a false
# success just because a failure had no "✗" marker in the streamed output.
MODULE_FAILURES=0
run_module(){
  local id="$1"; shift
  msg "Module '$id' — running"
  if "$@"; then RESULTS+=("$id:ok"); ok "Module $id: completed without error"
  else
    RESULTS+=("$id:fail")
    MODULE_FAILURES=$((MODULE_FAILURES + 1))
    err "Module $id: ERROR (see messages above)"
  fi
  hr
}

# Script paths by category (the individual apps and shared stack live in
# scripts/apps/, one folder per app; the other modules each in scripts/).
SCRIPTS="$SCRIPT_DIR/scripts"
APPS_DIR="$SCRIPTS/apps"
AUDIO_PLUGIN_MANAGER_DIR="$APPS_DIR/audio-plugin-manager"
BITWIG_DIR="$APPS_DIR/bitwig"
REAPER_DIR="$APPS_DIR/reaper"
LLM_DIR="$SCRIPTS/LLM"
VM_DIR="$SCRIPTS/windows-vm"
MACOS_VM_DIR="$SCRIPTS/macos-vm"
OMARCHY_VM_DIR="$SCRIPTS/omarchy-vm"
ABLETON_DIR="$APPS_DIR/ableton"
GUITARPRO_DIR="$APPS_DIR/guitarpro"
DAVINCI_DIR="$APPS_DIR/davinci"
HANDBRAKE_DIR="$APPS_DIR/handbrake"
MOVE_CONVERTER_DIR="$SCRIPTS/apps/ableton-move-manager"
BATTERY_DIR="$SCRIPTS/plugins/power-management"
DISPLAY_DIR="$SCRIPTS/fixes"
TOUCHPAD_DIR="$SCRIPTS/fixes"
MXMASTER_DIR="$SCRIPTS/fixes"
SUPERFILE_DIR="$SCRIPTS/apps/superfile"
THEME_DIR="$SCRIPTS/theme"
ZEN_DIR="$SCRIPTS/apps/zen"
JAMJAMJAM_PLUGIN_DIR="$SCRIPTS/plugins/jamjamjam"
LIVE_MODE_DIR="$SCRIPTS/plugins/live-mode"

# ─────────────────── Required system libraries (Ableton-linux) ─────────────
# gstreamer (1.x) + base/good are prerequisites of the Ableton-linux runtime.
# Installed without asking (required); gstreamer0.10 (legacy) is not useful
# and is not handled here.
REQUIRED_LIBS=(gstreamer gst-plugins-base gst-plugins-good)

run_required_libs(){
  msg "Required system libraries (gstreamer + base/good plugins)"
  local missing=() p
  for p in "${REQUIRED_LIBS[@]}"; do
    pkg_has "$p" || missing+=("$p")
  done
  if ((${#missing[@]})); then
    mq_sudo -v || { err "Password required to install: ${missing[*]}"; return 1; }
    mq_sudo pacman -S --needed --noconfirm "${missing[@]}" || {
      err "Installation failed: ${missing[*]}"; return 1; }
    ok "Installed: ${missing[*]}"
  else
    ok "Already present: ${REQUIRED_LIBS[*]}"
  fi
}

run_reaper(){ bash "$REAPER_DIR/setup-reaper.sh"; }

run_audio(){
  # setup-bitwig.sh (Bitwig 6.0 Beta 6 via local .deb / AUR + custom bitwig.jar),
  # then setup-reaper.sh, then the local wine/yabridge stack + the Audio Plugin
  # Manager (scripts/apps/audio-plugin-manager) — without VM link.
  ok "(audio) launching setup-bitwig.sh (Bitwig 6.0 Beta 6)"
  if ! bash "$BITWIG_DIR/setup-bitwig.sh" $([[ $YES == 1 ]] && echo -y); then
    err "audio module: setup-bitwig.sh failed (see messages above)."
    return 1
  fi
  ok "(audio) launching setup-reaper.sh (REAPER)"
  bash "$REAPER_DIR/setup-reaper.sh" $([[ $YES == 1 ]] && echo -y)
  bash "$AUDIO_PLUGIN_MANAGER_DIR/setup-audio-stack.sh" $([[ $YES == 1 ]] && echo -y)
  return 0
}

run_windows_vm(){ bash "$VM_DIR/setup-windows-vm.sh" $([[ $YES == 1 ]] && echo -y); }
run_macos_vm(){ bash "$MACOS_VM_DIR/setup-macos-vm.sh" $([[ $YES == 1 ]] && echo -y); }
run_omarchy_vm(){
  # Install the SETUP only (manager + menu entry + keybinding): the heavy VM
  # creation (ISO download, disk) happens from the Omarchy VM manager
  # (Omarchy menu -> Setup -> Omarchy VM), not from here.
  bash "$OMARCHY_VM_DIR/setup-omarchy-vm.sh" --setup-only $([[ $YES == 1 ]] && echo -y)
}

run_ableton(){
  bash "$ABLETON_DIR/setup-ableton.sh" $([[ $YES == 1 ]] && echo -y)
}

run_guitarpro(){
  # Guitar Pro 8 via wine: dedicated prefix + corefonts + PipeWire audio + launcher.
  # Ends with a menu shortcut. The installer (guitar-pro-8-setup.exe) must
  # be present in GuitarPro/.
  bash "$GUITARPRO_DIR/setup-guitarpro.sh" $([[ $YES == 1 ]] && echo -y)
}

run_davinci(){
  # DaVinci Resolve (Studio or free): the Blackmagic zip must be placed in
  # davinci/ (the file name picks the edition). H.264/H.265 handled according to
  # the edition; the libav patch / FFmpeg plugin proposed. With -y: auto libav
  # patch (free), FFmpeg plugin not forced (Studio), SpectraFilm not forced.
  bash "$DAVINCI_DIR/setup-davinci.sh" $([[ $YES == 1 ]] && echo -y)
}

run_ableton_move_converter(){
  # Ableton Move → Move Manager → Ableton → Bitwig: import sets, save .als exports
  # or export MIDI; native Omarchy prompts; Trigger > Music menu entry; udev plug
  # notification as root. The module setup cleans legacy duplicates by itself.
  bash "$MOVE_CONVERTER_DIR/setup-ableton-move-manager.sh" $([[ $YES == 1 ]] && echo -y)
}

run_handbrake(){
  # HandBrake Qt GUI + CLI, H.264/H.265 encoders, presets sync (presets/ folder)
  # and Hyprland compatibility rules. Presets must NOT be running in the GUI.
  bash "$HANDBRAKE_DIR/setup-handbrake.sh" $([[ $YES == 1 ]] && echo -y)
}

run_apps(){
  # Apps / tuis / webapps from a backup selection (apps.selected).
  # interactive: backup choice + checkbox (all checked by default, can uncheck)
  # + adding apps from the catalog. With -y: most recent backup selection, everything.
  bash "$APPS_DIR/setup-apps.sh" $([[ $YES == 1 ]] && echo -y)
}

PROTECT_OMARCHY_PKGS=(omacut omacalc omawrite)   # Omarchy core utilities, never removed

run_remove_preinstalls(){
  # Removes the Omarchy preinstalls ("stock" apps) while AVOIDING the personal
  # apps listed in the "apps" module (libreoffice, pinta, obsidian,
  # lazydocker...). The user's webapps and tuis are preserved (only the "stock"
  # packages are removed; omarchy-webapp-remove-all and omarchy-tui-remove-all
  # are not swept to avoid destroying personal apps/tuis).
  #
  # The "stock" list is omarchy-remove-preinstalls's (omarchy-install-preinstalls).
  local -a stock=(aether cliamp libreoffice-fresh xournalpp pinta obsidian \
                  obs-studio kdenlive moonlight-qt lazydocker omacut omacalc omawrite)
  local -a keep=() drop=() keep_note=() p
  # Protected apps: those the "apps" module installs (installed catalogs
  # or a backup selection) + the Omarchy core utilities.
  local catfiles=("$SCRIPT_DIR/scripts/apps/gui/guis.catalog" "$SCRIPT_DIR/scripts/apps/tui-tools/tuis.catalog") catf
  local line kind name
  for catf in "${catfiles[@]}"; do
    [[ -f $catf ]] || continue
    while IFS= read -r line || [[ -n $line ]]; do
      line="${line%%$'\r'}"
      [[ -z $line || $line == \#* ]] && continue
      kind="${line%%[ |]*}"
      [[ $kind == APP || $kind == TUI ]] || continue
      name="${line#*[ ]}"; name="${name%%|*}"
      keep+=("$name")
    done < "$catf"
  done
  keep+=("${PROTECT_OMARCHY_PKGS[@]}")

  for p in "${stock[@]}"; do
    if pkg_has "$p"; then
      local protect=0 q
      for q in "${keep[@]}"; do [[ $q == "$p" ]] && protect=1 && break; done
      if ((protect)); then keep_note+=("$p"); else drop+=("$p"); fi
    fi
  done
  if ((${#drop[@]} == 0)); then
    warn "No stock preinstall to remove (or all protected: ${keep_note[*]:-})."
    return 0
  fi

  msg "Removing Omarchy preinstalls (stock): ${drop[*]}"
  msg "  Protected (personal apps / utilities): ${keep_note[*]:-}"
  mq_sudo pacman -Rns --noconfirm "${drop[@]}" \
    && ok "Preinstalls removed: ${drop[*]}" \
    || { err "Failed to remove preinstalls."; return 1; }
}

preinstalls_removable(){
  # Says whether stock preinstalls (unprotected) are still installed
  local -a stock=(aether cliamp libreoffice-fresh xournalpp pinta obsidian \
                  obs-studio kdenlive moonlight-qt lazydocker)
  local p
  for p in "${stock[@]}"; do pkg_has "$p" && return 0; done
  return 1
}

run_ollama(){
  warn "Heavy downloads (~14 GB of models) — let it run."
  mq_sudo bash "$LLM_DIR/setup-ollama-audio-expert.sh"
}

run_battery(){ bash "$BATTERY_DIR/setup-battery-management.sh"; }
run_brightness(){ bash "$DISPLAY_DIR/fix-optimized-brightness.sh"; }
run_achraff(){ bash "$THEME_DIR/create-theme.sh" "$THEME_DIR/Wallpapers/achraf67.png"; }
run_keyboard_backlight(){ bash "$DISPLAY_DIR/fix-keyboard-backlight-menu.sh"; }
run_touchpad(){ bash "$TOUCHPAD_DIR/fix-touchpad.sh" $([[ $YES == 1 ]] && echo -y); }
run_superfile(){ bash "$SUPERFILE_DIR/setup-superfile.sh" $([[ $YES == 1 ]] && echo -y); }
run_zen(){ bash "$ZEN_DIR/setup-zen.sh" $([[ $YES == 1 ]] && echo -y); }
run_mx_master(){ bash "$MXMASTER_DIR/fix-mx-master.sh" $([[ $YES == 1 ]] && echo -y); }
run_keepassxc(){
  bash "$SCRIPTS/apps/keepassxc/setup-keepassxc-integration.sh" $([[ $YES == 1 ]] && echo -y)
}

run_keybindings(){
  # The keybindings manager is PART of mosquitOmarchy now (the TUI's
  # Keybindings screen — there is no external script anymore). A batch install
  # just makes sure the launcher binding exists; the full manager is the TUI
  # screen (Enter on the keybindings row).
  kb_ensure "SUPER + ALT + M" "mosquitOmarchy" "$HOME/.local/bin/mosquitomarchy" cmd
  if (( KB_CHANGED )); then
    kb_reload || true
  fi
  ok "Keybindings module ready — manage bindings from the TUI's Keybindings screen."
}
run_mosquitomarchy_update(){
  bash "$SCRIPTS/mosquitomarchy-update/setup-mosquitomarchy-update.sh" $([[ $YES == 1 ]] && echo -y)
}
run_jamjamjam_plugin(){
  # jamjamjam-plugin bar plugin (real-time key/BPM/chord analysis,
  # guitar fretboard, MIDI chord mode + synth). Idempotent, no prompts.
  bash "$JAMJAMJAM_PLUGIN_DIR/setup-jamjamjam-plugin.sh"
}

run_live_mode(){
  # Live mode (performance session): stay-awake + thermal + routing in
  # scratchpad. Idempotent; -y installs non-interactively (same flag the
  # move-manager / audio scripts accept). Needs root for the sudoers part.
  bash "$LIVE_MODE_DIR/setup-live-mode.sh" $([[ $YES == 1 ]] && echo -y)
}

run_mosquitomarchy(){
  # The manager TUI (the interface this script drives): build the Go binary,
  # deploy the dispatcher + desktop entry + float rule + post-boot hook.
  # Idempotent, non-interactive; the former standalone install-tui.sh WAS
  # this (the logic now lives in scripts/apps/mosquitomarchy/install-tui.sh
  # and is reused here as a module).
  bash "$SCRIPT_DIR/scripts/apps/mosquitomarchy/install-tui.sh" -y
}

un_mosquitomarchy(){
  bash "$SCRIPT_DIR/scripts/apps/mosquitomarchy/install-tui.sh" --remove
}

# ───────────────────────── Interactive selection ─────────────────────────
select_modules(){
  # One by one: install what is missing/partial, offer to update what is there,
  # always respect the modules you voluntarily uninstalled (unless re-offered).
  local row id state label default
  SELECTED=()
  load_excluded
  apply_includes

  local -a updated=()
  msg "Modules — completed ones are offered for UPDATE below, uninstalled ones are excluded:"
  for row in "${MODULES[@]}"; do
    id="${row%%:*}"; label="${row#*:}"
    state="$(module_state "$id")"
    if is_excluded "$id"; then
      [[ $state == ok ]] && continue
      warn "Module '$id' was uninstalled by you — skipped."
      if ask "Re-install it anyway?" n; then
        SELECTED+=("$id")
        unexclude "$id"
        ok "Module re-selected: $id"
      fi
      continue
    fi
    if [[ $state == ok ]]; then
      updated+=("$id")
      continue
    fi
    [[ $state == na ]] && continue
    default=y
    ask "Install module '$id' ($label)?" "$default" && { SELECTED+=("$id"); ok "Module selected: $id"; }
  done
  if ((${#updated[@]})); then
    echo
    if ((UPDATE_OK)); then
      SELECTED+=("${updated[@]}")
      ok "(auto) update of the present modules: ${updated[*]}"
    elif ask "Update the already-installed modules (re-run, idempotent)?" n; then
      SELECTED+=("${updated[@]}")
      ok "Update selected: ${updated[*]}"
    else
      ok "Present modules kept as-is."
    fi
  fi
}

# ───────────────────────── Final report ─────────────────────────
final_report(){
  # When driven by the mosquitOmarchy TUI, the per-module output + the error
  # prompt already say what happened; the launcher's FINAL REPORT and the
  # "Left to do by hand" checklist are orchestration noise there.
  [[ -n ${MOSQUITOMARCHY_TUI:-} ]] && return 0
  hr; msg "FINAL REPORT"
  local r fails=0 total=0
  for r in "${RESULTS[@]:-}"; do
    [[ -z $r ]] && continue
    total=$((total+1))
    if [[ $r == *:ok ]]; then printf " ${G}✓${N} %s\n" "${r%:ok}"
    else printf " ${R}✗${N} %s\n" "${r%:fail}"; fails=$((fails+1)); fi
  done
  ((total == 0)) && warn "No module selected — nothing was executed."
  hr
  if ((fails == 0)); then
    ok "Everything ran fine."
  else
    err "$fails module(s) failed — rerun ./mosquitomarchy-setup.sh to resume where it gets stuck."
  fi
  echo ""
  msg "Left to do by hand (depending on the installed modules):"
  echo " • The Windows VM itself: omarchy-windows-vm install (long download)."
  echo " • The Omarchy VM itself: install Omarchy from the ISO, then mark the install done (omarchy-vm-tui)."
  echo " • iLok-type plugin licenses: separate Wine (Linux) / VM activation."
  echo " • Rerun './scripts/apps/audio-plugin-manager/setup-audio-stack.sh --tweaks' after each new VST plugin."
  echo " • Re-login required if the realtime group was just joined."
  echo " • Ableton Linux: first setup in Live — Settings > Audio > Device PipeASIO."
  echo " • Bitwig 6.0 Beta 6: license via the app at first launch."
  echo " • DaVinci Resolve: Studio activation at first launch (file/dongle);"
  echo "     free version → check the H.264 import/export (libav patch)."
  echo " • Achraff (achraff module): the Plymouth BOOT screen to apply by hand:"
  echo "     omarchy-plymouth-set-by-theme \"achraff-67\"   (asks for the password)"
  hr
}

# ───────────────────────── Module execution loop (shared) ─────────────────────────
exec_modules(){
  # Runs the ids accumulated in SELECTED through run_module (shared by the
  # interactive flow, the -y auto pass AND the launcher menu's update/setup).
  # Prime sudo ONCE for the whole selection (one prompt), so every module's root
  # steps reuse the cache instead of prompting again.
  mq_sudo_prime >/dev/null 2>&1 || true
  local id
  for id in "${SELECTED[@]:-}"; do
    case $id in
      reaper)  run_module reaper run_reaper ;;
      audio)   run_module audio run_audio ;;
      windows-vm) run_module windows-vm run_windows_vm ;;
      macos-vm) run_module macos-vm run_macos_vm ;;
      omarchy-vm) run_module omarchy-vm run_omarchy_vm ;;
      ableton) run_module ableton run_ableton ;;
      guitarpro) run_module guitarpro run_guitarpro ;;
      davinci-resolve) run_module davinci-resolve run_davinci ;;
      ableton-move-manager) run_module ableton-move-manager run_ableton_move_converter ;;
      handbrake) run_module handbrake run_handbrake ;;
      apps) run_module apps run_apps ;;
      ollama)  run_module ollama run_ollama ;;
      remove-ai) run_module remove-ai run_restore_ai ;;
      battery) run_module battery run_battery ;;
      brightness) run_module brightness run_brightness ;;
      achraff) run_module achraff run_achraff ;;
      keyboard-backlight) run_module keyboard-backlight run_keyboard_backlight ;;
      touchpad) run_module touchpad run_touchpad ;;
      mx-master) run_module mx-master run_mx_master ;;
      keepassxc) run_module keepassxc run_keepassxc ;;
      keybindings) run_module keybindings run_keybindings ;;
      mosquitomarchy-update) run_module mosquitomarchy-update run_mosquitomarchy_update ;;
      superfile) run_module superfile run_superfile ;;
      zen) run_module zen run_zen ;;
      jamjamjam-plugin) run_module jamjamjam-plugin run_jamjamjam_plugin ;;
      live-mode) run_module live-mode run_live_mode ;;
      mosquitomarchy) run_module mosquitomarchy run_mosquitomarchy ;;
      *)
        # A selected id nothing handles must never look like a success.
        MODULE_FAILURES=$((MODULE_FAILURES + 1))
        err "Unknown module: $id — nothing was installed."
        ;;
    esac
  done
}

# ───────────────────────── Launcher menu (interactive) ─────────────────────────
# Shown at launch when you are in a terminal and did not pass a flag (-y / a MODE).
# Six actions in a loop: status / update / setup (by category) / remove /
# backup+restore (which explains itself BEFORE asking, like the update zone) /
# quit. Each action returns to the menu; quit leaves. The original step-by-step
# wizard stays available via --update / -y / the category choices.

# Categories of the "setup" action. id|label|modules (space-separated module ids).
CATEGORIES=(
  "apps|Apps|reaper audio ableton guitarpro davinci-resolve handbrake superfile zen keepassxc"
  "tuis|TUIs|"
  "webapps|Webapps|"
  "plugins|Plugins|mosquitomarchy jamjamjam-plugin battery brightness keyboard-backlight touchpad mx-master"
  "fixes|Quick fixes|"
  "mosquito|mosquito|"
  "keybindings|Keybindings|keybindings"
  "lame|lame language models (ai..)|ollama remove-ai"
  "themes|Themes|achraff"
  "vms|VMs|windows-vm macos-vm omarchy-vm"
  "menu|Menu entry|"
)

launcher_pick(){ # $1 = header, rest = one label per line → echoes the picked label
  local header="$1"; shift
  local -a labels=("$@")
  if [[ -z ${LAUNCHER_NUMERIC:-} ]] && command -v gum >/dev/null 2>&1; then
    gum choose "${labels[@]}" --header "$header" --height "${#labels[@]}" || true
  else
    # Called from $(...): the menu MUST go to stderr (else it is swallowed into
    # the captured result); only the selected label reaches stdout.
    echo >&2
    echo "$header" >&2
    local i=1 l
    for l in "${labels[@]}"; do printf '  %2d) %s\n' "$i" "$l" >&2; i=$((i+1)); done
    local n
    read -rp "Choice [1-${#labels[@]}, Enter = quit]: " n >&2 || n=""
    if [[ "$n" =~ ^[0-9]+$ ]] && ((n >= 1 && n <= ${#labels[@]})); then
      echo "${labels[$((n-1))]}"
    fi
  fi
}

# Multi-select variant of launcher_pick: $1 = header, $2 = pre-selected value
# ("*" = everything). Echoes one selected label per line (nothing = cancelled /
# none). Tab or "x" toggles in gum; the numbered fallback reads space-separated
# indexes. Never uses "space" — gum 2.x does not bind it.
launcher_multiselect(){
  local header="$1" preselect="${2:-}"; shift 2
  local -a labels=("$@")
  if [[ -z ${LAUNCHER_NUMERIC:-} ]] && command -v gum >/dev/null 2>&1; then
    local -a sel=()
    [[ -n $preselect ]] && sel=(--selected "$preselect")
    gum choose --no-limit --header "$header" "${sel[@]}" \
      --cursor-prefix "[ ] " --selected-prefix "[x] " --unselected-prefix "[ ] " "${labels[@]}"
  else
    echo >&2
    echo "$header" >&2
    local i=1 l
    for l in "${labels[@]}"; do printf '  %2d) [ ] %s\n' "$i" "$l" >&2; i=$((i+1)); done
    local n n2
    read -rp "Numbers to select (space-separated, empty = none): " n >&2 || n=""
    for n2 in $n; do
      [[ "$n2" =~ ^[0-9]+$ ]] && ((n2 >= 1 && n2 <= ${#labels[@]})) && printf '%s\n' "${labels[$((n2-1))]}"
    done
  fi
}

# Main menu (6 actions). Returns only when the user quits (=> exit 0).
launcher_menu(){
  local choice
  while :; do
    hr
    msg "mosquitOmarchy — what do you want to do?"
    choice="$(launcher_pick "Main menu" \
      "status          — state of every module" \
      "update          — check for and apply module updates" \
      "setup           — install/configure by category" \
      "remove          — uninstall modules" \
      "backup/restore  — save or restore a dated archive" \
      "quit")"
    case $choice in
      status*)  status_report; echo; read -rp "Press Enter to return to the menu" _ || true ;;
      update*)  launcher_update ;;
      setup*)   launcher_setup ;;
      remove*)  hr; uninstall_chooser || true ;;
      backup*)  launcher_backup ;;
      quit)     break ;;
      *)        continue ;;   # Esc / cancel → redisplay the main menu
    esac
  done
  hr; ok "Bye."
  exit 0
}

# Update: check for a newer repo AND for local changes, then offer — via a
# multi-select — to re-apply ONLY the installed modules whose scripts changed.
# Nothing new is installed and nothing is destroyed (idempotent re-run).
launcher_update(){
  hr; msg "Update — what this does"
  echo "  1. Checks GitHub for a newer version of the scripts (owner mode: update"
  echo "     as fast as possible; any user may self-update in an emergency)."
  echo "  2. Detects which INSTALLED modules actually changed, then lets you"
  echo "     multi-select the ones to re-apply (idempotent)."
  echo "  3. Installs nothing new and never wipes your local files."
  local old_head="" new_head=""
  [[ -d "$REPO_DIR/.git" ]] && old_head="$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || true)"
  check_repo_update
  [[ -d "$REPO_DIR/.git" ]] && new_head="$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || true)"

  # Changed paths = repo fast-forward diff + local (unstaged/staged) edits.
  local -a changed=()
  if [[ -n $old_head && -n $new_head && $old_head != "$new_head" ]]; then
    mapfile -t changed < <(git -C "$REPO_DIR" diff --name-only "$old_head" "$new_head" 2>/dev/null)
  fi
  mapfile -t -O "${#changed[@]}" changed < <(
    git -C "$REPO_DIR" diff --name-only HEAD 2>/dev/null
    git -C "$REPO_DIR" diff --name-only --cached 2>/dev/null
  )

  load_excluded; apply_includes
  local -A cand=()
  local row id state p m
  for row in "${MODULES[@]}"; do
    id="${row%%:*}"
    is_excluded "$id" && continue
    state="$(module_state "$id")"
    [[ $state == ok || $state == partial ]] || continue
    for p in "${changed[@]:-}"; do
      [[ -z $p ]] && continue
      m="$(module_of_path "$p")"
      [[ $m == "$id" ]] && { cand[$id]=1; break; }
    done
  done

  # Ordered list (MODULES order) of the modules that have an applicable update.
  local -a ids=()
  for row in "${MODULES[@]}"; do
    id="${row%%:*}"; [[ -n ${cand[$id]:-} ]] && ids+=("$id")
  done

  if ((${#ids[@]} == 0)); then
    ok "Everything is up to date — no applicable update for the installed modules."
    return 0
  fi
  hr; msg "Applicable updates — installed modules whose scripts changed: ${ids[*]}"
  SELECTED=()
  local -a picked=() pp
  mapfile -t picked < <(launcher_multiselect "Updates to apply (Tab/x = toggle, Enter = apply):" "*" "${ids[@]}")
  for pp in "${picked[@]}"; do [[ -n $pp ]] && SELECTED+=("$pp"); done
  ((${#SELECTED[@]})) || { ok "Nothing selected — no update applied."; return 0; }
  hr; ok "Applying ${#SELECTED[@]} update(s)…"
  exec_modules
  final_report
}

# ─────────────────── Generic per-category chooser (launcher) ───────────────────
# EVERY setup category first presents a multi-select of its candidate items
# (like fixes_pick) — nothing pre-checked, Tab/x toggles, Enter confirms,
# nothing selected = nothing run. launcher_multiselect supplies the gum /
# numeric fallback. Only the ticked items are then installed.

category_items(){ # catid -> echo the space-separated module ids of that category
  local c f
  for c in "${CATEGORIES[@]}"; do
    [[ "${c%%|*}" == "$1" ]] || continue
    f="${c#*|}"; printf '%s' "${f#*|}"
    return 0
  done
}

module_desc(){ # module / pseudo id -> short description
  local row
  # remove-ai gets a MODE-AWARE label: Setup says "bring back…", Uninstall
  # says "remove…" (the exact phrasings the user asked for).
  if [[ "$1" == remove-ai ]]; then
    if [[ ${TREE_MODE:-setup} == uninstall ]]; then printf "remove omarchy's agentic stuff (agents, AI-diag toasts, ollama loaders; Setup restores)"; else printf "bring back omarchy's agentic stuff (re-enable the Agents plugin, the AI-diagnosis toasts, ollama loaders)"; fi
    return 0
  fi
  for row in "${MODULES[@]}"; do
    [[ "${row%%:*}" == "$1" ]] && { printf '%s' "${row#*:}"; return 0; }
  done
  case $1 in
    audio-plugin-manager) printf '%s' "mosquito Audio Plugin Manager (TUI + actions) + shared audio core" ;;
    theme)                printf '%s' "Create an Omarchy theme from an image in theme/Wallpapers/" ;;
  esac
}

category_candidates(){ # catid -> CAND_KEYS (to run) + CAND_LABELS (to display)
  CAND_KEYS=(); CAND_LABELS=()
  local cat="$1" id items e name line kind
  case $cat in
    tuis|webapps)
      # Catalog-backed categories: one candidate per catalog entry.
      if [[ $cat == webapps ]]; then
        load_catalog || true
        for e in "${CAT_WEB[@]:-}"; do
          [[ -n $e ]] || continue
          name="${e%%|*}"
          CAND_KEYS+=("WEB $e")
          CAND_LABELS+=("$name  —  ${e#*|}")
        done
      elif [[ -f $CAT_FILE_TUI ]]; then
        while IFS= read -r line || [[ -n $line ]]; do
          line="${line%%$'\r'}"
          [[ -z $line || $line == \#* ]] && continue
          kind="${line%%[ |]*}"
          case $kind in
            TUI)
              name="${line#*[ ]}"; name="${name%%|*}"
              CAND_KEYS+=("TUI $name")
              CAND_LABELS+=("$name  —  ${line#*|}")
              ;;
            PLUG)
              e="${line#*[ ]}"; name="${e%%|*}"
              CAND_KEYS+=("PLUG $e")
              CAND_LABELS+=("$name  —  $(printf '%s' "$e" | cut -d'|' -f3)")
              ;;
          esac
        done < "$CAT_FILE_TUI"
      fi
      ;;
    mosquito)
      # The mosquito tools — every user-visible tool, displayed as
      # "mosquito-<tool>" rows; each maps to its module / pseudo-module key
      # (battery = mega-caffeine, ableton-move-manager = Move Manager, etc).
      CAND_KEYS+=("ableton-move-manager")
      CAND_LABELS+=("mosquito-move-manager  —  $(module_desc ableton-move-manager)")
      CAND_KEYS+=("audio-plugin-manager")
      CAND_LABELS+=("mosquito-audio-plugin-manager  —  $(module_desc audio-plugin-manager)")
      CAND_KEYS+=("jamjamjam-plugin")
      CAND_LABELS+=("mosquito-jamjamjam  —  $(module_desc jamjamjam-plugin)")
      CAND_KEYS+=("battery")
      CAND_LABELS+=("mosquito-mega-caffeine  —  $(module_desc battery)")
      CAND_KEYS+=("live-mode")
      CAND_LABELS+=("mosquito-live-mode  —  $(module_desc live-mode)")
      ;;
    *)
      items="$(category_items "$cat")"
      for id in $items; do
        CAND_KEYS+=("$id")
        # remove-ai's Setup label is EXACTLY "bring back omarchy's agentic
        # stuff" — the uninstall one is the 'remove omarchy's…' phrasing and
        # the tree branches below route it correctly.
        if [[ $id == remove-ai ]]; then
          CAND_LABELS+=("$id  —  bring back omarchy's agentic stuff (re-enables omarchy.agents, AI-diag toasts, ollama loaders)")
        else
          CAND_LABELS+=("$id  —  $(module_desc "$id")")
        fi
      done
      # The themes category also offers building a theme from a wallpaper.
      if [[ $cat == themes && -d "$THEME_DIR/Wallpapers" ]] \
         && compgen -G "$THEME_DIR/Wallpapers/*" >/dev/null 2>&1; then
        CAND_KEYS+=("theme")
        CAND_LABELS+=("theme  —  $(module_desc theme)")
      fi
      ;;
  esac
}

category_pick(){ # catid -> fills CATEGORY_SELECTED with the ticked keys
  CATEGORY_SELECTED=()
  local cat="$1" p i
  category_candidates "$cat"
  ((${#CAND_KEYS[@]})) || { warn "No installable item in category '$cat'."; return 0; }
  # Full descriptions first, wrapped to the terminal width: gum rows are
  # single-line and get truncated (same readability guard as fixes_pick).
  local cols="${COLUMNS:-}"
  [[ -z $cols ]] && cols="$(tput cols 2>/dev/null || echo 100)"
  (( cols < 40 )) && cols=100
  echo; msg "Category '$cat' — what can be installed:"
  for ((i=0; i<${#CAND_KEYS[@]}; i++)); do
    printf '  %s\n' "${CAND_LABELS[$i]}" | fold -s -w "$cols" | sed 's/^/    /'
  done
  echo
  local -a picked=()
  mapfile -t picked < <(launcher_multiselect \
    "Category '$cat' (Tab/x = toggle, Enter = confirm, none = nothing):" "" \
    "${CAND_LABELS[@]}")
  for p in "${picked[@]}"; do
    [[ -n $p ]] || continue
    for ((i=0; i<${#CAND_LABELS[@]}; i++)); do
      [[ "${CAND_LABELS[$i]}" == "$p" ]] && { CATEGORY_SELECTED+=("${CAND_KEYS[$i]}"); break; }
    done
  done
}

category_run(){ # catid -> run only the CATEGORY_SELECTED items
  local cat="$1" k
  case $cat in
    tuis|webapps)
      # Hand the exact ticked catalog entries to the apps module (--only keeps
      # the type; -y skips its own multi-select) so nothing else is installed.
      local tmp; tmp="$(mktemp)"
      printf '%s\n' "${CATEGORY_SELECTED[@]}" > "$tmp"
      hr; msg "Apps module — $cat only (${#CATEGORY_SELECTED[@]} entry/ies)"
      if bash "$APPS_DIR/setup-apps.sh" --from-backup="$tmp" -y --only="$cat"; then
        ok "Apps module ($cat): done."
      else
        MODULE_FAILURES=$((MODULE_FAILURES + 1))
        err "Apps module ($cat) reported an error (see the messages above)."
      fi
      rm -f "$tmp"
      ;;
    mosquito)
      load_excluded
      apply_includes
      RESULTS=()
      SELECTED=()
      local skipped=0
      for k in "${CATEGORY_SELECTED[@]}"; do
        case $k in
          audio-plugin-manager)
            run_module audio-plugin-manager bash "$AUDIO_PLUGIN_MANAGER_DIR/setup-audio-stack.sh" $([[ $YES == 1 ]] && echo -y) ;;
          *)
            # Module-backed mosquito tools (ableton-move-manager, battery
            # = mega-caffeine, jamjamjam-plugin, live-mode) go through
            # exec_modules like any module: excluded ones are skipped.
            if is_excluded "$k"; then
              warn "Module '$k' was uninstalled by you — skipped (re-offer with --include=$k)."
              skipped=$((skipped + 1))
            else
              SELECTED+=("$k")
            fi
            ;;
        esac
      done
      if ((${#CATEGORY_SELECTED[@]})) && ((${#SELECTED[@]} == 0)) && ((skipped > 0)); then
        MODULE_FAILURES=$((MODULE_FAILURES + 1))
        err "Nothing installed for '$cat': every selected item was uninstalled by you (re-offer with --include=<module>)."
      fi
      ((${#SELECTED[@]})) && exec_modules
      final_report
      ;;
    *)
      load_excluded
      apply_includes
      RESULTS=()
      SELECTED=()
      skipped=0
      for k in "${CATEGORY_SELECTED[@]}"; do
        if [[ $k == theme ]]; then
          run_module theme bash "$THEME_DIR/create-theme.sh"
          continue
        fi
        if is_excluded "$k"; then
          warn "Module '$k' was uninstalled by you — skipped (re-offer with --include=$k)."
          skipped=$((skipped + 1))
          continue
        fi
        SELECTED+=("$k")
      done
      if ((${#CATEGORY_SELECTED[@]})) && ((${#SELECTED[@]} == 0)) && ((skipped > 0)); then
        MODULE_FAILURES=$((MODULE_FAILURES + 1))
        err "Nothing installed for '$cat': every selected item was uninstalled by you (re-offer with --include=<module>)."
      fi
      ((${#SELECTED[@]})) && exec_modules
      final_report
      ;;
  esac
}

# Setup by category: the launcher_pick over CATEGORIES, then run that category.
launcher_setup(){
  local -a labels=() c label
  for c in "${CATEGORIES[@]}"; do label="${c#*|}"; label="${label%%|*}"; labels+=("$label"); done
  labels+=("quit")
  local picked entry id
  hr; msg "Setup by category"
  picked="$(launcher_pick "Which setup category?" "${labels[@]}")"
  [[ -n "$picked" ]] || return 0
  [[ "$picked" == quit ]] && return 0
  for c in "${CATEGORIES[@]}"; do
    label="${c#*|}"; label="${label%%|*}"
    if [[ "$label" == "$picked" ]]; then entry="$c"; break; fi
  done
  [[ -n $entry ]] || return 0
  id="${entry%%|*}"
  launcher_run_category "$id"
}

# Executes the chosen category. Every install category first shows its
# multi-select chooser (category_pick) and runs only the ticked items
# (category_run) — quick fixes keep their grouped fixes_pick; "menu" is a
# yes/no registration, not an install.
launcher_run_category(){
  local id="$1"
  case $id in
    fixes)
      # Propose the quick fixes (multi-select, grouped) — NEVER apply them
      # without an explicit choice.
      fixes_pick
      if ((${#FIXES_SELECTED[@]})); then
        RESULTS=()
        run_fixes || true
        final_report
      else
        ok "No quick fix selected."
      fi
      ;;
    menu)
      # Ask first; if yes, ONLY register the menu entry (no module status,
      # no other check).
      if ask "Add the mosquitOmarchy setup to the Omarchy install menu?" y; then
        install_menu_entry
      else
        ok "Menu entry not added."
      fi
      ;;
    *)
      category_pick "$id"
      if ((${#CATEGORY_SELECTED[@]})); then
        category_run "$id"
      else
        ok "Nothing selected — nothing installed."
      fi
      ;;
  esac
}

# Backup / restore: states its function FIRST (like the update zone), then asks
# what to do. Never touches the repo; restore puts files back where they were.
launcher_backup(){
  hr; msg "Backup / Restore — what this does"
  echo "  BACKUP  saves a DATED archive in $BACKUP_DIR :"
  echo "    - config-backup.tar.gz : config + Omarchy bar/menus + launchers +"
  echo "      yabridgectl + REAPER + the active Zen profile + omagrab +"
  echo "      KeePassXC passwords & settings (NEVER written to the repo)."
  echo "    - pkglist.txt / aurlist.txt : the exact packages to reinstall."
  echo "    - apps.selected : your apps / TUIs / webapps selection."
  echo "    - optionally the VST plugins (--vst-backup=full)."
  echo "    - optional in-place GPG AES-256 encryption → .gpg suffix."
  echo "  RESTORE lists the backups (chronological) and puts the files back"
  echo "    EXACTLY where they were (decrypts the .gpg archives first). It"
  echo "    restores FILES, not packages: use pkglist.txt / aurlist.txt"
  echo "    (pacman) afterwards to reinstall the same packages."
  echo
  local choice
  # Loop so every action returns to THIS menu (the user can chain a backup
  # then a list, etc.); "Back to the main menu" is the only exit.
  while :; do
    echo
    choice="$(launcher_pick "Backup / Restore — what do you want to do?" \
      "Backup now (dated archive in $BACKUP_DIR)" \
      "Restore a backup (chronological choice)" \
      "List the existing backups" \
      "Back to the main menu")"
    case $choice in
      Backup*)  do_backup || true ;;
      Restore*) restore_flow || true ;;
      List*)    list_backups ;;
      *)        return 0 ;;
    esac
    hr
  done
}

# ───────────────────────── Main ─────────────────────────
main(){
  # Launcher menu: shown when you sit in a terminal without any flag (-y counts
  # as "do everything with defaults", a MODE/--status/--uninstall has its own
  # path). The step-by-step wizard remains reachable from the menu's setup /
  # update entries (and via the -y / --update flags).
  # Interactive run with no flags → hand over to the NEW Go/Bubble Tea TUI
  # (it replaced the old in-script gum launcher_picker; this script remains
  # the engine behind the TUI's Setup/Uninstall/Backup flows and the flag
  # driven paths). This makes `./mosquitomarchy-setup.sh` behave exactly like
  # the mosquitomarchy menu entry / shortcut.
  if [[ -t 0 && -t 1 && -z $MODE && $STATUS_ONLY == 0 && $UNINSTALL_DELEGATE == 0 && $YES == 0 ]]; then
    TUI="$HOME/.local/bin/mosquitomarchy-tui"
    if [[ -x $TUI ]]; then
      exec "$TUI"
    fi
    warn "TUI not built yet — falling back to the old wizard."
  fi
  # Early modes: pure delegation, no report needed.
  case $MODE in
    backup) do_backup; exit $? ;;
    list)   list_backups; exit 0 ;;
    restore) restore_flow; exit $? ;;
    update-repo)
      if [[ -d "$REPO_DIR/.git" ]] && command -v git >/dev/null 2>&1; then
        update_repo_ff
      else
        err "No git repo at $REPO_DIR (or git missing) — nothing to update."
        exit 1
      fi
      exit $? ;;
  esac

  msg "mosquitomarchy-setup — Personal scripts for configuring Omarchy (Arch/Hyprland) oriented toward audio production (REAPER, Bitwig, Windows VST, local AI). All scripts are idempotent: safe to re-run on an already-configured machine."
  status_report

  if ((STATUS_ONLY)); then exit 0; fi

  # Repo update ("update zone"): check GitHub for a newer version, propose to
  # install it properly. Interactive only; -y warns without pulling.
  check_repo_update

  # Pure delegation: per-module uninstall (integrated here).
  if ((UNINSTALL_DELEGATE)); then
    hr; msg "Per-module uninstall"
    if ((YES)); then
      uninstall_all
      exit 0
    fi
    uninstall_chooser || true
    exit 0
  fi

  # Non-interactive: also register the Omarchy Install menu entry (idempotent).
  ((YES)) && install_menu_entry

  # Available option: skip the required system libs (gstreamer + base/good).
  ((${SKIP_LIBS:-0})) || run_required_libs

  # Question 0: quick system fixes (small idempotent one-shot fixes)
  if ((YES)); then
    if ((${#FIXES[@]})); then
      ok "(auto) all quick fixes"
      FIXES_SELECTED=()
      local fx
      for fx in "${FIXES[@]}"; do FIXES_SELECTED+=("${fx%%:*}"); done
      run_fixes || true
      echo ""
    fi
  elif ask "Apply quick system fixes (multi-choice, Tab to navigate)?" n; then
    fixes_pick
    if ((${#FIXES_SELECTED[@]})); then
      run_fixes || true
      echo ""
    fi
  fi

  # Question 1: backup / restore (integrated here)
  if ((YES)); then
    if existing_config; then
      ok "(auto) backup of the existing config"
      do_backup
    else
      ok "Fresh installation — nothing to back up."
    fi
  else
    if existing_config; then
      if has_backups; then
        pick_backup_action
      elif ask "A custom Omarchy config already exists. Make a backup first?" y; then
        do_backup
      fi
    else
      if has_backups; then
        warn "Fresh installation detected, but previous backups exist in $BACKUP_DIR."
        if ask "Restore an old backup (chronological choice) before installing?" n; then
          restore_flow
        fi
      else
        ok "Fresh installation: no config or backup to save."
      fi
    fi
  fi
  echo ""

  # Question 2: removal of the Omarchy preinstalls (stock) — preserves personal apps
  if ((YES)); then
    if preinstalls_removable; then
      warn "(auto) Omarchy preinstalls NOT removed (safe behavior) — use --status or manual interactive mode."
    fi
  else
    if preinstalls_removable; then
      hr
      if ask "Remove the Omarchy PREINSTALLS (stock apps) while keeping your personal apps/tuis?" n; then
        run_module preinstalls run_remove_preinstalls || true
      fi
      echo ""
    fi
  fi

  # Question 3: which modules
  if ((YES)); then
    SELECTED=()
    load_excluded
    apply_includes
    local row id state
    for row in "${MODULES[@]}"; do
      id="${row%%:*}"; state="$(module_state "$id")"
      [[ $state == na ]] && continue
      if is_excluded "$id"; then
        warn "(auto) module '$id' excluded (you uninstalled it) — skipped."
        continue
      fi
      if [[ $state == ok ]]; then
        ((UPDATE_OK)) && SELECTED+=("$id")
        continue
      fi
      SELECTED+=("$id")
    done
    if ((${#SELECTED[@]})); then ok "(auto) modules: ${SELECTED[*]}"
    else warn "Nothing selected — everything is up to date."; fi
  else
    select_modules
  fi
  ((${#SELECTED[@]})) || { warn "Nothing selected."; exit 0; }
  echo ""

  # Sequential execution
  exec_modules

  # Optional per-module uninstall (integrated).
  if ((YES == 0)) && ask "Uninstall some modules (per-module choice)?" n; then
    hr
    uninstall_chooser || true
  fi

  # Theme creation at the END (after the whole installation): offers a theme
  # from any image in theme/Wallpapers/. With -y, the achraff module
  # (forced achraf67.png image) covers it — no input here.
  if ((YES == 0)) && [[ -d "$THEME_DIR/Wallpapers" ]] \
     && compgen -G "$THEME_DIR/Wallpapers/*" >/dev/null 2>&1; then
    hr
    if ask "Create an Omarchy theme from an image in theme/Wallpapers/?" n; then
      run_module theme bash "$THEME_DIR/create-theme.sh"
    fi
  fi

  final_report
  status_report
}

# Menu for "config exists AND backups exist" (question 1, interactive).
pick_backup_action(){
  # Custom config AND existing backups -> 3 choices
  if command -v gum >/dev/null; then
    local a
    a="$(gum choose \
        "Backup now (before installing)" \
        "Restore a backup (chronological choice)" \
        "Continue without backup or restore" \
        --header "Existing config + backups detected — what to do?" --height 5)"
    case $a in
      Backup*)    do_backup ;;
      Restore*)   restore_flow ;;
      *)          warn "Continuing without backup or restore." ;;
    esac
  else
    echo " [1] Backup now   [2] Restore a backup   [3] Continue without backup"
    read -rp "Choice [1-3, default 1] : " ch; ch="${ch:-1}"
    case $ch in
      2) restore_flow ;;
      3) warn "Continuing without backup or restore." ;;
      *) do_backup ;;
    esac
  fi
}

if (( ! LIB_ONLY )) ; then
  main "$@" || exit $?
fi