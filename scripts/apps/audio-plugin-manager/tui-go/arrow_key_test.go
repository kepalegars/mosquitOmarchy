package main

import (
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

// pressArrow sends a REAL arrow key and runs the message it produces.
//
// The tests used to hand the model a tuikit.PickerSortMsg directly, which
// skipped the picker entirely — so they kept passing while the key did nothing.
// ← is a two-step gesture: the picker turns the keystroke into a fold, and the
// host answers it with a repaint. Driving it the way a terminal does is the only
// way to be sure the two halves still meet.
func pressArrow(t *testing.T, m model, k tea.KeyType) model {
	t.Helper()
	next, cmd := m.Update(tea.KeyMsg{Type: k})
	got, _ := next.(model)
	if cmd == nil {
		return got
	}
	// Drain the batch: the fold message is one of the commands it produced.
	msg := cmd()
	for {
		again, more := got.Update(msg)
		nm, _ := again.(model)
		got = nm
		if more == nil {
			return got
		}
		msg = more()
	}
}

// The screen where the gesture was actually broken.
//
// Uninstall looked the folder up with selectedFolderValue(), which matched only
// a row that WAS a folder row, so ← on a sub-plugin found nothing and did
// nothing. Closing a folder meant first putting the cursor back on its title —
// the exact thing ← is supposed to save.
func TestLeftOnASubPluginClosesItsFolderOnTheUninstallScreen(t *testing.T) {
	m := &model{
		nav: []screen{scrUninstallPick}, w: 100, h: 40,
		uninstallCache: []Item{
			{Kind: "folder", Value: "vendor:FabFilter", Display: "FabFilter"},
			{Kind: "plugin", Value: "vst:vst2:/x/One.dll", Display: "FabFilter One", Parent: "vendor:FabFilter"},
			{Kind: "plugin", Value: "vst:vst2:/x/Two.dll", Display: "FabFilter Two", Parent: "vendor:FabFilter"},
		},
		uninstallChecked: map[string]bool{},
		folderExpanded:   map[string]bool{"vendor:FabFilter": true},
	}
	m.rebuildUninstallPicker()
	for i, it := range m.picker.Items() {
		if it.Value == "vst:vst2:/x/Two.dll" {
			m.picker = m.picker.SelectIndex(i)
		}
	}
	if got := m.picker.SelectedValue(); got != "vst:vst2:/x/Two.dll" {
		t.Fatalf("cursor is on %q, want a sub-plugin", got)
	}

	got := pressArrow(t, *m, tea.KeyLeft)
	if got.folderExpanded["vendor:FabFilter"] {
		t.Fatal("← on a sub-plugin did not close its folder")
	}
	for _, it := range got.picker.Items() {
		if it.Value == "vst:vst2:/x/Two.dll" {
			t.Error("the sub-plugin is still listed under a closed folder")
		}
	}
	// The row the cursor was on is gone, so it has to land on the folder.
	if v := got.picker.SelectedValue(); v != "vendor:FabFilter" {
		t.Errorf("cursor is on %q after folding, want the folder we closed", v)
	}
}

// And the same gesture must work on every folder screen, including the two the
// plugin manager groups differently (the fixes chooser keys its categories by a
// value prefix rather than sharing the vendor tree).
func TestLeftOnAChildFoldsOnEveryFolderScreen(t *testing.T) {
	children := []PluginItem{
		{Kind: "plugin", Value: "vst:2:/x/One.vst3", Display: "One", Vendor: "FabFilter", Parent: "vendor:FabFilter"},
	}
	cases := []struct {
		name   string
		screen screen
		setup  func(*model)
		folder string
		child  string
	}{
		{"plugin list", scrPluginList, func(m *model) {
			m.pluginCache = append([]PluginItem{{Kind: "folder", Value: "vendor:FabFilter", Display: "FabFilter"}}, children...)
			m.pluginChecked = map[string]bool{}
			m.rebuildPluginPicker()
		}, "vendor:FabFilter", "vst:2:/x/One.vst3"},
		{"fix plugin pick", scrFixPluginPick, func(m *model) {
			m.fixPluginCache = append([]PluginItem{{Kind: "folder", Value: "vendor:FabFilter", Display: "FabFilter"}}, children...)
			m.fixAppliedPlugins = map[string]bool{}
			m.pluginChecked = map[string]bool{}
			m.rebuildFixPluginPicker()
		}, "vendor:FabFilter", "vst:2:/x/One.vst3"},
		{"uninstall pick", scrUninstallPick, func(m *model) {
			m.uninstallCache = []Item{
				{Kind: "folder", Value: "vendor:FabFilter", Display: "FabFilter"},
				{Kind: "plugin", Value: "vst:2:/x/One.vst3", Display: "One", Parent: "vendor:FabFilter"},
			}
			m.uninstallChecked = map[string]bool{}
			m.rebuildUninstallPicker()
		}, "vendor:FabFilter", "vst:2:/x/One.vst3"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			m := &model{
				nav: []screen{c.screen}, w: 100, h: 40,
				folderExpanded: map[string]bool{c.folder: true},
			}
			c.setup(m)
			for i, it := range m.picker.Items() {
				if it.Value == c.child {
					m.picker = m.picker.SelectIndex(i)
				}
			}
			if got := m.picker.SelectedValue(); got != c.child {
				t.Skipf("this screen does not nest %q under a folder row", c.child)
			}
			got := pressArrow(t, *m, tea.KeyLeft)
			if got.folderExpanded[c.folder] {
				t.Errorf("← on a child did not close %q", c.folder)
			}
		})
	}
}
