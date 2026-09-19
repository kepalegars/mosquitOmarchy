#!/usr/bin/env bash
# =============================================================================
# Omarchy Custom - SuperFile (terminal file manager, launched as a regular app)
# =============================================================================
# Installs superfile (`spf`) as an app you simply launch — it does NOT take
# over the default file-manager role. Concretely it sets up:
#
#   1. the `superfile` package (pacman, official repo; an AUR `superfile-git`
#      providing the same `spf` binary is accepted too)
#   2. an Omarchy applications-menu entry
#      (~/.local/share/applications/superfile.desktop) that opens `spf` in a
#      terminal, plus its icon in the hicolor theme
#      (~/.local/share/icons/hicolor/256x256/apps/superfile.png, sourced from
#      the official icon committed next to this script)
#   3. Enter/Right on a `.sh`/`.bash`/`.zsh` (or a bare executable) runs it in
#      a new terminal instead of opening it in the editor; editing is a
#      separate action, using superfile's own editor hotkey and the
#      Omarchy/system default editor ($EDITOR)
#   4. an Omarchy theme (config.toml -> theme/omarchy.toml) generated from
#      Omarchy's active theme, re-applied automatically on every Omarchy theme
#      switch via a ~/.config/omarchy/hooks/theme-set.d/ hook
#
# Deliberately absent: `xdg-mime default superfile.desktop inode/directory`,
# any default-file-manager .desktop role, the FileChooser
# xdg-desktop-portal override, and any SUPER+SHIFT+F / Nautilus keybinding
# override. Nothing here changes the system's file manager. Bind a shortcut to
# SuperFile through scripts/setup-keybindings.sh ("SuperFile" entry).
#
# Usage:
#   ./setup-superfile.sh                # install
#   ./setup-superfile.sh -y             # non-interactive install
#   ./setup-superfile.sh --apply-theme  # regenerate theme only (used by the hook)
#   ./setup-superfile.sh --status
#   ./setup-superfile.sh --remove
#
# NOTE: the `pacman -S` step needs root — this script calls `sudo` inline for
# exactly that line. Everything else is entirely user-scoped.
# =============================================================================
# --apply-theme is invoked non-interactively by the Omarchy theme-set hook;
# keep gui-run from reopening the script in a terminal (there is none in a
# desktop hook).
for __a in "$@"; do [[ $__a == --apply-theme ]] && export GUI_RUN_EXEC=1; done
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/gui-run.bash"  # gui-run: reopen in a terminal when launched from a file manager
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/elevate.bash"  # mq_sudo: native pkexec prompt when not root
set -euo pipefail

info() { echo -e "\033[1;34m==>\033[0m $*"; }
ok()   { echo -e "\033[1;32m ✓\033[0m $*"; }
warn() { echo -e "\033[1;33m !\033[0m $*"; }
err()  { echo -e "\033[1;31m ✗\033[0m $*" >&2; }

if [[ ! -d /usr/share/omarchy ]]; then
  echo "This script is meant for Omarchy." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF_SCRIPT="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
REAL_HOME="${HOME}"
STATE_DIR="$REAL_HOME/.config/superfile-module"
APPS_DIR="$REAL_HOME/.local/share/applications"
SUPERFILE_DESKTOP="$APPS_DIR/superfile.desktop"
SUPERFILE_ICON_SRC="$SCRIPT_DIR/superfile-icon.png"
SUPERFILE_ICON_DST="$REAL_HOME/.local/share/icons/hicolor/256x256/apps/superfile.png"

SUPERFILE_CONFIG_DIR="$REAL_HOME/.config/superfile"
SUPERFILE_CONFIG="$SUPERFILE_CONFIG_DIR/config.toml"
SUPERFILE_THEME_DIR="$SUPERFILE_CONFIG_DIR/theme"
SUPERFILE_THEME_FILE="$SUPERFILE_THEME_DIR/omarchy.toml"
EXEC_WRAPPER="$REAL_HOME/.local/bin/superfile-open-exec"

