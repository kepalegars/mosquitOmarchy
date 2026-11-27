package main

import (
	"testing"

	tuikit "mosquitomarchy.local/tui-kit"
)

// The temp cleanup is a second, always-available row directly under the
// drive-letter cleanup in the Wine submenu, and its confirm renders.
func TestPrefixTempsRowAndConfirm(t *testing.T) {
	found := false
	for _, it := range vstMenuItems(Status{}) {
		if it.Value != "cleanup_prefix_temps" {
			continue
		}
		found = true
		if it.Disabled {
			t.Fatal("temp cleanup row must be available even on a tidy machine")
		}
	}
	if !found {
		t.Fatal("temp cleanup row missing from the Wine submenu")
	}

	m := initialModel()
	m.w, m.h = 120, 40
	m.nav = []screen{scrMain, scrVstMenu}
	next, _ := m.handleVstMenuChoice("cleanup_prefix_temps")
	mm, ok := next.(model)
	if !ok {
		t.Fatalf("handler returned %T, want model", next)
	}
	if got, want := mm.top(), scrPrefixTempsConfirm; got != want {
		t.Fatalf("top = %v, want scrPrefixTempsConfirm", got)
	}
	_ = mm.View()

	// "No" leaves the menu without triggering a cleanup.
	back, _ := mm.update(tuikit.ConfirmResultMsg{Yes: false})
	got := back.(model)
	if got.top() != scrVstMenu {
		t.Fatalf("cancel left screen %v, want scrVstMenu", got.top())
	}

	// "Yes" stays on the spinner screen — it must not fall back to the options
	// list before the result prompt appears.
	run, _ := mm.update(tuikit.ConfirmResultMsg{Yes: true})
	if got := run.(model).top(); got != scrPrefixTempsRunning {
		t.Fatalf("after Yes screen = %v, want scrPrefixTempsRunning", got)
	}
}
