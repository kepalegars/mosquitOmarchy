package main

import (
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

// Refresh is a reserved home-page key now, not a menu row: the menu stays
// short, and r still triggers the same status fetch.
func TestRefreshIsAHomeShortcut(t *testing.T) {
	for _, it := range mainMenuItems(MoveStatus{}, false) {
		if it.Value == "refresh" {
			t.Fatal("the refresh row must be gone from the home menu")
		}
	}
	m := initialModel()
	res, cmd := m.updateScreen(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("r")})
	if !res.(model).loading {
		t.Fatal("r did not start a connection refresh")
	}
	if cmd == nil {
		t.Fatal("r returned no fetch command")
	}
}
