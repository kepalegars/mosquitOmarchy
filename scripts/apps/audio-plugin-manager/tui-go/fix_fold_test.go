package main

import (
	"testing"

	tuikit "mosquitomarchy.local/tui-kit"
)

// Plugin fixes auto-opens any folder that holds an already-applied fix, so the
// ■ marker is not hidden behind a closed folder. It used to re-force that on
// EVERY rebuild, which is what made the folder impossible to fold: ← closed it
// and the rebuild reopened it on the next line, so the gesture appeared dead
// there while working fine everywhere else.
func TestFixPluginFolderCanBeFoldedDespiteAutoOpen(t *testing.T) {
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
		// CrispyTuner already has a fix applied, so its folder auto-opens.
		fixAppliedPlugins: map[string]bool{"CrispyTuner": true},
		pluginChecked:     map[string]bool{},
	}
	m.rebuildFixPluginPicker()

	if !m.folderExpanded["folder:vst"] {
		t.Fatal("a folder holding an applied fix should auto-open on first build")
	}
	// Put the cursor on the PLUGIN, not the folder, and press ←.
	mm, _ := m.Update(tuikit.PickerSortMsg{Dir: -1})
	got, _ := mm.(model)
	if got.folderExpanded["folder:vst"] {
		t.Error("← from a plugin row did not fold its folder: rebuild re-opened it")
	}
	// And it stays folded through any number of rebuilds.
	for i := 0; i < 3; i++ {
		got.rebuildFixPluginPicker()
		if got.folderExpanded["folder:vst"] {
			t.Fatalf("rebuild %d re-opened a folder the user had folded", i+1)
		}
	}
	// → re-opens it, and the auto-open no longer fights back.
	mm2, _ := got.Update(tuikit.PickerSortMsg{Dir: 1})
	got2, _ := mm2.(model)
	if !got2.folderExpanded["folder:vst"] {
		t.Error("→ did not re-open the folder")
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
	mm, _ := m.Update(tuikit.PickerSortMsg{Dir: -1})
	got, _ := mm.(model)
	if got.folderExpanded["folder:vst"] {
		t.Error("← from inside the folder did nothing")
	}
	// The row under the cursor is gone, so the cursor lands on the folder.
	if v := got.picker.SelectedValue(); v != "folder:vst" {
		t.Errorf("cursor is on %q after folding, want the folder we closed", v)
	}
}
