package tuikit

import (
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

// treeRows is a vendor with two children, the shape every folder screen in
// these apps actually has.
func treeRows(open map[string]bool) []PickerItem {
	items := []PickerItem{
		{Display: "Other", Value: "cat:Other", Folder: true},
		{Display: "FabFilter", Value: "cat:FabFilter", Folder: true},
	}
	if open["cat:FabFilter"] {
		items = append(items,
			PickerItem{Display: "    └─ FabFilter One", Value: "item:One"},
			PickerItem{Display: "    ├─ FabFilter Two", Value: "item:Two"},
		)
	}
	return items
}

func treePicker(open map[string]bool, on string) Picker {
	return NewPicker("", treeRows(open)).WithTree(open).SelectValue(on)
}

func fold(t *testing.T, p Picker, keyStr string) (TreeFoldMsg, bool) {
	t.Helper()
	_, cmd := p.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(keyStr)})
	if keyStr == "left" {
		_, cmd = p.Update(tea.KeyMsg{Type: tea.KeyLeft})
	}
	if cmd == nil {
		return TreeFoldMsg{}, false
	}
	msg, ok := cmd().(TreeFoldMsg)
	return msg, ok
}

// The gesture the user asked for: ← on a CHILD closes the folder the cursor is
// in. Before this, a host that only looked at the selected row found no folder
// on a plugin row and left the vendor open.
func TestLeftOnAChildFoldsTheFolderItIsIn(t *testing.T) {
	open := map[string]bool{"cat:FabFilter": true}
	p := treePicker(open, "item:Two")

	msg, ok := fold(t, p, "left")
	if !ok {
		t.Fatal("← on a child did not produce a fold")
	}
	if msg.Folder != "cat:FabFilter" {
		t.Errorf("← on a child of FabFilter folded %q", msg.Folder)
	}
	if msg.Open {
		t.Error("← opened the folder instead of closing it")
	}
	if !open["cat:FabFilter"] == false {
		t.Error("the shared map was not flipped")
	}
	// The cursor was on a child that just disappeared, so it has to land on
	// the folder — not on a now-nonexistent row.
	if msg.Cursor != "cat:FabFilter" {
		t.Errorf("the cursor would land on %q, a row that no longer exists", msg.Cursor)
	}
}

// → on a folder title opens it and leaves the cursor where it was.
func TestRightOnAFolderOpensIt(t *testing.T) {
	open := map[string]bool{}
	p := treePicker(open, "cat:FabFilter")

	msg, ok := fold(t, p, "right")
	if !ok {
		t.Fatal("→ on a folder did not produce a fold")
	}
	if !msg.Open || msg.Folder != "cat:FabFilter" {
		t.Errorf("→ gave folder=%q open=%v", msg.Folder, msg.Open)
	}
	if msg.Cursor != "cat:FabFilter" {
		t.Errorf("the cursor should stay on the folder, not %q", msg.Cursor)
	}
}

// A row that belongs to no folder — the "Back" row, a header — must NOT claim
// to be inside one, and must keep the old meaning of the arrow.
func TestArrowOnALooseRowStillSorts(t *testing.T) {
	open := map[string]bool{"cat:FabFilter": true}
	p := NewPicker("", []PickerItem{
		{Display: "Readme", Value: "readme"},
		{Display: "FabFilter", Value: "cat:FabFilter", Folder: true},
	}).WithTree(open).SelectValue("readme")

	_, cmd := p.Update(tea.KeyMsg{Type: tea.KeyLeft})
	if cmd == nil {
		t.Fatal("← on a loose row did nothing at all")
	}
	if _, isSort := cmd().(PickerSortMsg); !isSort {
		t.Error("← on a row that is in no folder should still mean sort")
	}
}

// Without WithTree the picker is not a tree, so the arrows must keep meaning
// sort. This is the guard that keeps every settings screen that cycles a value
// with ←/→ working.
func TestAPlainPickerStillSorts(t *testing.T) {
	p := NewPicker("", []PickerItem{{Display: "Auto", Value: "auto"}}).SelectValue("auto")
	_, cmd := p.Update(tea.KeyMsg{Type: tea.KeyLeft})
	if cmd == nil {
		t.Fatal("← did nothing")
	}
	sm, ok := cmd().(PickerSortMsg)
	if !ok {
		t.Fatal("a picker with no tree is not a tree")
	}
	if sm.Dir != -1 {
		t.Errorf("← gave dir=%d", sm.Dir)
	}
}

// SelectValue is what a host calls after rebuilding: the row COUNT changed, so
// the old index is meaningless. Matching by value is what keeps the cursor on
// the plugin the user was looking at.
func TestSelectValueSurvivesARebuild(t *testing.T) {
	// Before: the folder is open, so its two children are listed.
	before := treePicker(map[string]bool{"cat:FabFilter": true}, "cat:FabFilter")
	// After ← and the host's rebuild: the children are gone, so the list is
	// SHORTER and the old index no longer points at the same row.
	after := NewPicker("", treeRows(map[string]bool{})).WithTree(map[string]bool{}).SelectValue("cat:FabFilter")
	if len(before.Items()) <= len(after.Items()) {
		t.Fatal("the test needs the rebuild to shorten the list")
	}
	if got := after.SelectedValue(); got != "cat:FabFilter" {
		t.Errorf("after the rebuild the cursor is on %q", got)
	}
	// A value that is gone must not drag the cursor somewhere arbitrary.
	orphan := NewPicker("", treeRows(map[string]bool{})).WithTree(map[string]bool{}).SelectValue("cat:Nope")
	if got := orphan.SelectedValue(); got == "cat:Nope" {
		t.Error("SelectValue invented a row that does not exist")
	}
}
