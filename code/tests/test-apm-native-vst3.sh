#!/usr/bin/env bash
# A bridged Windows VST3 bundle is a directory just like a native one. The
# native scan must only count bundles carrying an ELF .so under Contents/,
# otherwise Serum2.vst3 comes back as an untracked "native" plugin on every
# launch while its real (bridged) file is already in the log.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
mkdir -p "$HOME" "$TMP/plugins/vst3"
export AUDIOSTACK_VST_ROOT="$TMP/plugins"
export XDG_CONFIG_HOME="$TMP/cfg"

# shellcheck source=/dev/null
source "$ROOT/code/modules/mosquito/audio-stack/apm/lib-audio-plugin-manager-core.sh"

# A bridged bundle: a Windows file in Contents/x86_64-win/, no ELF anywhere.
mkdir -p "$VST_VST3/Serum2.vst3/Contents/x86_64-win"
printf 'MZ binary\n' > "$VST_VST3/Serum2.vst3/Contents/x86_64-win/Serum2.vst3"
# A genuine native bundle: ELF shared object under Contents/.
mkdir -p "$VST_VST3/Native.vst3/Contents/x86_64-linux"
cp /bin/true "$VST_VST3/Native.vst3/Contents/x86_64-linux/Native.so"

out="$(scan_native_plugins)"
grep -qF "$VST_VST3/Native.vst3" <<< "$out" || { echo "fail: native VST3 bundle not scanned" >&2; exit 1; }
if grep -qF "$VST_VST3/Serum2.vst3" <<< "$out"; then
  echo "fail: bridged Windows bundle counted as native" >&2; exit 1
fi
