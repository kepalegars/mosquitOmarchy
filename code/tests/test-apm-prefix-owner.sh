#!/usr/bin/env bash
# A plugin found through a prefix's symlinked VST folder must not be recorded
# as owned by that prefix — all prefixes link to the same shared store, and the
# first scan hit used to be ~/.wine, the gaming prefix.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/cfg"
mkdir -p "$HOME" "$XDG_CONFIG_HOME"

# shellcheck source=/dev/null
source "$ROOT/code/modules/mosquito/audio-stack/apm/lib-audio-plugin-manager-core.sh"

shared="$TMP/shared/vst3"
mkdir -p "$shared" "$HOME/.wine/drive_c/Program Files/Common Files" \
         "$HOME/.wine-vst/drive_c/Program Files/Vendor"
printf 'plugin\n' > "$shared/Plug.vst3"
ln -s "$shared" "$HOME/.wine/drive_c/Program Files/Common Files/VST3"
printf 'real plugin\n' > "$HOME/.wine-vst/drive_c/Program Files/Vendor/Real.dll"

[[ -z $(wine_owner_prefix_of "$HOME/.wine/drive_c/Program Files/Common Files/VST3/Plug.vst3") ]] || {
  echo "fail: symlinked plugin was attributed to .wine" >&2; exit 1; }
[[ $(wine_owner_prefix_of "$HOME/.wine-vst/drive_c/Program Files/Vendor/Real.dll") == "$HOME/.wine-vst" ]] || {
  echo "fail: real prefix-owned plugin not recognised" >&2; exit 1; }
