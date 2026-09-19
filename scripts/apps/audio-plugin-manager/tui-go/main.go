// Command mosquito-audio-plugin-manager-tui is the terminal interface for the
// mosquito Audio Plugin Manager (see ../lib-audio-plugin-manager-core.sh for what this does)
// — a real Bubble Tea program (Go, charmbracelet/bubbletea + bubbles +
// lipgloss), replacing the previous bash+gum implementation. The TUI is
// the ONLY interface. Same architecture as the sibling
// mosquito-move-manager-tui: one persistent tea.Program owns every screen
// and every decision; mosquito-audio-plugin-manager-actions (a thin,
// non-interactive backend sourcing the exact same lib-audio-plugin-manager-core.sh
// this program's own backend uses) performs the mechanical action once a
// decision is made here.
//
// Not meant to be launched directly under normal use — the stable
// mosquito-audio-plugin-manager dispatcher routes every no-argument launch straight
// here. Runs standalone fine too (no-args via the dispatcher and a plain
// run are equivalent).
package main

import (
	"fmt"
	"os"

	tea "github.com/charmbracelet/bubbletea"
)

func main() {
	p := tea.NewProgram(initialModel(), tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		fmt.Fprintln(os.Stderr, "mosquito-audio-plugin-manager-tui:", err)
		os.Exit(1)
	}
}
