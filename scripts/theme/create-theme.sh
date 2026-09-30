#!/usr/bin/env bash
# =============================================================================
# Omarchy Custom - create-theme.sh (theme creator from an image)
# =============================================================================
# Generates a complete Omarchy theme from an image chosen in theme/Wallpapers/.
# The colors are deduced from the image itself (dominant accent + contrasting
# background/text), then everything is derived:
#
#   1. Omarchy theme   ~/.config/omarchy/themes/<slug>/  — colors.toml derived
#      from the image, icons, keyboard backlight, wallpaper, previews and the
#      UNI unlock logo. Applied via "omarchy theme set".
#   2. Boot Plymouth   "omarchy-plymouth-set-by-theme" (unlock logo + theme
#      colors) — sudo required, offered at the end.
#
# The lock screen is NOT touched: it remains the stock Omarchy lock
# (password bar only, no theme name).
#
# Special case achraf67.png → the reference theme ' Achraff 67 ': frozen
# lime/red palette and red unlock logo + ' achraff_67 ' (frozen name, does not
# change from theme to theme) — the equivalent of the former
# setup-achraff-theme.sh, merged here.
#
# Interactive selection:
#   1. Choose an image in theme/Wallpapers/ (gum or numbered).
#   2. Validate the theme name (proposed from the file name) -> it becomes
#      the slug, and the unlock logo for generic themes.
#      (achraf67.png: locked name ' Achraff 67 ', unlock logo ' achraff_67 '.)
#
# Usage:
#   ./theme/create-theme.sh            # interactive: image -> name -> theme
#   ./theme/create-theme.sh IMAGE      # force an image from Wallpapers/
#
# NOTE: the ' achraff ' module of mosquitomarchy-setup.sh delegates here (the
# achraf67.png image is forced), but this script remains usable standalone to
# create any theme from an image in Wallpapers/.
# =============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/elevate.bash"  # mq_sudo: native pkexec prompt when not root

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The source images live in <app>/theme/Wallpapers/
WALLPAPERS_DIR="$SCRIPT_DIR/Wallpapers"

G='\033[1;32m'; B='\033[1;34m'; Y='\033[1;33m'; R='\033[1;31m'; D='\033[2m'; N='\033[0m'
msg(){ printf "${B}==>${N} %s\n" "$*"; }
ok(){ printf " ${G}✓${N} %s\n" "$*"; }
warn(){ printf " ${Y}!${N} %s\n" "$*"; }
err(){ printf " ${R}✗${N} %s\n" "$*" >&2; }

if [[ ! -d /usr/share/omarchy ]]; then
  err "This script is meant for Omarchy."
  exit 1
fi

# -----------------------------------------------------------------------------
# 0. Source image (browses the Wallpapers/ folder)
# -----------------------------------------------------------------------------
if [[ ! -d "$WALLPAPERS_DIR" ]]; then
  err "Images folder not found: $WALLPAPERS_DIR"
  err "Drop some .png/.jpg/.jpeg/.webp into theme/Wallpapers/ then rerun."
  exit 1
fi

IMAGES=()
while IFS= read -r f; do
  [[ -n $f ]] && IMAGES+=("$f")
done < <(find "$WALLPAPERS_DIR" -maxdepth 1 -type f \( -iname '*.png' -o -iname '*.jpg' \
        -o -iname '*.jpeg' -o -iname '*.webp' \) 2>/dev/null | sort)

FORCED="${1:-}"
if [[ -n $FORCED ]]; then
  FORCED_ABS="$WALLPAPERS_DIR/$(basename "$FORCED")"
  [[ -f "$FORCED_ABS" ]] || { err "Image not found: $FORCED_ABS"; exit 1; }
  SRC_IMG="$FORCED_ABS"