OMARCHY_COLORS="$REAL_HOME/.local/state/omarchy/current/theme/colors.toml"
OMARCHY_HOOKS_DIR="$REAL_HOME/.config/omarchy/hooks/theme-set.d"
THEME_HOOK_FILE="$OMARCHY_HOOKS_DIR/superfile-module.sh"
HYPR_BINDINGS="$REAL_HOME/.config/hypr/bindings.lua"

STATUS_ONLY=false REMOVE=false APPLY_THEME=false YES=false
for a in "$@"; do case "$a" in
  -y|--yes)       YES=true ;;
  --status)       STATUS_ONLY=true ;;
  --remove)       REMOVE=true ;;
  --apply-theme)  APPLY_THEME=true ;;
  -h|--help)      sed -n '2,38p' "$0"; exit 0 ;;
  *)              echo "Unknown option: $a (supported: -y --status --remove --apply-theme)" >&2; exit 1 ;;
esac; done

pkg_has() { pacman -Q "$1" &>/dev/null; }

ask() {
  $YES && return 0
  local r; read -rp "$1 [y/N] " r; [[ ${r:-n} =~ ^[yY] ]]
}

# -----------------------------------------------------------------------------
# Package install (root-gated — see header note)
# -----------------------------------------------------------------------------
install_superfile_pkg() {
  # Accepts either the official `superfile` package or an AUR `superfile-git`
  # already providing the same `spf` binary — no need to fight a conflicting
  # reinstall if the user already has one of them.
  if command -v spf >/dev/null 2>&1; then
    local existing; existing="$(pkg_has superfile && echo superfile || { pkg_has superfile-git && echo superfile-git; })"
    ok "spf already available${existing:+ ($existing installed)}"
    return 0
  fi
  info "Installing superfile (pacman, official repo)"
  mq_sudo pacman -S --needed --noconfirm superfile || { err "pacman install failed"; return 1; }
  ok "superfile installed"
}

# -----------------------------------------------------------------------------
# Menu entry + icon (regular app launcher — NOT a file-manager role)
# -----------------------------------------------------------------------------
# Launches `spf` inside a terminal window, matching the repo's other TUI
# entries. foot is Omarchy's default terminal, so prefer it and fall back to
# xdg-terminal-exec otherwise.
superfile_launch_cmd() {
  if command -v foot >/dev/null 2>&1; then
    echo "foot -a org.omarchy.superfile -e spf"
  else
    echo "xdg-terminal-exec --app-id=org.omarchy.superfile -e spf"
  fi
}

install_icon() {
  if [[ ! -f $SUPERFILE_ICON_SRC ]]; then
    warn "icon asset not found ($SUPERFILE_ICON_SRC) — the menu entry falls back to a generic icon."
    return 0
  fi
  if [[ -f $SUPERFILE_ICON_DST ]] && cmp -s "$SUPERFILE_ICON_SRC" "$SUPERFILE_ICON_DST"; then
    ok "icon already in place ($SUPERFILE_ICON_DST)"
    return 0
  fi
  mkdir -p "$(dirname "$SUPERFILE_ICON_DST")"
  cp "$SUPERFILE_ICON_SRC" "$SUPERFILE_ICON_DST"
  command -v gtk-update-icon-cache >/dev/null 2>&1 \
    && gtk-update-icon-cache -f -t "$REAL_HOME/.local/share/icons/hicolor" >/dev/null 2>&1 || true
  ok "icon installed ($SUPERFILE_ICON_DST)"
}

remove_icon() {
  rm -f "$SUPERFILE_ICON_DST"
  command -v gtk-update-icon-cache >/dev/null 2>&1 \
    && gtk-update-icon-cache -f -t "$REAL_HOME/.local/share/icons/hicolor" >/dev/null 2>&1 || true
}

write_desktop_entry() {
  mkdir -p "$APPS_DIR"
  local exec_line; exec_line="$(superfile_launch_cmd)"
  cat > "$SUPERFILE_DESKTOP" <<EOF
[Desktop Entry]
Type=Application
Name=SuperFile
Comment=Terminal file manager (spf) — installed via mosquitOmarchy
Exec=$exec_line
Icon=superfile
Terminal=false
Categories=System;FileTools;Utility;
Keywords=superfile;spf;file;manager;terminal;
EOF
  command -v update-desktop-database >/dev/null && update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true
  ok "menu entry written ($SUPERFILE_DESKTOP)"
}

