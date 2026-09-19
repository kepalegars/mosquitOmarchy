#!/usr/bin/env bash
# setup-mosquitomarchy-update.sh — update watchdog (module "mosquitomarchy-update").
#
# Installs a POST-BOOT Omarchy hook (~/.config/omarchy/hooks/post-boot.d/zzz-mosquitomarchy-update-check).
# At each desktop start it checks, in order:
#
#   1. the mosquitOmarchy GITHUB repo: is there a newer version than
#      the local checkout? → notification, and the "update zone" rules apply:
#        • OWNER → update the repo as fast as possible (commit + push).
#        • USERS → self-update in an EMERGENCY via ./setup-customarchy.sh --update-repo.
#        • RECOMMENDED → wait for the owner's update instead of pulling yourself.
#   2. otherwise, pending Omarchy-related updates → PERSISTENT desktop
#      notification, repeated at every boot until "omarchy update" is run.
#      The "Review with opencode" action opens a terminal running opencode to
#      review the pending update for conflicts with this package's customizations:
#        • SIMPLE conflicts (renamed paths/keys breaking our blocks) → the review
#          proposes the fixes for the corresponding mosquitOmarchy scripts.
#        • DEEP conflicts (duplicated functions such as battery stay-awake /
#          mega-caffeine, bar/idle overhaul) → the review proposes adjustments
#          but does NOT integrate them before a discussion.
#
# Checks use the already-synced pacman databases (no network at boot), with a
# weekly best-effort refresh (fakeroot pacman -Syu --print, no password). The
# repo check uses `git ls-remote` (github.com, 15 s timeout), skipped if git or
# the checkout is missing.
#
# Usage:
#   ./setup-mosquitomarchy-update.sh    # install the hook
#   ./setup-mosquitomarchy-update.sh -y # install without confirmation
#   ./setup-mosquitomarchy-update.sh -h # help
#
# Removal is handled by setup-customarchy.sh (module "mosquitomarchy-update").

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/gui-run.bash"  # gui-run: reopen in a terminal when launched from a file manager
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="$HOME/.config/omarchy/hooks"
DEST_DIR="$HOOKS_DIR/post-boot.d"
DEST="$DEST_DIR/zzz-mosquitomarchy-update-check"

YES=0
for a in "$@"; do case "$a" in
  -y|--yes) YES=1 ;;
  -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
  *) echo "Unknown option: $a (supported: -y)" >&2; exit 1 ;;
esac; done

G='\033[1;32m'; B='\033[1;34m'; Y='\033[1;33m'; R='\033[1;31m'; N='\033[0m'
msg(){ printf "${B}==>${N} %s\n" "$*"; }
ok(){ printf " ${G}✓${N} %s\n" "$*"; }
warn(){ printf " ${Y}!${N} %s\n" "$*"; }
hr(){ printf '%.0s─' {1..72}; echo; }

ask(){
  local q="$1" def="${2:-y}" r
  ((YES)) && return 0
  read -rp "$q [$([ "$def" = y ] && echo Y/n || echo y/N)] " r
  r="${r:-$def}"; [[ "$r" =~ ^[oOyY] ]]
}

