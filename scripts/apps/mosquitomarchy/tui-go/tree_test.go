package main

import (
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"

	tuikit "mosquitomarchy.local/tui-kit"
)

// flatSetup builds the smallest Setup state that exercises the one-page tree:
// two categories, one collapsed, so the tests can assert both the flat
// listing and the fold.
func flatSetup() model {
	m := initialModel()
	m.nav = []screen{scrMain, scrSetup}
	m.w, m.h = 100, 34
	m.setupFolders = []FolderRec{
		{Folder: "apps", Label: "Apps"},
		{Folder: "mosquito", Label: "mosquito"},
	}
	m.setupItems = []SetupItemRec{
		{Folder: "apps", Key: "reaper", Label: "reaper"},
		{Folder: "apps", Key: "extracto", Label: "extracto"},
		{Folder: "mosquito", Key: "live-mode", Label: "Live Mode Manager"},
	}
	for _, it := range m.setupItems {
		m.setupByValue[setupValue(it.Folder, it.Key)] = it
	}
	m.folderOpen["apps"] = true
	m.folderOpen["mosquito"] = true
	m.setupPicker = m.rebuildSetup()
	return m
}

// pressKey feeds a key to the picker and resolves the ONE command it returns,
// so tests exercise the same Enter → PickerResultMsg path the terminal does.
// A single resolution matters: looping would let the post-push confirm/blink
// messages overwrite the very fields under test.
func pressKey(m model, k tea.KeyMsg) model {
	var cmd tea.Cmd
	m.setupPicker, cmd = m.setupPicker.Update(k)
	if cmd == nil {
		return m
	}
	m, _ = m.update(cmd())
	return m
}

// TestSetupIsOnePage checks the shape of the reworked Setup: every category
// AND its modules live in the same list, children are indented under their
// parent, and the old "Install selection" row is gone for good.
func TestSetupIsOnePage(t *testing.T) {
	m := flatSetup()
	view := m.setupPicker.View()

	for _, want := range []string{"Apps", "reaper", "extracto", "mosquito", "Live Mode Manager"} {
		if !strings.Contains(view, want) {
			t.Fatalf("flat Setup is missing %q:\n%s", want, view)
		}
	}
	// Children are drawn under their category with the tree connectors, not
	// as a second level reachable by Enter.
	if !strings.Contains(view, "├─") || !strings.Contains(view, "└─") {
		t.Fatalf("expected tree connectors on the flat page:\n%s", view)
	}
	// No second-level entry point left.
	for _, it := range m.setupPicker.items {
		if it.Value == "install-selection" || it.Value == "uninstall-selection" {
			t.Fatalf("obsolete selection row %q is back", it.Value)
		}
	}
}

// TestSetupLeafValueRoundTrip guards the value format the whole tree depends on:
// a leaf row must carry "item:<folder>:<key>" so the host can look the module
// up in setupByValue and split it back. It regressed once already when the
// host pre-prefixed the id that BuildFolderTree prefixes itself, producing
// "item:item:apps:reaper" that matched nothing.
func TestSetupLeafValueRoundTrip(t *testing.T) {
	m := flatSetup()
	var leaf string
	for _, it := range m.setupPicker.items {
		if strings.HasPrefix(it.Value, "item:") {
			leaf = it.Value
		}
	}
	if leaf == "" {
		t.Fatal("no leaf row found on the flat Setup page")
	}
	if strings.HasPrefix(leaf, "item:item:") {
		t.Fatalf("leaf value double-prefixed: %q", leaf)
	}
	if _, ok := m.setupByValue[leaf]; !ok {
		t.Fatalf("leaf %q is not in setupByValue, Enter cannot route it", leaf)
	}
	folder, key := splitSetupValue(leaf)
	if folder != "mosquito" || key != "live-mode" {
		t.Fatalf("splitSetupValue(%q) = %q,%q want mosquito,live-mode", leaf, folder, key)
	}
}

// TestSetupEnterOnCategoryDoesNothing pins the rule that Enter only ever
// installs. Folding belongs to the arrows alone; letting Enter fold as well
// meant the same key meant "toggle" or "install" depending on the row.
func TestSetupEnterOnCategoryDoesNothing(t *testing.T) {
	m := flatSetup()
	idx := -1
	for i, it := range m.setupPicker.items {
		if it.Value == folderValue("apps") {
			idx = i
		}
	}
	if idx < 0 {
		t.Fatal("apps category row not found")
	}
	m.setupPicker = m.setupPicker.SelectIndex(idx)
	m = pressKey(m, tea.KeyMsg{Type: tea.KeyEnter})

	if m.top() != scrSetup {
		t.Fatalf("Enter on a category must stay on the page, top=%d", m.top())
	}
	if !m.folderOpen["apps"] {
		t.Fatal("Enter must not fold: that is the arrows' job")
	}
	if m.pendingAction != "" || m.top() == scrConfirm {
		t.Fatal("Enter on a category must not start an install")
	}

	// The arrows still do it, both ways.
	mm, _ := m.update(tuikit.PickerSortMsg{Dir: -1})
	if mm.folderOpen["apps"] {
		t.Fatal("← should fold the category")
	}
	if mm.setupPicker.SelectedValue() != folderValue("apps") {
		t.Fatalf("cursor jumped on fold: %q", mm.setupPicker.SelectedValue())
	}
	// While collapsed, the children really are gone from the list.
	for _, it := range mm.setupPicker.items {
		if it.Value == setupValue("apps", "reaper") {
			t.Fatal("← left the children listed under a collapsed category")
		}
	}
	mm, _ = mm.update(tuikit.PickerSortMsg{Dir: 1})
	if !mm.folderOpen["apps"] {
		t.Fatal("→ should re-open the category")
	}
	found := false
	for _, it := range mm.setupPicker.items {
		if it.Value == setupValue("apps", "reaper") {
			found = true
		}
	}
	if !found {
		t.Fatal("→ did not bring the children back")
	}
}

