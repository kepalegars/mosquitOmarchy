#!/usr/bin/env bash
# native-tidal-hifi-tidaluna.sh — integration hook for the TIDAL Hi-Fi
# (TidaLuna) entry of webapps.catalog.
#
# The package itself is installed by common.bash (yay -S tidal-hifi-tidaluna,
# driven by the catalog's "native:<pkg>" URL). This hook only owns the setting
# the package cannot ship for us: hide the Electron menu bar.
#
# TIDAL Hi-Fi reads ~/.config/tidal-hifi/config.json (electron-store). The
# store merges its defaults into a partial file, so writing just the two keys
# is safe even before the app has ever run. Everything the user already has is
# preserved verbatim.
#
#   menuBar = false             no permanent menu bar
#   disableAltMenuBar = true    Alt no longer pops it up either
#
# Usage: native-tidal-hifi-tidaluna.sh --install|--remove|--status
set -euo pipefail

CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/tidal-hifi/config.json"

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
    patch_config
    if pgrep -x tidal-hifi >/dev/null 2>&1; then
      echo "  !  TIDAL Hi-Fi is running — restart it to apply the menu-bar change"
    fi
    ;;
  --remove)
    # The package is about to be removed; keep the user's config untouched.
    ;;
  --status) status_config ;;
  *) echo "Usage: $0 --install|--remove|--status" >&2; exit 1 ;;
esac
