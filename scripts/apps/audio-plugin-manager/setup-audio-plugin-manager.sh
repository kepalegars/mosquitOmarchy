#!/usr/bin/env bash
# =============================================================================
# Omarchy Custom - "mosquito Audio Plugin Manager" (install / uninstall / status /
# standalone)
# =============================================================================
# Launches / installs the mosquito Audio Plugin Manager:
#   1. One interface, one core (same architecture as the sibling
#      mosquito-move-manager module — kept deliberately consistent):
#        - lib-audio-plugin-manager-core.sh   shared logic, not an entry point
#        - mosquito-audio-plugin-manager-tui        real terminal UI (Go, Bubble Tea),
#                                   THE ONLY interface
#        - mosquito-audio-plugin-manager            stable dispatcher — the ONLY file the
#                                   menu entry points at; no-args launches
#                                   (opens a foot/xterm window if needed),
#                                   flag actions (launch/install/status)
#                                   run through the core
#   2. The menu entry "mosquito Audio Plugin Manager"
#      (~/.local/share/applications/mosquito-audio-plugin-manager.desktop) visible in
#      the Omarchy launcher, consistent with "Ableton Live (VM)" (AudioVideo);
#      also matches the "mosquito" search in the Omarchy launcher.
#   3. The mosquito.confirm Omarchy plugin (native Yes/No overlay), same
#      plugin the sibling mosquito-move-manager module installs — ensured
#      here too so this module doesn't implicitly depend on that one
#      having run first.
#   4. A custom monochrome jigsaw-piece icon (audio-plugin-manager-icon.png, white
#      glyph on transparent 256×256, same style as the Move Manager's) for
#      the menu entry.
# Removes the previous "Install a VST plugin" entry and wrapper.
#
# Usage:
#   ./setup-audio-plugin-manager.sh        install (interactive, silent re-install)
#   ./setup-audio-plugin-manager.sh -y     non-interactive install
# =============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/elevate.bash"  # mq_sudo: native pkexec prompt when not root

info()  { echo -e "\033[1;34m==>\033[0m $*"; }
ok()    { echo -e "\033[1;32m ✓\033[0m $*"; }
warn()  { echo -e "\033[1;33m !\033[0m $*"; }
die()   { warn "$*"; exit 1; }

ask(){
  local q="$1" def="${2:-y}" r
  ((YES)) && { ok "(auto) $q -> yes"; return 0; }
  if command -v gum >/dev/null; then
    gum confirm "$q" --default=$([[ $def == y ]] && echo true || echo false) && return 0 || return 1
  fi
  read -rp "$q [$([ $def = y ] && echo Y/n || echo y/N)] " r
  r="${r:-$def}"; [[ $r =~ ^[oOyY] ]]
}

YES=0
for a in "$@"; do case "$a" in
  -y|--yes) YES=1 ;;
esac; done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
APPS_DIR="$HOME/.local/share/applications"
STACK="$SCRIPT_DIR/setup-audio-stack.sh"

mkdir -p "$BIN_DIR" "$APPS_DIR"
[[ -x "$STACK" ]] || warn "setup-audio-stack.sh not found ($STACK) — the manager will stay standalone."

DESKTOP="$APPS_DIR/mosquito-audio-plugin-manager.desktop"
# Monochrome jigsaw-piece icon, same style as the sibling Move Manager's
# (white glyph on transparent background) — installed into the hicolor theme
# and referenced by name from the desktop entry.
VST_ICON_SRC="$SCRIPT_DIR/audio-plugin-manager-icon.png"
VST_ICON_DST="$HOME/.local/share/icons/hicolor/256x256/apps/mosquito-audio-plugin-manager.png"