remove_desktop_entry() {
  rm -f "$SUPERFILE_DESKTOP"
  command -v update-desktop-database >/dev/null && update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true
  ok "superfile.desktop removed"
}

# The `superfile` PACKAGE ships /usr/share/applications/spf.desktop (root),
# which shows a second, redundant "spf" entry in the Omarchy apps menu. We
# shadow it with a user Hidden=true override so only our "SuperFile" entry
# shows; the package file itself is never touched, and updates to the package
# can't bring the entry back.
SPF_PKG_DESKTOP="$APPS_DIR/spf.desktop"
hide_pkg_spf_desktop() {
  mkdir -p "$APPS_DIR"
  cat > "$SPF_PKG_DESKTOP" <<'EOF'
[Desktop Entry]
Type=Application
Name=spf
Hidden=true
EOF
  command -v update-desktop-database >/dev/null && update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true
  ok "package 'spf' menu entry hidden (user override)"
}
unhide_pkg_spf_desktop() {
  if [[ -f $SPF_PKG_DESKTOP ]] && grep -q '^Hidden=true' "$SPF_PKG_DESKTOP"; then
    rm -f "$SPF_PKG_DESKTOP"
    command -v update-desktop-database >/dev/null && update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true
    ok "package 'spf' entry restored (our override removed)"
  fi
}

# Strip the legacy "superfile-module-keybindings" block this module used to
# inject into bindings.lua when it took over SUPER+SHIFT+F. That default-FM
# role is gone; clean the stale block up so it stops overriding Nautilus.
remove_legacy_keybindings() {
  [[ -f $HYPR_BINDINGS ]] || return 0
  if grep -q 'superfile-module-keybindings' "$HYPR_BINDINGS"; then
    sed -i '/-- >>> superfile-module-keybindings >>>/,/-- <<< superfile-module-keybindings <<</d' "$HYPR_BINDINGS"
    ok "legacy superfile keybinding block removed ($HYPR_BINDINGS)"
  fi
}

# -----------------------------------------------------------------------------
# "Enter/Right on a script -> RUN it in a new terminal" (superfile's
# [open_with] table)
# -----------------------------------------------------------------------------
# superfile's own default action for Enter/Right on a non-directory file is
# `xdg-open <file>` (executeOpenCommand() in its source), unless the file's
# extension has an entry in [open_with] — matched by
# strings.ToLower(strings.TrimPrefix(filepath.Ext(path), ".")), so an
# extensionless executable matches the empty-string key "". superfile then
# runs the [open_with] command *detached from the terminal*
# (utils.DetachFromTerminal(): new session, stdin/stdout/stderr nil), so a
# plain `sh = "bash"` would run the script with no visible output and no way
# to interact with it. xdg-open has no useful default for a bare executable
# (no matching MIME handler), so pressing Enter on one silently does
# nothing. This routes shell scripts and bare executables to a small wrapper
# that opens a NEW terminal and holds it open, so a `.sh` is genuinely RUN.

# Extensions routed to $EXEC_WRAPPER: shell scripts plus bare executables
# (no extension, or the chmod +x'd binaries superfile would otherwise hand to
# xdg-open with no handler). Anything NOT in this list (images, video, PDFs,
# archives, text/code, ...) is untouched, still goes to whatever
# superfile/xdg-open already does for it.
EXEC_OPEN_EXTS=(sh bash zsh)  # plus the bare "" (no extension) key, always added separately below

