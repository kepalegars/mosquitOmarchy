package main

import (
	"testing"

	tea "github.com/charmbracelet/bubbletea"

	"mosquitomarchy.local/tui-kit"
)

// Toggling must not move the cursor. The row you changed is the row you stay
// on — toggling the FIRST one used to land on the second.
func TestToggleDoesNotMoveTheCursor(t *testing.T) {
	items := []ExecToggleItem{
		{Display: "SubLabXL.exe", Value: "/x/SubLabXL.exe", Shown: true},
		{Display: "RX 11.exe", Value: "/x/RX11.exe", Shown: false},
		{Display: "Neuron.exe", Value: "/x/Neuron.exe", Shown: false},
	}

	m := initialModel()
	m.w, m.h = 120, 40
	m.nav = []screen{scrMain, scrExecsToggle}
	m.picker = tuikit.NewPicker("execs", execItemsToPicker(items)).
		SetSize(m.contentSize()).SelectIndex(0)

	// The kit turns the key into a toggle message; see whether it also moved.
	np, cmd := m.picker.Update(tea.KeyMsg{Type: tea.KeyTab})
	m.picker = np
	if cmd == nil {
		t.Fatalf("tab produced no command")
	}
	_, ok := cmd().(tuikit.PickerToggleMsg)
	if !ok {
		t.Fatalf("tab produced %T, want PickerToggleMsg", cmd())
	}
	if m.picker.Index() != 0 {
		t.Fatalf("the kit itself moved the cursor to %d", m.picker.Index())
	}

	// The rebuild the toggle causes: the first row's mark flipped.
	after := []ExecToggleItem{
		{Display: "SubLabXL.exe", Value: "/x/SubLabXL.exe", Shown: false},
		{Display: "RX 11.exe", Value: "/x/RX11.exe", Shown: false},
		{Display: "Neuron.exe", Value: "/x/Neuron.exe", Shown: false},
	}
	m.rebuildPicker(func(tuikit.Picker) tuikit.Picker {
		return tuikit.NewPicker("execs", execItemsToPicker(after)).SetSize(m.contentSize())
	})

	if m.picker.SelectedValue() != "/x/SubLabXL.exe" {
		t.Errorf("after toggling the first row the cursor is on %q, want SubLabXL",
			m.picker.SelectedValue())
	}
}

// The whole path, through Update, for both keys that toggle: the row you
// changed is the row you stay on.
func TestToggleThroughUpdateKeepsTheRow(t *testing.T) {
	for _, key := range []tea.KeyMsg{
		{Type: tea.KeyTab},
		{Type: tea.KeyRunes, Runes: []rune{'x'}},
		{Type: tea.KeyEnter},
	} {
		items := []ExecToggleItem{
			{Display: "SubLabXL.exe", Value: "/x/SubLabXL.exe", Shown: true},
			{Display: "RX 11.exe", Value: "/x/RX11.exe", Shown: false},
			{Display: "Neuron.exe", Value: "/x/Neuron.exe", Shown: false},
		}
		m := initialModel()
		m.w, m.h = 120, 40
		m.nav = []screen{scrMain, scrExecsToggle}
		m.picker = tuikit.NewPicker("execs", execItemsToPicker(items)).SetSize(m.contentSize())

		out, cmd := m.update(key)
		if cmd == nil {
			continue
		}
		msg := cmd()
		if _, is := msg.(execToggleMsg); !is {
			continue
		}
		// Feed the re-list back in, with the first row's mark flipped.
		et, _ := msg.(execToggleMsg)
		et.items = []ExecToggleItem{
			{Display: "SubLabXL.exe", Value: "/x/SubLabXL.exe", Shown: false},
			{Display: "RX 11.exe", Value: "/x/RX11.exe", Shown: false},
			{Display: "Neuron.exe", Value: "/x/Neuron.exe", Shown: false},
		}
		out2, _ := out.(model).update(et)
		got := out2.(model)
		if got.picker.SelectedValue() != "/x/SubLabXL.exe" {
			t.Errorf("key %v: after toggling the first row the cursor is on %q, want SubLabXL",
				key.Type, got.picker.SelectedValue())
		}
	}
}

// Entering the screen from a row of the MAIN menu must not import that row.
//
// This is the reported bug: the first rebuild after entering is handed the
// main-menu picker, and its row was saved under the executable screen's key.
// The restore then looked for a main-menu row in the executable list, missed,
// and fell back to that index — so entering from main-menu row 1 put the cursor
// on executable row 1, and the first toggle appeared to move it.
func TestEnteringFromAnotherScreenDoesNotImportItsRow(t *testing.T) {
	main := []tuikit.PickerItem{
		{Display: "Installed plugins", Value: "list"},
		{Display: "Install a plugin", Value: "install"},
		{Display: "Settings", Value: "settings"},
	}
	execs := []tuikit.PickerItem{
		{Display: "●  SubLabXL.exe", Value: "/x/a.exe"},
		{Display: "○  RX 11.exe", Value: "/x/b.exe"},
		{Display: "○  Neuron.exe", Value: "/x/c.exe"},
	}

	m := initialModel()
	m.w, m.h = 120, 40
	m.nav = []screen{scrMain}
	// The user walks to row 1 of the main menu, then enters the screen.
	m.picker = tuikit.NewPicker("main", main).SetSize(m.contentSize()).SelectIndex(1)

	m.push(scrExecsToggle)
	m.rebuildPicker(func(tuikit.Picker) tuikit.Picker {
		return tuikit.NewPicker("execs", execs).SetSize(m.contentSize())
	})

	if m.picker.Index() != 0 {
		t.Fatalf("entering the screen landed on row %d (%q), want row 0",
			m.picker.Index(), m.picker.SelectedValue())
	}

	// And the first toggle keeps it there.
	m.rebuildPicker(func(tuikit.Picker) tuikit.Picker {
		return tuikit.NewPicker("execs", []tuikit.PickerItem{
			{Display: "○  SubLabXL.exe", Value: "/x/a.exe"},
			{Display: "○  RX 11.exe", Value: "/x/b.exe"},
			{Display: "○  Neuron.exe", Value: "/x/c.exe"},
		}).SetSize(m.contentSize())
	})
	if m.picker.SelectedValue() != "/x/a.exe" {
		t.Errorf("after the first toggle the cursor is on %q, want SubLabXL", m.picker.SelectedValue())
	}
}
