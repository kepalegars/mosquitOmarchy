package main

import (
	"testing"

	tuikit "mosquitomarchy.local/tui-kit"
)

// A Tab-held range over the uninstall list checks every known row on the
// way; unknown values (Back, headings) never land in the map.
func TestUninstallRangeChecksKnownRows(t *testing.T) {
	m := initialModel()
	m.nav = []screen{scrMain, scrUninstallPick}
	m.uninstallCache = []Item{
		{Display: "A", Value: "vst:vst2:/x/A.dll"},
		{Display: "B", Value: "vst:vst2:/x/B.dll"},
		{Display: "C", Value: "vst:vst2:/x/C.dll"},
	}
	m.uninstallChecked = map[string]bool{}
	mm, _ := m.update(tuikit.PickerRangeMsg{Values: []string{"vst:vst2:/x/A.dll", "vst:vst2:/x/B.dll", "back"}, Anchor: "vst:vst2:/x/A.dll"})
	got, _ := mm.(model)
	if !got.uninstallChecked["vst:vst2:/x/A.dll"] || !got.uninstallChecked["vst:vst2:/x/B.dll"] {
		t.Fatalf("range did not check: %v", got.uninstallChecked)
	}
	if got.uninstallChecked["vst:vst2:/x/C.dll"] || got.uninstallChecked["back"] {
		t.Fatalf("range checked too much: %v", got.uninstallChecked)
	}
}

// A range over a folder value fills the whole folder, like Tab on it.
func TestUninstallRangeFillsFolder(t *testing.T) {
	m := initialModel()
	m.nav = []screen{scrMain, scrUninstallPick}
	m.uninstallCache = []Item{
		{Display: "Suit", Value: "win:/x/Suite", Kind: "folder"},
		{Display: "A", Value: "vst:vst2:/x/A.dll", Parent: "win:/x/Suite"},
		{Display: "B", Value: "vst:vst2:/x/B.dll", Parent: "win:/x/Suite"},
	}
	m.uninstallChecked = map[string]bool{}
	mm, _ := m.update(tuikit.PickerRangeMsg{Values: []string{"win:/x/Suite"}, Anchor: "win:/x/Suite"})
	got, _ := mm.(model)
	if !got.uninstallChecked["vst:vst2:/x/A.dll"] || !got.uninstallChecked["vst:vst2:/x/B.dll"] {
		t.Fatalf("folder range did not fill: %v", got.uninstallChecked)
	}
}

// A range toggles: crossing a checked row unchecks it again.
func TestOrphanRangeToggles(t *testing.T) {
	m := initialModel()
	m.nav = []screen{scrMain, scrReconcileOrphansTick}
	m.orphanCache = []Item{
		{Display: "One", Value: "vst:vst2:/x/One.dll", Formats: "vst2"},
		{Display: "Two", Value: "vst:vst2:/x/Two.dll", Formats: "vst2"},
	}
	m.orphanChecked = map[string]bool{"vst:vst2:/x/One.dll": true}
	mm, _ := m.update(tuikit.PickerRangeMsg{Values: []string{"vst:vst2:/x/One.dll", "vst:vst2:/x/Two.dll"}, Anchor: "vst:vst2:/x/One.dll"})
	got, _ := mm.(model)
	if got.orphanChecked["vst:vst2:/x/One.dll"] {
		t.Fatalf("crossed checked row stayed checked: %v", got.orphanChecked)
	}
	if !got.orphanChecked["vst:vst2:/x/Two.dll"] {
		t.Fatalf("crossed unchecked row stayed unchecked: %v", got.orphanChecked)
	}
}