write_exec_open_wrapper() {
  mkdir -p "$(dirname "$EXEC_WRAPPER")"
  cat > "$EXEC_WRAPPER" <<'EOF'
#!/usr/bin/env bash
# superfile-open-exec — wired into superfile's [open_with] table by
# setup-superfile.sh. superfile invokes it as `<wrapper> <file>` with the
# selected file's path appended and detached from the spf terminal; this
# wrapper opens the file in a NEW terminal and holds it open so the script's
# output (and any prompts) are visible.
#
#   .sh / .bash -> run with `bash` (even when not chmod +x — the point is
#                  that Enter/Right RUNS shell scripts)
#   .zsh        -> run with `zsh`
#   anything else (bare executables, chmod +x'd AppImages) -> executed
#                  directly, relying on its shebang / exec bit
#
# Editing is a separate action, handled by superfile's own editor hotkey
# (`e` for the focused file, `E` for the current directory), not by this
# wrapper.
set -euo pipefail
f="$1"
case "${f,,}" in
  *.sh|*.bash) run=(bash "$f") ;;
  *.zsh)       run=(zsh "$f") ;;
  *)           run=("$f") ;;
esac

# xdg-terminal-exec's --hold is a no-op here: foot's own .desktop entry
# declares no Hold action, so the window would flash shut the instant the
# script exits, hiding its output or a crash. Same fix as this repo's own
# gui-run.bash: when foot is available, run inside a `read` so the window
# stays open until dismissed; xdg-terminal-exec --hold is kept only as the
# best-effort fallback for a non-foot terminal.
if command -v foot >/dev/null 2>&1; then
  exec foot bash -c '"$@"; ec=$?; printf "\n[%s] finished (exit %d). Press Enter to close this terminal." "$(basename "${@: -1}")" "$ec"; read -r _; exit "$ec"' _ "${run[@]}"
else
  exec xdg-terminal-exec --hold -- "${run[@]}"
fi
EOF
  chmod +x "$EXEC_WRAPPER"
  ok "Script/executable launcher installed ($EXEC_WRAPPER)"
}

remove_exec_open_wrapper() { rm -f "$EXEC_WRAPPER"; }

# The pre-simplification install stored a chosen text editor here and routed
# recognized text/code extensions through the wrapper above. There is no
# editor option any more (editing uses superfile's own editor hotkey with
# $EDITOR, the Omarchy/system default), so drop the stale preference.
remove_legacy_editor_preference() { rm -f "$STATE_DIR/editor"; }

write_open_with_exec_mappings() {
  mkdir -p "$SUPERFILE_CONFIG_DIR"
  if [[ ! -f $SUPERFILE_CONFIG ]]; then
    # First run before superfile itself has ever generated one: a minimal
    # file is enough — superfile fills in every other default itself.
    printf '# Generated by setup-superfile.sh — see https://superfile.dev/configure/superfile-config/ to customize further.\n\n[open_with]\n' > "$SUPERFILE_CONFIG"
  elif ! grep -q '^\[open_with\]' "$SUPERFILE_CONFIG"; then
    # [open_with] MUST stay the LAST table in the file (TOML can't reopen a
    # table once another one follows it) — safe to append since the config
    # doesn't have one yet at all.
    printf '\n[open_with]\n' >> "$SUPERFILE_CONFIG"
  fi
  # Drop the previously-managed block, then merge our keys in: the wrapper
  # mapping for "" (bare executables) plus each shell-script extension. Any
  # pre-existing key with the same name is replaced (duplicate TOML keys are
  # invalid and the module owns these names); every other key in [open_with]
  # — and every other table — is preserved untouched.
  sed -i '/# >>> superfile-module-exec-open >>>/,/# <<< superfile-module-exec-open <<</d' "$SUPERFILE_CONFIG"
  local tmp; tmp="$(mktemp)"
  awk -v wrapper="$EXEC_WRAPPER" -v execexts="${EXEC_OPEN_EXTS[*]}" '
    BEGIN {
      managed[""] = 1
      n = split(execexts, ee, " "); for (i = 1; i <= n; i++) managed[ee[i]] = 1
    }
    /^\[open_with\][ \t]*$/ && !done {
      print
      print "# >>> superfile-module-exec-open >>> shell scripts + executables (setup-superfile.sh)"
      print "\"\" = \"" wrapper "\""
      for (i = 1; i <= n; i++) print ee[i] " = \"" wrapper "\""
      print "# <<< superfile-module-exec-open <<<"
      done = 1; inow = 1; next
    }
    /^\[/ { inow = 0; print; next }
    inow && /^[ \t]*("[^"]*"|[A-Za-z0-9_.-]+)[ \t]*=/ {
      key = $0; sub(/[ \t]*=.*/, "", key); gsub(/^[ \t]+|[ \t]+$/, "", key); gsub(/^"|"$/, "", key)
      if (key in managed) next
      print; next
    }
    { print }
  ' "$SUPERFILE_CONFIG" > "$tmp" && mv "$tmp" "$SUPERFILE_CONFIG"
  ok "superfile [open_with]: .sh (and .bash/.zsh/bare executables) run in a new terminal on Enter/Right"
}

