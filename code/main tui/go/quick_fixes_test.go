package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	tuikit "mosquitomarchy.local/tui-kit"
)

func qfSetup() model {
	m := flatSetup()
	m.setupFolders = append(m.setupFolders, FolderRec{Folder: "fixes", Label: "Fixes"})
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

// Enter on the folder must NOT open a second list.
//
// The fixes are already child rows of the folder in the same tree as every
// other category, so the folder expands in place and Enter keeps you on the
// page. It used to push scrQuickFixes, which showed the same rows again behind
// an extra keystroke — a sub-screen for a category the tree already renders.
func TestEnterOnTheFolderStaysOnTheSameScreen(t *testing.T) {
	m := qfSetup()
	m.setupPicker = m.setupPicker.KeepCursor(tuikit.TreeValue(tuikit.TreeFolderPrefix, "fixes"))
	next, _ := m.update(tuikit.PickerResultMsg{Value: m.setupPicker.SelectedValue()})
	if next.top() == scrQuickFixes {
		t.Fatalf("Enter on the folder pushed the fixes list (%d); it must stay on the tree", scrQuickFixes)
	}
	if next.top() != scrSetup {
		t.Fatalf("Enter on the folder went to screen %d, want the Setup tree (%d)", next.top(), scrSetup)
	}
}

// Ticked fix rows must not turn the fixes folder into an install plan: fixes
// have their own action and their own confirmation.
func TestFolderEnterOnTickedFixesStaysInert(t *testing.T) {
	m := qfSetup()
	m.selected[setupValue("fixes", "wine-menu")] = true
	next, _ := m.update(tuikit.PickerResultMsg{Value: folderValue("fixes")})
	if next.top() != scrSetup || next.pendingAction != "" || len(next.pendingArgs) != 0 {
		t.Fatalf("fixes folder Enter acted: top=%d action=%q args=%v", next.top(), next.pendingAction, next.pendingArgs)
	}
}

// And the fixes must actually be IN that tree, or removing the sub-screen
// would leave no way to reach them at all.
func TestTheFixesAreRowsInTheTreeNotASubScreen(t *testing.T) {
	m := qfSetup()
	// The folder ships collapsed, like every category: open it the way the
	// user does, with the arrow.
	m.folderOpen = map[string]bool{"fixes": true}
	m.setupPicker = m.rebuildSetup()
	want := tuikit.TreeValue(tuikit.TreeItemPrefix, "fixes:wine-menu")
	for _, it := range m.setupPicker.Items() {
		if it.Value == want {
			return
		}
	}
	t.Fatalf("no %q row on the Setup page: removing the sub-screen would strand the fixes", want)
}

// Enter on a fix's own row asks to run THAT fix rather than offering to
// install a module called "wine-menu" — and rather than opening the whole
// fixes screen for a single row.
func TestEnterOnAFixRowDoesNotTryToInstallAModule(t *testing.T) {
	m := qfSetup()
	next, _ := m.update(tuikit.PickerResultMsg{Value: "item:fixes:wine-menu"})
	if next.top() != scrConfirm {
		t.Fatalf("Enter on a fix row went to screen %d, want the confirmation", next.top())
	}
	if next.pendingAction == "apply" {
		t.Error("Enter on a fix queued an INSTALL")
	}
	if next.pendingAction != "quick-fixes" {
		t.Fatalf("pendingAction = %q, want quick-fixes", next.pendingAction)
	}
	if len(next.pendingFixIDs) != 1 || next.pendingFixIDs[0] != "wine-menu" {
		t.Fatalf("pendingFixIDs = %v, want [wine-menu]", next.pendingFixIDs)
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

// A tweak is a Setup row of the "tweaks" folder just like a fix is a row of
// "fixes". Enter on it must queue the TWEAKS catalog (run_tweaks), not the
// fixes one — otherwise a preference would be run through the repair path, and
// a key present in neither catalog would fall through to the module installer.
func TestEnterOnATweakRowQueuesTheTweaksCatalog(t *testing.T) {
	m := flatSetup()
	m.setupFolders = append(m.setupFolders, FolderRec{Folder: "tweaks", Label: "Tweaks"})
	m.setupItems = append(m.setupItems,
		SetupItemRec{Folder: "tweaks", Key: "wine-theme", Label: "wine-theme", Info: "dark/light"},
	)
	m.setupPicker = m.rebuildSetup()

	next, _ := m.update(tuikit.PickerResultMsg{Value: "item:tweaks:wine-theme"})
	if next.top() != scrConfirm {
		t.Fatalf("Enter on a tweak row went to screen %d, want the confirmation", next.top())
	}
	if next.pendingAction != "quick-tweaks" {
		t.Fatalf("pendingAction = %q, want quick-tweaks", next.pendingAction)
	}
	if len(next.pendingFixIDs) != 1 || next.pendingFixIDs[0] != "wine-theme" {
		t.Fatalf("pendingFixIDs = %v, want [wine-theme]", next.pendingFixIDs)
	}
}

// Quick fixes and tweaks run in the streamed Runner, exactly like a module:
// the old silent path buffered the whole run until the end, showed one toast
// and wrote no log. The runner shows the output live, writes a dated log and
// ends on the "view the full log?" confirmation.
func TestConfirmingAFixStartsTheStreamedRunner(t *testing.T) {
	m := qfSetup()
	m.w, m.h = 120, 40
	m.nav = []screen{scrMain, scrSetup, scrQuickFixes, scrConfirm}
	m.pendingAction = "quick-fixes"
	m.pendingFixIDs = []string{"wine-menu"}

	next, _ := m.update(tuikit.ConfirmResultMsg{Yes: true})
	defer next.runner.Cancel()
	if next.top() != scrWorking {
		t.Fatalf("the run did not reach the streamed runner: top=%d", next.top())
	}
	if next.workOp != "Quick fixes" {
		t.Fatalf("workOp = %q, want Quick fixes", next.workOp)
	}
	if len(next.pendingFixIDs) != 0 {
		t.Errorf("pendingFixIDs = %v, want them consumed", next.pendingFixIDs)
	}
}

func TestConfirmingATweakStartsTheStreamedRunner(t *testing.T) {
	m := qfSetup()
	m.w, m.h = 120, 40
	m.nav = []screen{scrMain, scrSetup, scrQuickFixes, scrConfirm}
	m.pendingAction = "quick-tweaks"
	m.pendingFixIDs = []string{"wine-theme"}

	next, _ := m.update(tuikit.ConfirmResultMsg{Yes: true})
	defer next.runner.Cancel()
	if next.top() != scrWorking {
		t.Fatalf("the tweak did not reach the streamed runner: top=%d", next.top())
	}
	if next.workOp != "Tweaks" {
		t.Fatalf("workOp = %q, want Tweaks", next.workOp)
	}
}

// A successful quick-fix run must leave a dated log on disk and end on the
// confirmation that offers to read it.
func TestASuccessfulFixRunWritesALogAndOffersIt(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("MOSQUITOMARCHY_LOG_DIR", dir)
	m := qfSetup()
	m.w, m.h = 120, 40
	m.nav = []screen{scrMain, scrSetup, scrWorking}
	m.pendingAction = "quick-fixes"
	m.workingLabel = "Applying quick fixes"
	m.workOp = "Quick fixes"
	m.workStart = time.Now()
	m.runner = tuikit.NewRunner()
	m.runner, _ = m.runner.Update(tuikit.RunnerLineMsg{Text: "✓ 1px-seam applied"})

	done, _ := m.update(tuikit.RunnerDoneMsg{})
	if done.pendingAction != "run-done-log" {
		t.Fatalf("pendingAction = %q, want run-done-log", done.pendingAction)
	}
	if done.top() != scrConfirm {
		t.Fatalf("top = %d, want the success confirmation", done.top())
	}
	if !strings.Contains(done.pendingMsg, "View the full log") {
		t.Fatalf("confirmation = %q, want it to offer the log", done.pendingMsg)
	}
	entries, err := os.ReadDir(dir)
	if err != nil || len(entries) != 1 {
		t.Fatalf("run log: %v, entries=%v", err, entries)
	}
	body, _ := os.ReadFile(filepath.Join(dir, entries[0].Name()))
	if !strings.Contains(string(body), "1px-seam applied") {
		t.Fatalf("log does not contain the run output:\n%s", body)
	}
}

// uninstallTweaksSetup is flatSetup plus a tickable tweak row, in the tree the
// Uninstall screen shows.
func uninstallTweaksSetup() model {
	m := flatSetup()
	m.treeMode = "uninstall"
	m.setupFolders = append(m.setupFolders, FolderRec{Folder: "tweaks", Label: "Tweaks"})
	// The Uninstall tree prefixes routing keys, exactly as the backend emits
	// them; a bare key would take the generic module path and hide the bug.
	it := SetupItemRec{Folder: "tweaks", Key: "tweak:wine-theme", Label: "wine-theme", Info: "dark/light"}
	m.setupItems = append(m.setupItems, it)
	m.setupByValue[setupValue("tweaks", "tweak:wine-theme")] = it
	return m
}

// In the Uninstall tree a tweak row is a REMOVAL, never "apply this tweak".
// Enter used to fall into the apply branch: with a set ticked it offered to
// apply the row under the cursor and ignored the selection.
func TestEnterOnATweakRowInUninstallModeUninstallsTheSelection(t *testing.T) {
	m := uninstallTweaksSetup()
	m.selected[setupValue("tweaks", "tweak:wine-theme")] = true
	m.selected[setupValue("apps", "reaper")] = true
	m.setupPicker = m.rebuildSetup()

	next, _ := m.update(tuikit.PickerResultMsg{Value: "item:tweaks:tweak:wine-theme"})
	if next.top() != scrConfirm {
		t.Fatalf("Enter on a tweak row went to screen %d, want the confirmation", next.top())
	}
	if next.pendingAction != "uninstall" {
		t.Fatalf("pendingAction = %q, want uninstall", next.pendingAction)
	}
	got := strings.Join(next.pendingArgs, ",")
	if !strings.Contains(got, "tweak:wine-theme") || !strings.Contains(got, "reaper") {
		t.Fatalf("pendingArgs = %v, want the whole ticked set", next.pendingArgs)
	}
}

// Enter on the tweaks FOLDER in Uninstall mode must confirm the ticked set.
// The fixes/tweaks "folder does nothing" rule used to run first, so Enter on
// the folder with items ticked did nothing at all.
func TestEnterOnTheTweaksFolderInUninstallModeUninstallsTheSelection(t *testing.T) {
	m := uninstallTweaksSetup()
	m.selected[setupValue("tweaks", "tweak:wine-theme")] = true

	next, _ := m.update(tuikit.PickerResultMsg{Value: folderValue("tweaks")})
	if next.top() != scrConfirm || next.pendingAction != "uninstall" {
		t.Fatalf("tweaks folder Enter: top=%d action=%q, want the uninstall confirmation", next.top(), next.pendingAction)
	}
	if len(next.pendingArgs) != 1 || next.pendingArgs[0] != "tweak:wine-theme" {
		t.Fatalf("pendingArgs = %v, want [tweak:wine-theme]", next.pendingArgs)
	}
}

// Enter on a fix row applies the Tab-marked set, not the row under the cursor.
// The old branch built the confirmation from the cursor alone, so ticking
// three repairs and pressing Enter on one offered to run only that one.
func TestEnterOnAFixRowAppliesTheTickedSet(t *testing.T) {
	m := qfSetup()
	m.selected[setupValue("fixes", "wine-menu")] = true
	m.selected[setupValue("fixes", "tui-theme")] = true
	next, _ := m.update(tuikit.PickerResultMsg{Value: "item:fixes:wine-menu"})
	if next.pendingAction != "quick-fixes" {
		t.Fatalf("pendingAction = %q, want quick-fixes", next.pendingAction)
	}
	if got := strings.Join(next.pendingFixIDs, ","); got != "wine-menu,tui-theme" {
		t.Fatalf("pendingFixIDs = %v, want both ticked fixes", next.pendingFixIDs)
	}
	if strings.Contains(next.pendingMsg, "Apply fix?") {
		t.Errorf("single-fix wording used for two ticked fixes: %q", next.pendingMsg)
	}
}

// A ticked fix plus a ticked tweak is one confirmation, but two backend
// subcommands: fixes run first, the tweaks are queued as the next stage.
func TestEnterOnAMixedSelectionRunsBothKinds(t *testing.T) {
	m := qfSetup()
	m.tweaks = []ItemRec{{Key: "wine-menu-tweak", Label: "Wine menu tweak"}}
	m.setupFolders = append(m.setupFolders, FolderRec{Folder: "tweaks", Label: "Tweaks"})
	m.setupItems = append(m.setupItems, SetupItemRec{Folder: "tweaks", Key: "wine-menu-tweak", Label: "Wine menu tweak"})
	m.selected[setupValue("fixes", "wine-menu")] = true
	m.selected[setupValue("tweaks", "wine-menu-tweak")] = true

	next, _ := m.update(tuikit.PickerResultMsg{Value: "item:fixes:wine-menu"})
	if next.pendingAction != "quick-repairs" {
		t.Fatalf("pendingAction = %q, want quick-repairs", next.pendingAction)
	}
	if got := strings.Join(next.pendingFixIDs, ","); got != "wine-menu" {
		t.Fatalf("pendingFixIDs = %v", next.pendingFixIDs)
	}
	if got := strings.Join(next.pendingArgs, ","); got != "wine-menu-tweak" {
		t.Fatalf("pendingArgs = %v", next.pendingArgs)
	}
	if !strings.Contains(next.pendingMsg, "fixes and tweaks") {
		t.Errorf("mixed prompt does not say what will run: %q", next.pendingMsg)
	}
}
