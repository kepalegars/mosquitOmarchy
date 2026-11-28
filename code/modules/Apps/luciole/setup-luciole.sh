#!/usr/bin/env bash
# setup-luciole.sh — install Luciole and make it the file manager everywhere.
#
# Luciole (https://github.com/noctalia-dev/luciole) is a native Wayland file
# manager from the Noctalia team, packaged on the AUR as luciole-git. The package
# gives the binary, menu entry, D-Bus services and the xdg-desktop-portal
# backend; this module adds the per-user wiring that makes it the default for
# anything that opens a folder:
#
#   - folder association  (inode/directory, i.e. xdg-open and "Open with")
#   - FileManager1        ("Open file location" from browsers/GTK apps)
#   - file chooser        (portal Open/Save dialogs, luciole first, others kept)
#   - Omarchy keybinds    (SUPER+SHIFT+F and SUPER+ALT+SHIFT+F)
#
# It also deploys the bundled settings (seed/settings.toml, copied from the
# author's live Luciole settings.toml) right after the install, and keeps
# Luciole's palette in sync with the active Omarchy theme: colors.toml is
# generated from Omarchy's current colors and a theme-set hook regenerates it
# on every theme switch.
#
# Everything this module changes is reversible: --remove undoes the wiring,
# --uninstall also removes the package.
#
# Usage:
#   ./setup-luciole.sh              # install + defaults + settings + theme sync
#   ./setup-luciole.sh -y           # non-interactive install
#   ./setup-luciole.sh --status
#   ./setup-luciole.sh --remove     # undo the wiring, keep the package
#   ./setup-luciole.sh --uninstall  # undo the wiring + remove the package
#   ./setup-luciole.sh --apply-theme  # regenerate the palette only (theme hook)
#   ./setup-luciole.sh -h
# =============================================================================
for __a in "$@"; do
  case $__a in
    -y|--yes|--remove|--uninstall|--status|--apply-theme|-h|--help) export GUI_RUN_EXEC=1 ;;
  esac
done
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../lib/gui-run.bash"  # gui-run: reopen in a terminal when launched from a file manager
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../lib/elevate.bash"  # mq_sudo: native pkexec prompt when not root
set -euo pipefail

info() { echo -e "\033[1;34m==>\033[0m $*"; }
ok()   { echo -e "\033[1;32m ✓\033[0m $*"; }
warn() { echo -e "\033[1;33m !\033[0m $*"; }
err()  { echo -e "\033[1;31m ✗\033[0m $*" >&2; }

REMOVE=false UNINSTALL=false STATUS=false APPLY_THEME=false YES=false
for a in "$@"; do case "$a" in
  -y|--yes)       YES=true ;;
  --remove)       REMOVE=true ;;
  --uninstall)    UNINSTALL=true ;;
  --status)       STATUS=true ;;
  --apply-theme)  APPLY_THEME=true ;;
  -h|--help)      sed -n '2,31p' "$0"; exit 0 ;;
  *)              echo "Unknown option: $a (supported: -y --remove --uninstall --status --apply-theme)" >&2; exit 1 ;;
esac; done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF_SCRIPT="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
REAL_HOME="${HOME}"
DESKTOP_FILE="dev.noctalia.luciole.desktop"
BIN="/usr/bin/luciole"
LUCIOLE_CONFIG_DIR="$REAL_HOME/.config/luciole"
LUCIOLE_SETTINGS="$LUCIOLE_CONFIG_DIR/settings.toml"
LUCIOLE_BASE_CONFIG="$LUCIOLE_CONFIG_DIR/config.toml"
LUCIOLE_COLORS="$LUCIOLE_CONFIG_DIR/colors.toml"
SEED_SETTINGS="$SCRIPT_DIR/seed/settings.toml"

STATE_DIR="$REAL_HOME/.config/luciole-module"
PREV_MIME="$STATE_DIR/previous-folder-handler"
PREV_FM1="$STATE_DIR/previous-filemanager1"
DBUS_DIR="${XDG_DATA_HOME:-$REAL_HOME/.local/share}/dbus-1/services"
FM1_SERVICE="$DBUS_DIR/org.freedesktop.FileManager1.service"
FM1_SRC="/usr/share/dbus-1/services/dev.noctalia.luciole.FileManager1.service"
PORTAL_DIR="${XDG_CONFIG_HOME:-$REAL_HOME/.config}/xdg-desktop-portal"
OMARCHY_COLORS="$REAL_HOME/.local/state/omarchy/current/theme/colors.toml"
HOOK_DIR="$REAL_HOME/.config/omarchy/hooks/theme-set.d"
HOOK_FILE="$HOOK_DIR/luciole-module.sh"
BINDINGS="$REAL_HOME/.config/hypr/bindings.lua"

