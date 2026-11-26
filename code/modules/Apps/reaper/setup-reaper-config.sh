#!/usr/bin/env bash
# Installs the Reapertips theme pack into REAPER, then applies the user's own
# custom REAPER configuration (if one is present). --revert undoes the visual
# part: the REAPER config is restored from the backup taken at install time and
# the generated theme assets are removed. Scripts, plugins, JSFX, ReaPacks and
# SWS files are never touched by a revert.
#
# What an install does, all taken from the newest Reapertips archive in ./configs:
#   • LSP plugins (EQ, dynamics, limiter) from the Arch repos, when missing;
#   • ReaPack + SWS, downloaded from GitHub Releases or copied from ~/Downloads;
#   • the Omarchy-generated theme: the Reapertips dark or light base recoloured
#     to Omarchy's accent and set in its system font (generated once, never
#     rewritten at launch);
#   • the Linux libSwell window colours, same accent;
#   • the purple toolbar icons (100%, 150%, 200%);
#   • the REAPER 7 splash screen.
# Then, if ./configs/custom/ exists, its tree is copied over the REAPER resource
# path. Every file it overwrites is copied first into ./backups/<date>-install/.
# The manifest in .mosquitomarchy/ records only what a revert owns: reaper.ini,
# the generated theme, the splash, libSwell colours and the toolbar icons.
#
# Usage: setup-reaper-config.sh [--fonts=system|reapertips] [--revert]
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../lib/gui-run.bash"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../lib/elevate.bash"  # mq_sudo
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIGS="$HERE/configs"
RES="${REAPER_RESOURCE_PATH:-$HOME/.config/REAPER}"
STATE="$RES/.mosquitomarchy"
MANIFEST="$STATE/manifest"
BACKUP_ROOT="${REAPER_BACKUP_DIR:-$HERE/backups}"
BK="$BACKUP_ROOT/$(date +%Y-%m-%d_%H-%M-%S)-install"
TARGET="$RES/ColorThemes/Reapertips Theme – Omarchy.ReaperThemeZip"

MODE=install
FONTS=system
for a in "$@"; do
  case "$a" in
    --fonts=system|--fonts=reapertips) FONTS="${a#*=}" ;;
    --revert) MODE=revert ;;
  esac
done
case "$FONTS" in
  system|reapertips) ;;
  *) echo "Unknown font choice: $FONTS (expected system or reapertips)" >&2; exit 1 ;;
esac

write_info() { # write_info <backup dir> <action>
  {
    printf 'REAPER config backup\n'
    printf 'action: %s\n' "$2"
    printf 'date: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'source: %s\n' "$RES"
  } >"$1/backup-info.txt"
}

backup_file() { # backup_file <absolute destination>
  local dst="$1" rel
  [[ -e $dst || -L $dst ]] || return 0
  rel="${dst#"$RES"/}"
  mkdir -p "$BK/$(dirname "$rel")"
  cp -a -- "$dst" "$BK/$rel"
}

track_rel() { # track_rel B|A <path relative to RES>
  grep -qxF "$1$2" "$MANIFEST" 2>/dev/null && return 0
  printf '%s%s\n' "$1" "$2" >>"$MANIFEST"
}