elif ((${#IMAGES[@]} == 0)); then
  err "No image in $WALLPAPERS_DIR."
  err "Drop a .png/.jpg/.jpeg/.webp file here then rerun."
  exit 1
elif ((${#IMAGES[@]} == 1)); then
  SRC_IMG="${IMAGES[0]}"
else
  msg "Available images in Wallpapers/:"
  if command -v gum >/dev/null; then
    SRC_IMG="$(gum choose "${IMAGES[@]}" --header "Which image for the theme?")"
  else
    local i=0
    for f in "${IMAGES[@]}"; do i=$((i+1)); printf "  %d) %s\n" "$i" "$(basename "$f")"; done
    read -rp "Image number [default 1]: " n
    n="${n:-1}"
    SRC_IMG="${IMAGES[$((n-1))]}"
  fi
fi
[[ -n $SRC_IMG ]] || { err "No image chosen."; exit 1; }

# Proposed name = file name without extension (spaces/dashes -> words)
IMG_BASE="$(basename "${SRC_IMG%.*}")"
PROPOSED="$(printf '%s\n' "$IMG_BASE" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/ /g; s/^ +| +$//g; s/ (.)/\U\1/g' | sed -E 's/^(.)/\U\1/')"
[[ -n $PROPOSED ]] || PROPOSED="$IMG_BASE"

# The reference theme ' Achraff 67 ' = achraf67.png image (former
# setup-achraff-theme.sh, merged into this script): frozen name/palette/render.
ACHRAFF=false
[[ "${IMG_BASE,,}" == "achraf67" ]] && ACHRAFF=true

# -----------------------------------------------------------------------------
# 1. Theme name (proposed from the file) — this is also the unlock title
# -----------------------------------------------------------------------------
msg "Image: $(basename "$SRC_IMG")"
if [[ $ACHRAFF == true ]]; then
  THEME_NAME="Achraff 67"
  ok "Reference image (achraf67.png) — name locked ' $THEME_NAME '"
else
  THEME_NAME=""
  if command -v gum >/dev/null; then
    THEME_NAME="$(gum input --prompt "Theme name: " --value "$PROPOSED" --placeholder "$PROPOSED")"
  else
    read -rp "Theme name [$PROPOSED]: " THEME_NAME
    THEME_NAME="${THEME_NAME:-$PROPOSED}"
  fi
  [[ -n $THEME_NAME ]] || THEME_NAME="$PROPOSED"
fi

slugify(){ printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g'; }
THEME_SLUG="$(slugify "$THEME_NAME")"
[[ -n $THEME_SLUG ]] || { err "Invalid theme name."; exit 1; }

THEME_DIR="$HOME/.config/omarchy/themes/$THEME_SLUG"
# Unlock logo text (Plymouth): theme name, but achraf67.png keeps the
# historical render ' achraff_67 ' — frozen, it does not change theme to theme.
TITLE_TEXT="$THEME_NAME"
[[ $ACHRAFF == true ]] && TITLE_TEXT="achraff_67"

ok "Theme ' $THEME_NAME ' (slug: $THEME_SLUG, unlock title: ' $TITLE_TEXT ')"

# -----------------------------------------------------------------------------
# 2. Palette derived from the image (accent, background, text + full colors)
# -----------------------------------------------------------------------------
derive_palette(){
  python3 - "$SRC_IMG" << 'PY'
import sys, colorsys
from PIL import Image

path = sys.argv[1]
im = Image.open(path).convert("RGB")
im.thumbnail((160, 160))
px = list(im.resize((64, 64)).getdata())
n = len(px)

def hx(rgb):
    return "#%02x%02x%02x" % rgb

# Dominant colors (quantization)
q = im.quantize(colors=8)
pal = [tuple(q.getpalette()[i*3:i*3+3]) for i in range(256)]
from collections import Counter
cnt = Counter(q.getdata())
dom = [pal[c] for c, _ in cnt.most_common(8)]

# accent = most saturated dominant color (vivid)
def sat(c):
    h, l, s = colorsys.rgb_to_hls(c[0]/255, c[1]/255, c[2]/255)
    return s
accent = max(dom, key=sat)

def lum(c):
    return 0.2126*c[0] + 0.7152*c[1] + 0.0722*c[2]

# background = darkest dominant color; otherwise a dark variant of the accent
dark = min(dom, key=lum)
if lum(dark) > 70:
    dark = tuple(int(c * 0.12) for c in accent)
bg = dark if lum(dark) <= 90 else (min(c, 32) for c in accent)

# light text = brightest dominant color, otherwise a light variant
light = max(dom, key=lum)
if lum(light) < 160:
    light = tuple(min(255, int(c * 0.7) + 40) for c in accent)

# dark variants
def darken(c, f):
    return tuple(max(0, int(v * f)) for v in c)
def lighten(c, f):
    return tuple(min(255, int(255 - (255 - v) * f)) for v in c)

accent = tuple(accent)
bg = tuple(bg)
fg = tuple(light)
lighter_bg = lighten(bg, 0.18)
darker_bg = darken(bg, 0.55)
darker2_bg = darken(bg, 0.25)
light_fg = lighten(fg, 0.25)
dark_fg = darken(fg, 0.45)
bright_fg = lighten(fg, 0.45)
selection = lighten(bg, 0.45)
muted = lighten(bg, 0.6)

# functional colors (reds/greens...) stay readable on a dark background
ferr = (237, 28, 36)      # error red (like the reference theme)
yellow = (255, 201, 14)
orange = (238, 94, 33)
green = (34, 169, 73)
cyan = (44, 207, 168)
blue = (135, 165, 224)
magenta = (188, 116, 145)
brown = (181, 84, 47)
bright_red = (255, 82, 87)
bright_yellow = (255, 221, 85)
bright_green = (65, 228, 92)
bright_cyan = (107, 233, 200)
bright_blue = (175, 196, 240)
bright_magenta = (216, 157, 182)

print("accent=%s" % hx(accent))
print("background=%s" % hx(bg))
print("dark_background=%s" % hx(darker_bg))
print("darker_background=%s" % hx(darker2_bg))
print("lighter_background=%s" % hx(lighter_bg))
print("foreground=%s" % hx(fg))
print("dark_foreground=%s" % hx(dark_fg))
print("light_foreground=%s" % hx(light_fg))
print("bright_foreground=%s" % hx(bright_fg))
print("selection=%s" % hx(selection))
print("muted=%s" % hx(muted))
print("red=%s" % hx(ferr))
print("yellow=%s" % hx(yellow))
print("orange=%s" % hx(orange))
print("green=%s" % hx(green))
print("cyan=%s" % hx(cyan))
print("blue=%s" % hx(blue))
print("magenta=%s" % hx(magenta))
print("brown=%s" % hx(brown))
print("bright_red=%s" % hx(bright_red))
print("bright_yellow=%s" % hx(bright_yellow))
print("bright_green=%s" % hx(bright_green))
print("bright_cyan=%s" % hx(bright_cyan))
print("bright_blue=%s" % hx(bright_blue))
print("bright_magenta=%s" % hx(bright_magenta))
PY
}

declare -A C
# Frozen palette of the reference theme (lime/red) — mirrors the former achraff-67
achraff_palette(){
  cat << 'EOF'
accent=#b5e61d
selection=#3c4822
muted=#4e9237
background=#0d0d0b
dark_background=#060604
darker_background=#020101
lighter_background=#232415
foreground=#dbcfbf
dark_foreground=#8a7e74
light_foreground=#e9dfd3
bright_foreground=#f7f1e8
red=#ed1c24
yellow=#ffc90e
orange=#ee5e21
green=#22a949
cyan=#2ccfa8
blue=#87a5e0
magenta=#bc7491
brown=#b5542f
bright_red=#ff5257
bright_yellow=#ffdd55
bright_green=#41e45c
bright_cyan=#6be9c8
bright_blue=#afc4f0
bright_magenta=#d89db6
EOF
}
parse_palette(){
  local line key val
  while IFS= read -r line; do
    key="${line%%=*}" ; val="${line#*=}"
    C["$key"]="$val"
  done < <(if [[ $ACHRAFF == true ]]; then achraff_palette; else derive_palette; fi)
}
parse_palette
if [[ $ACHRAFF == true ]]; then
  ok "Frozen achraff palette — accent ${C[accent]}, background ${C[background]}, text ${C[foreground]}"
else
  ok "Derived palette — accent ${C[accent]}, background ${C[background]}, text ${C[foreground]}"
fi

# Strip the '#' from colors for Plymouth
strip_hash(){ printf '%s\n' "${1#\#}"; }
ACCENT_NO="#${C[accent]}" ; ACCENT_NO="${ACCENT_NO#\#}"
BG_NO="$(strip_hash "${C[background]}")"
FG_NO="$(strip_hash "${C[foreground]}")"

# -----------------------------------------------------------------------------
# 3. Building the theme folder
# -----------------------------------------------------------------------------
msg "Building theme $THEME_SLUG"
mkdir -p "$THEME_DIR/backgrounds"

if [[ -f "$THEME_DIR/colors.toml" ]]; then
  warn "colors.toml already present — kept (delete it to regenerate)."
else
  cat > "$THEME_DIR/colors.toml" << TOMLEOF
mode = "dark"

accent = "${C[accent]}"
selection = "${C[selection]}"
muted = "${C[muted]}"

background = "${C[background]}"
dark_background = "${C[dark_background]}"
darker_background = "${C[darker_background]}"
lighter_background = "${C[lighter_background]}"

foreground = "${C[foreground]}"
dark_foreground = "${C[dark_foreground]}"
light_foreground = "${C[light_foreground]}"
bright_foreground = "${C[bright_foreground]}"

red = "${C[red]}"
yellow = "${C[yellow]}"
orange = "${C[orange]}"
green = "${C[green]}"
cyan = "${C[cyan]}"
blue = "${C[blue]}"
magenta = "${C[magenta]}"
brown = "${C[brown]}"

bright_red = "${C[bright_red]}"
bright_yellow = "${C[bright_yellow]}"
bright_green = "${C[bright_green]}"
bright_cyan = "${C[bright_cyan]}"
bright_blue = "${C[bright_blue]}"
bright_magenta = "${C[bright_magenta]}"
TOMLEOF
  ok "colors.toml created"
fi

if [[ $ACHRAFF == true ]]; then
  [[ -f "$THEME_DIR/icons.theme" ]] || { echo "Yaru-olive" > "$THEME_DIR/icons.theme"; ok "icons.theme = Yaru-olive"; }
  [[ -f "$THEME_DIR/keyboard.rgb" ]] || { echo "b5e61d" > "$THEME_DIR/keyboard.rgb"; ok "keyboard.rgb = b5e61d"; }
else
  [[ -f "$THEME_DIR/icons.theme" ]] || { echo "Yaru" > "$THEME_DIR/icons.theme"; ok "icons.theme = Yaru"; }
  [[ -f "$THEME_DIR/keyboard.rgb" ]] || { echo "$ACCENT_NO" > "$THEME_DIR/keyboard.rgb"; ok "keyboard.rgb = $ACCENT_NO"; }
fi

# Wallpaper
BG_EXT="${SRC_IMG##*.}"
BG_FILE="background.${BG_EXT,,}"
if [[ ! -f "$THEME_DIR/backgrounds/$BG_FILE" || "$SRC_IMG" -nt "$THEME_DIR/backgrounds/$BG_FILE" ]]; then
  cp "$SRC_IMG" "$THEME_DIR/backgrounds/$BG_FILE"
  ok "Wallpaper backgrounds/$BG_FILE"
else
  ok "Wallpaper already up to date"
fi

# -----------------------------------------------------------------------------
# 3b. Image generation (uni unlock logo + previews)
# -----------------------------------------------------------------------------
gen_unlock_png(){
  # Logo 800x188: UNI background + text = TITLE_TEXT, no outline. For achraf67.png
  # frozen red background + lime text; otherwise accent + auto contrast.
  local mode=generic
  [[ $ACHRAFF == true ]] && mode=achraff
  local unlock_bg="${C[accent]}"
  [[ $ACHRAFF == true ]] && unlock_bg="#ec1f25"
  python3 - "$THEME_DIR/unlock.png" "$unlock_bg" "$TITLE_TEXT" "$mode" << 'PY'
import sys
from PIL import Image, ImageDraw, ImageFont

out, bg_hex, text, mode = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
W, H = 800, 188
bg_hex = bg_hex.lstrip("#")
bg = tuple(int(bg_hex[i:i+2], 16) for i in (0, 2, 4)) + (255,)   # 100% opacity

if mode == "achraff":
    # achraf67.png: frozen lime text on a red background
    fill = (181, 230, 29, 255)
    desc = "lime"
else:
    # automatic contrast: black on light accent, white on dark accent
    L = 0.2126*bg[0] + 0.7152*bg[1] + 0.0722*bg[2]
    fill = (0, 0, 0, 255) if L > 150 else (255, 255, 255, 255)
    desc = "black" if L > 150 else "white"

img = Image.new("RGBA", (W, H), bg)
draw = ImageDraw.Draw(img)

font = None
for cand in ("/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Bold.ttf",
             "JetBrainsMono Nerd Font Bold",
             "/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
             "DejaVuSansMono-Bold"):
    try:
        font = ImageFont.truetype(cand, 96)
        break
    except Exception:
        continue
if font is None:
    font = ImageFont.load_default()

draw.text((W // 2, H // 2), text, font=font, fill=fill, spacing=4, anchor="mm")
img.save(out)
print(f"   unlock.png: {W}x{H}, bg {bg_hex.upper()}, text {desc} ({text})")
PY
}

gen_preview_png(){
  python3 - "$THEME_DIR/preview.png" "$SRC_IMG" << 'PY'
import sys
from PIL import Image
out, src = sys.argv[1], sys.argv[2]
im = Image.open(src).convert("RGB")
im.thumbnail((1800, 1800))
im.save(out, optimize=True)
print(f"   preview.png: {im.width}x{im.height}")
PY
}

gen_preview_unlock_png(){
  python3 - "$THEME_DIR/preview-unlock.png" "$SRC_IMG" "$THEME_DIR/unlock.png" << 'PY'
import sys
from PIL import Image, ImageFilter, ImageDraw, ImageFont

out, bg_src, logo_src = sys.argv[1], sys.argv[2], sys.argv[3]
W, H = 1920, 1080
bg = Image.open(bg_src).convert("RGB")
bg.thumbnail((W, H))
canvas = Image.new("RGB", (W, H), (13, 13, 11))
canvas.paste(bg, ((W - bg.width) // 2, (H - bg.height) // 2))
canvas = canvas.filter(ImageFilter.GaussianBlur(18))

logo = Image.open(logo_src).convert("RGBA")
scale = 640 / logo.width
logo = logo.resize((round(logo.width * scale), round(logo.height * scale)), Image.LANCZOS)
canvas.paste(logo, ((W - logo.width) // 2, (H - logo.height) // 2 - 120), logo)
canvas.save(out, optimize=True)
print(f"   preview-unlock.png: {W}x{H}")
PY
}

need(){ [[ ! -f "$1" || ( -f "$SRC_IMG" && "$SRC_IMG" -nt "$1" ) ]]; }

need_title(){ [[ -f "$THEME_DIR/.title" ]] && [[ "$(cat "$THEME_DIR/.title")" != "$TITLE_TEXT" ]]; }

if need "$THEME_DIR/unlock.png" || need_title; then
  msg "Regenerating unlock.png (text ' $TITLE_TEXT ')"
  gen_unlock_png
  printf '%s\n' "$TITLE_TEXT" > "$THEME_DIR/.title"
  ok "unlock.png"
else
  ok "unlock.png present"
fi

if need "$THEME_DIR/preview.png"; then
  msg "Regenerating preview.png"
  gen_preview_png
  ok "preview.png"
else
  ok "preview.png present"
fi

if ! need "$THEME_DIR/preview-unlock.png" && [[ -f "$THEME_DIR/unlock.png" \
     && "$THEME_DIR/unlock.png" -nt "$THEME_DIR/preview-unlock.png" ]]; then
  msg "Regenerating preview-unlock.png (unlock logo updated)"
  gen_preview_unlock_png
  ok "preview-unlock.png (refreshed)"
elif need "$THEME_DIR/preview-unlock.png"; then
  msg "Regenerating preview-unlock.png"
  gen_preview_unlock_png
  ok "preview-unlock.png"
else
  ok "preview-unlock.png present"
fi

# -----------------------------------------------------------------------------
# 4. Applying the theme
# -----------------------------------------------------------------------------
if [[ "$(omarchy theme current 2>/dev/null || true)" != "$THEME_NAME" ]]; then
  msg "Applying the theme ' $THEME_NAME '"
  omarchy theme set "$THEME_NAME"
  ok "Theme applied (omarchy theme set)"
else
  ok "Theme ' $THEME_NAME ' already active"
fi

# -----------------------------------------------------------------------------
# 6. Boot Plymouth (sudo required) — offered at the end
# -----------------------------------------------------------------------------
setup_plymouth(){
  if [[ "$(omarchy-plymouth-current 2>/dev/null || true)" == "$THEME_SLUG" ]]; then
    ok "Plymouth already on ' $THEME_SLUG '"
    return 0
  fi
  warn "BOOT Plymouth screen: requires sudo (password)."
  if mq_sudo -n true 2>/dev/null; then
    omarchy-plymouth-set-by-theme "$THEME_SLUG"
    ok "Plymouth applied (unlock logo + theme colors)"
  else
    err "sudo not available non-interactively."
    err "To run yourself (password):  omarchy-plymouth-set-by-theme \"$THEME_SLUG\""
  fi
}
setup_plymouth

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
hr(){ printf '%.0s─' {1..72}; echo; }
hr
ok "Theme ' $THEME_NAME ' ready."
echo "  • Folder   : ~/.config/omarchy/themes/$THEME_SLUG/"
echo "  • Colors   : accent ${C[accent]} / background ${C[background]} / text ${C[foreground]}"
echo "  • Plymouth (boot) : omarchy-plymouth-set-by-theme \"$THEME_SLUG\"  (password)"
  echo "  • Remove   : omarchy theme (choose another theme) ; reverse:"
  echo "    rm -rf ~/.config/omarchy/themes/$THEME_SLUG"
hr