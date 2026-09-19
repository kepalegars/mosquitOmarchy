package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	tuikit "mosquitomarchy.local/tui-kit"
)

// setUpBackend exposes the real mosquitomarchy-actions backend on PATH and
// points HOME (and the LIB_ONLY/GUI_RUN_EXEC env the backend needs) at an
// isolated temp dir, so the live system is never mutated: status only reads
// state and inspects installed binaries.
func setUpBackend(t *testing.T) {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	t.Setenv("GUI_RUN_EXEC", "1")
	t.Setenv("MOSQUITOMARCHY_LIB_ONLY", "1")
	binDir := t.TempDir()
	backend, err := filepath.Abs(filepath.Join("..", "mosquitomarchy-actions"))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(backend, filepath.Join(binDir, "mosquitomarchy-actions")); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", binDir+":"+os.Getenv("PATH"))
}

// feedStreamedRun feeds a model the complete message sequence of a streamed
// action: one RunnerLineMsg per captured output line, then a terminal
// RunnerDoneMsg. After the done message the runner screen must have popped
// back to the main menu. Retains the model for further assertions.
func feedStreamedRun(t *testing.T, m model, out []byte, runErr error) model {
	t.Helper()
	for _, ln := range strings.Split(strings.TrimRight(string(out), "\n"), "\n") {
		if ln == "" {
			continue
		}
		var next tea.Cmd
		m, next = m.update(tuikit.RunnerLineMsg{Text: ln})
		if next == nil {
			t.Fatalf("RunnerLineMsg did not re-arm the wait cmd")
		}
	}
	m, _ = m.update(tuikit.RunnerDoneMsg{Err: runErr})
	if m.top() != scrMain {
		t.Fatalf("after done, top = %d, want %d", m.top(), scrMain)
	}
	return m
}

// TestBackendStatus runs the real backend's read-only `status` query and
// feeds the captured output through the model's Runner messaging. It must
// land back on the main menu with an OK toast.
func TestBackendStatus(t *testing.T) {
	setUpBackend(t)
	out, err := runQuick("status")
	if err != nil {
		t.Fatalf("backend status query failed: %v", err)
	}
	m := initialModel()
	m.w, m.h = 120, 40
	m.push(scrWorking)
	m.runner = tuikit.NewRunner().SetSize(m.contentSize())
	m = feedStreamedRun(t, m, out, nil)
	if v := m.toast.View(); !strings.Contains(v, "✓") {
		t.Fatalf("expected OK toast, got %q", v)
	}
}

// TestDecodeJSONLines checks the query formats the backend emits parse into
// the model's record types (fixtures mirrored from observed output).
func TestDecodeJSONLines(t *testing.T) {
	status := []byte("{\"id\":\"reaper\",\"label\":\"Reaper\",\"state\":\"ok\",\"excluded\":false}\n{\"id\":\"qmk\",\"label\":\"QMK\",\"state\":\"missing\",\"excluded\":true}\n")
	got, err := decodeJSONLines[StatusRec](status)
	if err != nil || len(got) != 2 {
		t.Fatalf("status decode: %v %d", err, len(got))
	}
	if got[1].Id != "qmk" || !got[1].Excluded {
		t.Fatalf("bad status rec: %+v", got[1])
	}

	upd := []byte("{\"repo_update\":true,\"modules\":[{\"key\":\"shell\",\"label\":\"Shell\"},{\"key\":\"reaper\",\"label\":\"Reaper\"}]}\n")
	u, err := updateCheckJSON(upd)
	if err != nil || !u.RepoUpdate || len(u.Modules) != 2 || u.Modules[1].Key != "reaper" {
		t.Fatalf("update decode: %v %+v", err, u)
	}

	back := []byte("{\"file\":\"omarchy-backup-2026.tar.gz\",\"size\":\"1.2M\",\"date\":\"2026-09-18\"}\n")
	bb, err := decodeJSONLines[BackupRec](back)
	if err != nil || len(bb) != 1 || bb[0].File == "" {
		t.Fatalf("backup decode: %v %+v", err, bb)
	}
}
