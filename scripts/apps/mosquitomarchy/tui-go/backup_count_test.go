package main

import (
	"regexp"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	tuikit "mosquitomarchy.local/tui-kit"
)

var selectedCountRE = regexp.MustCompile(`Apps / TUIs / webapps: (\d+) selected`)

// backupCountShown reads the "N selected" figure off the Backup options screen.
// Read from the picker's own rows, not from the rendered view: Info and the
// option list render a viewport, so a short terminal would scroll the count out
// of view and the assertion would be testing the terminal size instead.
func backupCountShown(t *testing.T, m model) string {
	t.Helper()
	for _, it := range m.backupOptPicker.items {
		if mt := selectedCountRE.FindStringSubmatch(it.Display); len(mt) == 2 {
			return mt[1]
		}
	}
	t.Fatalf("no row says how many apps are selected; rows=%v", m.backupOptPicker.items)
	return ""
}

func backupCountModel() model {
	m := initialModel()
	m.nav = []screen{scrMain, scrBackup, scrBackupOptions}
	m.w, m.h = 120, 40
	m.backupOpts = BackupOpts{VST: "list", Keepass: true, HasKeep: true}
	m.backupFolders = []FolderRec{{Folder: "apps", Label: "Apps"}}
	m.backupItems = []SetupItemRec{
		{Folder: "apps", Key: "APP reaper", Label: "reaper", Checked: true},
		{Folder: "apps", Key: "APP vlc", Label: "vlc", Checked: false},
	}
	m.backupChecked = map[string]bool{setupValue("apps", "APP reaper"): true}
	m.backupOpen = map[string]bool{"apps": true}
	m.backupOptPicker = m.rebuildBackupOptions()
	m.backupAppsPicker = m.rebuildBackupApps()
	return m
}

// TestBackupCountRefreshesOnLeavingTheSubmenu pins when the "N selected" figure
// changes.
//
// It must NOT move while you are picking inside the sub-menu, and it must be
// right by the time you are back on the options screen. A figure that updates on
// every keystroke in a list you are still editing is answering a question you
// have not finished asking, and it is distracting on a list where every row is a
// toggle.
func TestBackupCountRefreshesOnLeavingTheSubmenu(t *testing.T) {
	m := backupCountModel()
	if got := backupCountShown(t, m); got != "1" {
		t.Fatalf("expected the initial figure to be 1, got %q", got)
	}

	m, _ = m.update(tuikit.PickerResultMsg{Value: "apps"})
	if m.top() != scrBackupApps {
		t.Fatalf("the sub-menu did not open, top is %v", m.top())
	}
	if got := backupCountShown(t, m); got != "1" {
		t.Fatalf("opening the sub-menu changed the figure to %q", got)
	}

	// Arrows move the cursor. They must not move the number.
	for _, k := range []tea.KeyMsg{{Type: tea.KeyDown}, {Type: tea.KeyUp}} {
		m, _ = m.update(k)
		if got := backupCountShown(t, m); got != "1" {
			t.Fatalf("a cursor key changed the figure to %q", got)
		}
	}

	// Tick one more app while still inside.
	m, _ = m.update(tuikit.PickerToggleMsg{Value: "item:apps:APP vlc"})
	if got := backupCountShown(t, m); got != "1" {
		t.Fatalf("ticking a row changed the figure to %q before leaving the sub-menu", got)
	}

	// Leaving is the moment it catches up.
	m, _ = m.update(tuikit.PickerResultMsg{Value: ""})
	if m.top() != scrBackupOptions {
		t.Fatalf("did not return to the options screen, top is %v", m.top())
	}
	if got := backupCountShown(t, m); got != "2" {
		t.Fatalf("expected 2 once back on the options screen, got %q", got)
	}
}

// TestBackupCountRefreshesOnEscape is the regression that mattered.
//
// ESC — how people actually leave a sub-screen — arrives as
// PickerResultMsg{Canceled: true}, which screenPicked answers BEFORE its switch
// on the screen. So the handler that rebuilds the Backup options picker was
// unreachable from that path and the "N selected" figure kept whatever it said
// when the screen was built. It caught up only when an unrelated key in the
// options screen happened to rebuild the picker.
//
// The first version of this test drove the exit with an empty Value instead of
// Canceled, so it exercised the working path, passed, and hid the bug for as
// long as nobody pressed escape.
func TestBackupCountRefreshesOnEscape(t *testing.T) {
	m := backupCountModel()
	m, _ = m.update(tuikit.PickerResultMsg{Value: "apps"})
	if m.top() != scrBackupApps {
		t.Fatalf("the sub-menu did not open, top is %v", m.top())
	}
	// Tick the second row, so the truth becomes 2 while the options picker still
	// says 1 from when it was built.
	//
	// Ending on a figure that HAPPENS to equal the stale one would make this
	// test pass against the broken code, which is how a regression test ends up
	// asserting nothing: the number has to differ, or it proves nothing.
	m, _ = m.update(tuikit.PickerToggleMsg{Value: "item:apps:APP vlc"})
	if got := backupCountShown(t, m); got != "1" {
		t.Fatalf("inside the sub-menu the options figure is still the stale 1, got %q", got)
	}

	// ESC, not Enter: Canceled takes the early return in screenPicked.
	m, _ = m.update(tuikit.PickerResultMsg{Canceled: true})
	if m.top() != scrBackupOptions {
		t.Fatalf("esc did not return to the options screen, top is %v", m.top())
	}
	if got := backupCountShown(t, m); got != "2" {
		t.Fatalf("after esc the figure should read 2, got %q — the picker was not rebuilt", got)
	}
}
