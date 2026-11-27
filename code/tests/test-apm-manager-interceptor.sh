#!/usr/bin/env bash
# A plugin manager that downloads an installer and runs it itself bypasses the
# plugin log. Only NEW, finished downloads may be intercepted; the files that
# were already there when the manager opened must never be run again.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/cfg"
export XDG_CACHE_HOME="$TMP/cache" XDG_DOWNLOAD_DIR="$TMP/downloads"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_DOWNLOAD_DIR/Vendor"

# shellcheck source=/dev/null
source "$ROOT/code/modules/mosquito/audio-stack/apm/lib-audio-plugin-manager-core.sh"

# Record which installer reached the real install path instead of running wine.
declare -a installed=()
install_plugin(){ installed+=("$1 $2"); : > "$1"; }

# Present before the manager opened: seeded, never intercepted.
printf 'old\n' > "$XDG_DOWNLOAD_DIR/Vendor/Old.exe"
apm_seed_manager_installers
apm_intercept_new_installer "$HOME/.wine-vst"
apm_intercept_new_installer "$HOME/.wine-vst"
((${#installed[@]} == 0)) || { echo "fail: pre-existing installer was run" >&2; exit 1; }

# A new download: first sighting only records its size, second one installs it.
printf 'new installer\n' > "$XDG_DOWNLOAD_DIR/Vendor/New Setup (x64).msi"
apm_intercept_new_installer "$HOME/.wine-vst"
((${#installed[@]} == 0)) || { echo "fail: incomplete download was run" >&2; exit 1; }
apm_intercept_new_installer "$HOME/.wine-vst"
((${#installed[@]} == 1)) || { echo "fail: new installer was not intercepted" >&2; exit 1; }
[[ ${installed[0]} == *"New Setup (x64).msi $HOME/.wine-vst" ]] || {
  echo "fail: wrong installer or prefix: ${installed[0]}" >&2; exit 1; }
[[ ! -e "$XDG_DOWNLOAD_DIR/Vendor/New Setup (x64).msi" ]] || {
  echo "fail: installer still in the manager's download folder" >&2; exit 1; }
