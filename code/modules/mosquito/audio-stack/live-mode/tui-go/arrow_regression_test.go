package main

import (
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

// TestArrowCycleReturnsModelType is a regression guard for a crash the user hit
// repeatedly: pressing Left or Right on a setting killed the TUI.
//
// cycleSetting had a POINTER receiver and returned `m`, so it handed the
// runtime a *model where every other step returns a model. Bubble Tea
// type-asserts whatever Update returns back to the concrete model type, and
// that assertion panicked — so the only key path that reached this function
// was the only one that crashed. Asserting on the returned type (rather than
// only that the call returns) is what makes this fail loudly if the signature
// drifts back.
func TestArrowCycleReturnsModelType(t *testing.T) {
	m := initialModel()
	res, _ := m.update(tea.WindowSizeMsg{Width: 100, Height: 30})
	m = res.(model)

	for i := 0; i < len(m.mainItems()); i++ {
		m.picker = m.picker.SelectIndex(i)
		// cycleSetting must hand back a value model, never a *model.
		out, cmd := m.cycleSetting(1)
		if _, ok := out.(model); !ok {
			t.Fatalf("cycleSetting returned %T, want main.model (a *model crashes the runtime)", out)
		}
		_ = out
		if cmd != nil {
			_ = cmd()
		}
	}
}
