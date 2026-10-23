package main

import (
	"strings"
	"testing"

	"mosquitomarchy.local/tui-kit"
)

// Leaving the untracked page with Esc must show the MAIN MENU.
//
// m.picker is one field every screen writes to, so the orphan rows stayed on
// it: the menu rendered with the plugin NAMES where its own options belonged,
// and it took two more Esc presses to get back a usable menu.
func TestEscFromUntrackedShowsTheMainMenu(t *testing.T) {
	m := initialModel()
	m.w, m.h = 120, 40
	m.nav = []screen{scrMain, scrReconcileOrphansTick}

	// The orphan page fills the shared picker with its own rows.
	m.picker = tuikit.NewPicker("Found on disk but not tracked",
		[]tuikit.PickerItem{
			{Display: "iZotope/Neutron 5.vst3", Value: "a"},
			{Display: "RX 11 Connect.vst3", Value: "b"},
		}).SetSize(m.contentSize())

	m.pop()

	if m.top() != scrMain {
		t.Fatalf("left on screen %d, want the main menu", m.top())
	}
	view := m.picker.View()
	for _, want := range mainItems() {
		if want.Value == "back" || want.Value == "quit" {
			continue
		}
		if !strings.Contains(view, strings.TrimSpace(want.Display)) {
			t.Errorf("the main menu is missing %q; it shows:\\n%s", want.Display, view)
		}
	}
	if strings.Contains(view, "RX 11 Connect") {
		t.Errorf("an orphan row survived on the main menu:\\n%s", view)
	}
}

// The same leak in the other direction: entering a screen and coming back must
// not hand the main menu somebody else's rows either.
func TestPushThenPopRestoresTheMainMenu(t *testing.T) {
	m := initialModel()
	m.w, m.h = 120, 40
	m.nav = []screen{scrMain}
	m.syncPickerToTop()

	m.push(scrReconcileOrphansTick)
	m.picker = tuikit.NewPicker("x", []tuikit.PickerItem{{Display: "LEAKED", Value: "x"}}).SetSize(m.contentSize())
	m.pop()

	if strings.Contains(m.picker.View(), "LEAKED") {
		t.Errorf("the main menu still shows the other screen's row:\\n%s", m.picker.View())
	}
}
