#!/usr/bin/env bash
# Self-check for levels-guard: managed EVO is blocked until the user opts in
# (with a 0% OSD); every other default delegates to Omarchy.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="$here/levels-guard"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/config/mosquitomixbay"
log="$tmp/log"
osd_log="$tmp/osd"

cat >"$tmp/bin/omarchy-audio-output-sink" <<'SH'
#!/bin/bash
cat "$SINK_NAME"
SH
cat >"$tmp/bin/pactl" <<'SH'
#!/bin/bash
if [[ $1 == get-default-source ]]; then cat "$SOURCE_NAME"; fi
SH
cat >"$tmp/bin/omarchy-audio-output-volume" <<'SH'
#!/bin/bash
printf 'output %s\n' "$*" >>"$LOG"
SH
cat >"$tmp/bin/omarchy-audio-input-mute" <<'SH'
#!/bin/bash
printf 'input mute\n' >>"$LOG"
SH
cat >"$tmp/bin/omarchy-osd" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$OSD_LOG"
SH
chmod +x "$tmp"/bin/*
export PATH="$tmp/bin:$PATH"
export XDG_CONFIG_HOME="$tmp/config"
export LOG="$log"
export OSD_LOG="$osd_log"
printf 'alsa_output.usb-Audient_EVO8-00.pro-output-0\n' >"$tmp/sink"
printf 'alsa_input.pci-0000.test\n' >"$tmp/source"
export SINK_NAME="$tmp/sink"
export SOURCE_NAME="$tmp/source"

# Managed output, no opt-in: ignored.
run() { : >"$log"; : >"$osd_log"; "$helper" "$@" || true; cat "$log"; }
[[ -z $(run output raise) ]] || { echo "managed output was not blocked"; exit 1; }
[[ $(cat "$osd_log") == *"-i volume-muted -p 0"* ]] || { echo "blocked output did not show the 0% OSD"; exit 1; }

# Managed output, opt-in: delegated.
echo '{"allow_native_volume": true}' >"$tmp/config/mosquitomixbay/ui.json"
[[ $(run output raise) == "output raise" ]] || { echo "opt-in did not delegate"; exit 1; }
rm -f "$tmp/config/mosquitomixbay/ui.json"

# Unmanaged output: delegated.
printf 'alsa_output.pci-0000.00.0.analog-stereo\n' >"$tmp/sink2"
export SINK_NAME="$tmp/sink2"
[[ $(run output lower) == "output lower" ]] || { echo "unmanaged output did not delegate"; exit 1; }

# Managed input, no opt-in: ignored; then opt-in delegates.
printf 'alsa_input.usb-Audient_EVO8-00.pro-input-0\n' >"$tmp/source2"
export SOURCE_NAME="$tmp/source2"
[[ -z $(run input) ]] || { echo "managed input was not blocked"; exit 1; }
[[ $(cat "$osd_log") == *"-i microphone-muted -p 0"* ]] || { echo "blocked input did not show the 0% OSD"; exit 1; }
echo '{"allow_native_volume": true}' >"$tmp/config/mosquitomixbay/ui.json"
[[ $(run input) == "input mute" ]] || { echo "input opt-in did not delegate"; exit 1; }

echo ok
