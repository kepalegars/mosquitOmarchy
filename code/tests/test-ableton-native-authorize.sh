#!/usr/bin/env bash
# The native authorization helper must read the HWID from the native Live
# data dir (not a Wine prefix), offer it to the clipboard, wait for the tool
# and copy the freshly generated .auz into the native install folder.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SCRIPT="$ROOT/code/modules/Apps/ableton/native/authorize-native.sh"

export HOME="$TMP/home" XDG_DATA_HOME="$TMP/data"
export PATH="$TMP/bin:$PATH"
mkdir -p "$HOME/Documents/new patch" "$HOME/Downloads" "$XDG_DATA_HOME/Ableton/Live 12.4.7/Unlock" "$TMP/bin"

cat > "$XDG_DATA_HOME/Ableton/Live 12.4.7/Unlock/Unlock.json" <<'JSON'
{"products":[{"challenge_code":"2506-6416-085B-4129-987C-0AB3"}]}
JSON

# Clipboard + opener stubs.
cat > "$TMP/bin/wl-copy" <<'EOF'
#!/usr/bin/env bash
cat > "$HOME/clipboard"
EOF
cat > "$TMP/bin/xdg-open" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HOME/opened"
EOF
# Fake tool: writes the .auz only when launched, mimicking the manual step.
cat > "$TMP/bin/wine" <<'EOF'
#!/usr/bin/env bash
printf 'auz\n' > "$HOME/Documents/new patch/generated.auz"
EOF
chmod +x "$TMP/bin/"*

bash "$SCRIPT" --no-run
for _ in {1..40}; do [[ -f "$HOME/clipboard" ]] && break; sleep 0.05; done
[[ $(cat "$HOME/clipboard") == '2506-6416-085B-4129-987C-0AB3' ]]
[[ ! -f "$HOME/Documents/new patch/generated.auz" ]]

: > "$HOME/Documents/new patch/WM_Ableton.r2rwm"
R2RWM_TOOL="$HOME/Documents/new patch/WM_Ableton.r2rwm" bash "$SCRIPT"
[[ -f "$XDG_DATA_HOME/ableton-live-12/generated.auz" ]]
grep -q "$XDG_DATA_HOME/ableton-live-12" "$HOME/opened"

echo 'ok: native HWID -> clipboard -> tool -> .auz -> install folder'