# -----------------------------------------------------------------------------
# 0. Runtime dependencies (the tools the core actually invokes). The stack
# script (setup-audio-stack.sh) installs the full audio set; this step keeps
# the manager usable standalone for machines that only install the manager.
# -----------------------------------------------------------------------------
if ! command -v wine >/dev/null 2>&1 || ! command -v yabridgectl >/dev/null 2>&1; then
  info "Runtime dependencies (wine-staging + yabridge) — required for Windows-VST support"
  missing_deps=()
  for p in wine-staging yabridge yabridgectl; do
    pacman -Q "$p" &>/dev/null || missing_deps+=("$p")
  done
  if ((${#missing_deps[@]})) && ask "Install the missing packages (${missing_deps[*]}) ?"; then
    mq_sudo -v || die "Password required to install package(s): ${missing_deps[*]}"
    mq_sudo pacman -S --needed --noconfirm "${missing_deps[@]}" \
      || die "Installation failed: ${missing_deps[*]}"
    ok "Installed: ${missing_deps[*]}"
  fi
fi

# -----------------------------------------------------------------------------
# 1. Deploy the dispatcher + the TUI + the shared core
# -----------------------------------------------------------------------------
deploy_one() {
  local name="$1" src="$SCRIPT_DIR/$1" dst="$BIN_DIR/$1"
  [[ -f $src ]] || die "$name not found next to this script ($src)"
  cp "$src" "$dst"
  chmod +x "$dst"
  bash -n "$dst" || die "Invalid syntax: $name"
  ok "$name deployed: $dst"
}
deploy_one "lib-audio-plugin-manager-core.sh"
deploy_one "mosquito-audio-plugin-manager-actions"

# mosquito-audio-plugin-manager-tui is a compiled Go/Bubble Tea program (see tui-go/
# and the shared ../../tui-kit component library) — same architecture and
# same build-time-only Go dependency as the sibling mosquito-move-manager
# module (see its setup script's build_and_deploy_tui() for the full
# rationale). The TUI is THE ONLY interface now (Roadmap 3.9) — a missing
# build degrades worse than it used to (there is no native interface to
# fall back to), so say exactly that, but keep it non-fatal for the rest
# of the install (menu entry, icon, … work independently).
if ! command -v go >/dev/null 2>&1; then
  warn "go not found — mosquito-audio-plugin-manager-tui (Go/Bubble Tea) won't be built. The TUI is the ONLY interface, so the menu can't launch until it is. Install go (e.g. via mise, or sudo pacman -S go) and re-run this installer."
else
  TUI_TMP_OUT="$(mktemp "$BIN_DIR/.mosquito-audio-plugin-manager-tui.XXXXXX")"
  if (cd "$SCRIPT_DIR/tui-go" && go build -o "$TUI_TMP_OUT" .); then
    chmod +x "$TUI_TMP_OUT"
    mv -f "$TUI_TMP_OUT" "$BIN_DIR/mosquito-audio-plugin-manager-tui"
    ok "mosquito-audio-plugin-manager-tui built and deployed ($BIN_DIR/mosquito-audio-plugin-manager-tui)"
  else
    rm -f "$TUI_TMP_OUT"
    warn "mosquito-audio-plugin-manager-tui build failed — the menu can't launch until it builds (re-run this installer after fixing the cause)."
  fi
fi
deploy_one "mosquito-audio-plugin-manager"

# Remove the previous wrapper (superseded by the manager).
rm -f "$BIN_DIR/vst-install"
ok "removed superseded wrapper: $BIN_DIR/vst-install"
# Remove the old pre-rename binaries/interfaces (superseded by the
# mosquito-* names) — a machine that ran an older setup keeps them otherwise.
rm -f "$BIN_DIR/vst-manager" "$BIN_DIR/vst-manager-native" "$BIN_DIR/vst-manager-tui"
ok "removed superseded pre-rename binaries: vst-manager{, -native, -tui}"

# -----------------------------------------------------------------------------
# 1b. Stale native-mode cleanup (Roadmap 3.9): the old native script, its
# interface mode file, and last switch's log are from the removed
# two-interface era — clean up any instance of them on disk so nothing
# still references the deleted modes. (The TUI is the only interface now;
# there is no preference to ask for or switch.)
# -----------------------------------------------------------------------------
if [[ -f "$BIN_DIR/mosquito-vst-manager-native" ]]; then
  rm -f "$BIN_DIR/mosquito-vst-manager-native"
  ok "Stale native-interface script removed ($BIN_DIR/mosquito-vst-manager-native)"
fi
if [[ -f "$HOME/.config/vst-manager/interface" ]]; then
  rm -f "$HOME/.config/vst-manager/interface"
  ok "Stale interface mode file removed (~/.config/vst-manager/interface)"
fi
rm -f "$HOME/.config/vst-manager/interface-switch.log"

# -----------------------------------------------------------------------------
# 1b'. Rename migration: "VST Manager" -> "mosquito Audio Plugin Manager".
# Copies the still-live file-picker preference forward (never just resets
# it) before removing every pre-rename artifact — binaries, .desktop, icon,
# Hyprland marker block. Idempotent: safe to re-run once already migrated.
# -----------------------------------------------------------------------------
NEW_FILE_PICKER_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/audio-plugin-manager/file-picker"
if [[ -f "$HOME/.config/vst-manager/file-picker" && ! -f "$NEW_FILE_PICKER_FILE" ]]; then
  mkdir -p "$(dirname "$NEW_FILE_PICKER_FILE")"
  cp "$HOME/.config/vst-manager/file-picker" "$NEW_FILE_PICKER_FILE"
  ok "File picker preference migrated to $NEW_FILE_PICKER_FILE"
fi
# vst-state.json is git-ignored, so a `git pull` on an already-installed
# machine leaves the OLD filename sitting next to this script even after
# the code itself updates to expect the new one -- migrate it in place
# rather than silently starting a fresh (empty) install history.
if [[ -f "$SCRIPT_DIR/vst-state.json" && ! -f "$SCRIPT_DIR/audio-plugin-manager-state.json" ]]; then
  mv "$SCRIPT_DIR/vst-state.json" "$SCRIPT_DIR/audio-plugin-manager-state.json"
  ok "Machine-scoped state log migrated to $SCRIPT_DIR/audio-plugin-manager-state.json"
fi
rmdir "$HOME/.config/vst-manager" 2>/dev/null || true
rm -f "$BIN_DIR/lib-vst-manager-core.sh" "$BIN_DIR/mosquito-vst-manager" \
      "$BIN_DIR/mosquito-vst-manager-actions" "$BIN_DIR/mosquito-vst-manager-tui" \
      "$BIN_DIR/vst-install.new"
rm -f "$APPS_DIR/mosquito-vst-manager.desktop" \
      "$HOME/.local/share/icons/hicolor/256x256/apps/mosquito-vst-manager.png"
sed -i '/-- >>> mosquito-vst-manager-tui-setup >>>/,/-- <<< mosquito-vst-manager-tui-setup <<</d' "$HOME/.config/hypr/hyprland.lua" 2>/dev/null || true
ok "Pre-rename \"VST Manager\" artifacts cleaned up (binaries, .desktop, icon, Hyprland block)"

# -----------------------------------------------------------------------------
# 1c. mosquito.confirm Omarchy plugin (native Yes/No overlay) — always
# re-copied over whatever's deployed, not just on first install, so a repo
# update is never left stale (this module and mosquito-move-manager share
# the exact same plugin, one source of truth).
# -----------------------------------------------------------------------------
PLUGIN_SRC="$SCRIPT_DIR/../../plugins/power-management/omarchy-plugins/mosquito.confirm"
PLUGIN_DST="$HOME/.config/omarchy/plugins/mosquito.confirm"
if [[ -d $PLUGIN_SRC ]]; then
  mkdir -p "$PLUGIN_DST"
  cp -a "$PLUGIN_SRC/." "$PLUGIN_DST/"
  omarchy plugin enable mosquito.confirm >/dev/null 2>&1 || true
  ok "Omarchy plugin mosquito.confirm installed/updated (native Yes/No overlay)"
elif [[ -d $PLUGIN_DST ]]; then
  ok "Omarchy plugin mosquito.confirm already present (repo source not found to re-sync from)"
else
  warn "mosquito.confirm sources not found — prompts will use the zenity fallback."
fi

# -----------------------------------------------------------------------------
# 1c'. Custom icon (monochrome jigsaw piece, style of the sibling Move
# Manager's) for the desktop entry — copied into the hicolor theme when
# missing or stale, referenced by name (Icon=mosquito-audio-plugin-manager) from the
# menu entry below so the launcher shows it.
# -----------------------------------------------------------------------------
if [[ -f $VST_ICON_SRC ]]; then
  if [[ -f $VST_ICON_DST ]] && cmp -s "$VST_ICON_SRC" "$VST_ICON_DST"; then
    ok "icon already in place ($VST_ICON_DST)"
  else
    mkdir -p "$(dirname "$VST_ICON_DST")"
    cp "$VST_ICON_SRC" "$VST_ICON_DST"
    ok "icon installed ($VST_ICON_DST)"
  fi
  command -v gtk-update-icon-cache >/dev/null 2>&1 \
    && gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" >/dev/null 2>&1 || true
else
  warn "icon not found ($VST_ICON_SRC) — menu entry will fall back to a generic icon."
fi

# -----------------------------------------------------------------------------
# 1d. Hyprland float rule for the TUI window. Without this,
# mosquito-audio-plugin-manager-tui's window tiles like any other window instead of
# floating — Omarchy's own floating-window whitelist
# (default/hypr/apps/system.lua) matches specific known app-ids
# (org.omarchy.btop, org.omarchy.terminal, …) verbatim, not a wildcard, so a
# custom app-id like ours is never covered by it. Same idempotent
# marked-block pattern as scripts/apps/reaper/setup-reaper.sh and the sibling
# setup-ableton-move-manager.sh: strip any previously-injected block first
# so re-running after an edit actually updates hyprland.lua rather than
# being a no-op, then append the current one. Size matches Omarchy's own
# floating-window tag (system.lua) for consistency with the rest of the
# desktop's TUI popups.
# -----------------------------------------------------------------------------
HYPR_CONF="$HOME/.config/hypr/hyprland.lua"
mkdir -p "$HOME/.config/hypr"
touch "$HYPR_CONF"
sed -i '/-- >>> mosquito-audio-plugin-manager-tui-setup >>>/,/-- <<< mosquito-audio-plugin-manager-tui-setup <<</d' "$HYPR_CONF"
cat >>"$HYPR_CONF" <<'EOF'
-- >>> mosquito-audio-plugin-manager-tui-setup >>> float mosquito-audio-plugin-manager-tui
-- (the Bubble Tea TUI's own window) instead of the tiled default -- its
-- app-id isn't in Omarchy's own floating-window whitelist (that one only
-- matches a fixed set of known app-ids verbatim, not a wildcard).
o.window("org.omarchy.mosquito-audio-plugin-manager-tui", { float = true, center = true })
-- <<< mosquito-audio-plugin-manager-tui-setup <<<
EOF
hyprctl reload >/dev/null 2>&1 || true
ok "Hyprland float rule for the TUI window installed/updated ($HYPR_CONF)"

# -----------------------------------------------------------------------------
# 2. Menu entry
# -----------------------------------------------------------------------------
cat > "$DESKTOP" <<DESKTOP_EOF
[Desktop Entry]
Name=mosquito Audio Plugin Manager
Comment=Manage VST (Windows, via Wine) and native (LV2/CLAP/VST3) plugins
Exec=uwsm app -- mosquito-audio-plugin-manager
Icon=mosquito-audio-plugin-manager
Terminal=false
Type=Application
Categories=AudioVideo;Audio;
Keywords=mosquito;vst;vst3;clap;lv2;plugin;wine;
StartupNotify=false
DESKTOP_EOF
rm -f "$APPS_DIR/vst-install.desktop"
rm -f "$APPS_DIR/vst-manager.desktop"
command -v update-desktop-database >/dev/null && update-desktop-database "$APPS_DIR" 2>/dev/null || true
ok "menu: $DESKTOP"

# -----------------------------------------------------------------------------
# 2b. Deployed README (regenerated live by the core on every Settings change;
# this bootstrap only creates the file for a fresh install, reflecting the
# current/previous prefs or the defaults).
# -----------------------------------------------------------------------------
bootstrap_dir_readme() {
  local dir="$HOME/.config/audio-plugin-manager"
  local dl="$HOME/Downloads" pr="$HOME/Music/Plugins" fp="Default"
  if [[ -f "$dir/prefs" ]]; then
    local k v
    while IFS='=' read -r k v; do
      case "$k" in
        DOWNLOADS_DIR) dl="${v//\"/}" ;;
        PLUGINS_ROOT)  pr="${v//\"/}" ;;
      esac
    done < "$dir/prefs"
  fi
  [[ -f "$dir/file-picker" && $(cat "$dir/file-picker" 2>/dev/null) == superfile ]] && fp="Superfile"
  mkdir -p "$dir" 2>/dev/null || true
  cat > "$dir/README.md" <<EOF
# mosquito Audio Plugin Manager

This file is regenerated automatically whenever you change a preference
via the TUI (Main menu → Settings).

## Current configuration

- **Default plugin installation file directory**: \`${dl}\`
- **Plugins folder**: \`${pr}\`
- **File picker**: ${fp}

EOF
  ok "deployed README reflecting current settings ($dir/README.md)"
}
bootstrap_dir_readme

info "mosquito Audio Plugin Manager ready (see the Omarchy launcher, Audio category — search 'mosquito')."
