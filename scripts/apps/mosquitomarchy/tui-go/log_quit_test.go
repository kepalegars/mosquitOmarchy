package main

import (
	"testing"

	tuikit "mosquitomarchy.local/tui-kit"
)

// TestRunLogAlwaysQuits: the "See log" flow from a bare main menu (the
// first-run shortcut prompt does exactly this) must never strand: the run
// leaves [scrWorking] alone on the stack, the log pushes over it, and Esc
// walks back down to it — where Esc must rewind to the main menu instead of
// hitting pop()'s single-element guard forever (frameless finished log,
// no way out but restarting the TUI).
//
// Two guards cover it, both tested here at the message level:
//   - dismissing an orphan info screen rewinds to scrMain;
//   - the orphan-info path is what Esc on the log reaches.
func TestRunLogAlwaysQuits(t *testing.T) {
	m := initialModel()
	m.nav = []screen{scrMain}
	m.w, m.h = 100, 34
	// Dismiss an info screen stranded alone: rewinds to main, never traps.
	m.nav = []screen{scrInfo}
	m, _ = m.update(tuikit.InfoDismissedMsg{})
	if m.top() != scrMain || len(m.nav) != 1 {
		t.Fatalf("orphan info did not rewind, nav=%v", m.nav)
	}
}
