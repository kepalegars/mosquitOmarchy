package main

import (
	"strings"
	"testing"

	tuikit "mosquitomarchy.local/tui-kit"
)

func qfSetup() model {
	m := flatSetup()
	m.setupFolders = append(m.setupFolders, FolderRec{Folder: "fixes", Label: "Quick fixes"})
	m.setupItems = append(m.setupItems,
		SetupItemRec{Folder: "fixes", Key: "wine-menu", Label: "wine-menu", Info: "drop the clutter"},
		SetupItemRec{Folder: "fixes", Key: "tui-theme", Label: "tui-theme", Info: "force-adapt"},
	)
	m.quickFixes = []ItemRec{
		{Key: "wine-menu", Label: "Uninstall/Manual entries cluttering", Cat: "Windows & input", Info: "drop the ones belonging to managed prefixes"},
		{Key: "tui-theme", Label: "Force-adapt the TUIs' theme", Cat: "Appearance", Info: "regenerate the palette"},
	}
	m.setupPicker = m.rebuildSetup()
	return m
}

// The Setup page dropped the quick fixes entirely, so nothing in the TUI could
// reach a single one of them. The backend emitted the `fixes` folder and its
// rows the whole time; the TUI skipped that folder in two places and nothing
// ever carried the category across from the shell launcher it replaced.
func TestTheQuickFixesFolderIsOnTheSetupPage(t *testing.T) {
	m := qfSetup()
	want := tuikit.TreeValue(tuikit.TreeFolderPrefix, "fixes")
	found := false
	for _, it := range m.setupPicker.Items() {
		if it.Value == want {
			found = true
		}
	}
	if !found {
		t.Fatal("the Quick fixes folder is not on the Setup page")
	}
}

// Enter on the folder opens the fixes list. The check has to sit BEFORE the
// generic `cat:` early-return in screenPicked: that return swallows every
// folder row, so a check placed after it can never match — which is exactly how
// Enter on Menu entries used to do nothing, and how this would have too.
func TestEnterOnTheFolderOpensTheFixesList(t *testing.T) {
	m := qfSetup()
	m.setupPicker = m.setupPicker.KeepCursor(tuikit.TreeValue(tuikit.TreeFolderPrefix, "fixes"))
	next, _ := m.update(tuikit.PickerResultMsg{Value: m.setupPicker.SelectedValue()})
	if next.top() != scrQuickFixes {
		t.Fatalf("Enter on the folder went to screen %d, want the fixes list (%d)", next.top(), scrQuickFixes)
	}
}

// Enter on a fix's own row opens the same screen rather than offering to
// install a module called "wine-menu".
func TestEnterOnAFixRowDoesNotTryToInstallAModule(t *testing.T) {
	m := qfSetup()
	next, _ := m.update(tuikit.PickerResultMsg{Value: "item:fixes:wine-menu"})
	if next.top() != scrQuickFixes {
		t.Fatalf("Enter on a fix row went to screen %d, want the fixes list", next.top())
	}
	if next.pendingAction == "apply" {
		t.Error("Enter on a fix queued an INSTALL")
	}
}

// Tab marks, Enter applies the marked set through a confirmation. Nothing runs
// before the answer.
func TestFixesAreAppliedOnlyAfterConfirmation(t *testing.T) {
	m := qfSetup()
	m.nav = []screen{scrQuickFixes}
	m.quickFixChecked = map[string]bool{"tui-theme": true}
	m.quickFixPicker = m.rebuildQuickFixes()

	m2, _ := m.update(tuikit.PickerResultMsg{Value: "item:wine-menu"})
	got := m2
	if got.top() != scrConfirm {
		t.Fatalf("Enter did not ask: screen %d", got.top())
	}
	if got.pendingAction != "quick-fixes" {
		t.Fatalf("pendingAction = %q", got.pendingAction)
	}
	// The MARKED fix is the one that goes, not the one under the cursor.
	if len(got.pendingFixIDs) != 1 || got.pendingFixIDs[0] != "tui-theme" {
		t.Errorf("pendingFixIDs = %v, want [tui-theme]", got.pendingFixIDs)
	}

	// Declining runs nothing.
	m3, cmd := got.update(tuikit.ConfirmResultMsg{Yes: false})
	if cmd != nil {
		t.Error("declining the confirmation started a command")
	}
	_ = m3
}

// With nothing marked, Enter is never a dead key: it asks about the row under
// the cursor.
func TestEnterWithNothingMarkedAsksAboutTheFocusedFix(t *testing.T) {
	m := qfSetup()
	m.nav = []screen{scrQuickFixes}
	m.quickFixChecked = map[string]bool{}
	m.quickFixPicker = m.rebuildQuickFixes()
	m2, _ := m.update(tuikit.PickerResultMsg{Value: "item:wine-menu"})
	got := m2
	if got.top() != scrConfirm {
		t.Fatalf("Enter with nothing marked did not ask: screen %d", got.top())
	}
	if len(got.pendingFixIDs) != 1 || got.pendingFixIDs[0] != "wine-menu" {
		t.Errorf("pendingFixIDs = %v, want [wine-menu]", got.pendingFixIDs)
	}
}

// Tab must flip the tick. The global toggle switch runs first and returns
// unconditionally, so a Tab branch inside the screen's own case would be dead
// code — the same trap the menu entries screen fell into.
func TestTabTicksAFix(t *testing.T) {
	m := qfSetup()
	m.nav = []screen{scrQuickFixes}
	m.quickFixChecked = map[string]bool{}
	m.quickFixPicker = m.rebuildQuickFixes()
	m2, _ := m.update(tuikit.PickerToggleMsg{Value: "item:tui-theme"})
	if !m2.quickFixChecked["tui-theme"] {
		t.Error("tab did not tick the fix")
	}
	m3, _ := m2.update(tuikit.PickerToggleMsg{Value: "item:tui-theme"})
	if m3.quickFixChecked["tui-theme"] {
		t.Error("tab did not untick the fix")
	}
}

// The list is grouped by category, the way the shell picker groups it.
func TestTheFixesListIsGroupedByCategory(t *testing.T) {
	m := qfSetup()
	rows := m.quickFixesList()
	var cats []string
	for _, r := range rows {
		if r.Folder {
			cats = append(cats, r.Display)
		}
	}
	joined := strings.Join(cats, ",")
	if !strings.Contains(joined, "Appearance") || !strings.Contains(joined, "Windows & input") {
		t.Errorf("categories = %v, want both of the fix's own categories", cats)
	}
}
