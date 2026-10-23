package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	tuikit "mosquitomarchy.local/tui-kit"
)

// TestStartUninstallRoutesAbletonToItsOwnFlow: Ableton cannot go through the
// generic uninstall confirm — it opens the module's own one-edition-at-a-time
// flow before confirming. startUninstall must therefore hand the terminal to
// that flow (a non-nil command) and stash any keys batched behind Ableton so
// they resume afterwards.
func TestStartUninstallRoutesAbletonToItsOwnFlow(t *testing.T) {
	m := initialModel()

	// Ableton alone: no confirm screen, a command is returned, nothing stashed.
	m2, cmd := m.startUninstall([]string{"ableton"}, "Uninstall Ableton?")
	if cmd == nil {
		t.Fatalf("ableton uninstall produced no command (its flow never ran)")
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

// TestStartAbletonInstallHoldsRestOfPlan: Ableton's install runs in its own
// interactive terminal flow. Any other module batched with it must wait and
// be applied once it returns, instead of being handed to the non-interactive
// actions runner.
func TestStartAbletonInstallHoldsRestOfPlan(t *testing.T) {
	m := initialModel()
	m2, cmd := m.startAbletonInstall([]string{"apps\tableton\treaper", "tweaks\tfoo"})
	if cmd == nil {
		t.Fatalf("ableton install produced no command (its flow never ran)")
	}
	want := []string{"apps\treaper", "tweaks\tfoo"}
	if len(m2.abletonInstallWait) != len(want) {
		t.Fatalf("abletonInstallWait = %q, want %q", m2.abletonInstallWait, want)
	}
	for i := range want {
		if m2.abletonInstallWait[i] != want[i] {
			t.Fatalf("abletonInstallWait = %q, want %q", m2.abletonInstallWait, want)
		}
	}
	if !planHasAbleton([]string{"apps\tableton"}) {
		t.Fatal("planHasAbleton missed the ableton key")
	}
}

func TestCleanAbletonLog(t *testing.T) {
	raw := "\nScript started on x [COMMAND=\"bash setup\"]\r\n" +
		"\x1b[1;31mstep 4 failed\x1b[0m\r\n" +
		"payload: 12\r\n\r\n" +
		"Script done on x [COMMAND_EXIT_CODE=\"1\"]\r\n"
	got := cleanAbletonLog(raw)
	want := "step 4 failed\npayload: 12"
	if got != want {
		t.Fatalf("cleanAbletonLog = %q, want %q", got, want)
	}
}

// TestAbletonErrorKeepsLogFrame: a failed module run must not fall straight
// back to the menu. It asks to view the transcript, and that transcript is a
// real scrInfo (so `c` copies it).
func TestAbletonErrorKeepsLogFrame(t *testing.T) {
	m := initialModel()
	m.lastOutput = "# exit: exit status 1\nstep 4 failed"
	m.abletonInstallWait = []string{"apps\treaper"}
	m2, _ := m.askAbletonLog("ableton-install-err")
	if m2.top() != scrConfirm || m2.pendingAction != "ableton-install-err" {
		t.Fatalf("error did not land on the log prompt: top=%v action=%q", m2.top(), m2.pendingAction)
	}
	m3, _ := m2.update(tuikit.ConfirmResultMsg{Yes: true})
	if m3.top() != scrInfo || m3.abletonLogReturn != "ableton-install-err" {
		t.Fatalf("View log did not open scrInfo: top=%v ret=%q", m3.top(), m3.abletonLogReturn)
	}
	m4, _ := m3.update(tuikit.InfoDismissedMsg{})
	if m4.abletonLogReturn != "" || m4.pendingAction != "" || len(m4.abletonInstallWait) != 0 {
		t.Fatalf("log dismissal did not finish: ret=%q action=%q wait=%v", m4.abletonLogReturn, m4.pendingAction, m4.abletonInstallWait)
	}
}

func TestTakeAbletonLogIncludesNativeRunLog(t *testing.T) {
	repo := t.TempDir()
	t.Setenv("MOSQUITOMARCHY_REPO", repo)
	dir := filepath.Join(repo, "scripts", "apps", "ableton")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "ableton-linux-installer-20261021T011545-1.log")
	if err := os.WriteFile(path, []byte("\x1b[31m[ERR] failed step 4\x1b[0m\r\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	m := initialModel()
	m.abletonLogSince = time.Now().Add(-time.Minute)
	got := m.takeAbletonLog()
	if !strings.Contains(got, "failed step 4") {
		t.Fatalf("native .run log missing from transcript: %q", got)
	}
	if !strings.Contains(got, "Saved installer log") {
		t.Fatalf("native log path missing from transcript: %q", got)
	}
	if !m.abletonLogSince.IsZero() {
		t.Fatal("abletonLogSince was not reset")
	}
}
