package main

import "testing"

// TestStartUninstallRoutesAbletonToItsOwnFlow: Ableton cannot go through the
// generic uninstall confirm — it opens the module's own edition picker (Tab
// multi-select) before confirming. startUninstall must therefore hand the
// terminal to that flow (a non-nil command) and stash any keys batched behind
// Ableton so they resume afterwards.
func TestStartUninstallRoutesAbletonToItsOwnFlow(t *testing.T) {
	m := initialModel()

	// Ableton alone: no confirm screen, a command is returned, nothing stashed.
	m2, cmd := m.startUninstall([]string{"ableton"}, "Uninstall Ableton?")
	if cmd == nil {
		t.Fatalf("ableton uninstall produced no command (its picker never ran)")
	}
	if len(m2.uninstallWait) != 0 {
		t.Fatalf("ableton alone stashed %v", m2.uninstallWait)
	}
	if m2.top() == scrConfirm {
		t.Fatalf("ableton uninstall opened the generic confirm instead of its own flow")
	}

	// Ableton batched with another module: the other waits until it returns.
	m3, cmd := m.startUninstall([]string{"ableton", "reaper"}, "Uninstall 2 items?")
	if cmd == nil {
		t.Fatalf("batched ableton uninstall produced no command")
	}
	if len(m3.uninstallWait) != 1 || m3.uninstallWait[0] != "reaper" {
		t.Fatalf("batched keys not held back: %v", m3.uninstallWait)
	}
}
