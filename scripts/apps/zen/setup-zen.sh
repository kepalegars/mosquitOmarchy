#!/usr/bin/env bash
# =============================================================================
# Omarchy Custom - Zen Browser config (plugins + settings + chrome theme)
# =============================================================================
# Deploys the user's Zen browser configuration into the ACTIVE profile:
#   - extensions (XPI from seed/extensions/) -> <profile>/extensions/
#   - extension settings (preferences/settings JSON) -> <profile>/
#   - chrome (zen-themes.css + zen-themes/ from seed/chrome/) -> <profile>/chrome/
#
# The seed/ directory is the canonical copy kept in this repository (refreshed
# via scripts/apps/zen under the "apps" module handling zen-browser-bin). The
# active profile is detected from $HOME/.config/zen/profiles.ini:
#   1. the [Install...] block (Default=<profile>) — what zen-bin actually runs,
#   2. fallback: the [Profile...] block marked Default=1,
#   3. fallback: the profile with the most recently modified places.sqlite.
# Relies on the app being installed (zen-browser-bin, see the "apps" module);
# missings are handled by the restore-time deps manifest (deps).
#
# Usage:
#   ./setup-zen.sh                    # deploy the seed config into the active profile
#   ./setup-zen.sh -y                 # non-interactive (overwrite existing files)
#   ./setup-zen.sh --status           # report the active profile + applied state
#   ./setup-zen.sh --remove           # remove what this module deployed
#
# NOTE: only files this module owns (exact copies of the seed) are overwritten
# without asking; anything the user hand-tweaked is preserved (asked first).
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/gui-run.bash"
set -euo pipefail

info() { echo -e "\033[1;34m==>\033[0m $*"; }
ok()   { echo -e "\033[1;32m ✓\033[0m $*"; }
warn() { echo -e "\033[1;33m !\033[0m $*"; }
err()  { echo -e "\033[1;31m ✗\033[0m $*" >&2; }

if [[ ! -d /usr/share/omarchy ]]; then
  echo "This script is meant for Omarchy." >&2
  exit 1
fi

REAL_HOME="${HOME}"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEED_DIR="$SELF_DIR/seed"
ZEN_CFG="$REAL_HOME/.config/zen"
PROFILES_INI="$ZEN_CFG/profiles.ini"
INSTALLS_INI="$ZEN_CFG/installs.ini"

STATUS_ONLY=false REMOVE=false YES=false
for a in "$@"; do case "$a" in
  -y|--yes)         YES=true ;;
  --status)         STATUS_ONLY=true ;;
  --remove)         REMOVE=true ;;
  -h|--help)        sed -n '2,38p' "$0"; exit 0 ;;
  *)                echo "Unknown option: $a (supported: -y --status --remove)" >&2; exit 1 ;;
esac; done

[[ -d $SEED_DIR ]] || { err "seed/ directory missing ($SEED_DIR) — module incomplete."; exit 1; }

