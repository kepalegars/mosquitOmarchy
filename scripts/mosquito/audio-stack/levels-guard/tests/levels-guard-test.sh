#!/usr/bin/env bash
# Self-check for levels-guard: every Mixbay-managed interface is blocked until
# the user opts in (with a 100% icon/text and an empty level bar); every other
# default delegates to Omarchy.
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
cat >"$tmp/bin/omarchy-shell" <<'SH'
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

run() { : >"$log"; : >"$osd_log"; "$helper" "$@" || true; cat "$log"; }
blocked_osd() {  # blocked_osd ICON : empty level bar, 100% text
  grep -qF -- "\"icon\":\"$1\"" "$osd_log" \
    && grep -qF -- '"value":0' "$osd_log" \
    && grep -qF -- '"progressText":"100%"' "$osd_log"
}
set_sink() { printf '%s\n' "$1" >"$tmp/sink"; SINK_NAME="$tmp/sink"; }
set_source() { printf '%s\n' "$1" >"$tmp/source"; SOURCE_NAME="$tmp/source"; }

# Managed output, no opt-in: ignored, full icon + 100% text + empty bar.
[[ -z $(run output raise) ]] || { echo "managed output was not blocked"; exit 1; }
blocked_osd volume || { echo "blocked output OSD is wrong"; exit 1; }

# Every supported Mixbay interface is recognised by its PipeWire node name.
set_sink 'alsa_output.usb-RME_Fireface_UCX_II_12345678-00.analog-stereo'
[[ -z $(run output raise) ]] || { echo "RME output was not blocked"; exit 1; }
blocked_osd volume || { echo "RME output OSD is wrong"; exit 1; }

set_sink 'alsa_output.usb-PreSonus_Quantum_ES_4_1234-00.analog-stereo'
[[ -z $(run output raise) ]] || { echo "PreSonus output was not blocked"; exit 1; }
blocked_osd volume || { echo "PreSonus output OSD is wrong"; exit 1; }

# Unmanaged USB and PCI outputs delegate.
set_sink 'alsa_output.usb-Focusrite_Scarlett_2i2_USB-00.analog-stereo'
[[ $(run output lower) == "output lower" ]] || { echo "unmanaged USB output did not delegate"; exit 1; }
set_sink 'alsa_output.pci-0000.00.0.analog-stereo'
[[ $(run output lower) == "output lower" ]] || { echo "unmanaged PCI output did not delegate"; exit 1; }

# Managed output, opt-in: delegated.
set_sink 'alsa_output.usb-Audient_EVO8-00.pro-output-0'
echo '{"allow_native_volume": true}' >"$tmp/config/mosquitomixbay/ui.json"
[[ $(run output raise) == "output raise" ]] || { echo "opt-in did not delegate"; exit 1; }
rm -f "$tmp/config/mosquitomixbay/ui.json"

# Managed input, no opt-in: ignored with the mic icon; then opt-in delegates.
set_source 'alsa_input.usb-Audient_EVO8-00.pro-input-0'
[[ -z $(run input) ]] || { echo "managed input was not blocked"; exit 1; }
blocked_osd microphone || { echo "blocked input OSD is wrong"; exit 1; }

set_source 'alsa_input.usb-ESI_Audiotechnik_UGM192_1234-00.analog-stereo'
[[ -z $(run input) ]] || { echo "ESI input was not blocked"; exit 1; }
blocked_osd microphone || { echo "ESI input OSD is wrong"; exit 1; }

set_source 'alsa_input.usb-Focusrite_Scarlett_2i2_USB-00.analog-stereo'
[[ $(run input) == "input mute" ]] || { echo "unmanaged input did not delegate"; exit 1; }

set_source 'alsa_input.usb-Audient_EVO8-00.pro-input-0'
echo '{"allow_native_volume": true}' >"$tmp/config/mosquitomixbay/ui.json"
[[ $(run input) == "input mute" ]] || { echo "input opt-in did not delegate"; exit 1; }

echo ok
