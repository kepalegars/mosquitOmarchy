# Themes — create-theme.sh

Generates a complete Omarchy theme from an image: colours derived from the image
itself (accent + contrasting background/text), then everything downstream —
`colors.toml`, `icons.theme`, `keyboard.rgb`, the wallpaper, two previews, and
the Plymouth unlock logo. **The lock screen is untouched** (it stays the stock
Omarchy lock).

## The theme is not applied automatically

A fresh theme is only *built*. Applying it runs every Omarchy theme hook —
wallpaper, bar, icons, terminal, GTK — so it stays an explicit step:

- from the TUI, it is the **Apply theme** row of the success prompt;
- from the terminal, add `--apply`.

```bash
scripts/theme/create-theme.sh            # interactive: image -> name -> theme
scripts/theme/create-theme.sh IMAGE      # force an image from Wallpapers/
scripts/theme/create-theme.sh --apply    # build it AND apply it
```

Applying later by hand: `omarchy theme set '<name>'`.

## TUI flow

The generator is reached from the mosquitomarchy TUI's **main menu**, on the row
right after **Keybindings** — it is a create-this-thing action, not a module to
install, so it does not live under Setup. Four steps, all decided in the TUI:

1. **Folder** — `~/Pictures/Wallpapers` first, then the usual suspects
   (Omarchy wallpapers, `~/Pictures`, `~/Downloads`, `~/Images`,
   `~/Pictures/Screenshots`) plus *Type a folder path…*. The default is created
   if it does not exist.
2. **Image** — every `.png/.jpg/.jpeg/.webp` in that folder.
3. **Name** — pre-filled with the image's own name; Enter twice is a complete
   theme. The name becomes the slug, the unlock logo text and both previews.
4. **Create** — confirmed, then streamed in the runner.

Then a success prompt with three exits: **See log**, **OK — back to the menu**,
**Apply theme**.

The TUI never lets `create-theme.sh` pick the image itself: gum choosing from a
popup behind a full-screen TUI is how you silently build a theme from the wrong
file. Given `--image` and `--name`, the script never prompts.

## Options

| Option | Effect |
|---|---|
| `--dir DIR` | browse `DIR` instead of `Wallpapers/` |
| `--image IMG` | force that image, no prompt |
| `--name NAME` | force that name, no prompt |
| `--apply` / `--no-apply` | apply the theme after building it (default: no) |
| `--log FILE` | tee the whole run into `FILE`, pkexec prompt included |

The Plymouth boot splash needs sudo, which the TUI's runner cannot prompt for, so
from there it is skipped with the command to run by hand. **It never fails the
run** — the theme itself is already built and Plymouth is only the boot screen.

## "Achraff 67" mode

`achraf67.png` produces the frozen reference theme `achraff-67`: lime
`#b5e61d`/red palette, `Yaru-olive` icons, the `achraff_67` unlock logo, Plymouth
in the theme colours. The name and logo are locked and do not vary. This is what
the `achraff` module of `mosquitomarchy-setup.sh` runs (forced image, `--apply`).