folder_handler() { xdg-mime query default inode/directory 2>/dev/null || true; }
pkg_has() { pacman -Q luciole-git >/dev/null 2>&1 || pacman -Q luciole >/dev/null 2>&1; }

status() {
  if command -v luciole >/dev/null 2>&1; then
    local ver=""
    ver="$(pacman -Q luciole-git 2>/dev/null | awk '{print $2}' || true)"
    [[ -z $ver ]] && ver="$(pacman -Q luciole 2>/dev/null | awk '{print $2}' || true)"
    ok "luciole installed${ver:+ ($ver)}"
  else
    warn "luciole not installed"
  fi
  printf 'default folder handler: %s\n' "$(folder_handler)"
  [[ -f $FM1_SERVICE ]] && echo "FileManager1: Luciole" || echo "FileManager1: not set"
  local conf; conf="$(portal_conf_path)"
  if [[ -f $conf ]]; then
    grep -q 'org.freedesktop.impl.portal.FileChooser=luciole' "$conf" \
      && echo "file chooser: Luciole first" || echo "file chooser: not set"
  else
    echo "file chooser: no portal config"
  fi
  if [[ -f $BINDINGS ]]; then
    grep -q 'luciole-module: file-manager start' "$BINDINGS" \
      && echo "Omarchy keybinds: Luciole" || echo "Omarchy keybinds: not changed"
  fi
  echo "settings: $([[ -f $LUCIOLE_SETTINGS ]] && echo present || echo absent) (seed: $([[ -f $SEED_SETTINGS ]] && echo present || echo absent))"
  echo "theme sync: $([[ -x $HOOK_FILE ]] && echo "active (hook: $HOOK_FILE)" || echo "not active")"
  echo "palette: $([[ -f $LUCIOLE_COLORS ]] && echo "$LUCIOLE_COLORS" || echo absent)"
}

install_pkg() {
  if command -v luciole >/dev/null 2>&1; then
    ok "luciole already installed"
    return 0
  fi
  command -v yay >/dev/null 2>&1 || { err "yay is required to install luciole-git from the AUR"; return 1; }
  info "Installing luciole-git (AUR, native Wayland file manager)"
  if ! yay -S --needed --noconfirm luciole-git; then
    err "luciole-git install failed"
    return 1
  fi
  ok "luciole installed"
}

save_previous_handler() {
  local prev; prev="$(folder_handler)"
  mkdir -p "$STATE_DIR"
  if [[ -n $prev && $prev != "$DESKTOP_FILE" ]]; then
    printf '%s\n' "$prev" > "$PREV_MIME"
  fi
}