remove_open_with_exec_mappings() {
  [[ -f $SUPERFILE_CONFIG ]] || return 0
  sed -i '/# >>> superfile-module-exec-open >>>/,/# <<< superfile-module-exec-open <<</d' "$SUPERFILE_CONFIG"
  ok "superfile [open_with] script/executable mappings removed"
}

# -----------------------------------------------------------------------------
# Omarchy theme sync (superfile follows the active Omarchy theme, not just at
# install — a theme-set hook re-applies it on every Omarchy theme switch too)
# -----------------------------------------------------------------------------
# Merged from the former apply-omarchy-theme.sh: generates
# ~/.config/superfile/theme/omarchy.toml from Omarchy's CURRENT active theme
# colors and points config.toml at it. Idempotent — safe to re-run any time.
apply_omarchy_theme() {
  [[ -f $OMARCHY_COLORS ]] || { warn "no active Omarchy theme found ($OMARCHY_COLORS) — skipping"; return 0; }

  local mode accent muted background dark_background foreground dark_foreground green red blue
  omarchy_color() { sed -n "s/^$1 *= *\"\([^\"]*\)\"\$/\1/p" "$OMARCHY_COLORS" | head -1; }
  mode="$(omarchy_color mode)"
  accent="$(omarchy_color accent)"
  muted="$(omarchy_color muted)"
  background="$(omarchy_color background)"
  dark_background="$(omarchy_color dark_background)"
  foreground="$(omarchy_color foreground)"
  dark_foreground="$(omarchy_color dark_foreground)"
  green="$(omarchy_color green)"
  red="$(omarchy_color red)"
  blue="$(omarchy_color blue)"

  # Bare fallbacks -- an Omarchy theme is expected to define all of these,
  # but a partial/custom theme shouldn't crash the generator.
  accent="${accent:-#b5e61d}"; muted="${muted:-#4e9237}"
  background="${background:-#0d0d0b}"; dark_background="${dark_background:-$background}"
  foreground="${foreground:-#dbcfbf}"; dark_foreground="${dark_foreground:-$muted}"
  green="${green:-#22a949}"; red="${red:-#ed1c24}"; blue="${blue:-#87a5e0}"
  local syntax="monokai"; [[ $mode == light ]] && syntax="github"

  mkdir -p "$SUPERFILE_THEME_DIR"
  cat > "$SUPERFILE_THEME_FILE" <<EOF
# Generated by setup-superfile.sh from Omarchy's current theme -- do not
# edit by hand, it is overwritten on every Omarchy theme switch. Pick a
# different superfile theme yourself by changing config.toml's "theme"
# value; re-running setup-superfile.sh (or switching Omarchy's theme again)
# will not touch that choice unless this file is still the active one.

code_syntax_highlight = "$syntax"

#-- Full Screen
full_screen_fg = "$foreground"
full_screen_bg = "$background"

#-- Gradient
gradient_color = ["$green", "$accent"]

#-- File Panel
file_panel_fg = "$foreground"
file_panel_bg = "$background"
file_panel_border = "$muted"
file_panel_border_active = "$accent"
file_panel_top_directory_icon = "$accent"
file_panel_top_path = "$blue"
file_panel_item_selected_fg = "$background"
file_panel_item_selected_bg = "$accent"

#-- Footer
footer_fg = "$foreground"
footer_bg = "$background"
footer_border = "$muted"
footer_border_active = "$accent"

#-- Sidebar
sidebar_fg = "$foreground"
sidebar_bg = "$background"
sidebar_title = "$accent"
sidebar_border = "$background"
sidebar_border_active = "$accent"
sidebar_item_selected_fg = "$background"
sidebar_item_selected_bg = "$accent"
sidebar_divider = "$dark_foreground"

#-- Modals
modal_fg = "$foreground"
modal_bg = "$dark_background"
modal_border_active = "$accent"
modal_cancel_fg = "$foreground"
modal_cancel_bg = "$muted"
modal_confirm_fg = "$background"
modal_confirm_bg = "$accent"

#-- Help Menu
help_menu_hotkey = "$accent"
help_menu_title = "$accent"

#-- Special
cursor = "$accent"
correct = "$green"
error = "$red"
hint = "$blue"
cancel = "$muted"
EOF

  mkdir -p "$SUPERFILE_CONFIG_DIR"
  if [[ ! -f $SUPERFILE_CONFIG ]]; then
    printf 'theme = "omarchy"\n\n[open_with]\n' > "$SUPERFILE_CONFIG"
  elif grep -q '^theme *=' "$SUPERFILE_CONFIG"; then
    sed -i 's/^theme *=.*/theme = "omarchy"/' "$SUPERFILE_CONFIG"
  else
    # Top-level keys must come before any [table] header -- prepend.
    { printf 'theme = "omarchy"\n\n'; cat "$SUPERFILE_CONFIG"; } > "$SUPERFILE_CONFIG.tmp"
    mv "$SUPERFILE_CONFIG.tmp" "$SUPERFILE_CONFIG"
  fi

  ok "superfile theme synced to Omarchy's active theme ($SUPERFILE_THEME_FILE)"
}

