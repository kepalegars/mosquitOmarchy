package main

import (
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

// The plugin fixes list arrives FULLY COLLAPSED — every folder shut, whatever
// it holds. It used to auto-open any folder holding an already-applied fix so
// its marker would not be hidden, which meant the page came in already
// unfolded and the reason was invisible.
//
// The marker moved to the FOLDER ROW instead, so a closed folder still says it
// holds a fixed plugin. That is the property worth pinning: collapsed by
// default, and not at the cost of the information.
func TestFixPluginFoldersArriveCollapsedAndKeepTheirMarker(t *testing.T) {
	m := &model{
		nav:                []screen{scrFixPluginPick},
		w:                  100,
		h:                  34,
		folderExpanded:     map[string]bool{},
		folderFoldedByUser: map[string]bool{},
		fixPluginCache: []PluginItem{
			{Kind: "folder", Value: "folder:vst", Display: "VST plugins"},
			{Kind: "plugin", Value: "vst:2:/x/CrispyTuner.vst3", Display: "CrispyTuner", Parent: "folder:vst"},
			{Kind: "folder", Value: "folder:other", Display: "Other"},
		},
		// CrispyTuner already has a fix applied.
		fixAppliedPlugins: map[string]bool{"CrispyTuner": true},
		pluginChecked:     map[string]bool{},
	}
	m.rebuildFixPluginPicker()

	if len(m.folderExpanded) != 0 {
		t.Fatalf("a folder was force-opened on arrival: %v", m.folderExpanded)
	}
	// ...and the child row is not on screen, which is what "collapsed" means.
	for _, it := range m.picker.Items() {
		if it.Value == "vst:2:/x/CrispyTuner.vst3" {
			t.Fatal("a plugin is visible while its folder is collapsed")
		}
	}
	// The folder still carries the applied-fix marker, so nothing is lost by
	// arriving closed.
	marked := false
	for _, it := range m.picker.Items() {
		if it.Value == "folder:vst" && it.TrailingBadge == fixAppliedBadge {
			marked = true
		}
	}
	if !marked {
		t.Error("the closed folder lost its applied-fix marker")
	}

	// → opens it, and it stays open through rebuilds.
	got := pressArrow(t, *m, tea.KeyRight)
	if !got.folderExpanded["folder:vst"] {
		t.Fatal("→ did not open the folder")
	}
	for i := 0; i < 3; i++ {
		got.rebuildFixPluginPicker()
		if !got.folderExpanded["folder:vst"] {
			t.Fatalf("rebuild %d closed a folder the user had opened", i+1)
		}
	}
	// ← closes it again, and no rebuild re-opens it.
	got2 := pressArrow(t, got, tea.KeyLeft)
	if got2.folderExpanded["folder:vst"] {
		t.Fatal("← did not fold the folder")
	}
	for i := 0; i < 3; i++ {
		got2.rebuildFixPluginPicker()
		if got2.folderExpanded["folder:vst"] {
			t.Fatalf("rebuild %d re-opened a folder the user had folded", i+1)
		}
	}
}

// ← has to close the folder the cursor is IN on this screen too, not only when
// the cursor happens to sit on the folder row.
func TestFixPluginFoldFromInsideTheFolder(t *testing.T) {
	m := &model{
		nav:            []screen{scrFixPluginPick},
		w:              100,
		h:              34,
		folderExpanded: map[string]bool{"folder:vst": true},
		fixPluginCache: []PluginItem{
			{Kind: "folder", Value: "folder:vst", Display: "VST plugins"},
			{Kind: "plugin", Value: "vst:2:/x/CrispyTuner.vst3", Display: "CrispyTuner", Parent: "folder:vst"},
		},
		pluginChecked: map[string]bool{},
	}
	m.rebuildFixPluginPicker()
	for i, it := range m.picker.Items() {
		if it.Value == "vst:2:/x/CrispyTuner.vst3" {
			m.picker = m.picker.SelectIndex(i)
		}
	}
	if got := m.picker.SelectedValue(); got != "vst:2:/x/CrispyTuner.vst3" {
		t.Fatalf("cursor is on %q, want the plugin row", got)
	}
	got := pressArrow(t, *m, tea.KeyLeft)
	if got.folderExpanded["folder:vst"] {
		t.Error("← from inside the folder did nothing")
	}
	// The row under the cursor is gone, so the cursor lands on the folder.
	if v := got.picker.SelectedValue(); v != "folder:vst" {
		t.Errorf("cursor is on %q after folding, want the folder we closed", v)
	}
}
