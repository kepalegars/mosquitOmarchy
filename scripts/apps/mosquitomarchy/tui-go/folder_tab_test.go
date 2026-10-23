package main

import (
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	tuikit "mosquitomarchy.local/tui-kit"
)

// TestTabOnFolderTicksAll: Tab on a level-1 folder ticks every tickable row
// inside it (greyed rows stay out), and unticks them all on the second Tab.
func TestTabOnFolderTicksAll(t *testing.T) {
	m := flatSetup()
	m.nav = []screen{scrMain, scrSetup}
	m.w, m.h = 100, 34
	m.treeMode = "install"
	m.setupPicker = m.rebuildSetup()
	m.setupPicker = m.setupPicker.SelectValue("cat:apps")
	var cmd tea.Cmd
	m.setupPicker, cmd = m.setupPicker.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("\t")})
	_ = cmd
	// The picker emits ToggleMsg through its own Update; drive the host path.
	m, _ = m.update(tuikit.PickerToggleMsg{Value: "cat:apps"})
	if !m.selected[setupValue("apps", "reaper")] || !m.selected[setupValue("apps", "extracto")] {
		t.Fatalf("folder Tab did not tick the children: %v", m.selected)
	}
	m, _ = m.update(tuikit.PickerToggleMsg{Value: "cat:apps"})
	if m.selected[setupValue("apps", "reaper")] || m.selected[setupValue("apps", "extracto")] {
		t.Fatalf("second folder Tab did not untick: %v", m.selected)
	}
}

// TestFolderSquareNeedsFullTick: the folder square fills only when every
// tickable row is ticked; a partial tick leaves it empty.
func TestFolderSquareNeedsFullTick(t *testing.T) {
	m := flatSetup()
	m.w, m.h = 100, 34
	m.treeMode = "install"
	square := func() bool {
		for _, it := range m.rebuildSetup().items {
			if it.Value == "cat:apps" {
				return it.TrailingBadge == "■"
			}
		}
		return false
	}
	m.selected[setupValue("apps", "reaper")] = true
	if square() {
		t.Fatalf("partial tick filled the folder square")
	}
	m.selected[setupValue("apps", "extracto")] = true
	if !square() {
		t.Fatalf("full tick did not fill the folder square")
	}
	filled := false
	for _, it := range m.rebuildSetup().items {
		if it.Value == "cat:apps" {
			filled = it.Filled
		}
	}
	if !filled {
		t.Fatalf("full tick did not fill the folder glyph")
	}
}

// TestEnterOnItemInstallsWholeTickedFolder: after Tab ticks a folder, Enter on
// any row must install the WHOLE ticked set, not just the row under the cursor.
func TestEnterOnItemInstallsWholeTickedFolder(t *testing.T) {
	m := flatSetup()
	m.treeMode = "install"
	m.setupPicker = m.setupPicker.SelectValue("cat:apps")
	m, _ = m.update(tuikit.PickerToggleMsg{Value: "cat:apps"})
	if !m.selected[setupValue("apps", "reaper")] || !m.selected[setupValue("apps", "extracto")] {
		t.Fatalf("folder tick did not select its children: %v", m.selected)
	}
	m.setupPicker = m.setupPicker.SelectValue("item:apps:reaper")
	m, _ = m.screenPicked(tuikit.PickerResultMsg{Value: "item:apps:reaper"})
	if len(m.pendingArgs) != 1 {
		t.Fatalf("pendingArgs = %#v, want one grouped plan", m.pendingArgs)
	}
	plan := m.pendingArgs[0]
	if !strings.Contains(plan, "reaper") || !strings.Contains(plan, "extracto") {
		t.Fatalf("Enter installed %q, want both ticked apps", plan)
	}
}

// TestCategoryInfoExplainsPurposeThenContents: `i` on a category must say what
// the group is for before dumping its inventory.
func TestCategoryInfoExplainsPurposeThenContents(t *testing.T) {
	m := flatSetup()
	info := m.categoryInfo("apps")
	purpose := categoryPurpose["apps"]
	if purpose == "" {
		t.Fatal("apps category has no purpose text")
	}
	if !strings.Contains(info, purpose) {
		t.Fatalf("category info lost the purpose:\n%s", info)
	}
	if !strings.Contains(info, "reaper") || !strings.Contains(info, "extracto") {
		t.Fatalf("category info lost the contents:\n%s", info)
	}
	if strings.Index(info, purpose) > strings.Index(info, "reaper") {
		t.Fatalf("purpose must come before the item list:\n%s", info)
	}
}

func TestRealKeysFolderThenEnterOnChild(t *testing.T) {
	m := flatSetup()
	m.treeMode = "install"
	m.setupPicker = m.setupPicker.SelectValue("cat:apps")
	m = pressKey(m, tea.KeyMsg{Type: tea.KeyTab})
	if !m.selected[setupValue("apps", "reaper")] || !m.selected[setupValue("apps", "extracto")] {
		t.Fatalf("Tab on folder did not tick children: %v (cursor %q)", m.selected, m.setupPicker.SelectedValue())
	}
	m.setupPicker = m.setupPicker.SelectValue("item:apps:reaper")
	m = pressKey(m, tea.KeyMsg{Type: tea.KeyEnter})
	if len(m.pendingArgs) != 1 || !strings.Contains(m.pendingArgs[0], "extracto") {
		t.Fatalf("Enter after folder Tab = %#v (top %v, cursor %q)", m.pendingArgs, m.top(), m.setupPicker.SelectedValue())
	}
}

