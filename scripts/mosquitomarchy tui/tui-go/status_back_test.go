package main

import (
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

// TestStatusBackPops: Enter on the status screen's Back row leaves the
// screen. Regression test: Back sits after the last category folder, so the
// folder logic claimed it and Enter unfolded that folder instead of leaving.
func TestStatusBackPops(t *testing.T) {
	m := initialModel()
	m.nav = []screen{scrMain, scrStatus}
	m.w, m.h = 100, 34
	m.statusRecs = []StatusRec{
		{Id: "reaper", Label: "REAPER", State: "ok", Category: "apps"},
	}
	m.statusOpen = map[string]bool{}
	m.statusPicker = m.rebuildStatus()
	m.statusPicker = m.statusPicker.SelectValue("back")
	if m.statusPicker.SelectedValue() != "back" {
		t.Fatalf("could not park the cursor on Back")
	}
	m, _ = m.update(tea.KeyMsg{Type: tea.KeyEnter})
	if m.top() != scrMain {
		t.Fatalf("Enter on Back left top=%v, want scrMain", m.top())
	}
}
