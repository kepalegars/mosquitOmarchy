package main

import (
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	tuikit "mosquitomarchy.local/tui-kit"
)

// TestTreeItemsStayAlphabetical pins the display-layer guarantee: even when
// the backend appends rows after its sorted list (Backup content does this for
// modules the current tree skipped, flea included), every folder reads A→Z.
func TestTreeItemsStayAlphabetical(t *testing.T) {
	folders := []FolderRec{{Folder: "apps", Label: "Apps"}, {Folder: "plugins", Label: "Plugins"}}
	items := []SetupItemRec{
		{Folder: "apps", Key: "zen", Label: "zen"},
		{Folder: "apps", Key: "flea", Label: "flea"},
		{Folder: "apps", Key: "bitwig", Label: "Bitwig"},
		{Folder: "plugins", Key: "taskq", Label: "TaskQ"},
	}

	m := initialModel()
	m, _ = m.update(setupMsg{folders: folders, items: append([]SetupItemRec(nil), items...)})
	if got := labelsOf(m.setupItemsOf("apps")); !equalStrings(got, []string{"Bitwig", "flea", "zen"}) {
		t.Fatalf("setup apps order = %v, want alphabetical", got)
	}

	m = initialModel()
	m, _ = m.update(backupOptionsMsg{folders: folders, items: append([]SetupItemRec(nil), items...)})
	if got := labelsOf(m.backupItems); !equalStrings(got, []string{"Bitwig", "flea", "zen", "TaskQ"}) {
		t.Fatalf("backup order = %v, want folders in order, each alphabetical", got)
	}
}

func labelsOf(items []SetupItemRec) []string {
	out := make([]string, len(items))
	for i, it := range items {
		out[i] = it.Label
	}
	return out
}

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// TestCancelRunAsksFirst pins the accident guard: Esc (and Ctrl+C) during a
// run opens "Are you sure?" instead of killing it, and answering No returns to
// the running screen with the run untouched.
func TestCancelRunAsksFirst(t *testing.T) {
	for _, key := range []tea.KeyMsg{
		{Type: tea.KeyEsc},
		{Type: tea.KeyCtrlC},
	} {
		m := initialModel()
		m.nav = []screen{scrMain, scrWorking}
		m.runner = tuikit.NewRunner()

		m, _ = m.update(key)
		if m.top() != scrConfirm || !m.cancelRunAsking {
			t.Fatalf("%s during a run did not ask for confirmation (top=%v asking=%v)", key, m.top(), m.cancelRunAsking)
		}
		m, _ = m.update(tuikit.ConfirmResultMsg{Yes: false})
		if m.top() != scrWorking || m.cancelRunAsking {
			t.Fatalf("%s: answering No did not return to the running screen", key)
		}
	}
}
