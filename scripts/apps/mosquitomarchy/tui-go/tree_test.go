package main

import (
	"fmt"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"

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

// TestSetupBlinkKeepsTheCursor is the regression for "moving the cursor in
// Setup feels slow and broken". rebuildSetup used to hand back a brand-new
// picker, so the cursor fell back to row 0 — and rebuildSetup runs on the
// accent blink, twice a second, so holding "down" fought it and the cursor
// crawled upward instead of down.
func TestSetupBlinkKeepsTheCursor(t *testing.T) {
	m := flatSetup()
	m.setupPicker = m.rebuildSetup()
	last := len(m.setupPicker.items) - 1
	m.setupPicker = m.setupPicker.SelectIndex(last)
	if got := m.setupPicker.Index(); got != last {
		t.Fatalf("could not park the cursor on the last row: %d != %d", got, last)
	}

	// Two blink ticks, exactly what the timer delivers.
	for i := 0; i < 2; i++ {
		m, _ = m.update(blinkMsg{})
		if got := m.setupPicker.Index(); got != last {
			t.Fatalf("blink tick %d moved the cursor from %d to %d", i+1, last, got)
		}
	}
}

// TestSetupBlinkSkipsWorkWhenTheAccentRowIsOffscreen covers the other half: the
// blink only changes the "mosquito" category's accent, so when that row is not
// in the viewport there is nothing to repaint. It must not rebuild regardless —
// the rebuild is what costs, not the flag.
func TestSetupBlinkSkipsWorkWhenTheAccentRowIsOffscreen(t *testing.T) {
	m := flatSetup()
	m.setupFolders = nil
	m.setupItems = nil
	// A long list of flat leaves with no "mosquito" category in it at all.
	m.setupFolders = []FolderRec{{Folder: "apps", Label: "Apps"}}
	for i := 0; i < 40; i++ {
		m.setupItems = append(m.setupItems, SetupItemRec{
			Folder: "apps", Key: fmt.Sprintf("k%02d", i), Label: fmt.Sprintf("Module %02d", i),
		})
		m.setupByValue[setupValue("apps", fmt.Sprintf("k%02d", i))] = SetupItemRec{
			Folder: "apps", Key: fmt.Sprintf("k%02d", i), Label: fmt.Sprintf("Module %02d", i),
		}
	}
	m.folderOpen["apps"] = false
	m.w, m.h = 60, 12
	m.setupPicker = m.rebuildSetup()
	if m.setupPicker.RowVisible(folderValue("mosquito")) {
		t.Fatal("there is no mosquito category in this list, so nothing can be visible")
	}
	before := m.setupPicker
	m, _ = m.update(blinkMsg{})
	if before.Index() != m.setupPicker.Index() {
		t.Fatalf("the blink moved the cursor: %d -> %d", before.Index(), m.setupPicker.Index())
	}
}

// TestSetupLeftArrowFoldsFromInsideTheCategory is the "← closes the folder I am
// in" rule. It used to look only at the selected row's own value, so a leaf
// row resolved to "not a folder" and the arrows did nothing until the cursor
// had been walked back up to the title.
func TestSetupLeftArrowFoldsFromInsideTheCategory(t *testing.T) {
	m := flatSetup()
	m.folderOpen["apps"] = true
	m.folderOpen["mosquito"] = true
	m.setupPicker = m.rebuildSetup()

	// Park the cursor on a MODULE inside "apps".
	leaf := setupValue("apps", "reaper")
	idx := -1
	for i, it := range m.setupPicker.items {
		if it.Value == leaf {
			idx = i
		}
	}
	if idx < 0 {
		t.Fatalf("module %q not on the page", leaf)
	}
	m.setupPicker = m.setupPicker.SelectIndex(idx)

	// ← from inside the category.
	m2, _ := m.update(tuikit.PickerSortMsg{Dir: -1})
	if m2.folderOpen["apps"] {
		t.Fatal("← from a module did not fold its category")
	}
	// The other category is untouched.
	if !m2.folderOpen["mosquito"] {
		t.Fatal("← folded an unrelated category too")
	}
	// The row we were on no longer exists, so the cursor has to land somewhere
	// real — the category we just closed.
	if got := m2.setupPicker.SelectedValue(); got != folderValue("apps") {
		t.Fatalf("cursor is on %q after folding, want the category we closed (%q)", got, folderValue("apps"))
	}
	// And → re-opens it from there.
	m3, _ := m2.update(tuikit.PickerSortMsg{Dir: 1})
	if !m3.folderOpen["apps"] {
		t.Fatal("→ from the category title did not re-open it")
	}
}

// The same rule on the Status tree, which uses its own row prefixes.
func TestStatusLeftArrowFoldsFromInsideTheCategory(t *testing.T) {
	m := initialModel()
	m.nav = []screen{scrMain, scrStatus}
	m.w, m.h = 100, 34
	m.statusRecs = []StatusRec{
		{Id: "reaper", Category: "apps", State: "ok"},
		{Id: "bat", Category: "tuis", State: "ok"},
	}
	m.setupFolders = []FolderRec{{Folder: "apps", Label: "Apps"}, {Folder: "tuis", Label: "TUIs"}}
	m.statusOpen = map[string]bool{}
	m.statusPicker = m.rebuildStatus()

	idx := -1
	for i, it := range m.statusPicker.items {
		if it.Value == "status:reaper" {
			idx = i
		}
	}
	if idx < 0 {
		t.Fatal("status module row not found")
	}
	m.statusPicker = m.statusPicker.SelectIndex(idx)

	m2, _ := m.update(tea.KeyMsg{Type: tea.KeyLeft})
	if m2.statusOpen["apps"] {
		t.Fatal("← from a status module did not fold its category")
	}
	if !m2.statusOpen["tuis"] {
		t.Fatal("← folded an unrelated status category too")
	}
	if got := m2.statusPicker.SelectedValue(); got != "status-cat:apps" {
		t.Fatalf("cursor is on %q after folding, want status-cat:apps", got)
	}
}

// rowPads is the left margin of every non-blank rendered line: where each row
// actually starts on screen.
func rowPads(view string) []int {
	var out []int
	for _, l := range strings.Split(view, "\n") {
		p := ansi.Strip(l)
		if strings.TrimSpace(p) == "" {
			continue
		}
		out = append(out, len(p)-len(strings.TrimLeft(p, " ")))
	}
	return out
}

// isSubsequence reports whether want appears in got in order. Folding only ever
// ADDS rows, so the rows that were already there must keep their exact
// position — same values, same order.
func isSubsequence(want, got []int) bool {
	i := 0
	for _, g := range got {
		if i < len(want) && g == want[i] {
			i++
		}
	}
	return i == len(want)
}

// The picker CENTERS its row block, so the block's width IS the left margin. It
// used to measure only the rows currently on screen, so opening a folder with
// long children ("lame language models", "Omarchy preinstalls") made the block
// grow and re-centered the whole page: every other line slid sideways. Folding
// must only add rows, never move one.
func TestSetupFoldingDoesNotReflowThePage(t *testing.T) {
	m := flatSetup()
	m.setupFolders = append(m.setupFolders, FolderRec{Folder: "lame", Label: "lame language models"})
	m.setupItems = append(m.setupItems,
		SetupItemRec{Folder: "lame", Key: "ollama", Label: "Ollama — local models, no cloud"},
		SetupItemRec{Folder: "lame", Key: "cpp", Label: "llama.cpp"})
	for _, it := range m.setupItems {
		m.setupByValue[setupValue(it.Folder, it.Key)] = it
	}
	m.folderOpen = map[string]bool{"apps": true, "mosquito": true}

	closed := rowPads(m.rebuildSetup().View())
	m.folderOpen["lame"] = true
	open := rowPads(m.rebuildSetup().View())

	if len(open) <= len(closed) {
		t.Fatalf("opening lame added no rows: %v -> %v", closed, open)
	}
	if !isSubsequence(closed, open) {
		t.Errorf("expanding lame MOVED existing rows.\n collapsed: %v\n expanded:  %v", closed, open)
	}
}

// Same rule on the Uninstall tree, where "preinstalls" is a folder whose child
// row is a very long sentence.
func TestUninstallFoldingDoesNotReflowThePage(t *testing.T) {
	m := flatSetup()
	m.treeMode = "uninstall"
	m.setupFolders = []FolderRec{
		{Folder: "apps", Label: "Apps"},
		{Folder: "preinstalls", Label: "Omarchy preinstalls"},
	}
	m.setupItems = []SetupItemRec{
		{Folder: "apps", Key: "reaper", Label: "reaper"},
		{Folder: "preinstalls", Key: "choose", Label: "Choose which stock preinstalls to remove (tab = keep, enter to confirm)"},
	}
	for _, it := range m.setupItems {
		m.setupByValue[setupValue(it.Folder, it.Key)] = it
	}
	m.folderOpen = map[string]bool{"apps": true}

	closed := rowPads(m.rebuildSetup().View())
	m.folderOpen["preinstalls"] = true
	open := rowPads(m.rebuildSetup().View())

	if len(open) <= len(closed) {
		t.Fatalf("opening preinstalls added no rows: %v -> %v", closed, open)
	}
	if !isSubsequence(closed, open) {
		t.Errorf("expanding preinstalls MOVED existing rows.\n collapsed: %v\n expanded:  %v", closed, open)
	}
}

// A category with something ticked inside it wears the accent square at the end
// of its row, exactly like the plugin manager's folder that has an applied fix.
// Setup and Uninstall are mostly a wall of category names with a count on the
// right, and the count alone does not say whether the ticked module is in there
// yet — the two were easy to confuse.
func TestCategoryRowsCarryTheAccentSquareWhenSomethingIsTicked(t *testing.T) {
	m := flatSetup()
	m.folderOpen = map[string]bool{"apps": true, "mosquito": true}
	m.selected[setupValue("apps", "reaper")] = true

	view := ansi.Strip(m.rebuildSetup().View())
	rows := map[string]string{}
	for _, l := range strings.Split(view, "\n") {
		if strings.TrimSpace(l) == "" {
			continue
		}
		for _, name := range []string{"Apps", "mosquito", "Menu entries"} {
			if strings.Contains(l, name) {
				rows[name] = l
			}
		}
	}
	if got := rows["Apps"]; !strings.Contains(got, tuikit.MarkBadge) {
		t.Errorf("the ticked category has no %q: %q", tuikit.MarkBadge, got)
	}
	// Nothing ticked inside the others, so no square — otherwise it is noise.
	for _, name := range []string{"mosquito", "Menu entries"} {
		if got := rows[name]; strings.Contains(got, tuikit.MarkBadge) {
			t.Errorf("untouched category %q still shows the %q: %q", name, tuikit.MarkBadge, got)
		}
	}
}

// The visible rows are derived by filtering the fully-open tree, so every
// folder row arrives already stamped FoldExpanded. It has to be restamped from
// the real fold state: a closed folder that keeps the expanded marker draws an
// open arrow over a folder showing no children at all.
func TestClosedFolderKeepsTheCollapsedMarker(t *testing.T) {
	m := flatSetup()
	m.folderOpen = map[string]bool{} // everything closed
	m.setupPicker = m.rebuildSetup()
	for _, it := range m.setupPicker.Items() {
		if it.Folder && it.Fold != tuikit.FoldCollapsed {
			t.Errorf("closed folder %q drawn as %v, want collapsed", it.Display, it.Fold)
		}
		// Only tree children matter here; "Update"/"Back" are plain rows.
		if _, _, ok := tuikit.TreeSplit(it.Value); ok && !it.Folder {
			t.Errorf("closed folder leaked the child row %q", it.Display)
		}
	}
	// And the converse: opening it really does show the children.
	m.folderOpen["apps"] = true
	m.setupPicker = m.rebuildSetup()
	kids := 0
	for _, it := range m.setupPicker.Items() {
		if it.Folder {
			if it.Display == "Apps" && it.Fold != tuikit.FoldExpanded {
				t.Errorf("open folder %q drawn as %v, want expanded", it.Display, it.Fold)
			}
			continue
		}
		if _, _, ok := tuikit.TreeSplit(it.Value); ok {
			kids++
		}
	}
	if kids == 0 {
		t.Error("opening the folder showed no children")
	}
}

// Building the Setup rows must NEVER talk to the backend. It used to: the
// "remove-ai" row asked whether omarchy's agentic stuff was still there while
// the rows were being assembled, and that answer costs ~900ms because the
// backend shells out to `omarchy plugin list` and `crash-notify`. Since
// rebuildSetup runs on every blink tick, every tick of a checkbox and every
// fold, the screen forked a shell that took most of a second and froze solid.
// The answer is fetched once, in the background, and read from the model.
func TestSetupRowsNeverForkTheBackend(t *testing.T) {
	calls := 0
	orig := aiRemovedQuery
	aiRemovedQuery = func() (bool, error) { calls++; return false, nil }
	defer func() { aiRemovedQuery = orig }()

	m := flatSetup()
	m.setupItems = append(m.setupItems, SetupItemRec{
		Folder: "apps", Key: "remove-ai", Label: "remove omarchy's agentic stuff",
	})
	m.setupByValue[setupValue("apps", "remove-ai")] = m.setupItems[len(m.setupItems)-1]
	m.setupPicker = m.rebuildSetup()

	if calls != 0 {
		t.Fatalf("rebuildSetup asked the backend %d time(s) while building rows", calls)
	}
	// Neither may the blink, nor a fold, nor a tick of a checkbox.
	for i := 0; i < 5; i++ {
		m.blinkOn = !m.blinkOn
		m.setupPicker = m.rebuildSetup()
	}
	m.folderOpen["apps"] = false
	m.setupPicker = m.rebuildSetup()
	m.selected[setupValue("apps", "remove-ai")] = true
	m.setupPicker = m.rebuildSetup()
	if calls != 0 {
		t.Errorf("the render path forked the backend %d time(s) after rebuilds", calls)
	}
}

// Until the background answer arrives, the "bring back" row stays greyed: there
// is nothing to bring back until a removal has actually happened.
func TestRemoveAIRowIsDisabledUntilTheAnswerArrives(t *testing.T) {
	calls := 0
	orig := aiRemovedQuery
	aiRemovedQuery = func() (bool, error) { calls++; return true, nil }
	defer func() { aiRemovedQuery = orig }()

	m := flatSetup()
	m.setupItems = append(m.setupItems, SetupItemRec{
		Folder: "apps", Key: "remove-ai", Label: "bring back omarchy's agentic stuff",
	})
	m.setupByValue[setupValue("apps", "remove-ai")] = m.setupItems[len(m.setupItems)-1]
	m.folderOpen["apps"] = true
	m.setupPicker = m.rebuildSetup()

	row := func(mod model) tuikit.PickerItem {
		for _, it := range mod.setupPicker.Items() {
			if strings.Contains(it.Display, "agentic stuff") {
				return it
			}
		}
		t.Fatal("the remove-ai row is missing from Setup")
		return tuikit.PickerItem{}
	}
	if !row(m).Disabled {
		t.Error("row is live before the backend has even been asked")
	}
	// The answer says a removal DID happen, so the restore is now selectable.
	mm, _ := m.Update(fetchAIRemovedCmd()())
	got := mm.(model)
	if !got.aiRemovedKnown || !got.aiRemoved {
		t.Fatalf("the async answer was not stored: known=%v removed=%v", got.aiRemovedKnown, got.aiRemoved)
	}
	if calls != 1 {
		t.Errorf("the fetch ran %d time(s), want exactly 1", calls)
	}
	if row(got).Disabled {
		t.Error("row stayed greyed even though a removal was recorded")
	}
}
