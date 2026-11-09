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

# ISSKIN: the installer carries the string; the missing piece is the MFC42
# runtime, not a copy of ISSKINU.DLL. sonible installers are recognised by name
# too (their build compresses the string).
printf 'MZ....ISSKINU.DLL....' > "$TMP/isskin.exe"
installer_uses_isskin "$TMP/isskin.exe" || { echo "fail: ISSKIN installer not detected" >&2; exit 1; }
needs_isskin_runtime "$TMP/isskin.exe" || { echo "fail: ISSKIN runtime not required" >&2; exit 1; }
printf 'MZ....plain....' > "$TMP/plain.exe"
installer_uses_isskin "$TMP/plain.exe" && { echo "fail: false ISSKIN match" >&2; exit 1; }
needs_isskin_runtime "$TMP/plain.exe" && { echo "fail: plain installer flagged" >&2; exit 1; }
needs_isskin_runtime "$TMP/Setup smartEQ4 v1.0.1.exe" || { echo "fail: sonible installer not detected" >&2; exit 1; }

# The default root is the shared Music folder, never the empty legacy ~/VST.
(
  export HOME="$TMP/home-default"
  mkdir -p "$HOME"
  unset AUDIOSTACK_VST_ROOT
  # shellcheck source=/dev/null
  source "$ROOT/code/modules/mosquito/audio-stack/apm/lib-audio-plugin-manager-core.sh"
  [[ $VST_ROOT == "$HOME/Music/Audio Plugins" ]] || {
    echo "fail: default VST root is $VST_ROOT, not the shared Music folder" >&2; exit 1; }
)

# An empty ~/VST skeleton is removed; a legacy root holding a real plugin stays.
mkdir -p "$HOME/VST/vst" "$HOME/VST/vst3" "$HOME/VST/clap"
apm_clean_empty_legacy_vst_root
[[ ! -e "$HOME/VST" ]] || { echo "fail: empty ~/VST kept" >&2; exit 1; }
mkdir -p "$HOME/VST/vst/Keep"
: > "$HOME/VST/vst/Keep/plugin.dll"
apm_clean_empty_legacy_vst_root
[[ -d "$HOME/VST" ]] || { echo "fail: legacy ~/VST with a plugin removed" >&2; exit 1; }

# A native DAW must not scan the shared WINDOWS plugin folders: a Windows PE
# .vst3 cannot be loaded by native REAPER, and its cached failure shadows the
# yabridge chainloader of the same basename. Old wizard versions wrote those
# paths; the repair removes them, keeps the native folders, and drops the
# failure-only cache lines so the chainloaders are retried.
mkdir -p "$HOME/.config/REAPER"
reaper_ini="$HOME/.config/REAPER/reaper.ini"
cat > "$reaper_ini" <<EOF
[reaper]
vstpath=~/.vst;~/.vst3;$AUDIOSTACK_VST_ROOT/vst/;$AUDIOSTACK_VST_ROOT/vst3/;$AUDIOSTACK_VST_ROOT/vst3-native/
lv2path_linux=/usr/lib/lv2;~/.lv2;$AUDIOSTACK_VST_ROOT/lv2/;$AUDIOSTACK_VST_ROOT/clap/;$AUDIOSTACK_VST_ROOT/clap-native/
clappath=~/.clap;$AUDIOSTACK_VST_ROOT/clap/
EOF
cat > "$HOME/.config/REAPER/reaper-vstplugins64.ini" <<'EOF'
[vstcache]
kHs_Gain.vst3=801A4EA5CF6DDD01
Analog_Lab_V.vst3=00069EB649E7DB01,1097621878,Analog Lab V (Arturia)!!!VSTi
EOF
apm_fix_native_daw_paths
vst_line="$(sed -n 's/^vstpath=//p' "$reaper_ini")"
lv2_line="$(sed -n 's/^lv2path_linux=//p' "$reaper_ini")"
clap_line="$(sed -n 's/^clappath=//p' "$reaper_ini")"
case ";$vst_line;" in
  *";$AUDIOSTACK_VST_ROOT/vst;"*|*";$AUDIOSTACK_VST_ROOT/vst3;"*)
    echo "fail: Windows VST folder kept in REAPER vstpath" >&2; exit 1 ;;
