#!/usr/bin/env bash
# setup-tidal.sh — TIDAL Hi-Fi (TidaLuna): package + settings.
#
# Installs tidal-hifi-tidaluna via yay, then owns the settings the package
# cannot ship for us: hide the Electron menu bar and bind SUPER+SHIFT+M to
# TIDAL in ~/.config/hypr/bindings.lua (that combo is Spotify by default).
#
# TIDAL Hi-Fi reads ~/.config/tidal-hifi/config.json (electron-store). The
# store merges its defaults into a partial file, so writing just the two keys
# is safe even before the app has ever run. Everything the user already has is
# preserved verbatim.
#
#   menuBar = false             no permanent menu bar
#   disableAltMenuBar = true    Alt no longer pops it up either
#
# Usage: setup-tidal.sh --install|--remove|--uninstall|--status
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/elevate.bash"  # mq_sudo: native pkexec prompt

PKG=tidal-hifi-tidaluna
pkg_has(){ pacman -Q "$PKG" &>/dev/null; }

install_pkg(){
  pkg_has && return 0
  command -v yay >/dev/null 2>&1 || { echo "yay is required to install $PKG" >&2; return 1; }
  yay -S --needed --noconfirm "$PKG"
}

remove_pkg(){
  pkg_has || { echo "$PKG: not installed"; return 0; }
  mq_sudo pacman -Rns --noconfirm "$PKG"
}

CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/tidal-hifi/config.json"
BINDINGS="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/bindings.lua"

patch_config(){
  python3 - "$CONFIG" <<'PY'
import json
import os
import pathlib
import sys
import tempfile

path = pathlib.Path(sys.argv[1])
data = {}
if path.is_file():
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        sys.exit(f"cannot parse {path}: {e} — left untouched")
    if not isinstance(data, dict):
        sys.exit(f"{path} is not a JSON object — left untouched")
else:
    path.parent.mkdir(parents=True, exist_ok=True)

data["menuBar"] = False
data["disableAltMenuBar"] = True

fd, tmp = tempfile.mkstemp(prefix=".config.", dir=path.parent)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent="\t", ensure_ascii=False)
        fh.write("\n")
    if path.exists():
        os.chmod(tmp, path.stat().st_mode & 0o777)
    os.replace(tmp, path)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
print(f"  ok menu bar hidden in {path}")
PY
}

patch_bindings(){
  python3 - "$BINDINGS" "${1:-install}" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
action = sys.argv[2]
start = "-- >>> tidal-hotkey-bind"
end = "-- <<< tidal-hotkey-bind"
block = [
    start,
    '-- TIDAL Hi-Fi : SUPER + SHIFT + M (overrides the Spotify default)',
    'hl.unbind("SUPER + SHIFT + M")',
    'o.bind("SUPER + SHIFT + M", "TIDAL Hi-Fi", { launch = "tidal-hifi" })',
    end,
]

text = path.read_text(encoding="utf-8") if path.is_file() else ""
lines = text.splitlines()

def drop_marker(lines):
    out, skip = [], False
    for line in lines:
        if line.strip() == start:
            skip = True
            continue
        if skip:
            if line.strip() == end:
                skip = False
            continue
        out.append(line)
    return out

def drop_legacy_sone(lines):
    out = []
    for line in lines:
        if 'SONE (Tidal)' in line or 'launch = "sone"' in line:
            while out:
                prev = out[-1].strip()
                if prev == 'hl.unbind("SUPER + SHIFT + M")' or (
                    prev.startswith("#") and "SONE (Tidal)" in prev
                ):
                    out.pop()
                else:
                    break
            continue
        if "use SONE (Tidal) instead" in line:
            continue
        out.append(line)
    return out

lines = drop_legacy_sone(drop_marker(lines))
if action == "install":
    while lines and not lines[-1].strip():
        lines.pop()
    lines += [""] + block

path.parent.mkdir(parents=True, exist_ok=True)
path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
print(f"  ok TIDAL hotkey {'installed' if action == 'install' else 'removed'} in {path}")
PY
}

status_bindings(){
  python3 - "$BINDINGS" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8") if path.is_file() else ""
if "-- >>> tidal-hotkey-bind" in text and 'launch = "tidal-hifi"' in text:
    print("  ok SUPER + SHIFT + M -> TIDAL Hi-Fi")
elif "SONE (Tidal)" in text:
    print("  !  legacy SONE hotkey present — rerun --install")
else:
    print("  !  SUPER + SHIFT + M -> TIDAL hotkey absent — run the install hook once")
PY
}

reload_hypr(){
  command -v hyprctl >/dev/null 2>&1 || return 0
  [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] || return 0
  hyprctl reload >/dev/null 2>&1 || true
}

status_config(){
  python3 - "$CONFIG" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
if not path.is_file():
    print(f"  !  {path} absent — run the install hook once")
    raise SystemExit(0)
try:
    data = json.loads(path.read_text(encoding="utf-8"))
except (OSError, ValueError) as e:
    print(f"  xx cannot parse {path}: {e}")
    raise SystemExit(1)
menu = data.get("menuBar", "unset")
alt = data.get("disableAltMenuBar", "unset")
print(f"  {'ok' if menu is False else '! '} menuBar={menu}")
print(f"  {'ok' if alt is True else '! '} disableAltMenuBar={alt}")
PY
}

case "${1:-}" in
  --install)
    install_pkg || exit 1
    patch_config
    patch_bindings install
    reload_hypr
    if pgrep -x tidal-hifi >/dev/null 2>&1; then
      echo "  !  TIDAL Hi-Fi is running — restart it to apply the menu-bar change"
    fi
    ;;
  --remove)
    # Keep the user's config untouched; drop our hotkey so the Spotify default
    # becomes reachable again.
    patch_bindings remove
    reload_hypr
    ;;
  --uninstall)
    patch_bindings remove
    reload_hypr
    remove_pkg
    ;;
  --status)
    if pkg_has; then echo ok; else echo missing; fi
    status_config; status_bindings ;;
  *) echo "Usage: $0 --install|--remove|--uninstall|--status" >&2; exit 1 ;;
esac
