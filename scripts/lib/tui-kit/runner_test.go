package tuikit

import (
	"errors"
	"io"
	"os/exec"
	"strings"
	"testing"
	"time"
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

// TestWaitErrCleanExitWithWaitDelay pins the false-failure fix: a command that
// exits 0 while a background child keeps its stdout open makes Wait return
// exec.ErrWaitDelay, which must not be reported as a failed module.
func TestWaitErrCleanExitWithWaitDelay(t *testing.T) {
	cmd := exec.Command("sh", "-c", "sleep 1 & exit 0")
	pr, pw := io.Pipe()
	cmd.Stdout = pw
	cmd.Stderr = pw
	cmd.WaitDelay = 100 * time.Millisecond
	go io.Copy(io.Discard, pr)
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	err := cmd.Wait()
	pw.Close()
	if !errors.Is(err, exec.ErrWaitDelay) {
		t.Skipf("no WaitDelay on this platform: %v", err)
	}
	if got := waitErr(err, cmd.ProcessState); got != nil {
		t.Fatalf("waitErr(%v) = %v, want nil after a clean exit", err, got)
	}
}
