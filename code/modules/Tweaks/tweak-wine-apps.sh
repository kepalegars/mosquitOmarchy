#!/usr/bin/env bash
# =============================================================================
# mosquitOmarchy - Wine: promote installer shortcuts into the Omarchy app menu
# =============================================================================
# A Windows installer publishes its Start-Menu shortcuts, and Wine copies them
# into ~/.local/share/applications/wine/Programs/<vendor>/<app>/*.desktop.
# They work, but they live in a "Wine/Programs" tree and use the installer's
# raw name/icon. This tweak turns each real application shortcut into a normal
# top-level app entry (so it shows in the Apps menu), copies/uses its icon, and
# moves the original Wine .desktop to the desktop trash.
#
# It is not a permanent converter daemon:
#   * a systemd .path unit watches the Wine applications tree;
#   * a change starts a one-shot watcher service, which exits immediately when
#     no Wine process is running (so it does nothing outside a Wine wizard);
#   * while a Wine process is alive it follows the tree with inotifywait (or a
#     2 s poll fallback) and converts entries as soon as they are written;
#   * an APM install is detected and skipped entirely: APM removes its own
#     launcher entries, and this script must never race it.
#
# Uninstallers, "Manual"/readme entries, NoDisplay file associations and
# non-Wine entries are never promoted. The source .desktop is moved with
# `gio trash` (fallback `trash-put`); if neither exists it is left in place.
#
# Usage:
#   ./tweak-wine-apps.sh              # install + convert current entries
#   ./tweak-wine-apps.sh --scan       # convert once (only during a Wine run)
#   ./tweak-wine-apps.sh --scan --force  # convert current entries now
#   ./tweak-wine-apps.sh --watch      # internal: watcher service
#   ./tweak-wine-apps.sh --status
#   ./tweak-wine-apps.sh --remove     # remove watcher/units (entries kept)
# =============================================================================
set -uo pipefail

G='\033[1;32m'; B='\033[1;34m'; Y='\033[1;33m'; R='\033[1;31m'; N='\033[0m'
msg(){ printf "${B}==>${N} %s\n" "$*"; }
ok(){  printf " ${G}✓${N} %s\n" "$*"; }
warn(){ printf "${Y} !${N} %s\n" "$*" >&2; }
err(){ printf "${R} ✗${N} %s\n" "$*" >&2; }

REAL_HOME="$HOME"
SELF="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
BIN_DIR="$REAL_HOME/.local/bin"
DEPLOYED="$BIN_DIR/mosquitomarchy-wine-apps"
APPS_DIR="${XDG_DATA_HOME:-$REAL_HOME/.local/share}/applications"
WINE_ROOT="$APPS_DIR/wine"
PROGRAMS="$WINE_ROOT/Programs"
ICON_DIR="${XDG_DATA_HOME:-$REAL_HOME/.local/share}/icons/hicolor/256x256/apps"
UNIT_DIR="${XDG_CONFIG_HOME:-$REAL_HOME/.config}/systemd/user"
PATH_UNIT="$UNIT_DIR/mosquitomarchy-wine-apps.path"
SERVICE_UNIT="$UNIT_DIR/mosquitomarchy-wine-apps.service"
PATH_NAME="mosquitomarchy-wine-apps.path"
SERVICE_NAME="mosquitomarchy-wine-apps.service"

STATUS_ONLY=false REMOVE=false FORCE=false SCAN=false WATCH=false
while (( $# )); do
  case "$1" in
    --status) STATUS_ONLY=true ;;
    --remove|--uninstall) REMOVE=true ;;
    --scan) SCAN=true ;;
    --watch) WATCH=true ;;
    --force) FORCE=true ;;
    -h|--help) sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) err "Unknown option: $1"; exit 1 ;;
  esac
  shift
done

apm_busy(){
  pgrep -f 'mosquito-audio-plugin-manager-actions install' >/dev/null 2>&1
}

wine_active(){
  pgrep -f '(/|^)(wine|wine64|wine-preloader)([[:space:]]|$)' >/dev/null 2>&1 && return 0
  pgrep -x wineserver >/dev/null 2>&1
}

