package main

import (
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

// TestPreinstallsBackPops: Enter on Back leaves the preinstalls screen even
// when every row is disabled (fresh machine: nothing installed, nothing to
// tick). The screen must never trap.
func TestPreinstallsBackPops(t *testing.T) {
	m := initialModel()
	m.nav = []screen{scrMain, scrPreinstalls}
	m.w, m.h = 100, 34
	m.preinstalls = []PreinstallRec{
		{Name: "aether", Label: "Aether (web browser)", Installed: false},
	}
	m.preinstallChecked = map[string]bool{}
	m.preinstallPicker = m.rebuildPreinstallPicker()
	m.preinstallPicker = m.preinstallPicker.SelectValue("back")
	var cmd tea.Cmd
	m.preinstallPicker, cmd = m.preinstallPicker.Update(tea.KeyMsg{Type: tea.KeyEnter})
	if cmd == nil {
		t.Fatalf("Enter on Back produced no message")
	}
	m, _ = m.update(cmd())
	if m.top() != scrMain {
		t.Fatalf("Enter on Back left top=%v, want scrMain", m.top())
	}
}
