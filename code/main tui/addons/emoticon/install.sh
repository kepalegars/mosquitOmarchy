#!/usr/bin/env bash
# emoticon — build one Omarchy theme from a folder of wallpapers.
#
# The pictures are copied into mosquitOmarchy's own addon storage first, so the
# theme still has them after the source disk is unplugged, then into the theme
# background folder Omarchy reads.
#
# Put the wallpapers in this addon's own images/ folder, or import them once
# with EMOTICON_SRC=/a/folder (they are copied into images/ and kept there).
# There is no machine-specific default source.
# Theme: $EMOTICON_THEME_NAME, default "Emoticon". The first image
# (alphabetical) drives the palette; every image becomes a background.
set -euo pipefail

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m !\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m ✗\033[0m %s\n' "$*" >&2; }

IMAGES="${MQ_ADDON_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/images"
NAME="${EMOTICON_THEME_NAME:-Emoticon}"
REPO="${MQ_REPO:?MQ_REPO is required}"
CREATE="$REPO/code/modules/Themes/create-theme.sh"

[[ -x $CREATE ]] || { err "create-theme.sh not found: $CREATE"; exit 1; }
mkdir -p "$IMAGES"

is_image() {
  case "${1,,}" in
    *.png|*.jpg|*.jpeg|*.webp|*.jfif) return 0 ;;
  esac
  return 1
}

copy_images() { # source folder -> images/
  local src="$1" f n=0
  [[ -d $src ]] || return 1
  mkdir -p "$IMAGES"
  while IFS= read -r -d '' f; do
    is_image "${f##*/}" || continue
    dest="${f##*/}"
    ext="${dest##*.}"; ext="${ext,,}"
    # .jfif is a JPEG with a different extension; rename it so create-theme
    # (and every image tool) sees a normal .jpg.
    [[ $ext == jfif ]] && dest="${dest%.*}.jpg"
    cp -f -- "$f" "$IMAGES/$dest"
    n=$((n + 1))
  done < <(find "$src" -maxdepth 1 -type f -print0 2>/dev/null)
  ((n > 0)) || return 1
  ok "Copied $n image(s) into $IMAGES"
}

# Optional one-shot import: copy the pictures into the addon's dedicated
# folder, then use that folder from now on.
if [[ -n ${EMOTICON_SRC:-} ]]; then
  copy_images "$EMOTICON_SRC" || warn "No image found in $EMOTICON_SRC"
fi

first="$(find "$IMAGES" -maxdepth 1 -type f \( -iname '*.png' -o -iname '*.jpg' \
  -o -iname '*.jpeg' -o -iname '*.webp' \) 2>/dev/null | sort | head -n1)"
[[ -n $first ]] || {
  err "No image in $IMAGES"
  err "Put the wallpapers in that folder (or rerun with EMOTICON_SRC=/folder)."
  exit 1
}

info "Building theme '$NAME' from $(basename "$first")"
bash "$CREATE" --dir "$IMAGES" --image "$(basename "$first")" --name "$NAME" \
  --no-apply --no-unlock-style

slug="$(printf '%s\n' "$NAME" | tr '[:upper:]' '[:lower:]' \
  | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g')"
theme="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/themes/$slug/backgrounds"
mkdir -p "$theme"
while IFS= read -r -d '' f; do
  is_image "${f##*/}" || continue
  cp -f -- "$f" "$theme/${f##*/}"
done < <(find "$IMAGES" -maxdepth 1 -type f -print0 2>/dev/null)

ok "Theme '$NAME' ready with $(find "$theme" -maxdepth 1 -type f | wc -l) background(s)"
ok "Apply it when you want: omarchy theme set '$NAME'"
