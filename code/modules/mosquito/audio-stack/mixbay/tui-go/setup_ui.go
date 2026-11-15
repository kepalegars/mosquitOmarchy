package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"mosquitomarchy.local/mosquitomixbay-tui/profiles"
	tuikit "mosquitomarchy.local/tui-kit"
)

// setupDoneMsg ends every setup that prints a log: oscmix, douze, a
// downloaded card's own integration, a foundation apply/remove. The
// transcript path survives a failure, so the result popup always offers it.
type setupDoneMsg struct {
	what  string
	log   string
	err   error
	after tea.Cmd
}

// setupCmd runs a setup in the real terminal — sudo, pkexec and gum need a
// TTY — while `script` records everything to a file the result popup shows.
// The setup itself never decides how it is reported: success and failure both
// end on the same "See log / Close" prompt.
func setupCmd(what string, after tea.Cmd, args ...string) tea.Cmd {
	dir := filepath.Join(profiles.ConfigDir(), "logs")
	_ = os.MkdirAll(dir, 0o755)
	log := filepath.Join(dir, setupSlug(what)+"-"+time.Now().Format("20060102-150405")+".log")
	quoted := make([]string, len(args))
	for i, a := range args {
		quoted[i] = "'" + strings.ReplaceAll(a, "'", `'\''`) + "'"
	}
	c := exec.Command("script", "-qef", "-c", strings.Join(quoted, " "), log)
	return tea.ExecProcess(c, func(err error) tea.Msg {
		return setupDoneMsg{what: what, log: log, err: err, after: after}
	})
}

func setupSlug(s string) string {
	s = strings.ToLower(s)
	s = strings.Map(func(r rune) rune {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') {
			return r
		}
		return '-'
	}, s)
	return strings.Trim(s, "-")
}

// ansiSEQ matches the colour codes and CRs `script` keeps in the transcript.
var ansiSEQ = regexp.MustCompile(`\x1b\[[0-9;?]*[a-zA-Z]|\x1b\][^\x07]*\x07|\r`)

// readSetupLog returns the transcript, readable in the Info overlay.
func readSetupLog(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return "No log captured: " + err.Error()
	}
	text := strings.TrimSpace(ansiSEQ.ReplaceAllString(string(data), ""))
	if text == "" {
		return "No log captured."
	}
	return text
}

// setupResult turns a finished setup into the end-of-run prompt mosquitOmarchy
// uses for its own modules: "Success!" or "failed", plus the log on demand.
func (m model) setupResult(msg setupDoneMsg) (model, tea.Cmd) {
	status := "Success! " + msg.what + " completed without errors."
	if msg.err != nil {
		status = msg.what + " failed (" + msg.err.Error() + ")."
	}
	m.confirmLog = msg.log
	m.confirm = tuikit.NewConfirm(status+"\n\nSee the full log, or close?", "Close", "See log")
	m.push(scrConfirm)
	return m, msg.after
}
