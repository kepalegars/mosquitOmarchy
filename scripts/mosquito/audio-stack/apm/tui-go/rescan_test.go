package main

import (
	"testing"

	tuikit "mosquitomarchy.local/tui-kit"
)

// Starting a rescan shows progress in place: the cursor turns into a
// spinner on the row, a toast says what is happening, and the cursor
// never leaves the option.
func TestRescanShowsProgressInPlace(t *testing.T) {
	m := initialModel()
	m.nav = []screen{scrMain, scrSettings}
	m.w, m.h = 100, 34
	mm, cmd := m.update(tuikit.PickerResultMsg{Value: "rescan"})
	_ = cmd
	got, _ := mm.(model)
	if top := got.top(); top != scrSettings {
		t.Fatalf("rescan left settings (top=%d)", top)
	}
	if !got.scanBusy {
		t.Fatal("scanBusy not set while the sweep runs")
	}
	if got.picker.BusyGlyph() == "" {
		t.Fatal("no spinner glyph on the picker while the sweep runs")
	}
}

// Esc mid-scan cancels and STAYS in Settings: no pop, no late results.
func TestEscCancelsRescanAndStays(t *testing.T) {
	m := initialModel()
	m.nav = []screen{scrMain, scrSettings}
	m.w, m.h = 100, 34
	mm, _ := m.update(tuikit.PickerResultMsg{Value: "rescan"})
	got, _ := mm.(model)
	gen := got.scanGen
	mm2, _ := got.update(tuikit.PickerResultMsg{Canceled: true})
	got2, _ := mm2.(model)
	if got2.top() != scrSettings {
		t.Fatalf("cancelled scan left settings (top=%d)", got2.top())
	}
	if got2.scanBusy {
		t.Fatal("scanBusy still set after Esc")
	}
	// The late result of the cancelled sweep is dropped.
	mm3, _ := got2.update(rescanMsg{gen: gen, items: []Item{{Display: "X", Value: "vst:vst2:/x/X.dll"}}})
	got3, _ := mm3.(model)
	if got3.top() != scrSettings {
		t.Fatalf("stale result opened a screen (top=%d)", got3.top())
	}
}

// A rescan that finds orphans REPLACES settings instead of pushing over
// it: one Esc leaves the untracked page, not two.
func TestRescanOrphansReplaceSettings(t *testing.T) {
	m := initialModel()
	m.nav = []screen{scrMain, scrSettings}
	m.w, m.h = 100, 34
	m.scanGen = 1
	mm, _ := m.update(rescanMsg{gen: 1, items: []Item{
		{Display: "One", Value: "vst:vst2:/x/One.dll", Formats: "vst2"},
	}})
	got, _ := mm.(model)
	if got.top() != scrReconcileOrphansTick {
		t.Fatalf("orphans did not open (top=%d)", got.top())
	}
	if got.picker.BusyGlyph() != "" {
		t.Fatal("spinner still on after the sweep finished")
	}
	mm2, _ := got.update(tuikit.PickerResultMsg{Canceled: true})
	got2, _ := mm2.(model)
	if got2.top() != scrMain {
		t.Fatalf("one Esc did not leave the untracked page (top=%d)", got2.top())
	}
}
