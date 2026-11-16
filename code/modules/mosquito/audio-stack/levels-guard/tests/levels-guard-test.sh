#!/usr/bin/env bash
# Self-check for levels-guard: Mixbay-managed interfaces stay free by default,
# are blocked when the user opts into hardware & UI exclusive (with a 100%
# icon/text and an empty level bar), and are locked for the whole session by a
# live-mode session that asks for it; every other default delegates to Omarchy.
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
cat >"$tmp/bin/omarchy-osd" <<'SH'
#!/bin/bash
printf 'osd %s\n' "$*" >>"$OSD_LOG"
SH
cat >"$tmp/bin/mosquito-mixbay-actions" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$ACTIONS_LOG"
case "$1" in
  status-json) cat "$STATUS_JSON" ;;
esac
SH
chmod +x "$tmp"/bin/*
export PATH="$tmp/bin:$PATH"
export XDG_CONFIG_HOME="$tmp/config"
export XDG_STATE_HOME="$tmp/state"
export LOG="$log"
export OSD_LOG="$osd_log"
export ACTIONS_LOG="$tmp/actions"
printf '{"spec":{"vol_min_db":-96,"vol_max_db":0,"num_output_pairs":2},"outputs":[{"volume_db":-20,"muted":false}]}\n' >"$tmp/status.json"
export STATUS_JSON="$tmp/status.json"
printf 'alsa_output.usb-Audient_EVO8-00.pro-output-0\n' >"$tmp/sink"
printf 'alsa_input.pci-0000.test\n' >"$tmp/source"
export SINK_NAME="$tmp/sink"
export SOURCE_NAME="$tmp/source"

run() { : >"$log"; : >"$osd_log"; : >"$tmp/actions"; "$helper" "$@" || true; cat "$log"; }
actions_log() { cat "$tmp/actions"; }
blocked_osd() {  # blocked_osd ICON : empty level bar, 100% text
  grep -qF -- "\"icon\":\"$1\"" "$osd_log" \
    && grep -qF -- '"value":0' "$osd_log" \
    && grep -qF -- '"progressText":"100%"' "$osd_log"
}
set_sink() { printf '%s\n' "$1" >"$tmp/sink"; SINK_NAME="$tmp/sink"; }
set_source() { printf '%s\n' "$1" >"$tmp/source"; SOURCE_NAME="$tmp/source"; }

# Managed output, free by default (no ui.json): the keys move the card's
# hardware volume through Mixbay.
run output raise >/dev/null
grep -qF -- 'set volume -15.0 --device evo8 --pair 0' <<<"$(actions_log)" \
  || { echo "free-by-default managed output did not reach Mixbay hardware: $(actions_log)"; exit 1; }

# Exclusive opt-in: ignored, full icon + 100% text + empty bar.
echo '{"allow_native_volume": false}' >"$tmp/config/mosquitomixbay/ui.json"
[[ -z $(run output raise) ]] || { echo "managed output was not blocked"; exit 1; }
blocked_osd volume || { echo "blocked output OSD is wrong"; exit 1; }

# Mixbay split sinks are managed too, even though they are loopbacks.
set_sink 'evo8_main_output'
[[ -z $(run output raise) ]] || { echo "split output was not blocked"; exit 1; }
blocked_osd volume || { echo "split output OSD is wrong"; exit 1; }

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

# Managed output, opt-in: the keys drive the card's hardware volume through
# Mixbay instead of the PipeWire level, and the OSD shows the result.
set_sink 'evo8_main_output'
echo '{"allow_native_volume": true}' >"$tmp/config/mosquitomixbay/ui.json"
run output raise >/dev/null
grep -qF -- 'set volume -15.0 --device evo8 --pair 0' <<<"$(actions_log)" \
  || { echo "managed output raise did not reach Mixbay hardware: $(actions_log)"; exit 1; }
grep -qF -- 'osd -i volume-high -p 84' "$osd_log" \
  || { echo "managed output OSD is wrong: $(cat "$osd_log")"; exit 1; }

# ALT+arrows are the precise ±1 dB step.
run output +1 >/dev/null
grep -qF -- 'set volume -19.0 --device evo8 --pair 0' <<<"$(actions_log)" \
  || { echo "precise step did not reach Mixbay hardware: $(actions_log)"; exit 1; }

# Mute toggles the right output pair and reports a muted OSD.
run output mute-toggle >/dev/null
grep -qF -- 'set mute 1 -t output1 --device evo8' <<<"$(actions_log)" \
  || { echo "mute did not reach Mixbay hardware: $(actions_log)"; exit 1; }
grep -qF -- 'osd -i volume-muted -p 0' "$osd_log" \
  || { echo "muted output OSD is wrong: $(cat "$osd_log")"; exit 1; }
rm -f "$tmp/config/mosquitomixbay/ui.json"

# The EVO 8 secondary split node maps to output pair 2, not the main out.
echo '{"allow_native_volume": true}' >"$tmp/config/mosquitomixbay/ui.json"
set_sink 'evo8_output_3_4'
run output lower >/dev/null
grep -qF -- 'set volume -25.0 --device evo8 --pair 1' <<<"$(actions_log)" \
  || { echo "secondary output did not map to pair 2: $(actions_log)"; exit 1; }

# A failed hardware read falls back to Omarchy instead of leaving keys dead.
: >"$tmp/status.json"
[[ $(run output raise) == "output raise" ]] \
  || { echo "failed hardware read did not delegate"; exit 1; }
printf '{"spec":{"vol_min_db":-96,"vol_max_db":0,"num_output_pairs":2},"outputs":[{"volume_db":-20,"muted":false}]}\n' >"$tmp/status.json"
echo '{"allow_native_volume": false}' >"$tmp/config/mosquitomixbay/ui.json"

# Managed input, exclusive opt-in: ignored with the mic icon; then free delegates.
set_source 'alsa_input.usb-Audient_EVO8-00.pro-input-0'
[[ -z $(run input) ]] || { echo "managed input was not blocked"; exit 1; }
blocked_osd microphone || { echo "blocked input OSD is wrong"; exit 1; }

set_source 'evo8_mic_1_2'
[[ -z $(run input) ]] || { echo "split input was not blocked"; exit 1; }
blocked_osd microphone || { echo "split input OSD is wrong"; exit 1; }

set_source 'alsa_input.usb-ESI_Audiotechnik_UGM192_1234-00.analog-stereo'
[[ -z $(run input) ]] || { echo "ESI input was not blocked"; exit 1; }
blocked_osd microphone || { echo "ESI input OSD is wrong"; exit 1; }

set_source 'alsa_input.usb-Focusrite_Scarlett_2i2_USB-00.analog-stereo'
[[ $(run input) == "input mute" ]] || { echo "unmanaged input did not delegate"; exit 1; }

set_source 'alsa_input.usb-Audient_EVO8-00.pro-input-0'
echo '{"allow_native_volume": true}' >"$tmp/config/mosquitomixbay/ui.json"
[[ $(run input) == "input mute" ]] || { echo "input opt-in did not delegate"; exit 1; }

# A live session with LOCK_OUTPUT_VOLUME reserves the volume for hardware & UI,
# overriding Mixbay's free choice; "no" and an inactive session leave it free.
set_sink 'evo8_main_output'
mkdir -p "$tmp/state/live-mode" "$tmp/config/live-mode"
printf 'on\n' >"$tmp/state/live-mode/active"
printf 'LOCK_OUTPUT_VOLUME="yes"\n' >"$tmp/config/live-mode/settings"
[[ -z $(run output raise) ]] || { echo "live output lock was ignored"; exit 1; }
blocked_osd volume || { echo "live locked OSD is wrong"; exit 1; }
printf 'LOCK_OUTPUT_VOLUME="no"\n' >"$tmp/config/live-mode/settings"
run output raise >/dev/null
grep -qF -- 'set volume' <<<"$(actions_log)" \
  || { echo "LOCK_OUTPUT_VOLUME=no still locked: $(actions_log)"; exit 1; }
printf 'LOCK_OUTPUT_VOLUME="yes"\n' >"$tmp/config/live-mode/settings"
rm -f "$tmp/state/live-mode/active"
run output raise >/dev/null
grep -qF -- 'set volume' <<<"$(actions_log)" \
  || { echo "inactive session still locked: $(actions_log)"; exit 1; }

echo ok
