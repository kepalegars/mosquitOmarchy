package main

import (
	"testing"

	"mosquitomarchy.local/tui-kit"
)

// "See log" then Esc must reach the main menu — on EVERY path that ends on the
// success prompt.
//
// The auto-apply path rewinds to the menu and REPLACES it with the runner, so
// the stack is one deep. pop() is a no-op at depth 1, so the handler's two pops
// removed nothing, the success prompt stayed underneath, and Esc off the log
// landed back on it — a loop.
func TestSeeLogThenEscReachesTheMenu(t *testing.T) {
	// The stack shape each ending leaves behind.
	stacks := map[string][]screen{
		"plain install":      {scrMain, scrInstalling},
		"auto apply":         {scrInstalling}, // replaced onto a 1-deep stack
		"auto apply, none":   {scrInstalling},
		"manual apply, back": {scrMain, scrFixChoose},
	}

	for name, st := range stacks {
		m := initialModel()
		m.w, m.h = 120, 40
		m.nav = append([]screen{}, st...)
		m.runner = tuikit.NewRunner().SetSize(m.contentSize())
		m.installLog = "install log"
		m.replace(scrRunnerSuccessConfirm)

		out, _ := m.update(tuikit.ConfirmResultMsg{})
		got := out.(model)
		if got.top() != scrInfo {
			t.Fatalf("%s: \"See log\" landed on %d, want the log (%d)", name, got.top(), scrInfo)
		}
		out2, _ := got.update(tuikit.InfoDismissedMsg{})
		esc := out2.(model)
		if esc.top() != scrMain {
			t.Errorf("%s: Esc off the log landed on screen %d, want the main menu",
				name, esc.top())
		}
	}
}

// "Back" on the success prompt reaches the menu too, on the same shapes.
func TestSuccessBackReachesTheMenu(t *testing.T) {
	for _, st := range [][]screen{{scrMain, scrInstalling}, {scrInstalling}} {
		m := initialModel()
		m.w, m.h = 120, 40
		m.nav = append([]screen{}, st...)
		m.runner = tuikit.NewRunner().SetSize(m.contentSize())
		m.replace(scrRunnerSuccessConfirm)

		out, _ := m.update(tuikit.ConfirmResultMsg{Yes: true})
		if got := out.(model); got.top() != scrMain {
			t.Errorf("stack %v: Back landed on %d, want the main menu", st, got.top())
		}
	}
}
