# Themes — Omarchy module (create-theme.sh)

Generates a complete Omarchy theme from an image in `Wallpapers/`: colors derived from the image (accent + background/text), applied everywhere (`colors.toml`, `icons.theme`, `keyboard.rgb`, wallpaper, previews, unlock logo) + optional **Plymouth boot** splash (sudo, offered at the end). **The lock screen is not changed** (remains the stock Omarchy lock).

```bash
./create-theme.sh            # interactive: image -> name -> theme
./create-theme.sh IMAGE      # forces an image from Wallpapers/
```

> The `achraff` module of `setup-customarchy.sh` delegates here (the `achraf67.png` image is forced), but this script remains usable standalone to create any theme from an image in `Wallpapers/`.

## "Achraff 67" mode

The `achraf67.png` image produces the frozen theme `achraff-67`: lime `#b5e61d`/red palette, `Yaru-olive` icons, "achraff_67" unlock logo (locked text); Plymouth with the theme colors. This is the `achraff` module of `setup-customarchy.sh` (forced image). Name and logo never change.