remove_omarchy_theme() {
  rm -f "$SUPERFILE_THEME_FILE"
  if [[ -f $SUPERFILE_CONFIG ]] && grep -q '^theme *= *"omarchy"' "$SUPERFILE_CONFIG"; then
    sed -i '/^theme *= *"omarchy"/d' "$SUPERFILE_CONFIG"
  fi
  ok "superfile Omarchy theme removed"
}

write_theme_hook() {
  mkdir -p "$OMARCHY_HOOKS_DIR"
  cat > "$THEME_HOOK_FILE" <<EOF
#!/bin/bash
# Installed by setup-superfile.sh -- keeps superfile's own theme in sync with
# Omarchy's active theme every time it changes (\$1 = new theme's snake-cased
# name, unused here — the script always re-reads the CURRENT theme's colors,
# not this argument, so it stays correct even if invoked out of order).
# GUI_RUN_EXEC=1 keeps setup-superfile.sh from reopening itself in a terminal
# (there is none in a desktop hook).
GUI_RUN_EXEC=1 "$SELF_SCRIPT" --apply-theme >/dev/null 2>&1 || true
EOF
  chmod +x "$THEME_HOOK_FILE"
  ok "Omarchy theme-change hook registered ($THEME_HOOK_FILE)"
}

remove_theme_hook() {
  rm -f "$THEME_HOOK_FILE"
  # Stale artifact from the pre-merge install (a deployed copy of the old
  # apply-omarchy-theme.sh) — no longer installed, clean it up if present.
  rm -f "$REAL_HOME/.local/bin/superfile-apply-omarchy-theme"
  ok "Omarchy theme-change hook removed"
}