slugify(){
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

# read_key <key> <file>: one Desktop Entry value, quotes stripped.
read_key(){
  local key="$1" file="$2" v
  v="$(grep -m1 -iE "^[[:space:]]*${key}[[:space:]]*=" "$file" 2>/dev/null | sed 's/^[^=]*=[[:space:]]*//' | tr -d '\r')"
  # Only a value wrapped in quotes loses them. Exec= usually contains its own
  # quoted Windows paths, and stripping those turns a valid command into a
  # truncated one.
  if [[ $v == \"*\" && $v == *\" ]]; then
    v="${v#\"}"; v="${v%\"}"
  fi
  printf '%s' "$v"
}

# skip_entry <name> <source>: true for things that are not real app entries.
skip_entry(){
  local name="$1" src="$2"
  [[ -n $name ]] || return 0
  case "${name,,}" in
    *uninstall*|*unins*|*manual*|*readme*|*read\ me*|*help*|*website*|*web\ site*|\
    *documentation*|*license*|*repair*|*modify*|*remove*|*setup*|*install*) return 0 ;;
  esac
  grep -qiE '^[[:space:]]*NoDisplay[[:space:]]*=[[:space:]]*true' "$src" 2>/dev/null && return 0
  return 1
}

# icon_for <source.desktop> <slug>: an icon name or an absolute path.
icon_for(){
  local src="$1" slug="$2" icon ext
  icon="$(read_key Icon "$src")"
  [[ -n $icon ]] || { printf ''; return 0; }
  if [[ -f $icon ]]; then
    ext="${icon##*.}"; ext="${ext,,}"
    case "$ext" in
      ico)
        mkdir -p "$ICON_DIR"
        if command -v magick >/dev/null 2>&1; then
          magick "$icon" "$ICON_DIR/$slug.png" 2>/dev/null && { printf '%s' "$slug"; return 0; }
        elif command -v convert >/dev/null 2>&1; then
          convert "$icon" "$ICON_DIR/$slug.png" 2>/dev/null && { printf '%s' "$slug"; return 0; }
        fi
        printf '%s' "$icon"; return 0
        ;;
      png|svg|xpm|jpg|jpeg)
        mkdir -p "$ICON_DIR"
        if cp -f "$icon" "$ICON_DIR/$slug.$ext" 2>/dev/null; then
          printf '%s' "$slug"; return 0
        fi
        ;;
    esac
    printf '%s' "$icon"; return 0
  fi
  # A theme icon name ("wine", "applications-games", ...) is already usable.
  printf '%s' "$icon"
}

# Move the source entry to the desktop trash; never delete it outright.
trash_source(){
  local src="$1"
  if command -v gio >/dev/null 2>&1 && gio trash -- "$src" 2>/dev/null; then
    return 0
  fi
  if command -v trash-put >/dev/null 2>&1 && trash-put -- "$src" 2>/dev/null; then
    return 0
  fi
  warn "could not move to trash: $src (left in place; the promoted entry remains)"
  return 1
}

