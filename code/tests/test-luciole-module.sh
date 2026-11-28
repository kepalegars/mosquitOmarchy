#!/usr/bin/env bash
# Luciole module: dispatcher wiring, settings seed, Omarchy theme sync and a
# install/remove round-trip in a throwaway HOME (no package install, no session
# bus so the portal/keybind reloads cannot touch the live desktop).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

SCRIPT="code/modules/Apps/luciole/setup-luciole.sh"
[[ -x $SCRIPT ]]
for pat in \
  '"luciole:Luciole' 'luciole) st_luciole' 'st_luciole()' \
  'code/modules/Apps/luciole/*)' 'luciole) un_luciole' \
  'LUCIOLE_DIR=' 'luciole) run_module luciole' \
  'superfile luciole strata flea' ; do
  grep -qF "$pat" mosquitomarchy-setup.sh || { echo "fail: dispatcher missing $pat" >&2; exit 1; }
done
grep -q '^luciole=' VERSIONS

python3 - <<'PY'
import pathlib, tomllib
p = pathlib.Path("code/modules/Apps/luciole/seed/settings.toml")
d = tomllib.loads(p.read_text())
assert d["schema_version"] == 1
assert d["browser"]["corner_radius_scale"] == 0.6
assert d["browser"]["reduce_animations"] is True
assert d["browser"]["remember_folder_views"] is True
PY

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home/.config/hypr" "$TMP/home/.config/xdg-desktop-portal" \
  "$TMP/home/.local/state/omarchy/current/theme" "$TMP/home/.local/share/dbus-1/services" "$TMP/runtime"
printf '#!/bin/sh\necho stub\n' > "$TMP/bin/luciole"; chmod +x "$TMP/bin/luciole"
printf 'o.bind("SUPER + SHIFT + F", "File manager", { launch = "flea --gui" })\n' \
  > "$TMP/home/.config/hypr/bindings.lua"
printf '[preferred]\ndefault=hyprland;gtk\norg.freedesktop.impl.portal.FileChooser=strata;flea;gtk;\n' \
  > "$TMP/home/.config/xdg-desktop-portal/hyprland-portals.conf"
cp /usr/share/omarchy/themes/catppuccin/colors.toml \
  "$TMP/home/.local/state/omarchy/current/theme/colors.toml"
printf '[D-BUS Service]\nName=org.freedesktop.FileManager1\nExec=/usr/bin/strata --gapplication-service\n' \
  > "$TMP/home/.local/share/dbus-1/services/io.github.lgse.Strata.FileManager1.service"

run() {
  env PATH="$TMP/bin:$PATH" HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/home/.config" \
    XDG_DATA_HOME="$TMP/home/.local/share" XDG_RUNTIME_DIR="$TMP/runtime" GUI_RUN_EXEC=1 \
    env -u DBUS_SESSION_BUS_ADDRESS -u HYPRLAND_INSTANCE_SIGNATURE \
    bash "$ROOT/$SCRIPT" "$@"
}

run -y >/dev/null
grep -q '^org.freedesktop.impl.portal.FileChooser=luciole;strata;flea;gtk;$' \
  "$TMP/home/.config/xdg-desktop-portal/hyprland-portals.conf"
grep -q 'luciole-module: file-manager start' "$TMP/home/.config/hypr/bindings.lua"
[[ -f $TMP/home/.config/luciole/settings.toml ]]
[[ -x $TMP/home/.config/omarchy/hooks/theme-set.d/luciole-module.sh ]]
[[ -f $TMP/home/.local/share/dbus-1/services/org.freedesktop.FileManager1.service ]]
TMP_HOME="$TMP/home" python3 - <<'PY'
import os, pathlib, tomllib
home = pathlib.Path(os.environ["TMP_HOME"])
c = tomllib.loads((home / ".config/luciole/colors.toml").read_text())["colors"]
assert c["primary"] == "#89b4fa" and c["surface"] == "#1e1e2e"
assert c["on_surface_variant"] == "#6c7086" and len(c) == 28
assert tomllib.loads((home / ".config/luciole/config.toml").read_text())["color_scheme"] == "auto"
PY

# A theme switch regenerates the palette via the installed hook.
sed -i 's/#89b4fa/#ff0000/g' "$TMP/home/.local/state/omarchy/current/theme/colors.toml"
HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/home/.config" XDG_DATA_HOME="$TMP/home/.local/share" \
  GUI_RUN_EXEC=1 "$TMP/home/.config/omarchy/hooks/theme-set.d/luciole-module.sh"
grep -q 'primary = "#ff0000"' "$TMP/home/.config/luciole/colors.toml"

run --remove >/dev/null
[[ ! -e $TMP/home/.config/luciole/colors.toml ]]
[[ ! -e $TMP/home/.config/omarchy/hooks/theme-set.d/luciole-module.sh ]]
[[ ! -e $TMP/home/.local/share/dbus-1/services/org.freedesktop.FileManager1.service ]]
[[ -f $TMP/home/.local/share/dbus-1/services/io.github.lgse.Strata.FileManager1.service ]]
grep -q '^org.freedesktop.impl.portal.FileChooser=strata;flea;gtk;$' \
  "$TMP/home/.config/xdg-desktop-portal/hyprland-portals.conf"
! grep -q 'luciole-module' "$TMP/home/.config/hypr/bindings.lua"
[[ -f $TMP/home/.config/luciole/settings.toml ]]

echo 'ok: luciole module wiring, settings, theme sync and undo are sound'