# The hook is written as a standalone file (no dependency on the repo path,
# except the git checkout it is asked to watch): once installed it lives in
# the user config and survives a repo removal.
write_hook(){
  cat > "$DEST" <<'HOOK'
#!/usr/bin/env bash
# Omarchy update watchdog (mosquitOmarchy — module "mosquitomarchy-update").
# Installed by mosquitomarchy-update/setup-mosquitomarchy-update.sh. At each desktop
# start, in priority order:
#   1. GitHub has a newer version of the mosquitOmarchy repo → notify
#      (OWNER: update ASAP — commit + push; USERS: --update-repo in emergency;
#      RECOMMENDED: wait for the owner's update).
#   2. Omarchy-related packages have pending updates → PERSISTENT notification
#      until "omarchy update" is run. "Review with opencode" runs opencode to
#      review the update for conflicts with the customizations.
# Safe to delete.
set -u

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-update-check"
mkdir -p "$STATE_DIR"

# Weekly best-effort DB refresh (fakeroot, no password) so a stale local
# database still detects a proposed update. Runs at most once every 7 days.
LAST="$STATE_DIR/last-refresh"
NOW="$(date +%s)"
if [[ ! -f "$LAST" ]] || (( NOW - $(date -r "$LAST" +%s 2>/dev/null || echo 0) > 604800 )); then
  if command -v fakeroot >/dev/null 2>&1; then
    fakeroot -- pacman -Syu --print >/dev/null 2>&1 || true
  fi
  touch "$LAST"
fi

# ── 1. mosquitOmarchy repo update (priority) ──
REPO_DIR="${OMARCHY_SCRIPTS_REPO:-$HOME/mosquitOmarchy}"
REPO_REMOTE="origin"
REPO_BRANCH="master"
SCRIPTS_FLAG="$STATE_DIR/scripts-update.txt"
if command -v git >/dev/null 2>&1 && [[ -d "$REPO_DIR/.git" ]]; then
  local_head="$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || true)"
  if [[ -n "$local_head" ]]; then
    remote_head="$(timeout 15 git -C "$REPO_DIR" ls-remote "$REPO_REMOTE" "refs/heads/$REPO_BRANCH" 2>/dev/null | head -1 | awk '{print $1}')"
    if [[ -n "$remote_head" && "$remote_head" != "$local_head" ]]; then
      cat > "$SCRIPTS_FLAG.msg" <<M
Mise à jour des SCRIPTS disponible (repo mosquitOmarchy).
  • PROPRIÉTAIRE : poussez cette version dès que possible (recommandé).
  • URGENCE     : auto-update via ./setup-customarchy.sh --update-repo
                   (avant de tirer soi-même, voir la zone "Updating").
  • RECOMMANDÉ  : attendre la mise à jour du propriétaire.
M
      printf '%s' "$(cat "$SCRIPTS_FLAG.msg")" > "$SCRIPTS_FLAG"
      if command -v notify-send >/dev/null 2>&1; then
        notify-send --app-name="Omarchy scripts" --urgency=normal --expire-time=0 \
          "Mise à jour mosquitOmarchy disponible" "$(cat "$SCRIPTS_FLAG.msg")" >/dev/null 2>&1 || true
      fi
      exit 0
    fi
  fi
fi
rm -f "$SCRIPTS_FLAG" "$SCRIPTS_FLAG.msg"

# ── 2. Omarchy-related package updates ──
# Pending updates (pacman -Qu on the synced databases, no network).
PENDING="$STATE_DIR/pending.txt"
pacman -Qu 2>/dev/null > "$PENDING" || true

# Relevant packages = the Omarchy / Hyprland / Quickshell stack that this
# package customizes.
REL="$STATE_DIR/relevant.txt"
rg -i '^(omarchy|omarchy-[a-z0-9-]+|quickshell|hypr[a-z0-9-]*|qt6-[a-z0-9-]+|qtbase|waybar|mako|kanshi)' "$PENDING" 2>/dev/null > "$REL" || true
[[ -s "$REL" ]] || exit 0

COUNT="$(wc -l < "$REL")"
LIST="$(sed 's/^/     • /' "$REL")"

# ── opencode review prompt ──
PROMPT="$STATE_DIR/review.txt"
{
  printf 'Une mise à jour Omarchy concerne %s paquet(s) en attente :\n%s\n\n' "$COUNT" "$LIST"
  cat <<'EOF'
Contexte : ce système utilise le package mosquitOmarchy (~/mosquitOmarchy),
qui personnalise des fichiers maintenant susceptibles d'évoluer avec cette mise à jour :
- ~/.config/hypr/bindings.lua                     (blocs -- >>> Omarchy_Custom_Scripts_…)
- ~/.config/hypr/hyprland.lua                      (blocs Handbrake / Touchpad)
- ~/.config/omarchy/extensions/omarchy-menu.jsonc  (blocs // >>> Omarchy_Custom_Scripts)
- ~/.config/omarchy/plugins/                        (custom.power, clones custom.lock/<user>.lock)
- ~/.config/hypr/touchpad.lua
- ~/.local/bin/                                     (backlight, ultra-save, power-helper,
                                                     mega-caffeine, kbd-toggle, guitarpro, …)
- système : /etc/sudoers.d/battery-management,
            /etc/udev/rules.d/99-lenovo-charge-threshold.rules,
            /usr/local/bin/power-helper, /opt/resolve (patch libav)

Vérifie la mise à jour en attente pour les conflits possibles :
1. CAS SIMPLE (chemins/clés renommés, références cassées dans nos blocs)
   → propose les corrections pour les scripts mosquitOmarchy concernés.
2. CAS PROFOND (fonctions dupliquées ex. battery stay-awake / mega-caffeine,
   refonte du bar ou de l'idle) → NE PAS appliquer directement : propose des
   ajustements et ne les intègre qu'après discussion.

Rends un rapport court : paquets concernés, fichiers de ce package potentiellement
affectés, corrections proposées.
EOF
} > "$PROMPT"

# ── Notification (persistent until installed) ──
TERM=""
for t in foot alacritty kitty ghostty xterm; do
  command -v "$t" >/dev/null 2>&1 && TERM="$t" && break
done
ACTION=""
if [[ -n "$TERM" ]]; then
  ACTION="review=$TERM -e bash -lc 'echo; echo \"Review Omarchy update conflicts (opencode) — context: $PROMPT\"; echo; exec opencode'"
fi

TITLE="Mise à jour Omarchy : $COUNT paquet(s) en attente"
BODY="Installées via 'omarchy update'. Démarrages suivants : nouvelle notification tant qu'elles ne sont pas installées.
$LIST"

if command -v notify-send >/dev/null 2>&1; then
  if [[ -n "$ACTION" ]]; then
    notify-send --app-name="Omarchy update" --urgency=normal --expire-time=0 \
      --action="$ACTION" "$TITLE" "$BODY" >/dev/null 2>&1 || true
  else
    notify-send --app-name="Omarchy update" --urgency=normal --expire-time=0 \
      "$TITLE" "$BODY" >/dev/null 2>&1 || true
  fi
fi
exit 0
HOOK
  chmod +x "$DEST"
}

hr
msg "Update watchdog (scripts repo first, then Omarchy updates)"
if [[ -f "$DEST" ]] && rg -q -e 'customarchy' "$DEST"; then
  warn "The hook is already installed: $DEST"
  ask "Re-install it (refresh the hook code)?" n || { ok "Kept as-is."; hr; exit 0; }
fi

if [[ -d "$DEST_DIR" ]] || mkdir -p "$DEST_DIR"; then
  write_hook
fi

ok "Hook installed: $DEST"
ok "At each boot: scripts-repo update check first, then pending Omarchy update → persistent notification + opencode review action."
echo
echo "  Debug/state (transient): ~/.local/state/omarchy-update-check/"
echo "  Uninstall:                ./setup-customarchy.sh --uninstall  (module: mosquitomarchy-update)"
hr