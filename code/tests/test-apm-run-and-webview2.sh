#!/usr/bin/env bash
# Two launch/install paths that used to be dead ends:
#  - a Makeself .run is a shell header + tar payload: the plugin inside must be
#    installed without EXECUTING the vendor's install.sh;
#  - a WebView2 manager must find a runtime in its own wine prefix before its
#    window can open, and must be watched to close so its installs are adopted.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/cfg" XDG_CACHE_HOME="$TMP/cache"
export AUDIOSTACK_VST_ROOT="$TMP/plugins" VST_STATE_DIR="$TMP/state"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$AUDIOSTACK_VST_ROOT/vst3" "$VST_STATE_DIR"

# shellcheck source=/dev/null
source "$ROOT/code/modules/mosquito/audio-stack/apm/lib-audio-plugin-manager-core.sh"
state_init
load_prefs

# A Makeself-shaped file: five header lines, then a gzipped tar payload that
# carries one VST3 bundle and the install.sh we must NOT run.
payload="$TMP/payload"; mkdir -p "$payload/payload/vst3/PitchNet.vst3/Contents/x86_64-linux"
: > "$payload/payload/vst3/PitchNet.vst3/Contents/x86_64-linux/PitchNet.so"
printf '#!/bin/sh\ntouch /tmp/makeself-MUST-NOT-RUN\n# fixture\nskip="5"\neval $finish\n' > "$TMP/p.run"
tar -czf - -C "$payload" . >> "$TMP/p.run"

install_native_plugin_from_file "$TMP/p.run" > /dev/null
[[ -d "$AUDIOSTACK_VST_ROOT/vst3/PitchNet.vst3" ]] || { echo "fail: .run plugin not installed" >&2; exit 1; }
grep -q 'native/PitchNet' "$STATE_FILE" || { echo "fail: .run plugin not tracked" >&2; exit 1; }
[[ ! -e /tmp/makeself-MUST-NOT-RUN ]] || { echo "fail: install.sh was executed" >&2; exit 1; }

exe="$HOME/.wine-vst/drive_c/Program Files/Mercurial Tones Hub/mercurial-software-center.exe"
is_plugin_manager_exe "$exe" || { echo "fail: manager not recognised" >&2; exit 1; }
is_plugin_manager_exe "$HOME/.wine-vst/drive_c/Program Files/Mercurial Tones Hub/unins000.exe" && {
  echo "fail: a plain exe was recognised as a manager" >&2; exit 1; }

src="$HOME/.wine-ableton/drive_c/Program Files (x86)/Microsoft/EdgeWebView/Application/99.0.1"
mkdir -p "$src" "$HOME/.wine-vst/drive_c"
: > "$src/msedgewebview2.exe"
apm_ensure_webview2 "$HOME/.wine-vst" "$exe"
[[ $WEBVIEW2_BROWSER_EXECUTABLE_FOLDER == 'C:\Program Files (x86)\Microsoft\EdgeWebView\Application\99.0.1' ]] || {
  echo "fail: bad runtime path: $WEBVIEW2_BROWSER_EXECUTABLE_FOLDER" >&2; exit 1; }
[[ -f "$HOME/.wine-vst/drive_c/Program Files (x86)/Microsoft/EdgeWebView/Application/99.0.1/msedgewebview2.exe" ]] || {
  echo "fail: runtime not linked into the launch prefix" >&2; exit 1; }

# The MSI's own "Launch the hub" checkbox spawns the app as a CHILD of the
# installer, so install_plugin must set the override before starting wine.
called="$TMP/install-env-called"
apm_ensure_webview2(){ printf '%s|%s' "$1" "$2" > "$called"; return 1; }
install_plugin "$HOME/Downloads/Mercurial-Tones-Hub-Windows.msi" "$HOME/.wine-vst" >/dev/null 2>&1 || true
[[ $(<"$called") == "$HOME/.wine-vst|$HOME/Downloads/Mercurial-Tones-Hub-Windows.msi" ]] || {
  echo "fail: installer did not set up WebView2 before launching its child" >&2; exit 1; }
