package main

import (
	"testing"

	tuikit "mosquitomarchy.local/tui-kit"
)

// TestRunLogAlwaysQuits: the "See log" flow from a bare main menu (the
// first-run shortcut prompt does exactly this) must unwind to the main menu
// on Esc, Esc — never strand on the runner screen or an orphan info screen.
// Regression test: startWorking REPLACED scrMain, so the stack dead-ended at
// [scrWorking] (log shown again with no frame) and pop()'s single-element
// guard made Esc a no-op there.
func TestRunLogAlwaysQuits(t *testing.T) {
	m := initialModel()
	m.nav = []screen{scrMain}
	m.w, m.h = 100, 34
	// A finished run launched straight from the main menu.
	m, _ = m.startWorking("Adding the shortcut", "__no_such_action__")
	if len(m.nav) != 2 || m.top() != scrWorking {
		t.Fatalf("working screen should sit over main, nav=%v", m.nav)
	}
	// Dismiss an info screen stranded alone: rewinds to main, never traps.
	m.nav = []screen{scrInfo}
	m, _ = m.update(tuikit.InfoDismissedMsg{})
	if m.top() != scrMain {
		t.Fatalf("orphan info did not rewind, top=%v", m.top())
	}
}