// TestEnterOnUntickedFolderDoesNothing: Enter must never turn a folder into
// an implicit select-all/install.
func TestEnterOnUntickedFolderDoesNothing(t *testing.T) {
	m := flatSetup()
	m.treeMode = "install"
	m.setupPicker = m.setupPicker.SelectValue("cat:apps")
	m = pressKey(m, tea.KeyMsg{Type: tea.KeyEnter})
	if m.top() != scrSetup || m.pendingAction != "" || len(m.pendingArgs) != 0 {
		t.Fatalf("unticked folder Enter acted: top=%v action=%q args=%v", m.top(), m.pendingAction, m.pendingArgs)
	}
	if len(m.selected) != 0 {
		t.Fatalf("folder Enter auto-ticked rows: %v", m.selected)
	}
}

// TestEnterOnUntickedItemDoesNothing: an untouched cursor row is not a
// selection.
func TestEnterOnUntickedItemDoesNothing(t *testing.T) {
	m := flatSetup()
	m.treeMode = "install"
	m.setupPicker = m.setupPicker.SelectValue("item:apps:reaper")
	m = pressKey(m, tea.KeyMsg{Type: tea.KeyEnter})
	if m.top() != scrSetup || m.pendingAction != "" || len(m.pendingArgs) != 0 {
		t.Fatalf("unticked item Enter acted: top=%v action=%q args=%v", m.top(), m.pendingAction, m.pendingArgs)
	}
}

// TestEnterOnTickedFolderInstallsTickedSet: Tab on the folder is the explicit
// select-all; Enter then applies that selection.
func TestEnterOnTickedFolderInstallsTickedSet(t *testing.T) {
	m := flatSetup()
	m.treeMode = "install"
	m.setupPicker = m.setupPicker.SelectValue("cat:apps")
	m, _ = m.update(tuikit.PickerToggleMsg{Value: "cat:apps"})
	m = pressKey(m, tea.KeyMsg{Type: tea.KeyEnter})
	if m.top() != scrConfirm || m.pendingAction != "apply" {
		t.Fatalf("ticked folder Enter did not open the install confirm: top=%v action=%q", m.top(), m.pendingAction)
	}
	plan := strings.Join(m.pendingArgs, "|")
	if !strings.Contains(plan, "reaper") || !strings.Contains(plan, "extracto") {
		t.Fatalf("ticked folder Enter plan = %q, want both apps", plan)
	}
}

// TestEnterAppliesSelectionsAcrossFolders: the selection is global, not
// scoped to the folder the cursor happens to be on.
func TestEnterAppliesSelectionsAcrossFolders(t *testing.T) {
	m := flatSetup()
	m.treeMode = "install"
	m.selected[setupValue("apps", "reaper")] = true
	m.selected[setupValue("mosquito", "live-mode")] = true
	m.setupPicker = m.setupPicker.SelectValue("cat:apps")
	m = pressKey(m, tea.KeyMsg{Type: tea.KeyEnter})
	if m.top() != scrConfirm || m.pendingAction != "apply" {
		t.Fatalf("cross-folder Enter did not confirm: top=%v action=%q", m.top(), m.pendingAction)
	}
	plan := strings.Join(m.pendingArgs, "|")
	if !strings.Contains(plan, "reaper") || !strings.Contains(plan, "live-mode") {
		t.Fatalf("cross-folder plan = %q, want both checked rows", plan)
	}
}

// TestEnterOnCatalogFolderStaysInert: fixes/tweaks/preinstalls are not module
// folders; Enter on their title must not mass-install or mass-remove.
func TestEnterOnCatalogFolderStaysInert(t *testing.T) {
	for _, folder := range []string{"fixes", "tweaks", "preinstalls", "patches"} {
		m := flatSetup()
		m.setupFolders = append(m.setupFolders, FolderRec{Folder: folder, Label: folder})
		m.setupItems = append(m.setupItems, SetupItemRec{Folder: folder, Key: "x", Label: "x"})
		m.setupPicker = m.rebuildSetup()
		m.setupPicker = m.setupPicker.SelectValue("cat:" + folder)
		m = pressKey(m, tea.KeyMsg{Type: tea.KeyEnter})
		if m.top() != scrSetup || m.pendingAction != "" || m.pendingArgs != nil {
			t.Fatalf("%s: folder Enter acted as a module install (top=%v action=%q args=%v)", folder, m.top(), m.pendingAction, m.pendingArgs)
		}
	}
}

// TestFolderInstallConfirmShowsShortfall: the folder flow must reach the same
// disk-warning path as a single row.
func TestFolderInstallConfirmShowsShortfall(t *testing.T) {
	m := flatSetup()
	m.setupPicker = m.setupPicker.SelectValue("cat:apps")
	m, _ = m.update(tuikit.PickerToggleMsg{Value: "cat:apps"})
	m = pressKey(m, tea.KeyMsg{Type: tea.KeyEnter})
	m.applySpaceMsg(spaceMsg{seq: m.spaceSeq, rec: DiskRec{FreeKB: 1024, NeedKB: 4096}})
	if !strings.Contains(m.confirm.Message, notEnough) {
		t.Fatalf("folder confirm lost the warning: %q", m.confirm.Message)
	}
}