# Only one per-user FileManager1 provider can own the name. Another one (the
# strata module installs its own) is set aside here and put back by --remove.
clear_other_filemanager1() {
  local f
  mkdir -p "$DBUS_DIR" "$PREV_FM1"
  for f in "$DBUS_DIR"/*.service; do
    [[ -f $f ]] || continue
    grep -qx 'Name=org.freedesktop.FileManager1' "$f" || continue
    [[ $(basename "$f") == "$(basename "$FM1_SERVICE")" ]] && continue
    mv -f "$f" "$PREV_FM1/"
    ok "set aside $(basename "$f") so Luciole handles \"Open file location\""
  done
}

restore_other_filemanager1() {
  local f
  [[ -d $PREV_FM1 ]] || return 0
  for f in "$PREV_FM1"/*.service; do
    [[ -f $f ]] || continue
    install -Dm644 "$f" "$DBUS_DIR/$(basename "$f")"
    ok "restored $(basename "$f") as the \"Open file location\" provider"
  done
  rm -rf "$PREV_FM1"
}

reload_session_bus() {
  command -v gdbus >/dev/null 2>&1 \
    && timeout 5 gdbus call --session --dest org.freedesktop.DBus \
      --object-path /org/freedesktop/DBus \
      --method org.freedesktop.DBus.ReloadConfig >/dev/null 2>&1 || true
}

install_filemanager1() {
  [[ -f $FM1_SRC ]] || { warn "$FM1_SRC missing (package too old?)"; return 0; }
  install -Dm644 "$FM1_SRC" "$FM1_SERVICE"
  reload_session_bus
  ok "Luciole handles \"Open file location\""
}

install_folder_handler() {
  xdg-mime default "$DESKTOP_FILE" inode/directory
  local cur; cur="$(folder_handler)"
  [[ $cur == "$DESKTOP_FILE" ]] \
    && ok "Luciole is the default application for folders" \
    || warn "folder handler is '$cur' (expected $DESKTOP_FILE)"
}

portal_conf_path() {
  if [[ -f $PORTAL_DIR/hyprland-portals.conf ]]; then
    printf '%s\n' "$PORTAL_DIR/hyprland-portals.conf"
  elif [[ -f $PORTAL_DIR/portals.conf ]]; then
    printf '%s\n' "$PORTAL_DIR/portals.conf"
  else
    printf '%s\n' "$PORTAL_DIR/hyprland-portals.conf"
  fi
}

# Put luciole first in the FileChooser list, keeping the other choosers as
# fallbacks. --remove drops only luciole, so later edits to other keys survive.
portal_chooser() {
  local mode=$1 conf
  conf="$(portal_conf_path)"
  [[ -f $conf || $mode == add ]] || return 0
  python3 - "$conf" "$mode" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
mode = sys.argv[2]
key = "org.freedesktop.impl.portal.FileChooser="
p.parent.mkdir(parents=True, exist_ok=True)
text = p.read_text() if p.exists() else "[preferred]\n"
out, found = [], False
for line in text.splitlines():
    if line.startswith(key):
        found = True
        items = [x for x in line[len(key):].split(";") if x and x != "luciole"]
        if mode == "add":
            items.insert(0, "luciole")
        if items:
            out.append(key + ";".join(items) + ";")
        continue
    out.append(line)
if mode == "add" and not found:
    row = key + "luciole;"
    if "[preferred]" in out:
        out.insert(out.index("[preferred]") + 1, row)
    else:
        out = ["[preferred]", row] + out
p.write_text("\n".join(out).rstrip() + "\n")
PY
}

install_portal() {
  portal_chooser add
  ok "Luciole is the first Open/Save file chooser"
  restart_portal
}

restart_portal() {
  command -v systemctl >/dev/null 2>&1 || return 0
  systemctl --user restart xdg-desktop-portal.service 2>/dev/null \
    && ok "file chooser portal restarted" \
    || warn "could not restart xdg-desktop-portal; log out and back in"
}

install_keybinds() {
  [[ -f $BINDINGS ]] || { warn "$BINDINGS not found (Omarchy 3?); keybinds left alone"; return 0; }
  if grep -q 'luciole-module: file-manager start' "$BINDINGS"; then
    ok "file-manager keybinds already point to Luciole"
    return 0
  fi
  cp -p "$BINDINGS" "$BINDINGS.bak.$(date +%Y%m%d%H%M%S)"
  cat >>"$BINDINGS" <<'EOF'

-- luciole-module: file-manager start
hl.unbind("SUPER + SHIFT + F")
hl.unbind("SUPER + ALT + SHIFT + F")
o.bind("SUPER + SHIFT + F", "File manager", { launch = "/usr/bin/luciole" })
o.bind("SUPER + ALT + SHIFT + F", "File manager (cwd)",
  "uwsm-app -- /usr/bin/luciole \"$(omarchy-cmd-terminal-cwd)\"")
-- luciole-module: file-manager end
EOF
  ok "SUPER+SHIFT+F and SUPER+ALT+SHIFT+F open Luciole"
  reload_hypr
}

reload_hypr() {
  if command -v hyprctl >/dev/null 2>&1 && [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]]; then
    hyprctl reload >/dev/null 2>&1 || true
  fi
}

remove_keybinds() {
  [[ -f $BINDINGS ]] || return 0
  grep -q 'luciole-module: file-manager start' "$BINDINGS" || return 0
  python3 - "$BINDINGS" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
s = re.sub(r'\n*(?:#|--)\s*luciole-module: file-manager start.*?(?:#|--)\s*luciole-module: file-manager end\n*',
           '\n', s, flags=re.S)
open(p, 'w').write(s)
PY
  ok "removed Luciole's file-manager keybinds"
  reload_hypr
}

# Deploy the bundled settings right after install. An existing settings.toml is
# the user's own live state, so it is kept instead of being overwritten.
deploy_settings() {
  [[ -f $SEED_SETTINGS ]] || { warn "settings seed missing: $SEED_SETTINGS"; return 0; }
  mkdir -p "$LUCIOLE_CONFIG_DIR"
  if [[ -f $LUCIOLE_SETTINGS ]]; then
    ok "kept your existing Luciole settings ($LUCIOLE_SETTINGS)"
  else
    cp "$SEED_SETTINGS" "$LUCIOLE_SETTINGS"
    ok "deployed your Luciole settings to $LUCIOLE_SETTINGS"
  fi
}

# Luciole reads its palette from ~/.config/luciole/colors.toml ([colors] table)
# when color_scheme = "auto". Re-generate it from Omarchy's ACTIVE theme so the
# file manager follows every theme switch; the theme-set hook calls --apply-theme.
ensure_auto_color_scheme() {
  mkdir -p "$LUCIOLE_CONFIG_DIR"
  if [[ ! -f $LUCIOLE_BASE_CONFIG ]]; then
    printf 'color_scheme = "auto"\n' > "$LUCIOLE_BASE_CONFIG"
  elif grep -q '^color_scheme *=' "$LUCIOLE_BASE_CONFIG"; then
    sed -i 's/^color_scheme *=.*/color_scheme = "auto"/' "$LUCIOLE_BASE_CONFIG"
  else
    # Top-level keys must come before any [table] header -- prepend.
    { printf 'color_scheme = "auto"\n\n'; cat "$LUCIOLE_BASE_CONFIG"; } > "$LUCIOLE_BASE_CONFIG.tmp"
    mv "$LUCIOLE_BASE_CONFIG.tmp" "$LUCIOLE_BASE_CONFIG"
  fi
}

