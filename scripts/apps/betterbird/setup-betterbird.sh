#!/usr/bin/env bash
# =============================================================================
# Betterbird — install + configure (system tray, close/minimise to tray, start
# in the tray) + login autostart + Hyprland window rules (main window tiled,
# popups float at the pointer without stealing focus).
#
# Betterbird is a Thunderbird fork. Its tray is NOT a separate add-on: it is
# built in and driven by preferences (see the Expert Tips page). We set them
# through user.js so they survive profile rewrites and apply on every start.
#
# Usage:
#   ./setup-betterbird.sh            # install + configure + autostart + rules
#   ./setup-betterbird.sh -y         # same (accepted for the orchestrator)
#   ./setup-betterbird.sh --status   # report state, change nothing
#   ./setup-betterbird.sh uninstall  # remove autostart + rules (keep your mails)
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/gui-run.bash"  # gui-run: reopen in a terminal when launched from a file manager
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/mq_sudo.bash"  # mq_sudo: GUI password prompt, never a blind sudo hang
set -uo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PKG="betterbird-fr-bin"
# Betterbird's application.ini pins Profile=thunderbird, so the profile root is
# ~/.thunderbird (same as Thunderbird) — not a ~/.betterbird dir.
readonly PROFILE_ROOT="$HOME/.thunderbird"
readonly AUTOSTART_DIR="$HOME/.config/autostart"
readonly AUTOSTART_FILE="$AUTOSTART_DIR/betterbird.desktop"
readonly HYPR_DIALOGS="$SCRIPT_DIR/../../lib/hypr-dialogs.sh"

G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; B='\033[1;34m'; N='\033[0m'
msg(){ printf "${B}==>${N} %s\n" "$*"; }
ok(){ printf " ${G}✓${N} %s\n" "$*"; }
warn(){ printf " ${Y}!${N} %s\n" "$*" >&2; }
err(){ printf " ${R}✗${N} %s\n" "$*" >&2; }

# ── install the package (AUR: betterbird-fr-bin) ──────────────────────────────
install_betterbird(){
  if pacman -Q "$PKG" &>/dev/null; then ok "$PKG already installed"; return 0; fi
  msg "Installing $PKG (AUR) via yay"
  yay -S --needed --noconfirm "$PKG" || { err "failed to install $PKG"; return 1; }
  ok "$PKG installed"
}

