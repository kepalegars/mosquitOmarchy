package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"golang.org/x/sys/unix"
)

// Discretion mode is the manager's hidden, daemon-ish end state: once the
// whole Bitwig sequence is complete the window is already off-screen (a
// silent special workspace), the TUI stops rendering and stops every periodic
// tick, and all it does is wait for the watched Bitwig instance to exit — then
// it quits and cleans up after itself. It runs no external tool: the wait is a
// pidfd poll (or a /proc existence poll on kernels without pidfd), so a hidden
// manager costs no measurable CPU.
//
// A per-instance state marker is what keeps the single-instance gate honest:
// the dispatcher reads every marker and treats any instance whose mode is
// "discretion" (hidden final watchdog) OR "busy" (visible, already in the
// Bitwig handoff / final step) as non-conflicting, so a new manager starts
// normally next to it instead of offering to close it.

// bitwigClosedMsg is delivered by the watchdog when the watched Bitwig PID is
// no longer alive (or the wait failed); the model then quits.
type bitwigClosedMsg struct{ err error }

// managerInstanceBase is the per-user root that holds instance markers and
// the dispatcher PID file. It is deliberately derived from $HOME (the other
// side, the mosquito-move-manager dispatcher, uses the same
// "${HOME:-/tmp}/.local/state" rule) and NOT from an override env var such as
// MOSQUITO_MOVE_MANAGER_STATE_DIR: a TUI launched by a different route (foot
// from the Omarchy menu, uwsm app, a desktop file, or directly) could
// otherwise resolve a different directory than the dispatcher that later
// reads it, and a genuinely busy instance was then seen as an idle one — the
// "replace it?" prompt over a conversion already in flight.
func managerInstanceBase() string {
	if h := os.Getenv("HOME"); h != "" {
		return h
	}
	return "/tmp"
}

// managerStateDir is the canonical, env-independent directory holding one
// marker per instance: <base>/.local/state/mosquito-move-manager/instances.
// The dispatcher computes the identical path (MGR_STATE_DIR).
func managerStateDir() string {
	return filepath.Join(managerInstanceBase(), ".local", "state", "mosquito-move-manager", "instances")
}

// managerPidFilePath is the dispatcher's PID file, under the same canonical
// root as the markers so both sides always agree.
func managerPidFilePath() string {
	return filepath.Join(managerInstanceBase(), ".local", "state", "mosquito-move-manager", "manager.pid")
}

func discretionMarkerPath(pid int) string {
	return filepath.Join(managerStateDir(), fmt.Sprintf("mosquito-move-manager-%d.state", pid))
}

// writeStateMarker records this instance's PID and mode so the dispatcher's
// single-instance detector can skip it. Best-effort: a failure only means the
// gate would warn about this instance, never a broken flow. The write is
// atomic (temp + rename) so a reader never sees a half-written marker and
// prunes a live instance by mistake.
func writeStateMarker(pid int, mode string) {
	dir := managerStateDir()
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return
	}
	path := discretionMarkerPath(pid)
	tmp := fmt.Sprintf("%s.tmp.%d", path, os.Getpid())
	if err := os.WriteFile(tmp, []byte(fmt.Sprintf("pid=%d\nmode=%s\n", pid, mode)), 0o600); err != nil {
		_ = os.Remove(tmp)
		return
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
	}
}

func writeDiscretionMarker(pid int) { writeStateMarker(pid, "discretion") }

// writeBusyMarker marks a VISIBLE instance that must not be treated as
// replaceable: any conversion, Bitwig handoff, install/uninstall, or polling
// step in flight. The model keeps this in step with its current screen on
// every Update (see model.syncWorkMarker), so the marker is set the moment a
// step starts — not merely at the old Bitwig-handoff point — and the
// dispatcher never offers to replace an instance mid-operation.
func writeBusyMarker(pid int) { writeStateMarker(pid, "busy") }

func removeDiscretionMarker(pid int) {
	_ = os.Remove(discretionMarkerPath(pid))
}

// removeManagerPidFile drops the dispatcher's PID file. In discretion the
// older shell can outlive a newer, visible instance; the dispatcher's own
// cleanup is PID-aware, and this stops the hidden instance from being
// reported as a live visible one in the meantime.
func removeManagerPidFile() {
	_ = os.Remove(managerPidFilePath())
}

// waitBitwigClosedCmd blocks (in bubbletea's command goroutine) until the
// watched Bitwig PID exits. pidfd + poll is a true event wait with zero
// polling; where pidfd is unavailable it falls back to a low-frequency /proc
// check. No external process is ever spawned.
func waitBitwigClosedCmd(pid int) tea.Cmd {
	return func() tea.Msg {
		return waitBitwigClosed(pid)
	}
}

func waitBitwigClosed(pid int) bitwigClosedMsg {
	if pid <= 0 {
		return bitwigClosedMsg{}
	}
	if fd, err := unix.PidfdOpen(pid, 0); err == nil {
		defer unix.Close(fd)
		fds := []unix.PollFd{{Fd: int32(fd), Events: unix.POLLIN}}
		for {
			_, perr := unix.Poll(fds, -1)
			if perr == nil {
				return bitwigClosedMsg{}
			}
			if errors.Is(perr, unix.EINTR) {
				continue
			}
			return bitwigClosedMsg{err: perr}
		}
	}
	// No pidfd: a process-existence check twice a minute, nothing else.
	for {
		if err := unix.Kill(pid, 0); err != nil {
			return bitwigClosedMsg{}
		}
		time.Sleep(20 * time.Second)
	}
}

// enterDiscretion switches the model into hidden watchdog mode. It writes the
// state marker, drops the PID file, and arms the Bitwig-close wait. With no
// live Bitwig PID there is nothing to watch, so it quits immediately.
func (m model) enterDiscretion(pid int) (tea.Model, tea.Cmd) {
	m.discretion = true
	writeDiscretionMarker(os.Getpid())
	removeManagerPidFile()
	if pid <= 0 {
		removeDiscretionMarker(os.Getpid())
		m.quit = true
		return m, tea.Quit
	}
	return m, waitBitwigClosedCmd(pid)
}
