// Command mosquito-mixbay-tui is the terminal interface for mosquitomixbay,
// the mosquitOmarchy USB-audio control bay (Audient EVO 8/4, SSL 12 via douze,
// RME Fireface UCX II / ESI UGM192 via ALSA, user-added beta interfaces).
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
	"path/filepath"

	tea "github.com/charmbracelet/bubbletea"
)

// tuiPidFile lets `mixbay-startup --install-card` wake the running TUI with
// SIGUSR1. The dispatcher's own pidfile points at its shell, not this process.
func tuiPidFile() string {
	dir := os.Getenv("XDG_RUNTIME_DIR")
	if dir == "" {
		dir = os.TempDir()
	}
	return filepath.Join(dir, "mosquito-mixbay-tui.pid")
}

func main() {
	if len(os.Args) == 2 && (os.Args[1] == "--version" || os.Args[1] == "-v") {
		fmt.Println(appVersion)
		return
	}
	if code := runCLI(os.Args[1:]); code >= 0 {
		os.Exit(code)
	}
	pid := tuiPidFile()
	if err := os.WriteFile(pid, []byte(fmt.Sprintf("%d\n", os.Getpid())), 0o644); err == nil {
		defer os.Remove(pid)
	}
	p := tea.NewProgram(initialModel(), tea.WithAltScreen(), tea.WithReportFocus())
	if _, err := p.Run(); err != nil {
		fmt.Fprintln(os.Stderr, "mosquito-mixbay-tui:", err)
		os.Exit(1)
	}
}
