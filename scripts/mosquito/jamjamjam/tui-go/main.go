package main

import (
	"fmt"
	"os"

	tea "github.com/charmbracelet/bubbletea"
)

func main() {
	p := tea.NewProgram(initialModel(),
		tea.WithAltScreen(),
	)
	if _, err := p.Run(); err != nil {
		clearTuiPid()
		fmt.Fprintln(os.Stderr, "jamjamjam-tui:", err)
		os.Exit(1)
	}
	clearTuiPid()
}