# -----------------------------------------------------------------------------
# Active profile resolution
# -----------------------------------------------------------------------------
zen_active_profile() {
  [[ -f $PROFILES_INI ]] || return 1
  # 1. [Install...] block: the profile that install actually runs (Default=).
  local prof
  prof="$(awk -v FS='=' '
    /^\[/ { in_install = ($0 ~ /^\[Install/) }
    in_install && /^Default=/ { print $2; exit }
  ' "$PROFILES_INI")"
  [[ -n $prof ]] && { [[ -d "$ZEN_CFG/$prof" ]] && { printf '%s' "$prof"; return 0; } }
  # 2. [Profile...] block marked Default=1.
  prof="$(awk -v FS='=' '
    /^\[/ { in_profile = ($0 ~ /^\[Profile/); default_after = 0 }
    in_profile && /^Default=1$/ { default_after = 1 }
    in_profile && default_after && /^Path=/ { print $2; exit }
  ' "$PROFILES_INI")"
  [[ -n $prof ]] && { [[ -d "$ZEN_CFG/$prof" ]] && { printf '%s' "$prof"; return 0; } }
  # 3. The profile with the most recently modified places.sqlite.
  prof="$(cd "$ZEN_CFG" 2>/dev/null && ls -td */*/places.sqlite 2>/dev/null | head -1 || true)"
  [[ -n $prof ]] && { printf '%s' "${prof%/*/places.sqlite}"; return 0; }
  return 1
}

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
ask() {
  $YES && return 0
  local r; read -rp "$1 [y/N] " r; [[ ${r:-n} =~ ^[yY] ]]
}

file_content_differs() { # file seed_file -> 0 if different, 1 if equal/absent
  [[ -f $1 && -f $2 ]] || return 0
  cmp -s "$1" "$2" && return 1 || return 0
}

count_seed_extensions() { compgen -G "$SEED_DIR/extensions/*.xpi" >/dev/null 2>&1 && ls "$SEED_DIR"/extensions/*.xpi 2>/dev/null | wc -l || echo 0; }

# -----------------------------------------------------------------------------
# --status
# -----------------------------------------------------------------------------
do_status() {
  info "Zen Browser config module — status"
  echo "  • zen-browser-bin package: $(pkg_has() { command -v pacman >/dev/null && pacman -Q zen-browser-bin &>/dev/null; } && pkg_has && echo installed || echo 'not installed (apps module / deps manifest)')"
  if [[ -d $ZEN_CFG ]]; then
    local prof; prof="$(zen_active_profile || true)"
    if [[ -n $prof ]]; then
      echo "  • Active profile: $prof"
      local applied=0 total; total="$(count_seed_extensions)"
      for x in "$SEED_DIR"/extensions/*.xpi; do
        [[ -f "$ZEN_CFG/$prof/extensions/${x##*/}" ]] && applied=$((applied+1))
      done
      echo "  • Seed extensions deployed: $applied/$total"
      echo "  • extension-preferences.json: $([[ -f "$ZEN_CFG/$prof/extension-preferences.json" ]] && echo copied-backup-or-applied || echo absent)"
      echo "  • chrome/zen-themes.css: $([[ -f "$ZEN_CFG/$prof/chrome/zen-themes.css" ]] && echo present || echo absent)"
    else
      warn "No usable profile detected in $ZEN_CFG (profiles.ini)."
    fi
  else
    echo "  • $ZEN_CFG not present (Zen not configured yet)."
  fi
}

# -----------------------------------------------------------------------------
# --remove
# -----------------------------------------------------------------------------
do_remove() {
  local prof; prof="$(zen_active_profile || true)"
  [[ -n $prof ]] || { warn "Active profile not found — nothing removed."; return 0; }
  info "Removing the module's deployed files from profile '$prof'"
  $YES || if ! ask "Remove the seed extensions + settings + chrome from $prof?"; then ok "Cancelled."; return 0; fi
  local removed=0 f
  for f in "$SEED_DIR"/extensions/*.xpi; do
    [[ -f "$ZEN_CFG/$prof/extensions/${f##*/}" ]] && { rm -f "$ZEN_CFG/$prof/extensions/${f##*/}"; echo "  - removed extensions/${f##*/}"; removed=$((removed+1)); }
  done
  for f in extension-preferences.json extension-settings.json; do
    [[ -f "$ZEN_CFG/$prof/$f" ]] && { rm -f "$ZEN_CFG/$prof/$f"; echo "  - removed $f"; removed=$((removed+1)); }
  done
  for f in "$SEED_DIR"/chrome/*; do
    [[ -e "$ZEN_CFG/$prof/chrome/${f##*/}" ]] && { rm -rf "$ZEN_CFG/$prof/chrome/${f##*/}"; echo "  - removed chrome/${f##*/}"; removed=$((removed+1)); }
  done
  ((removed > 0)) && ok "Removed $removed item(s). Zen re-installs the stock defaults." || ok "Nothing deployed — nothing to remove."
  warn "zen-browser-bin itself stays installed (uninstall via the apps module or: sudo pacman -Rns zen-browser-bin)"
}

# -----------------------------------------------------------------------------
# Deploy
# -----------------------------------------------------------------------------
deploy() {
  info "Deploying the Zen config into the active profile"
  pkg_has_zen() { command -v pacman >/dev/null && pacman -Q zen-browser-bin &>/dev/null; }
  if ! pkg_has_zen; then
    warn "zen-browser-bin not installed — the config is staged but inactive until the browser exists."
    if ! $YES && ! ask "Continue staging the config anyway?"; then return 0; fi
  fi

  local prof; prof="$(zen_active_profile || true)"
  if [[ -z $prof ]]; then
    warn "Active profile not detected from profiles.ini — waiting for a first Zen launch."
    return 0
  fi
  [[ -f $PROFILES_INI ]] || { warn "$PROFILES_INI missing — install first."; return 1; }
  echo "  • Active profile: $prof"

  # Custom files (not module-owned) are preserved and reported.
  local deployed=0 changed=0
  local seed profile

  # 1) Extensions
  for seed in "$SEED_DIR"/extensions/*.xpi; do
    [[ -f $seed ]] || continue
    profile="$ZEN_CFG/$prof/extensions/${seed##*/}"
    if [[ -f $profile ]]; then
      if cmp -s "$seed" "$profile"; then
        echo "  = extensions/${seed##*/} (already identical)"
      else
        if $YES || ask "Overwrite extensions/${seed##*/} (differs from the seed)?"; then
          cp -f "$seed" "$profile"; echo "  + extensions/${seed##*/} (updated to seed)"; changed=$((changed+1))
        else
          warn "kept existing extensions/${seed##*/}"
        fi
      fi
    else
      cp -f "$seed" "$profile"; echo "  + extensions/${seed##*/}"; deployed=$((deployed+1))
    fi
  done

  # 2) Extension settings
  for seed in "$SEED_DIR"/extension-preferences.json "$SEED_DIR"/extension-settings.json; do
    [[ -f $seed ]] || continue
    profile="$ZEN_CFG/$prof/${seed##*/}"
    if [[ -f $profile ]]; then
      if cmp -s "$seed" "$profile"; then
        echo "  = ${seed##*/} (already identical)"
      else
        if $YES || ask "Overwrite ${seed##*/} (differs from the seed)?"; then
          cp -f "$seed" "$profile"; echo "  + ${seed##*/} (updated to seed)"; changed=$((changed+1))
        else
          warn "kept existing ${seed##*/}"
        fi
      fi
    else
      cp -f "$seed" "$profile"; echo "  + ${seed##*/}"; deployed=$((deployed+1))
    fi
  done

  # 3) chrome (zen-themes.css + zen-themes/)
  for seed in "$SEED_DIR"/chrome/*; do
    [[ -e $seed ]] || continue
    if [[ -d $seed ]]; then
      [[ -d "$ZEN_CFG/$prof/chrome/${seed##*/}" ]] \
        && cp -a "$seed/." "$ZEN_CFG/$prof/chrome/${seed##*/}/" \
        || { mkdir -p "$ZEN_CFG/$prof/chrome/${seed##*/}"; cp -a "$seed/." "$ZEN_CFG/$prof/chrome/${seed##*/}/"; }
      echo "  + chrome/${seed##*/}/ (merged)"; deployed=$((deployed+1))
    else
      mkdir -p "$ZEN_CFG/$prof/chrome"
      profile="$ZEN_CFG/$prof/chrome/${seed##*/}"
      if [[ -f $profile ]] && ! cmp -s "$seed" "$profile"; then
        if $YES || ask "Overwrite chrome/${seed##*/} (differs from the seed)?"; then
          cp -f "$seed" "$profile"; echo "  + chrome/${seed##*/} (updated)"; changed=$((changed+1))
        else
          warn "kept existing chrome/${seed##*/}"
        fi
      elif [[ ! -f $profile ]]; then
        cp -f "$seed" "$profile"; echo "  + chrome/${seed##*/}"; deployed=$((deployed+1))
      else
        echo "  = chrome/${seed##*/} (already identical)"
      fi
    fi
  done

  echo ""
  ok "Zen config deployed: $deployed new, $changed updated. Total seed extensions: $(count_seed_extensions)."
  warn "Restart Zen (or open a new window) for the changes to take effect."
}

# -----------------------------------------------------------------------------
# MAIN
# -----------------------------------------------------------------------------
if $STATUS_ONLY; then do_status; exit 0; fi
if $REMOVE; then do_remove; exit 0; fi
deploy