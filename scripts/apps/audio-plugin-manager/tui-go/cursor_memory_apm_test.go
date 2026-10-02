package main

import (
	"testing"

	"mosquitomarchy.local/tui-kit"
)

// The reported bug: toggle one executable, and the list throws you back to row
// 0 — so toggling several means walking the column again each time.
func TestToggleKeepsItsRow(t *testing.T) {
	m := initialModel()
	m.w, m.h = 120, 40
	m.nav = []screen{scrMain, scrExecsToggle}
	m.picker = tuikit.NewPicker("execs", []tuikit.PickerItem{
		{Display: "SubLabXL", Value: "a"},
		{Display: "RX 11", Value: "b"},
		{Display: "Neuron", Value: "c"},
	}).SetSize(m.contentSize()).SelectIndex(2)

	// The rebuild the toggle causes: fresh data, same rows.
	m.rebuildPicker(func(tuikit.Picker) tuikit.Picker {
		return tuikit.NewPicker("execs", []tuikit.PickerItem{
			{Display: "SubLabXL", Value: "a"},
			{Display: "RX 11", Value: "b"},
			{Display: "Neuron", Value: "c"},
		}).SetSize(m.contentSize())
	})

	if m.picker.SelectedValue() != "c" {
		t.Errorf("after a rebuild the cursor is on %q, want Neuron", m.picker.SelectedValue())
	}
}

// Leave a screen and come back: the row you were on is the row you get.
func TestLeavingAndReturningKeepsTheRow(t *testing.T) {
	m := initialModel()
	m.w, m.h = 120, 40
	m.nav = []screen{scrMain, scrExecsToggle}
	m.picker = tuikit.NewPicker("execs", []tuikit.PickerItem{
		{Display: "SubLabXL", Value: "a"},
		{Display: "RX 11", Value: "b"},
		{Display: "Neuron", Value: "c"},
	}).SetSize(m.contentSize()).SelectValue("b")

	m.pop() // leave for the menu: the position is remembered
	if m.top() != scrMain {
		t.Fatalf("did not reach the menu")
	}

	m.push(scrExecsToggle) // come back to the same list
	m.rebuildPicker(func(tuikit.Picker) tuikit.Picker {
		return tuikit.NewPicker("execs", []tuikit.PickerItem{
			{Display: "SubLabXL", Value: "a"},
			{Display: "RX 11", Value: "b"},
			{Display: "Neuron", Value: "c"},
		}).SetSize(m.contentSize())
	})
	if m.picker.SelectedValue() != "b" {
		t.Errorf("coming back landed on %q, want RX 11", m.picker.SelectedValue())
	}
}