apply_omarchy_theme() {
  [[ -f $OMARCHY_COLORS ]] || { warn "no active Omarchy theme found ($OMARCHY_COLORS) — skipping"; return 0; }
  local accent selection muted background darker_background lighter_background foreground dark_foreground red bright_red green cyan
  omarchy_color() { sed -n "s/^$1 *= *\"\([^\"]*\)\"\$/\1/p" "$OMARCHY_COLORS" | head -n1; }
  accent="$(omarchy_color accent)"
  selection="$(omarchy_color selection)"
  muted="$(omarchy_color muted)"
  background="$(omarchy_color background)"
  darker_background="$(omarchy_color darker_background)"
  lighter_background="$(omarchy_color lighter_background)"
  foreground="$(omarchy_color foreground)"
  dark_foreground="$(omarchy_color dark_foreground)"
  red="$(omarchy_color red)"
  bright_red="$(omarchy_color bright_red)"
  green="$(omarchy_color green)"
  cyan="$(omarchy_color cyan)"

  # Partial/custom themes should not crash the generator.
  accent="${accent:-#7aa2f7}"; selection="${selection:-#292e42}"; muted="${muted:-#414868}"
  background="${background:-#1a1b26}"; darker_background="${darker_background:-#0e0e14}"
  lighter_background="${lighter_background:-#24283b}"; foreground="${foreground:-#a9b1d6}"
  dark_foreground="${dark_foreground:-#565f89}"; red="${red:-#f7768e}"; bright_red="${bright_red:-$red}"
  green="${green:-#9ece6a}"; cyan="${cyan:-#449dab}"

  mkdir -p "$LUCIOLE_CONFIG_DIR"
  cat > "$LUCIOLE_COLORS" <<EOF
# Generated by setup-luciole.sh from Omarchy's current theme -- do not edit by
# hand: overwritten on every Omarchy theme switch. The 28 keys are Luciole's
# Noctalia palette tokens; unknown tokens are ignored by Luciole.

[colors]
primary = "$accent"
on_primary = "$background"
primary_container = "$selection"
on_primary_container = "$foreground"
secondary = "$cyan"
on_secondary = "$background"
secondary_container = "$muted"
on_secondary_container = "$foreground"
tertiary = "$green"
on_tertiary = "$background"
tertiary_container = "$darker_background"
on_tertiary_container = "$green"
error = "$red"
on_error = "$background"
error_container = "$darker_background"
on_error_container = "$bright_red"
surface = "$background"
on_surface = "$foreground"
on_surface_variant = "$dark_foreground"
surface_container_low = "$darker_background"
surface_container = "$background"
surface_container_high = "$lighter_background"
surface_container_highest = "$lighter_background"
outline_variant = "$muted"
shadow = "$darker_background"
scrim = "#000000"
hover = "$accent"
on_hover = "$background"
EOF
  ensure_auto_color_scheme
  ok "Luciole palette synced to the active Omarchy theme ($LUCIOLE_COLORS)"
}

