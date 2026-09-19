#!/bin/bash
# Launcher for macOS VM TUI - detects available terminal

# Self-locating: works wherever the scripts are deployed (~/.local/bin or a clone).
TUI_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/macos-vm-tui.sh"
CLASS="org.omarchy.MacosVmTui"

if command -v ghostty &>/dev/null; then
    exec ghostty --class="$CLASS" -e "$TUI_SCRIPT"
elif command -v kitty &>/dev/null; then
    exec kitty --class="$CLASS" -e "$TUI_SCRIPT"
elif command -v alacritty &>/dev/null; then
    exec alacritty --class "$CLASS" -e "$TUI_SCRIPT"
else
    notify-send "macOS VM Manager" "No supported terminal found (ghostty, kitty, alacritty)"
    exit 1
fi