# track_file records a destination BEFORE it is written: B (backed up, restore
# it) when it already exists, A (added by us, delete it) when it does not.
# One record per path, ever: a re-install must not turn an original into a
# "backup" of our own output, nor forget that a path was ours.
track_file() {
  local dst="$1" rel
  rel="${dst#"$RES"/}"
  [[ $dst == "$RES"/* ]] || return 0
  grep -qxF "B$rel" "$MANIFEST" 2>/dev/null && return 0
  grep -qxF "A$rel" "$MANIFEST" 2>/dev/null && return 0
  if [[ -e $dst || -L $dst ]]; then
    backup_file "$dst"
    track_rel B "$rel"
  else
    track_rel A "$rel"
  fi
}

set_ini() { # set_ini <key> <value>  (inside [reaper], one copy only)
  # reaper.ini is section-scoped. Appending a key at EOF made REAPER ignore it:
  # it kept its own empty splashimage= in [reaper] and showed the stock splash.
  local ini="$RES/reaper.ini" key="$1" val="$2"
  [[ -f $ini ]] || return 0
  awk -v k="$key" -v v="$key=$val" '
    BEGIN { in_reaper = 0; seen = 0 }
    /^\[reaper\][[:space:]]*$/ {
      print; print v; in_reaper = 1; seen = 1; next
    }
    /^\[/ { in_reaper = 0 }
    index($0, k "=") == 1 { next }
    { print }
    END { if (!seen) print v }
  ' "$ini" >"$ini.mosq-tmp" && cat "$ini.mosq-tmp" >"$ini" && rm -f "$ini.mosq-tmp"
}

del_ini() { # del_ini <key>
  [[ -f $RES/reaper.ini ]] || return 0
  sed -i "/^$1=/d" "$RES/reaper.ini"
}

revert() {
  if [[ ! -f $MANIFEST ]]; then
    echo "Nothing to restore: no REAPER config backup was recorded." >&2
    echo "Install the config with P in Setup first." >&2
    exit 1
  fi

  # Keep the config REAPER has right now before replacing it: restoring the
  # install-time file must never be a one-way door.
  local restore_bk="$BACKUP_ROOT/$(date +%Y-%m-%d_%H-%M-%S)-before-restore"
  mkdir -p "$restore_bk"
  if [[ -f $RES/reaper.ini ]]; then
    cp -a -- "$RES/reaper.ini" "$restore_bk/reaper.ini"
  fi
  write_info "$restore_bk" "before-restore"
  echo "Current config saved to $restore_bk/reaper.ini"

  local line rel d src restored=0
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    rel="${line:1}"
    case "$line" in
      A*) # created by the install: nothing to put back, just remove it
        # reaper.ini is never deleted: REAPER keeps writing the user's settings
        # into it after the install. The stale keys are cleaned below instead.
        if [[ $rel == reaper.ini ]]; then
          continue
        fi
        if [[ -e $RES/$rel || -L $RES/$rel ]]; then
          rm -f -- "$RES/$rel"
          restored=$((restored + 1))
        fi
        ;;
      B*) # the oldest install backup is the true pre-install file
        src=""
        for d in "$BACKUP_ROOT"/*-install; do
          [[ -d $d ]] || continue
          if [[ -e $d/$rel || -L $d/$rel ]]; then src="$d/$rel"; break; fi
        done
        if [[ -n $src ]]; then
          mkdir -p "$(dirname "$RES/$rel")"
          cp -a -- "$src" "$RES/$rel"
          restored=$((restored + 1))
        fi
        ;;
    esac
  done <"$MANIFEST"

  # The restored config may name a theme or splash that this revert removed;
  # leaving the pointer behind is what makes REAPER keep the old look. Only our
  # own paths are dropped: a theme the user keeps elsewhere is their business.
  local cur
  cur="$(sed -n 's/^lastthemefn5=//p' "$RES/reaper.ini" 2>/dev/null | tail -1)"
  if [[ $cur == *"/ColorThemes/Reapertips Theme – "* && ! -f $cur ]]; then
    del_ini lastthemefn5
  fi
  cur="$(sed -n 's/^splashimage=//p' "$RES/reaper.ini" 2>/dev/null | tail -1)"
  if [[ $cur == "$RES/splash.png" && ! -f $cur ]]; then
    del_ini splashimage
  fi

  # Fonts the install copied into the user's font dir go too (only the ones it
  # actually created; a pre-existing copy was never recorded).
  if [[ -f $STATE/fonts-added ]]; then
    local f
    while IFS= read -r f; do
      [[ -n $f ]] && rm -f -- "$f"
    done <"$STATE/fonts-added"
    command -v fc-cache >/dev/null 2>&1 && fc-cache -f >/dev/null || true
  fi

  # The theme generator must find no base, or the next launch would recreate
  # the theme we just removed. The backups stay for the user.
  rm -f -- "$STATE"/reapertips-base*.ReaperThemeZip "$STATE/libSwell-base.colortheme" \
    "$STATE/font-mode" "$MANIFEST" "$STATE/fonts-added"

  echo "Restored $restored file(s). Backups: $BACKUP_ROOT"
  echo "Launch REAPER from the launcher (or: ~/.local/bin/reaper-launch)."
}

if [[ $MODE == revert ]]; then
  revert
  exit 0
fi

shopt -s nullglob
archives=("$CONFIGS"/[Rr]eapertips*Theme*.zip)
# The archive is not shipped: pick the newest one straight out of ~/Downloads
# and file it here. No bootstrap step, no prompt.
if (( ${#archives[@]} == 0 )); then
  downloaded=("$HOME"/Downloads/[Rr]eapertips*Theme*.zip)
  if (( ${#downloaded[@]} )); then
    newest="$(printf '%s\n' "${downloaded[@]}" | sort -V | tail -1)"
    mkdir -p "$CONFIGS"
    cp -f -- "$newest" "$CONFIGS/"
    echo "Copied theme archive from Downloads: $(basename "$newest")"
    archives=("$CONFIGS"/[Rr]eapertips*Theme*.zip)
  fi
fi
shopt -u nullglob
if (( ${#archives[@]} == 0 )); then
  echo "No Reapertips theme archive found." >&2
  echo "Put 'Reapertips Theme v*.zip' in ~/Downloads (or in $CONFIGS) and retry." >&2
  exit 1
fi
ARCHIVE="$(printf '%s\n' "${archives[@]}" | sort -V | tail -1)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unzip -q "$ARCHIVE" -d "$TMP"

THEME_DARK="$(find "$TMP" -type f -path '*/02_Theme/Theme Variations/*Purple*.ReaperThemeZip' -print -quit)"
[[ -n $THEME_DARK ]] || THEME_DARK="$(find "$TMP" -type f -path '*/02_Theme/*Purple*.ReaperThemeZip' -print -quit)"
[[ -n $THEME_DARK ]] || { echo "The archive has no Purple ReaperThemeZip in 02_Theme/" >&2; exit 1; }
THEME_LIGHT="$(find "$TMP" -type f -path '*/02_Theme/Theme Variations/*– Light.ReaperThemeZip' -print -quit)"

FONTDIR="$(find "$TMP" -type d -path '*/01_Install these fonts' -print -quit)"
TOOLBAR="$(find "$TMP" -type d -path '*/04_Toolbar Icons/other colors/purple' -print -quit)"
COLORTHEME="$(find "$TMP" -type f -path '*/03_Extras/Linux Colortheme/libSwell-user.colortheme' -print -quit)"
# The small Mac splash from 03_Extras is the one used (the full-size one
# dominates a 1080p window). Fall back to the full version if it is absent.
SPLASH="$(find "$TMP" -type f -path '*/03_Extras/REAPER 7 Splash Screens/Mac/Reapertips_Splash-01_small.png' -print -quit)"
[[ -n $SPLASH ]] || SPLASH="$(find "$TMP" -type f -name Reapertips_Splash-01_small.png -print -quit)"
[[ -n $SPLASH ]] || SPLASH="$(find "$TMP" -type f -path '*/03_Extras/REAPER 7 Splash Screens/Mac/Reapertips_Splash-01.png' -print -quit)"
[[ -n $SPLASH ]] || SPLASH="$(find "$TMP" -type f -name Reapertips_Splash-01.png -print -quit)"

mkdir -p "$STATE" "$RES/ColorThemes" "$RES/Data/toolbar_icons/150" "$RES/Data/toolbar_icons/200" "$HOME/.local/bin" "$BACKUP_ROOT"

# The config is the file that decides which theme REAPER loads; it is backed up
# whole, before the custom config or any theme setting can change it.
track_file "$RES/reaper.ini"

echo "== 1/7 LSP plugins =="
# Non-fatal: the theme is the point of this action, and pacman can be offline.
if mq_sudo pacman -S --needed --noconfirm \
    lsp-plugins lsp-plugins-clap lsp-plugins-vst3 lsp-plugins-vst lsp-plugins-lv2; then
  echo "LSP plugins ready (VST2/VST3/CLAP/LV2)."
else
  echo "WARNING: LSP plugins could not be installed (offline?). The theme still goes in." >&2
fi

echo "== 2/7 ReaPack + SWS ="
# Both come from GitHub Releases; a compatible file in ~/Downloads wins
# so the user can pick a version. Non-fatal, like the LSP step.
bash "$HERE/reaper-addons.bash" install "$RES/UserPlugins" || true

echo "== 3/7 Fonts ($FONTS) =="
if [[ $FONTS == reapertips && -d $FONTDIR ]]; then
  mkdir -p "$HOME/.local/share/fonts"
  for f in "$FONTDIR"/*.ttf; do
    [[ -f $f ]] || continue
    dst="$HOME/.local/share/fonts/$(basename "$f")"
    [[ -e $dst ]] || printf '%s\n' "$dst" >>"$STATE/fonts-added"
    cp -f -- "$f" "$dst"
  done
  command -v fc-cache >/dev/null 2>&1 && fc-cache -f "$HOME/.local/share/fonts" >/dev/null || true
  echo "Installed the Reapertips fonts (Fira Sans, Roboto)."
else
  echo "Using Omarchy's system font."
fi

echo "== 4/7 Custom config (backup first) =="
echo "The newest Reapertips Theme v*.zip in ~/Downloads is copied into $CONFIGS"
echo "automatically — no bootstrap needed. It is not shipped with the repo."
CUSTOM="$CONFIGS/custom"
if [[ -d $CUSTOM ]]; then
  applied=0
  # backup_file only: scripts, plugins, JSFX, ReaPacks and SWS files copied here
  # stay on revert. The backup is for manual recovery, not for undo.
  while IFS= read -r -d '' src; do
    rel="${src#"$CUSTOM"/}"
    dst="$RES/$rel"
    backup_file "$dst"
    mkdir -p "$(dirname "$dst")"
    cp -a -- "$src" "$dst"
    applied=$((applied + 1))
  # .gitkeep/README.md are repo bookkeeping, not REAPER config: never copy them.
  done < <(find "$CUSTOM" \( -type f -o -type l \) ! -name .gitkeep ! -name README.md -print0)
  echo "Applied $applied file(s) from configs/custom/."
else
  echo "No configs/custom/ folder — theme assets only."
fi

echo "== 5/7 Theme (dark/light) + Linux window colours =="
mkdir -p "$BK"
write_info "$BK" install
cp -f -- "$THEME_DARK" "$STATE/reapertips-base-dark.ReaperThemeZip"
if [[ -n $THEME_LIGHT ]]; then
  cp -f -- "$THEME_LIGHT" "$STATE/reapertips-base-light.ReaperThemeZip"
fi
printf '%s\n' "$FONTS" >"$STATE/font-mode"
if [[ -f $COLORTHEME ]]; then
  [[ -f $STATE/libSwell-base.colortheme ]] || cp -f -- "$COLORTHEME" "$STATE/libSwell-base.colortheme"
fi
track_file "$TARGET"
track_file "$RES/libSwell-user.colortheme"
# One-shot generation: the theme and its pointer are then left alone.
bash "$HERE/reaper-theme-apply"
echo "Theme: $TARGET (applied once)"

echo "== 6/7 Toolbar icons + splash =="
if [[ -d $TOOLBAR ]]; then
  for f in "$TOOLBAR"/*; do
    [[ -f $f ]] || continue
    dst="$RES/Data/toolbar_icons/$(basename "$f")"
    track_file "$dst"
    cp -f -- "$f" "$dst"
  done
  for d in 150 200; do
    [[ -d $TOOLBAR/$d ]] || continue
    for f in "$TOOLBAR/$d"/*; do
      [[ -f $f ]] || continue
      dst="$RES/Data/toolbar_icons/$d/$(basename "$f")"
      track_file "$dst"
      cp -f -- "$f" "$dst"
    done
  done
  echo "Toolbar icons: $RES/Data/toolbar_icons/"
fi
if [[ -f $SPLASH ]]; then
  track_file "$RES/splash.png"
  cp -f -- "$SPLASH" "$RES/splash.png"
  echo "Splash: $RES/splash.png"
fi

echo "== 7/7 REAPER settings =="
mkdir -p "$RES"
touch "$RES/reaper.ini"
set_ini lastthemefn5 "$TARGET"
if [[ -f $SPLASH ]]; then
  set_ini splash 1
  set_ini splashimage "$RES/splash.png"
fi

echo "Backup: $BK"
echo "Done. Launch REAPER from the launcher (or: ~/.local/bin/reaper-launch)."