prune_dirs(){
  local d="$1"
  while [[ $d == "$PROGRAMS"/* ]]; do
    [[ -n $(find "$d" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null) ]] && break
    rmdir "$d" 2>/dev/null || break
    d="$(dirname "$d")"
  done
}

convert_one(){
  local src="$1" name exec icon comment categories slug dest mark
  [[ -f $src ]] || return 0
  [[ $src == "$PROGRAMS"/* ]] || return 0
  name="$(read_key Name "$src")"
  exec="$(read_key Exec "$src")"
  [[ -n $exec ]] || return 0
  [[ -n $name ]] || name="$(basename "$src" .desktop)"
  skip_entry "$name" "$src" && return 0
  grep -qi 'wine' <<< "$exec" || return 0

  slug="$(slugify "$name")"
  [[ -n $slug ]] || slug="app-$(printf '%s' "$src" | cksum | awk '{print $1}')"
  slug="wine-$slug"
  dest="$APPS_DIR/$slug.desktop"
  if [[ -f $dest ]]; then
    mark="$(read_key X-MosquitOmarchy-Wine-Source "$dest")"
    if [[ -n $mark && $mark != "$src" ]]; then
      slug="$slug-$(printf '%s' "$src" | cksum | awk '{print $1}')"
      dest="$APPS_DIR/$slug.desktop"
    fi
  fi

  icon="$(icon_for "$src" "$slug")"
  comment="$(read_key Comment "$src")"
  categories="$(read_key Categories "$src")"
  [[ -n $categories ]] || categories='Utility;'

  mkdir -p "$APPS_DIR"
  {
    printf '[Desktop Entry]\n'
    printf 'Type=Application\n'
    printf 'Name=%s\n' "$name"
    [[ -n $comment ]] && printf 'Comment=%s\n' "$comment"
    printf 'Exec=%s\n' "$exec"
    [[ -n $icon ]] && printf 'Icon=%s\n' "$icon"
    printf 'Terminal=false\n'
    printf 'Categories=%s\n' "$categories"
    printf 'StartupNotify=true\n'
    printf 'X-MosquitOmarchy-Wine-Source=%s\n' "$src"
    printf 'X-MosquitOmarchy-Wine-Key=%s\n' "$slug"
  } > "$dest" 2>/dev/null || { warn "could not write $dest"; return 0; }
  chmod 0644 "$dest" 2>/dev/null || true
  trash_source "$src" || true
  prune_dirs "$(dirname "$src")"
  printf 'promoted %s -> %s\n' "${src#"$APPS_DIR"/}" "${dest#"$APPS_DIR"/}"
}

refresh_caches(){
  command -v update-desktop-database >/dev/null 2>&1 \
    && update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true
  local hicolor="${ICON_DIR%/256x256/apps}"
  command -v gtk-update-icon-cache >/dev/null 2>&1 \
    && gtk-update-icon-cache -f -t "$hicolor" >/dev/null 2>&1 || true
}

convert_all(){
  [[ -d $PROGRAMS ]] || return 0
  local n=0 f
  while IFS= read -r -d '' f; do
    convert_one "$f"
    n=$((n + 1))
  done < <(find "$PROGRAMS" -type f -name '*.desktop' -print0 2>/dev/null)
  refresh_caches
  return 0
}

write_units(){
  mkdir -p "$UNIT_DIR" "$PROGRAMS"
  {
    printf '[Unit]\n'
    printf 'Description=Watch Wine-created .desktop shortcuts\n\n'
    printf '[Path]\n'
    local d
    for d in "$WINE_ROOT" "$PROGRAMS"; do
      printf 'PathChanged=%s\nPathModified=%s\n' "$d" "$d"
    done
    while IFS= read -r d; do
      printf 'PathChanged=%s\nPathModified=%s\n' "$d" "$d"
    done < <(find "$WINE_ROOT" -mindepth 2 -type d 2>/dev/null | sort | head -200)
    printf '\n[Install]\nWantedBy=default.target\n'
  } > "$PATH_UNIT"

  cat > "$SERVICE_UNIT" <<EOF
[Unit]
Description=Promote Wine-created shortcuts to app-menu entries

[Service]
Type=simple
ExecStart=$DEPLOYED --watch
EOF
}

watch_loop(){
  apm_busy && exit 0
  wine_active || exit 0
  convert_all
  # New app directories appeared: include them in the path unit for the next
  # run, then follow this run with inotifywait.
  if [[ $SELF == "$DEPLOYED" || -x $DEPLOYED ]]; then
    write_units
    systemctl --user daemon-reload >/dev/null 2>&1 || true
  fi
  if command -v inotifywait >/dev/null 2>&1; then
    # One-shot inotifywait (no -m): it returns after the first event, or after
    # 60 s idle. The outer loop re-scans and restarts it, and exits as soon as
    # Wine ends — so no watcher lingers after the wizard.
    while wine_active && ! apm_busy; do
      convert_all
      inotifywait -q -t 60 -r -e close_write,create,moved_to --format '%w%f' "$WINE_ROOT" 2>/dev/null |
        while IFS= read -r f; do
          case "$f" in *.desktop) convert_one "$f" ;; esac
        done
    done
  else
    while wine_active && ! apm_busy; do
      convert_all
      sleep 2
    done
  fi
}

show_status(){
  msg "Wine app-menu promotion"
  echo "  watcher path : $(systemctl --user is-enabled "$PATH_NAME" 2>/dev/null || echo disabled)"
  echo "  watcher state: $(systemctl --user is-active "$PATH_NAME" 2>/dev/null || echo inactive)"
  local n=0 f
  while IFS= read -r -d '' f; do
    grep -q '^X-MosquitOmarchy-Wine-Key=' "$f" 2>/dev/null && n=$((n + 1))
  done < <(find "$APPS_DIR" -maxdepth 1 -type f -name 'wine-*.desktop' -print0 2>/dev/null)
  echo "  promoted     : $n app entr(y/ies)"
  echo "  wine tree    : $WINE_ROOT"
}

do_apply(){
  mkdir -p "$PROGRAMS" "$APPS_DIR" "$ICON_DIR" "$UNIT_DIR"
  if [[ $SELF != "$DEPLOYED" ]]; then
    install -m 0755 "$SELF" "$DEPLOYED" || { err "could not install $DEPLOYED"; return 1; }
  fi
  write_units
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  systemctl --user enable --now "$PATH_NAME" >/dev/null 2>&1 \
    && ok "watcher enabled ($PATH_NAME)" \
    || warn "could not enable the user path unit; run: systemctl --user enable --now $PATH_NAME"
  msg "Converting current Wine shortcuts"
  if apm_busy; then
    warn "an APM install is running — current conversion skipped (the watcher does nothing during APM installs)."
  else
    convert_all
  fi
  # The tree changed (sources trashed, publisher dirs pruned); regenerate the
  # watched directory list so the next wizard is covered even in a new app dir.
  write_units
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  ok "Wine app-menu promotion installed (uninstallers/manual entries and APM installs are skipped)."
}

do_remove(){
  systemctl --user disable --now "$PATH_NAME" >/dev/null 2>&1 || true
  systemctl --user stop "$SERVICE_NAME" >/dev/null 2>&1 || true
  rm -f "$PATH_UNIT" "$SERVICE_UNIT" "$DEPLOYED"
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  ok "Wine app-menu watcher removed; promoted app entries were kept."
}

if $STATUS_ONLY; then show_status; exit 0; fi
if $REMOVE; then do_remove; exit 0; fi
if $WATCH; then watch_loop; exit 0; fi
if $SCAN; then
  apm_busy && exit 0
  if ! $FORCE; then
    wine_active || exit 0
  fi
  convert_all
  exit 0
fi
do_apply
