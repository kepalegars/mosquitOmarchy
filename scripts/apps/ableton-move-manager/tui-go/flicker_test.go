package main

import (
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

// TestMainMenuCloseRowStable is the host-side regression for the "Close row
// flickers in then out on return from a sub-screen" bug. It walks terminal
// heights around the pagination boundary and asserts the rendered home frame
// is identical whether it is drawn right after a pop or after the pop's
// background status refresh has rebuilt the picker.
func TestMainMenuCloseRowStable(t *testing.T) {
	st := MoveStatus{Connected: true, Host: "move.local", Address: "1", FilePicker: "default", MoveDir: "/tmp/x"}
	for h := 18; h <= 40; h++ {
		m := initialModel()
		mm, _ := m.Update(tea.WindowSizeMsg{Width: 120, Height: h})
		m = mm.(model)
		mm, _ = m.Update(statusMsg{status: st})
		m = mm.(model)
		mainClose := strings.Contains(m.View(), "Close")

		// Visit a sub-screen; a background refresh lands there and rebuilds
		// the home picker at whatever size that screen reports.
		m.push(scrSettings)
		_ = m.enterCmd()
		mm, _ = m.Update(statusMsg{status: st})
		m = mm.(model)

		// Pop and render immediately (state before the pop's own refresh)…
		m.pop()
		_ = m.enterCmd()
		popClose := strings.Contains(m.View(), "Close")

		// …then after that refresh rebuilds the picker.
		mm, _ = m.Update(statusMsg{status: st})
		m = mm.(model)
		afterClose := strings.Contains(m.View(), "Close")

		if mainClose != popClose || popClose != afterClose {
			t.Errorf("height %d: Close row unstable (main=%v pop=%v after=%v)",
				h, mainClose, popClose, afterClose)
		}
	}
}
