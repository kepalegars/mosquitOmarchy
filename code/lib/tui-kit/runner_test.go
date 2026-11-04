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

// TestRunnerProgressMarkers pins the streamed-download channel: \001progress
// lines feed Progress() and never pollute the visible log, values are capped
// at 100, and \001progress -1 clears the bar.
func TestRunnerProgressMarkers(t *testing.T) {
	r := NewRunner()
	if _, ok := r.Progress(); ok {
		t.Fatal("fresh runner must not show a progress bar")
	}

	r, _ = r.Update(RunnerLineMsg{Text: "\x01progress 42"})
	if pct, ok := r.Progress(); !ok || pct != 42 {
		t.Fatalf("Progress() = %d, %v; want 42, true", pct, ok)
	}
	if got := r.Output(); strings.Contains(got, "progress") {
		t.Fatalf("control marker leaked into the log: %q", got)
	}

	r, _ = r.Update(RunnerLineMsg{Text: "\x01progress 150"})
	if pct, ok := r.Progress(); !ok || pct != 100 {
		t.Fatalf("Progress() = %d, %v after 150; want 100, true", pct, ok)
	}

	r, _ = r.Update(RunnerLineMsg{Text: "\x01progress -1"})
	if _, ok := r.Progress(); ok {
		t.Fatal("-1 must clear the progress bar")
	}

	r, _ = r.Update(RunnerLineMsg{Text: "real log line"})
	if got := r.Output(); !strings.Contains(got, "real log line") {
		t.Fatalf("normal output was dropped: %q", got)
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
