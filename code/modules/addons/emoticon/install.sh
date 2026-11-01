#!/usr/bin/env bash
# emoticon — build one Omarchy theme from a folder of wallpapers.
#
# The pictures are copied into mosquitOmarchy's own addon storage first, so the
# theme still has them after the source disk is unplugged, then into the theme
# background folder Omarchy reads.
#
# Source: $EMOTICON_SRC, default /run/media/mosquito/Crucial X9/BACKUP/Wallpaper
# Theme : $EMOTICON_THEME_NAME, default "Emoticon"
# The first image (alphabetical) drives the palette; every image becomes a
# background of the theme.
set -euo pipefail

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m !\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m ✗\033[0m %s\n' "$*" >&2; }

SRC="${EMOTICON_SRC:-/run/media/mosquito/Crucial X9/BACKUP/Wallpaper}"
STORE="${XDG_DATA_HOME:-$HOME/.local/share}/mosquitomarchy/addons/emoticon/wallpapers"
NAME="${EMOTICON_THEME_NAME:-Emoticon}"
REPO="${MQ_REPO:?MQ_REPO is required}"
CREATE="$REPO/code/modules/Themes/create-theme.sh"

[[ -x $CREATE ]] || { err "create-theme.sh not found: $CREATE"; exit 1; }

is_image() {
  case "${1,,}" in
    *.png|*.jpg|*.jpeg|*.webp) return 0 ;;
  esac
  return 1
}

copy_images() { # source folder -> $STORE
  local src="$1" f n=0
  [[ -d $src ]] || return 1
  mkdir -p "$STORE"
  while IFS= read -r -d '' f; do
    is_image "${f##*/}" || continue
    cp -f -- "$f" "$STORE/${f##*/}"
    n=$((n + 1))
  done < <(find "$src" -maxdepth 1 -type f -print0 2>/dev/null)
  ((n > 0)) || return 1
  ok "Stored $n image(s) in $STORE"
}

if [[ -d $SRC ]]; then
  copy_images "$SRC" || warn "No image found in $SRC"
elif [[ -d $STORE ]]; then
  info "Source folder absent; using the pictures already stored by this addon."
else
  err "Image folder not found: $SRC"
  err "Store the pictures there (or set EMOTICON_SRC) and rerun."
  exit 1
fi

first="$(find "$STORE" -maxdepth 1 -type f \( -iname '*.png' -o -iname '*.jpg' \
  -o -iname '*.jpeg' -o -iname '*.webp' \) 2>/dev/null | sort | head -n1)"
[[ -n $first ]] || { err "No image in $STORE"; exit 1; }

info "Building theme '$NAME' from $(basename "$first")"
bash "$CREATE" --dir "$STORE" --image "$(basename "$first")" --name "$NAME" \
  --no-apply --no-unlock-style

slug="$(printf '%s\n' "$NAME" | tr '[:upper:]' '[:lower:]' \
  | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g')"
theme="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/themes/$slug/backgrounds"
mkdir -p "$theme"
while IFS= read -r -d '' f; do
  is_image "${f##*/}" || continue
  cp -f -- "$f" "$theme/${f##*/}"
done < <(find "$STORE" -maxdepth 1 -type f -print0 2>/dev/null)

ok "Theme '$NAME' ready with $(find "$theme" -maxdepth 1 -type f | wc -l) background(s)"
ok "Apply it when you want: omarchy theme set '$NAME'"
