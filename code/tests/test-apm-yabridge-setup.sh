#!/usr/bin/env bash
# The yabridge first-setup path must (a) point yabridgectl at the folders the
# manager scans instead of a stale config carried from another machine, and
# (b) remove the <vendor>/drive_c/... leftovers of the old suite mirror.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
mkdir -p "$HOME" "$TMP/plugins/vst" "$TMP/plugins/vst3" "$TMP/plugins/clap"
export AUDIOSTACK_VST_ROOT="$TMP/plugins"
export YABRIDGE_DST="$TMP/yabridge"
export XDG_CONFIG_HOME="$TMP/cfg"
export YABRIDGE_CFG="$TMP/cfg/yabridgectl/config.toml"
mkdir -p "$(dirname "$YABRIDGE_CFG")"
cat > "$YABRIDGE_CFG" <<'EOF'
yabridge_home = "/home/someone-else/.local/share/yabridge"
plugin_dirs = [
    '/home/someone-else/Music/Audio Plugins/vst',
]
vst2_location = 'centralized'
EOF

# shellcheck source=/dev/null
source "$ROOT/code/modules/mosquito/audio-stack/apm/lib-audio-plugin-manager-core.sh"

if command -v yabridgectl >/dev/null 2>&1; then
  yabridge_pin_yabridgectl
  grep -qF "yabridge_home = \"$YABRIDGE_DST\"" "$YABRIDGE_CFG" || \
    grep -qF "yabridge_home = '$YABRIDGE_DST'" "$YABRIDGE_CFG" || {
    echo "fail: yabridge_home not pinned" >&2; exit 1; }
  for d in "$VST_VST2" "$VST_VST3" "$VST_CLAP"; do
    yabridgectl list 2>/dev/null | grep -qxF "$d" || {
      echo "fail: $d not registered" >&2; exit 1; }
  done
  if yabridgectl list 2>/dev/null | grep -qF '/home/someone-else'; then
    echo "fail: stale plugin dir kept" >&2; exit 1
  fi
fi

# A config holding nothing but a foreign yabridge_home must still be rewritten:
# grep -v exits 1 when the remainder is empty, which used to abort the write.
export XDG_CONFIG_HOME="$TMP/cfg2"
export YABRIDGE_CFG="$TMP/cfg2/yabridgectl/config.toml"
mkdir -p "$(dirname "$YABRIDGE_CFG")"
printf 'yabridge_home = "/home/someone-else/.local/share/yabridge"\n' > "$YABRIDGE_CFG"
yabridge_pin_yabridgectl
grep -qF "$YABRIDGE_DST" "$YABRIDGE_CFG" || {
  echo "fail: lone foreign yabridge_home not replaced" >&2; exit 1; }

# The old mirror created <vendor>/drive_c/... symlinks into a wine prefix.
src="$HOME/.wine-test/drive_c/ProgramData/Arturia/Presets"
mkdir -p "$src"
stray="$VST_VST3/Arturia/drive_c/ProgramData/Arturia/Presets"
mkdir -p "$(dirname "$stray")"
ln -s "$src" "$stray"
printf 'explorer metadata\n' > "$VST_VST3/Arturia/desktop.ini"
apm_clean_shared_leftovers
[[ ! -e "$stray" ]] || { echo "fail: stray suite link kept" >&2; exit 1; }
[[ ! -e "$VST_VST3/Arturia/desktop.ini" ]] || { echo "fail: desktop.ini kept" >&2; exit 1; }
echo 'ok: yabridgectl points at the scanned folders; stray suite links are cleaned'