esac
case ";$vst_line;" in
  *";$AUDIOSTACK_VST_ROOT/vst3-native;"*|*";$HOME/.vst;"*) ;;
  *) echo "fail: native/chainloader VST folders lost from REAPER vstpath" >&2; exit 1 ;;
esac
case ";$lv2_line;$clap_line;" in
  *";$AUDIOSTACK_VST_ROOT/clap;"*)
    echo "fail: Windows CLAP folder kept in REAPER paths" >&2; exit 1 ;;
esac
case ";$lv2_line;" in
  *";$AUDIOSTACK_VST_ROOT/lv2;"*|*";$AUDIOSTACK_VST_ROOT/clap-native;"*) ;;
  *) echo "fail: native LV2/CLAP folders lost from REAPER lv2path" >&2; exit 1 ;;
esac
grep -q '^kHs_Gain\.vst3=[0-9A-F]*$' "$HOME/.config/REAPER/reaper-vstplugins64.ini" && {
  echo "fail: failed-scan cache line kept (chainloader stays shadowed)" >&2; exit 1; }
grep -q '^Analog_Lab_V\.vst3=.*,' "$HOME/.config/REAPER/reaper-vstplugins64.ini" || {
  echo "fail: valid cache line removed with the failures" >&2; exit 1; }
[[ -f "$reaper_ini.mosquito.bak" ]] || { echo "fail: no REAPER backup written" >&2; exit 1; }

# Running on an already-clean reaper.ini must still purge the failure-only
# cache lines: the earlier repair rewrote the paths and exited before the
# purge, so the stale failures were never retried.
cat > "$HOME/.config/REAPER/reaper-vstplugins64.ini" <<'EOF'
[vstcache]
Addictive_Drums_2.vst3=80235537CE6DDD01
Analog_Lab_V.vst3=00069EB649E7DB01,1097621878,Analog Lab V (Arturia)!!!VSTi
EOF
apm_fix_native_daw_paths
grep -q '^Addictive_Drums_2\.vst3=[0-9A-F]*$' "$HOME/.config/REAPER/reaper-vstplugins64.ini" && {
  echo "fail: failure-only cache line kept when reaper.ini needed no change" >&2; exit 1; }
grep -q '^Analog_Lab_V\.vst3=.*,' "$HOME/.config/REAPER/reaper-vstplugins64.ini" || {
  echo "fail: valid cache line removed on the no-change path" >&2; exit 1; }

# Wine's builtin msvcp140_atomic_wait.dll exports the __std_atomic_* names and
# then aborts when one is called. Checking only the exports called it a real
# runtime, so the fix reported "already present" and installed nothing -- and
# the first smart:comp3 call took the DAW down. The builtin marker must reject.
stub_pfx="$TMP/stub-pfx"
mkdir -p "$stub_pfx/drive_c/windows/system32"
printf 'MZ....Wine builtin DLL....__std_atomic_wait_get_deadline\n' \
  > "$stub_pfx/drive_c/windows/system32/msvcp140_atomic_wait.dll"
apm_has_real_msvc_atomic_wait "$stub_pfx" && {
  echo "fail: Wine builtin msvcp140_atomic_wait treated as the real runtime" >&2; exit 1; }

# A wrapper generated before the plugin prefix existed pins an EMPTY prefix. The
# DAW then falls back to ~/.wine, and grepping only for "WINEPREFIX=" called the
# wrapper pinned, so it was never rewritten.
# shellcheck source=/dev/null
source "$ROOT/code/lib/wine-runtime-daw.bash"
printf 'VST_PREFIX=""\n' > "$TMP/w-empty"
wrapper_pins_prefix "$TMP/w-empty" && {
  echo "fail: wrapper with an empty prefix treated as pinned" >&2; exit 1; }
printf 'VST_PREFIX="/home/u/.wine-vst"\n' > "$TMP/w-full"
wrapper_pins_prefix "$TMP/w-full" || {
  echo "fail: wrapper with a real prefix not recognised as pinned" >&2; exit 1; }

echo 'ok: yabridgectl points at the scanned folders; stray suite links are cleaned; ISSKIN and VST-root rules hold'