write_theme_hook() {
  mkdir -p "$HOOK_DIR"
  cat > "$HOOK_FILE" <<EOF
#!/usr/bin/env bash
# Installed by setup-luciole.sh -- regenerates Luciole's palette on every
# Omarchy theme switch (\$1 = the theme slug, unused here: the CURRENT theme's
# colors are re-read, so an out-of-order call stays correct).
script="$SELF_SCRIPT"
# A repo rename/checkout move used to leave this hook pointing at a path that
# no longer existed. Follow the deployed actions symlink into the checkout.
if [[ ! -x \$script ]]; then
  actions="\$(command -v mosquitomarchy-actions 2>/dev/null || echo "\$HOME/.local/bin/mosquitomarchy-actions")"
  script="\$(dirname "\$(readlink -f "\$actions")")/../../code/modules/Apps/luciole/setup-luciole.sh"
fi
[[ -x \$script ]] || exit 0
GUI_RUN_EXEC=1 "\$script" --apply-theme >/dev/null 2>&1 || true
EOF
  chmod +x "$HOOK_FILE"
  ok "Omarchy theme-change hook registered ($HOOK_FILE)"
}

remove_theme_sync() {
  rm -f "$HOOK_FILE" "$LUCIOLE_COLORS"
  [[ -f $LUCIOLE_BASE_CONFIG ]] && sed -i '/^color_scheme *= *"auto"$/d' "$LUCIOLE_BASE_CONFIG"
  ok "Luciole Omarchy theme sync removed (settings.toml kept)"
}

restore_folder_handler() {
  local prev=""
  [[ -s $PREV_MIME ]] && prev="$(head -n1 "$PREV_MIME")"
  rm -f "$PREV_MIME"
  if [[ -n $prev ]]; then
    xdg-mime default "$prev" inode/directory 2>/dev/null \
      && ok "folder handler restored to $prev" \
      || warn "could not restore the folder handler to $prev"
    return 0
  fi
  [[ -n $prev ]] && warn "previous handler $prev is gone — leaving the system default"
  # No usable recorded handler: drop only Luciole's association.
  local f="${XDG_CONFIG_HOME:-$REAL_HOME/.config}/mimeapps.list"
  [[ -f $f ]] || return 0
  sed -i "/^inode\/directory=.*${DESKTOP_FILE}/d" "$f" || true
  ok "Luciole removed from the folder association"
}

remove_integrations() {
  rm -f "$FM1_SERVICE"
  reload_session_bus
  restore_other_filemanager1
  restore_folder_handler
  portal_chooser remove
  ok "Luciole removed from the Open/Save chooser list"
  remove_keybinds
  remove_theme_sync
  restart_portal
  ok "Luciole integrations removed"
}

uninstall() {
  remove_integrations
  if pkg_has; then
    info "Removing the luciole package"
    if pacman -Q luciole-git >/dev/null 2>&1; then
      mq_sudo pacman -Rns --noconfirm luciole-git || warn "luciole-git removal failed"
    else
      mq_sudo pacman -Rns --noconfirm luciole || warn "luciole removal failed"
    fi
  fi
  ok "Luciole uninstalled (settings under $LUCIOLE_CONFIG_DIR kept)"
}

if $STATUS; then status; exit 0; fi
if $APPLY_THEME; then apply_omarchy_theme; exit 0; fi
if $REMOVE || $UNINSTALL; then
  if $UNINSTALL; then uninstall; else remove_integrations; fi
  rmdir "$STATE_DIR" 2>/dev/null || true
  exit 0
fi

info "Setting up Luciole (native Wayland file manager, default everywhere)"
install_pkg || exit 1
save_previous_handler
clear_other_filemanager1
install_filemanager1
install_folder_handler
install_portal
install_keybinds
deploy_settings
apply_omarchy_theme || warn "theme sync failed — Luciole keeps its previous palette"
write_theme_hook

echo ""
info "Setup complete. Summary:"
echo "  • Folders / Open file location / Open+Save dialogs / SUPER+SHIFT+F -> Luciole"
echo "  • Settings -> $LUCIOLE_SETTINGS (seed: $SEED_SETTINGS)"
echo "  • Theme -> follows Omarchy's active theme automatically (on switch too)"
