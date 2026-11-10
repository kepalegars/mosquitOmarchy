#!/usr/bin/env bash
# The restore must not leave a dead shell: the archived shell.json names the
# plugins of the source machine, and the Zen Mods live in the profile the
# source machine used, not in the one this machine opened.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" MOSQUITOMARCHY_LIB_ONLY=1 GUI_RUN_EXEC=1
mkdir -p "$HOME"

source "$ROOT/mosquitomarchy-setup.sh"

# --- shell.json: the plugins this machine does not have are dropped ---------
cat > "$TMP/source-shell.json" <<'EOF'
{
  "version": 1,
  "bar": {
    "id": "vanished.bar",
    "layout": {
      "left": [{"id": "omarchy.menu"}, {"id": "gone.widget"}],
      "center": [{"id": "omarchy.clock", "format": "HH:mm"}]
    }
  },
  "plugins": [{"id": "omarchy.agents"}, {"id": "missing.plugin"}],
  "disabledPlugins": ["omarchy.clock", "gone.plugin"],
  "cloneSourceRestores": ["omarchy.menu", "gone.plugin"]
}
EOF
mkdir -p "$TMP/src/.config/omarchy"
cp "$TMP/source-shell.json" "$TMP/src/.config/omarchy/shell.json"
tar czf "$TMP/config.tar.gz" -C "$TMP/src" .config/omarchy/shell.json

# A machine with only Omarchy's own plugins.
mkdir -p "$TMP/fake-omarchy/shell/plugins/panels/clock"
cat > "$TMP/fake-omarchy/shell/plugins/panels/clock/manifest.json" <<'EOF'
{"schemaVersion": 1, "id": "omarchy.clock", "name": "Clock", "version": "1", "kinds": ["panel"], "entryPoints": {}}
EOF
mkdir -p "$TMP/fake-omarchy/shell/plugins/menu"
cat > "$TMP/fake-omarchy/shell/plugins/menu/manifest.json" <<'EOF'
{"schemaVersion": 1, "id": "omarchy.menu", "name": "Menu", "version": "1", "kinds": ["menu"], "entryPoints": {}}
EOF
mkdir -p "$TMP/fake-omarchy/shell/plugins/agents"
cat > "$TMP/fake-omarchy/shell/plugins/agents/manifest.json" <<'EOF'
{"schemaVersion": 1, "id": "omarchy.agents", "name": "Agents", "version": "1", "kinds": ["panel"], "entryPoints": {}}
EOF

# Point the plugin scan at the fake Omarchy tree.
shell_json_known_plugins(){
  local -a ids=()
  local f id
  while IFS= read -r f; do
    id="$(jq -r '.id // empty' "$f" 2>/dev/null)"
    [[ -n $id ]] && ids+=("$id")
  done < <(find "$TMP/fake-omarchy/shell/plugins" -maxdepth 3 \
             \( -name 'manifest.json' -o -name '*.manifest.json' \) -type f 2>/dev/null)
  ((${#ids[@]})) || return 0
  printf '%s\n' "${ids[@]}" | jq -R . | jq -s 'unique' 2>/dev/null
}

restore_shell_json "$TMP/config.tar.gz" full
shell_json="$HOME/.config/omarchy/shell.json"
[[ -f $shell_json ]]
jq -e '(.plugins | map(.id)) == ["omarchy.agents"]' "$shell_json" >/dev/null
jq -e '(.bar.layout.left | map(.id)) == ["omarchy.menu"]' "$shell_json" >/dev/null
jq -e '(.bar.layout.center | map(.id)) == ["omarchy.clock"]' "$shell_json" >/dev/null
jq -e '.bar | has("id") | not' "$shell_json" >/dev/null
jq -e '.disabledPlugins == ["omarchy.clock"]' "$shell_json" >/dev/null
jq -e '.cloneSourceRestores == ["omarchy.menu"]' "$shell_json" >/dev/null

# Safe mode keeps the target's unrelated settings and replaces only the bar
# slice, so restoring onto a live machine does not reset its idle/dock settings.
cat > "$shell_json" <<'EOF'
{
  "version": 1,
  "bar": {"layout": {"left": [{"id": "omarchy.menu"}]}},
  "plugins": [],
  "disabledPlugins": ["omarchy.agents"],
  "cloneSourceRestores": [],
  "idle": {"lock": 999},
  "dock": {"pinned": ["foot"]}
}
EOF
restore_shell_json "$TMP/config.tar.gz" safe
jq -e '(.bar.layout.left | map(.id)) == ["omarchy.menu"]' "$shell_json" >/dev/null
jq -e '(.bar.layout.center | map(.id)) == ["omarchy.clock"]' "$shell_json" >/dev/null
jq -e '(.plugins | map(.id)) == ["omarchy.agents"]' "$shell_json" >/dev/null
jq -e '.disabledPlugins == ["omarchy.clock"]' "$shell_json" >/dev/null
jq -e '.cloneSourceRestores == ["omarchy.menu"]' "$shell_json" >/dev/null
jq -e '.idle.lock == 999' "$shell_json" >/dev/null
jq -e '.dock.pinned == ["foot"]' "$shell_json" >/dev/null

# --- Zen: the Mods land in the profile this machine uses --------------------
mkdir -p "$TMP/zen-src/.config/zen/source-profile/chrome/zen-themes/my-mod" \
  "$TMP/zen-src/.config/zen/source-profile/extensions"
printf 'mod css\n' > "$TMP/zen-src/.config/zen/source-profile/chrome/zen-themes/my-mod/chrome.css"
printf 'user_pref("zen.test", true);\n' > "$TMP/zen-src/.config/zen/source-profile/prefs.js"
printf 'xpi\n' > "$TMP/zen-src/.config/zen/source-profile/extensions/custom.xpi"
tar czf "$TMP/zen.tar.gz" -C "$TMP/zen-src" .config/zen/source-profile

mkdir -p "$HOME/.config/zen/target-profile"
printf '[Install1]\nDefault=target-profile\n' > "$HOME/.config/zen/profiles.ini"
zen_active_profile(){ printf 'target-profile'; }

restore_zen_profile "$TMP/zen.tar.gz" full
[[ -f "$HOME/.config/zen/target-profile/chrome/zen-themes/my-mod/chrome.css" ]]
[[ -f "$HOME/.config/zen/target-profile/extensions/custom.xpi" ]]
grep -q 'zen.test' "$HOME/.config/zen/target-profile/prefs.js"

echo 'ok: restore keeps the shell alive and puts the Zen Mods in the active profile'
