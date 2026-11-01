#!/usr/bin/env bash
# Regression test for the addon format and the update reinstall list.
# Runs in a throwaway HOME: one user addon + the shipped emoticon addon.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP"
export XDG_CONFIG_HOME="$TMP/.config"
export XDG_STATE_HOME="$TMP/.local/state"

mkdir -p "$XDG_CONFIG_HOME/mosquitomarchy/addons/demo" "$TMP/src"
cat > "$XDG_CONFIG_HOME/mosquitomarchy/addons/demo/addon.conf" <<'EOF'
NAME="demo"
DESCRIPTION="test addon"
ENABLED="yes"
EOF
cat > "$XDG_CONFIG_HOME/mosquitomarchy/addons/demo/install.sh" <<'EOF'
#!/usr/bin/env bash
printf 'run\n' >> "$HOME/demo-runs"
EOF
chmod +x "$XDG_CONFIG_HOME/mosquitomarchy/addons/demo/install.sh"
# The shipped emoticon addon needs an image; Omarchy ships theme previews, so
# the test does not depend on an external wallpaper disk.
img="$(find /usr/share/omarchy/themes -maxdepth 2 -name 'preview.png' 2>/dev/null | head -n1)"
[[ -n $img ]] || { echo "SKIP: no Omarchy preview image available"; exit 0; }
cp "$img" "$TMP/src/wall.png"
export EMOTICON_SRC="$TMP/src"
export EMOTICON_THEME_NAME="AddonTest"

bash "$ROOT/code/modules/addons/setup-addons.sh" --all >/dev/null
grep -Fxq demo "$XDG_STATE_HOME/mosquitomarchy/addons-installed"
grep -Fxq emoticon "$XDG_STATE_HOME/mosquitomarchy/addons-installed"

before="$(grep -c '^run$' "$TMP/demo-runs")"
bash "$ROOT/code/modules/addons/setup-addons.sh" --reinstall >/dev/null
after="$(grep -c '^run$' "$TMP/demo-runs")"
[[ $after -eq $((before + 1)) ]] || { echo "FAIL: reinstall did not re-run the recorded addon"; exit 1; }

echo "ok: addon format, state recording and update reinstall work"
