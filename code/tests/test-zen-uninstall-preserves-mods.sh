#!/usr/bin/env bash
# Zen module removal deletes only unchanged seed files; user mods and edited
# chrome files survive while the caller can remove the browser package.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[[ -d /usr/share/omarchy ]] || { echo 'skip: Zen module requires Omarchy'; exit 0; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/home/.config" GUI_RUN_EXEC=1 MOSQUITOMARCHY_NO_GUI=1
profile="$HOME/.config/zen/profile.test"
mkdir -p "$profile/extensions" "$profile/chrome/zen-themes/custom-user-mod"
printf '[InstallTest]\nDefault=profile.test\n' > "$HOME/.config/zen/profiles.ini"

seed_ext="$ROOT/code/modules/Apps/zen/seed/extensions/addon@darkreader.org.xpi"
seed_css="$ROOT/code/modules/Apps/zen/seed/chrome/zen-themes.css"
cp "$seed_ext" "$profile/extensions/${seed_ext##*/}"
cp "$seed_css" "$profile/chrome/zen-themes.css"
printf 'user edit\n' >> "$profile/chrome/zen-themes.css"
printf 'keep my Zen mod\n' > "$profile/chrome/zen-themes/custom-user-mod/chrome.css"

bash "$ROOT/code/modules/Apps/zen/setup-zen.sh" --remove -y >/dev/null
[[ ! -e "$profile/extensions/${seed_ext##*/}" ]]
grep -q 'user edit' "$profile/chrome/zen-themes.css"
[[ -f "$profile/chrome/zen-themes/custom-user-mod/chrome.css" ]]

echo 'ok: Zen uninstall removes unchanged seed files and preserves user mods'
