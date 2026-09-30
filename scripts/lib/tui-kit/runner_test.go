package tuikit

import (
	"strings"
	"testing"
)

// TestRunnerShortcutsHint pins the runner hint contract: a running runner
// only advertises cancel, and a finished runner advertises enter/esc to
// leave the log.
func TestRunnerShortcutsHint(t *testing.T) {
	if got := NewRunner().ShortcutsHint(); !strings.Contains(got, "esc cancel") {
		t.Fatalf("running hint = %q, want esc cancel", got)
	}
	if got := NewRunner().ShortcutsHint(); strings.Contains(got, "enter next step") {
		t.Fatalf("running hint = %q, must not advertise enter", got)
	}

	done := NewRunner()
	done.done = true
	if got := done.ShortcutsHint(); !strings.Contains(got, "enter/esc continue") {
		t.Fatalf("done hint = %q, want enter/esc continue", got)
	}
}
