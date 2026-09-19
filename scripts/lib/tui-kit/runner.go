package tuikit

import (
	"bufio"
	"context"
	"io"
	"os/exec"
	"strings"
	"syscall"
	"time"

	"github.com/charmbracelet/bubbles/spinner"
	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
)

// Runner streams a long external command (a wine installer, waiting on
// Ableton/Bitwig, the Move Manager webapp download wait, …) live into a
// scrolling viewport instead of freezing the screen while bash polls in a
// loop. This is the direct replacement for that class of wait: the host
// model stays fully responsive (including Ctrl+C, which Cancel() turns
// into a real kill of the running process, not just an unresponsive UI)
// for as long as the action runs.
type Runner struct {
	Label    string
	spinner  spinner.Model
	viewport viewport.Model
	lines    chan string
	result   chan error
	output   []string
	done     bool
	err      error
	cancel   context.CancelFunc
}

type RunnerLineMsg struct{ Text string }
type RunnerDoneMsg struct{ Err error }

func NewRunner() Runner {
	sp := spinner.New()
	sp.Spinner = spinner.Dot
	sp.Style = StyleAccent
	return Runner{spinner: sp, viewport: viewport.New(0, 0)}
}

func (r Runner) SetSize(w, h int) Runner {
	r.viewport.Width = w
	r.viewport.Height = h
	return r
}

// Start launches name(args...), streaming combined stdout+stderr line by
// line, with stdin left at its default (/dev/null for a nil Cmd.Stdin) —
// right for the many installers that only ever see EOF. Call once per
// action; a fresh Start resets prior output.
func (r Runner) Start(label, name string, args ...string) (Runner, tea.Cmd) {
	return r.start(label, name, args...)
}

func (r Runner) start(label, name string, args ...string) (Runner, tea.Cmd) {
	ctx, cancel := context.WithCancel(context.Background())
	r.Label = label
	r.cancel = cancel
	r.lines = make(chan string, 256)
	r.result = make(chan error, 1)
	r.output = nil
	r.done = false
	r.err = nil
	cmd := exec.CommandContext(ctx, name, args...)
	// Run the action in its own process group and cancel the WHOLE group: a
	// module's own signal traps (e.g. Davinci's ~25 GB temp-dir cleanup) only
	// run if the shell receives the signal, not just the Go parent. Without
	// this, cancelling an extraction can leave tens of GB behind.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error {
		if cmd.Process == nil {
			return nil
		}
		return syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
	}
	// Give the traps a moment to clean up; force-kill the group after that.
	cmd.WaitDelay = 5 * time.Second
	go runExternal(cmd, r.lines, r.result)
	return r, tea.Batch(r.spinner.Tick, waitForRunnerActivity(r.lines, r.result))
}

// Cancel kills the running process, if any. Safe to call when idle.
func (r Runner) Cancel() {
	if r.cancel != nil {
		r.cancel()
	}
}

func (r Runner) Done() bool     { return r.done }
func (r Runner) Err() error     { return r.err }
func (r Runner) Output() string { return strings.Join(r.output, "\n") }

func waitForRunnerActivity(lines <-chan string, result <-chan error) tea.Cmd {
	return func() tea.Msg {
		line, ok := <-lines
		if ok {
			return RunnerLineMsg{Text: line}
		}
		return RunnerDoneMsg{Err: <-result}
	}
}

func runExternal(cmd *exec.Cmd, lines chan<- string, result chan<- error) {
	defer close(lines)
	pr, pw := io.Pipe()
	cmd.Stdout = pw
	cmd.Stderr = pw
	scanDone := make(chan struct{})
	go func() {
		defer close(scanDone)
		scanner := bufio.NewScanner(pr)
		scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
		for scanner.Scan() {
			lines <- scanner.Text()
		}
	}()
	if err := cmd.Start(); err != nil {
		pw.Close()
		<-scanDone
		result <- err
		return
	}
	err := cmd.Wait()
	pw.Close()
	<-scanDone
	result <- err
}

// Update must be fed every Msg the host receives while a Runner is active.
func (r Runner) Update(msg tea.Msg) (Runner, tea.Cmd) {
	switch m := msg.(type) {
	case RunnerLineMsg:
		r.output = append(r.output, m.Text)
		r.viewport.SetContent(strings.Join(r.output, "\n"))
		r.viewport.GotoBottom()
		return r, waitForRunnerActivity(r.lines, r.result)
	case RunnerDoneMsg:
		r.done = true
		r.err = m.Err
		return r, nil
	case spinner.TickMsg:
		if r.done {
			return r, nil
		}
		var cmd tea.Cmd
		r.spinner, cmd = r.spinner.Update(m)
		return r, cmd
	}
	var cmd tea.Cmd
	r.viewport, cmd = r.viewport.Update(msg)
	return r, cmd
}

func (r Runner) View() string {
	// Re-stamp the spinner style from the live theme var on every render
	// (live theme following — a theme switch mid-run recolors the spinner
	// on the next frame).
	r.spinner.Style = StyleAccent
	status := r.spinner.View() + " " + r.Label + "…"
	if r.done {
		if r.err != nil {
			status = StyleErr.Render("✗ "+r.Label+" failed: ") + r.err.Error()
		} else {
			status = StyleOK.Render("✓ " + r.Label + " done")
		}
	}
	// The runner body intentionally omits the help/shortcut bar — hosts
	// pass that as a separate parameter to FrameScreen (the universal
	// layout pins it to the very last row of the screen, not in the
	// centred body). The runner is otherwise framed with the same
	// StyleFrame every other component uses.
	body := status + "\n\n" + r.viewport.View()
	return StyleFrame.Render(body)
}

// ShortcutsHint returns the bottom-row shortcut hint for this Runner: Esc
// cancels the run, and a finished run still advertises enter/esc to leave
// the log.
func (r Runner) ShortcutsHint() string {
	if r.done {
		return StyleHelp.Render("enter/esc continue")
	}
	return StyleHelp.Render("esc cancel")
}