# ── profile discovery ─────────────────────────────────────────────────────────
# Profiles live under PROFILE_ROOT, named in profiles.ini (Path=, relative to
# the root). We write user.js into every profile so whichever the user opens
# gets the tray behaviour. If Betterbird has never run there is no profile yet:
# create a stock one so the prefs are in place before the very first launch.
profile_dirs(){
  local ini="$PROFILE_ROOT/profiles.ini" p
  if [[ -f $ini ]]; then
    while IFS= read -r p; do
      [[ $p == Path=* ]] || continue
      p="${p#Path=}"
      [[ $p == /* ]] && printf '%s\n' "$p" || printf '%s\n' "$PROFILE_ROOT/$p"
    done < "$ini"
  fi
}

ensure_profile(){
  local ini="$PROFILE_ROOT/profiles.ini"
  mapfile -t _pd < <(profile_dirs)
  ((${#_pd[@]})) && return 0
  local name="mosquitomarchy.default"
  mkdir -p "$PROFILE_ROOT/$name"
  if [[ ! -f $ini ]]; then
    cat > "$ini" <<EOF
[Profile0]
Name=default
IsRelative=1
Path=$name
Default=1

[General]
StartWithLastProfile=1
Version=2
EOF
  fi
  ok "created Betterbird profile $name"
}

# ── preferences (the actual tray behaviour) ───────────────────────────────────
configure_betterbird(){
  msg "Writing tray preferences (tray icon, close/minimise to tray, start in tray)"
  ensure_profile
  local -a dirs; mapfile -t dirs < <(profile_dirs)
  local d
  for d in "${dirs[@]}"; do
    [[ -d $d ]] || continue
    # user.js is read at every start and re-applied over prefs.js: the robust
    # way to force a preference without racing the running app.
    cat > "$d/user.js" <<'EOF'
// mosquitOmarchy — Betterbird system-tray configuration (managed; edits are
// overwritten on every setup run). See Betterbird "Expert Tips" for the keys.
user_pref("mail.biff.show_tray_icon", true);          // tray icon when unread mail
user_pref("mail.biff.show_tray_icon_always", true);   // ... always, so it is there to restore from
user_pref("mail.minimizeToTray", true);               // the minimise button -> tray
user_pref("mail.closeToTray", true);                  // the X button -> tray (Betterbird 153+)
user_pref("mail.startupMinimized", true);             // start minimised -> in the tray
user_pref("mail.closeToTray.startInTray", true);      // start with no main window (153+)
user_pref("mail.minimizeToTray.supportedDesktops",
          "kde,gnome,xfce,mate,hyprland,niri,lxqt");  // Hyprland is Wayland: opt in
EOF
    ok "preferences written to $d/user.js"
  done
}

# ── login autostart (starts in the tray thanks to mail.startupMinimized) ───────
setup_autostart(){
  msg "Setting up Betterbird autostart (in tray)"
  mkdir -p "$AUTOSTART_DIR"
  # No --start-in-tray flag exists: the start-in-tray decision is made by the
  # preferences above, so a plain launch is enough.
  cat > "$AUTOSTART_FILE" <<'EOF'
[Desktop Entry]
Type=Application
Name=Betterbird
Exec=betterbird
Icon=betterbird
Terminal=false
Categories=Network;Email;
StartupNotify=false
X-GNOME-Autostart-enabled=true
EOF
  ok "autostart entry created at $AUTOSTART_FILE"
}

# ── Hyprland rules: main window tiled, popups float at the pointer ─────────────
setup_hypr(){
  [[ -f $HYPR_DIALOGS ]] || { warn "hypr-dialogs.sh missing — window rules skipped"; return 0; }
  # StartupWMClass=eu.betterbird.Betterbird (native Wayland) or the X11 class
  # betterbird — the same one-or-the-other dance as KeePassXC.
  if bash "$HYPR_DIALOGS" appwin betterbird '^(?i)eu\.betterbird\.Betterbird$|^(?i)betterbird$'; then
    ok "Hyprland rules applied (main tiled, popups at the pointer)"
  else
    warn "Hyprland rules could not be applied"
  fi
}

status_betterbird(){
  echo "package    : $(pacman -Q "$PKG" &>/dev/null && echo installed || echo missing)"
  echo "profile dir: $PROFILE_ROOT"
  local -a dirs; mapfile -t dirs < <(profile_dirs)
  echo "profiles   : ${#dirs[@]}"
  local d have=0
  for d in "${dirs[@]}"; do [[ -f $d/user.js ]] && have=$((have+1)); done
  echo "prefs      : $have/${#dirs[@]} user.js present"
  echo "autostart  : $([[ -f $AUTOSTART_FILE ]] && echo present || echo absent)"
  [[ -f $HYPR_DIALOGS ]] && echo "hypr rules : $(bash "$HYPR_DIALOGS" status betterbird)"
}

uninstall_betterbird(){
  msg "Removing Betterbird autostart and window rules (mail data is kept)"
  rm -f "$AUTOSTART_FILE"
  [[ -f $HYPR_DIALOGS ]] && bash "$HYPR_DIALOGS" remove betterbird >/dev/null 2>&1 || true
  # The package itself is removed by the orchestrator's uninstall (pacman -R).
  ok "autostart + Hyprland rules removed (profiles and mail untouched)"
}

main(){
  local arg="${1:-install}"
  case "$arg" in
    -y|--yes|install)
      install_betterbird && configure_betterbird && setup_autostart && setup_hypr
      ok "Betterbird installed and configured" ;;
    uninstall|--uninstall) uninstall_betterbird ;;
    --status) status_betterbird ;;
    -h|--help) sed -n '2,18p' "$0" ;;
    *) err "Usage: $0 [install|uninstall|--status]"; exit 1 ;;
  esac
}
main "$@"
