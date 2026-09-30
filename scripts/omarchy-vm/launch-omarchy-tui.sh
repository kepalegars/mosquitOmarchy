#!/bin/bash
# Launcher for the Omarchy VM Manager TUI - detects an available terminal.

# Self-locating: works wherever the scripts are deployed (~/.local/bin or a clone).
TUI_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/omarchy-vm-tui.sh"
CLASS="org.omarchy.omarchy-vm-tui"

# Crash reporting: a failed launch stores a dated log and offers the clickable
# AI diagnosis.
_mq_crash_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/crash.bash"
[[ -f $_mq_crash_lib ]] && { source "$_mq_crash_lib"; mq_crash_guard "launch-omarchy-tui"; }

if command -v ghostty &>/dev/null; then
    exec ghostty --class="$CLASS" -e "$TUI_SCRIPT"
elif command -v kitty &>/dev/null; then
    exec kitty --class="$CLASS" -e "$TUI_SCRIPT"
elif command -v alacritty &>/dev/null; then
    exec alacritty --class "$CLASS" -e "$TUI_SCRIPT"
else
    notify-send "Omarchy VM Manager" "No supported terminal found (ghostty, kitty, alacritty)"
    exit 1
fi
