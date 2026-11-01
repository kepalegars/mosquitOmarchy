#!/usr/bin/env bash
# Remove the theme built by the emoticon addon. The images stay in the addon's
# images/ folder: they are the user's own files and re-installing reuses them.
set -euo pipefail
NAME="${EMOTICON_THEME_NAME:-Emoticon}"
slug="$(printf '%s\n' "$NAME" | tr '[:upper:]' '[:lower:]' \
  | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g')"
theme="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/themes/$slug"
if [[ -d $theme ]]; then
  rm -rf -- "$theme"
  printf '\033[1;32m ✓\033[0m Removed theme %s (%s)\n' "$NAME" "$theme"
else
  printf '\033[1;33m !\033[0m Theme %s is not installed\n' "$NAME"
fi