# -----------------------------------------------------------------------------
# --status
# -----------------------------------------------------------------------------
do_status() {
  info "SuperFile module status"
  echo "  • superfile package: $(pkg_has superfile && echo "installed ($(pacman -Q superfile | awk '{print $2}'))" || echo "not installed")"
  echo "  • spf binary: $(command -v spf || echo "not found")"
  echo "  • Menu entry: $([[ -f $SUPERFILE_DESKTOP ]] && echo "present ($SUPERFILE_DESKTOP)" || echo absent)"
  echo "  • Icon: $([[ -f $SUPERFILE_ICON_DST ]] && echo "present ($SUPERFILE_ICON_DST)" || echo absent)"
  echo "  • Default file manager: $(xdg-mime query default inode/directory 2>/dev/null || echo unknown) (never changed by this module)"
  echo "  • Script/executable launcher: $([[ -x $EXEC_WRAPPER ]] && echo "present ($EXEC_WRAPPER)" || echo absent)"
  echo "  • Editing files: superfile's own editor hotkey, using \${EDITOR:-nano} (Omarchy/system default)"
  echo "  • superfile [open_with] script/exec mappings: $(grep -q 'superfile-module-exec-open' "$SUPERFILE_CONFIG" 2>/dev/null && echo active || echo "not active")"
  echo "  • Omarchy theme sync: $([[ -x $THEME_HOOK_FILE ]] && echo "active (hook: $THEME_HOOK_FILE)" || echo "not active")"
  echo "  • superfile theme: $(sed -n 's/^theme *= *"\(.*\)"/\1/p' "$SUPERFILE_CONFIG" 2>/dev/null | head -1 || echo unknown)"
  if [[ -f $HYPR_BINDINGS ]] && grep -q 'superfile-module-keybindings' "$HYPR_BINDINGS" 2>/dev/null; then
    echo "  • Legacy keybinding block: present (will be removed by a re-run)"
  else
    echo "  • Legacy keybinding block: none"
  fi
}

# -----------------------------------------------------------------------------
# --remove
# -----------------------------------------------------------------------------
do_remove() {
  remove_open_with_exec_mappings
  remove_exec_open_wrapper
  remove_omarchy_theme
  remove_theme_hook
  remove_desktop_entry
  remove_icon
  unhide_pkg_spf_desktop
  remove_legacy_keybindings
  remove_legacy_editor_preference
  # Stale state written by the pre-simplification default-FM era. The module no
  # longer takes that role, so these files are meaningless; the system's XDG
  # default is deliberately left untouched.
  rm -f "$STATE_DIR/prev-default-fm" "$STATE_DIR/fm-mode"
  rmdir "$STATE_DIR" 2>/dev/null || true
  command -v hyprctl >/dev/null 2>&1 && hyprctl reload >/dev/null 2>&1 || true
  echo ""
  info "superfile package itself was left installed"
  echo "  (uninstall manually if wanted: sudo pacman -Rns superfile)"
}

# -----------------------------------------------------------------------------
# MAIN
# -----------------------------------------------------------------------------
if $STATUS_ONLY; then do_status; exit 0; fi
if $REMOVE; then do_remove; exit 0; fi
if $APPLY_THEME; then apply_omarchy_theme; exit 0; fi

info "Setting up superfile (terminal file manager, launched as an app)"
install_superfile_pkg
install_icon
write_desktop_entry
hide_pkg_spf_desktop
remove_legacy_editor_preference
write_exec_open_wrapper
write_open_with_exec_mappings
apply_omarchy_theme || warn "Omarchy theme sync failed — superfile keeps its previous theme."
write_theme_hook
remove_legacy_keybindings
command -v hyprctl >/dev/null 2>&1 && hyprctl reload >/dev/null 2>&1 || true

echo ""
info "Setup complete. Summary:"
echo "  • Menu entry            -> $SUPERFILE_DESKTOP (launches spf in a terminal)"
echo "  • Icon                  -> $SUPERFILE_ICON_DST"
echo "  • Theme                 -> follows Omarchy's active theme automatically (on switch too)"
echo "  • Enter/Right on .sh/.bash/.zsh (or a bare executable) -> runs it in a new terminal"
echo "  • Editing files         -> superfile's own editor hotkey (e/E), using \${EDITOR:-nano} (Omarchy/system default)"
echo "  • Shortcut              -> add one via scripts/setup-keybindings.sh (\"SuperFile\" entry)"
echo "  • Default file manager  -> unchanged (this module never touches it)"
echo "  • Status                -> $0 --status"
echo "  • Revert                -> $0 --remove"
