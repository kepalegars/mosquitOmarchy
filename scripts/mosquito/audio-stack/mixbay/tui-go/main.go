// Command mosquito-mixbay-tui is the terminal interface for mosquitomixbay,
// the mosquitOmarchy USB-audio control bay (Audient EVO 8/4 today, RME
// Fireface UCX II / ESI UGM192 / PreSonus Quantum ES 4 via ALSA next).
//
// One Go binary, two faces (same architecture as the sibling manager TUIs):
//   - no arguments → the interactive Bubble Tea TUI (the ONLY interface),
//   - with arguments → the non-interactive backend (see cli.go) used by the
//     mosquito-mixbay-actions dispatcher, scripts and live-mode hooks.
//
// The dispatcher mosquito-mixbay (bash, next to this directory) owns the
// terminal handling (foot/xterm fallback) and the single-instance gate.
package main

import (
	"fmt"
	"os"

	tea "github.com/charmbracelet/bubbletea"
)

func main() {
	if code := runCLI(os.Args[1:]); code >= 0 {
		os.Exit(code)
	}
	p := tea.NewProgram(initialModel(), tea.WithAltScreen(), tea.WithReportFocus())
	if _, err := p.Run(); err != nil {
		fmt.Fprintln(os.Stderr, "mosquito-mixbay-tui:", err)
		os.Exit(1)
	}
}
