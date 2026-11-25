package main

import (
	"strings"
	"testing"
)

// An install confirmation must survive leaving the install screen. pop()
// clears non-critical toasts, so setting the OK toast BEFORE the pop swallowed
// every "plugin installed" message — the user saw no confirmation at all.
func TestActionOKToastSurvivesPop(t *testing.T) {
	m := initialModel()
	m.w, m.h = 120, 40
	m.push(scrInstallPrefixChoice)

	next, _ := m.Update(actionOKMsg{what: "plugin installed: Aeons Light EQ.clap"})
	got := next.(model)
	if got.top() != scrMain {
		t.Fatalf("install screen was not popped: %v", got.top())
	}
	if !strings.Contains(got.toast.View(), "plugin installed: Aeons Light EQ.clap") {
		t.Fatalf("confirmation toast was cleared: %q", got.toast.View())
	}
}