// TestSetupEnterOnModuleInstallsOne checks Enter on a module row applies that
// single module without the old tick-then-apply round trip.
func TestSetupEnterOnModuleInstallsOne(t *testing.T) {
	m := flatSetup()
	idx := -1
	for i, it := range m.setupPicker.items {
		if it.Value == setupValue("apps", "reaper") {
			idx = i
		}
	}
	if idx < 0 {
		t.Fatal("reaper row not found on the flat page")
	}
	m.setupPicker = m.setupPicker.SelectIndex(idx)
	m = pressKey(m, tea.KeyMsg{Type: tea.KeyEnter})

	if m.top() != scrConfirm {
		t.Fatalf("Enter on a module should ask for confirmation, top=%d", m.top())
	}
	if m.pendingAction != "apply" {
		t.Fatalf("pendingAction = %q want apply", m.pendingAction)
	}
	if len(m.pendingArgs) != 1 || !strings.Contains(m.pendingArgs[0], "reaper") {
		t.Fatalf("pendingArgs = %q, want just the reaper group", m.pendingArgs)
	}
}

// TestSetupEnterOnModuleUninstalls is the uninstall-mode mirror of the test
// above: the same one page also removes a single module.
func TestSetupEnterOnModuleUninstalls(t *testing.T) {
	m := flatSetup()
	m.treeMode = "uninstall"
	m.setupPicker = m.rebuildSetup()
	idx := -1
	for i, it := range m.setupPicker.items {
		if it.Value == setupValue("mosquito", "live-mode") {
			idx = i
		}
	}
	if idx < 0 {
		t.Fatal("live-mode row not found")
	}
	m.setupPicker = m.setupPicker.SelectIndex(idx)
	m = pressKey(m, tea.KeyMsg{Type: tea.KeyEnter})

	if m.top() != scrConfirm {
		t.Fatalf("Enter in uninstall mode should confirm, top=%d", m.top())
	}
	if m.pendingAction != "uninstall" {
		t.Fatalf("pendingAction = %q want uninstall", m.pendingAction)
	}
	if len(m.pendingArgs) != 1 || m.pendingArgs[0] != "live-mode" {
		t.Fatalf("pendingArgs = %q, want [live-mode]", m.pendingArgs)
	}
}

// TestSetupCountSuffixIsPerCategory checks the "n/m" counter: it belongs to the
// category and only counts that category's ticked modules.
func TestSetupCountSuffixIsPerCategory(t *testing.T) {
	m := flatSetup()
	m.selected[setupValue("apps", "reaper")] = true
	m.selected[setupValue("mosquito", "live-mode")] = true
	m.setupPicker = m.rebuildSetup()

	want := map[string]string{
		folderValue("apps"):     "1/2",
		folderValue("mosquito"): "1/1",
	}
	for _, it := range m.setupPicker.items {
		if w, ok := want[it.Value]; ok {
			if !strings.Contains(it.Suffix, w) {
				t.Fatalf("%s suffix = %q, want %q", it.Value, it.Suffix, w)
			}
			if !it.Folder {
				t.Fatalf("%s must be flagged Folder for the fold arrow", it.Value)
			}
		}
	}
}

// TestStatusArrivesFullyExpanded is the regression for "Status opens with every
// folder closed, then opening one flips the lot": the rows were built straight
// from statusTree() when the backend answered, bypassing the rebuild that seeds
// statusOpen, so nothing was expanded and the first fold touched every key.
func TestStatusArrivesFullyExpanded(t *testing.T) {
	m := initialModel()
	m.nav = []screen{scrMain, scrStatus}
	m.w, m.h = 100, 34
	m.setupFolders = []FolderRec{{Folder: "apps", Label: "Apps"}, {Folder: "tuis", Label: "TUIs"}}
	m.statusRecs = []StatusRec{
		{Id: "reaper", Category: "apps", State: "ok"},
		{Id: "extracto", Category: "apps", State: "missing"},
		{Id: "bat", Category: "tuis", State: "ok"},
	}
	// nil is the shape a fresh model can reach, and the reason the function
	// needs a pointer receiver at all.
	m.statusOpen = nil
	m.statusPicker = m.rebuildStatus()

	folded := map[string]bool{}
	for _, it := range m.statusPicker.items {
		if it.Value == "status-cat:apps" || it.Value == "status-cat:tuis" {
			if it.Fold != tuikit.FoldExpanded {
				folded[it.Value] = true
			}
		}
	}
	if len(folded) != 0 {
		t.Fatalf("Status must open fully expanded, these came in folded: %v", folded)
	}
	// The map is now shared with the caller, so folding one category is the
	// only thing the next rebuild may change.
	m.statusOpen["apps"] = false
	m.statusPicker = m.rebuildStatus()
	for _, it := range m.statusPicker.items {
		if it.Value == "status-cat:apps" && it.Fold != tuikit.FoldCollapsed {
			t.Fatalf("apps stayed expanded after ←")
		}
		if it.Value == "status-cat:tuis" && it.Fold != tuikit.FoldExpanded {
			t.Fatalf("folding apps also folded tuis — the map is not per-category")
		}
	}
}
