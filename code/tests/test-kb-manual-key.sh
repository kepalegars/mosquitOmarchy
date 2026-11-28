#!/usr/bin/env bash
# A manually typed key can be already bound: kb-check reports the owner, and
# kb-add refuses unless the user accepts the override with "force".
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home/.config/hypr" "$TMP/empty"
printf 'o.bind("Super + Q", "Launch terminal", "foot")\n' > "$TMP/empty/default.lua"
cat > "$TMP/home/.config/hypr/hyprland.lua" <<'EOF'
-- o.bind("SUPER + H", "commented example", "foot")
o.bind("SUPER + ALT + V", "Omarchy VM: focus the VM", "omarchy-vm-focus")
EOF
cat > "$TMP/home/.config/hypr/bindings.lua" <<'EOF'
o.bind("SUPER + A", "Terminal", "foot")
-- >>> mosquitOmarchy_Keybindings
o.bind("SUPER + B", "ours", "true", { locked = true, repeating = true })
-- <<< mosquitOmarchy_Keybindings
EOF

export HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/home/.config"
export KB_DEF_DIR="$TMP/empty" MQ_ELEVATED_ONCE=1
ACTIONS="$ROOT/code/main tui/mosquitomarchy-actions"

out="$(bash "$ACTIONS" kb-check 'super+a')"
grep -q '"taken":true' <<<"$out"
grep -q '"overridable":true' <<<"$out"
grep -q 'Terminal' <<<"$out"

out="$(bash "$ACTIONS" kb-check 'super+q')"
grep -q '"taken":true' <<<"$out"
grep -q '"overridable":true' <<<"$out"
grep -q 'Omarchy default (Launch terminal)' <<<"$out"

# A combo managed by mosquitOmarchy itself is a conflict too.
out="$(bash "$ACTIONS" kb-check 'SUPER + B')"
grep -q '"taken":true,"where":"managed by mosquitOmarchy (currently: ours)","overridable":true' <<<"$out"

# A binding in another hypr config is a conflict too; a commented example is not.
out="$(bash "$ACTIONS" kb-check 'SUPER + ALT + V')"
grep -q '"taken":true' <<<"$out"
grep -q '"overridable":false' <<<"$out"
grep -q 'hyprland.lua (Omarchy VM: focus the VM)' <<<"$out"

# Even "force" cannot override a bind declared after our block.
if bash "$ACTIONS" kb-add 'SUPER + ALT + V' 'Mine' 'true' cmd force >/dev/null 2>&1; then
  echo 'FAIL: kb-add force overrode an unsolvable conflict' >&2
  exit 1
fi

out="$(bash "$ACTIONS" kb-check 'SUPER + H')"
grep -q '"taken":false' <<<"$out"

out="$(bash "$ACTIONS" kb-check 'SUPER + SHIFT + F12')"
grep -q '"taken":false' <<<"$out"

if bash "$ACTIONS" kb-add 'SUPER + A' 'Mine' 'true' cmd >/dev/null 2>&1; then
  echo 'FAIL: kb-add overwrote a bound key without force' >&2
  exit 1
fi
bash "$ACTIONS" kb-add 'SUPER + A' 'Mine' 'true' cmd force >/dev/null
grep -q 'o.bind("SUPER + A", "Mine"' "$XDG_CONFIG_HOME/hypr/bindings.lua"

echo 'ok: manual key check warns and force is required to override'
