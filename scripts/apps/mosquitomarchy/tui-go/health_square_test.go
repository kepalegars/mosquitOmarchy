package main

import "testing"

// healthSquareOnMainRow reports whether the main menu's Health check row
// currently carries the pending-fix square.
func healthSquareOnMainRow(m model) bool {
	for _, it := range m.mainPicker.items {
		if it.Value == "health" {
			return it.TrailingBadge == "■"
		}
	}
	return false
}

// TestHealthSquareFollowsLatestCheck: the main-menu square tracks the latest
// health result, never a stale one. Regression test: results only rebuilt
// the health page, so a finding seen once kept its square after being fixed
// (or showed up long after, when an unrelated rebuild picked the stale
// items up) — a square with nothing to repair inside.
func TestHealthSquareFollowsLatestCheck(t *testing.T) {
	m := initialModel()
	m.nav = []screen{scrMain}
	m.w, m.h = 100, 34
	m.mainPicker = m.rebuildMainMenu()

	// A finding lands while the menu is up: square appears.
	m, _ = m.update(healthMsg{items: []HealthRec{{ID: "hook", Label: "hook"}}})
	if !healthSquareOnMainRow(m) {
		t.Fatalf("square missing although the check found something")
	}
	// A clean check lands: square clears, even though nothing was opened.
	m, _ = m.update(healthMsg{})
	if healthSquareOnMainRow(m) {
		t.Fatalf("square stuck after a clean check")
	}
	// Opening Health drops stale findings first: no square while loading.
	m.healthItems = []HealthRec{{ID: "stale", Label: "stale"}}
	m.mainPicker = m.rebuildMainMenu()
	if !healthSquareOnMainRow(m) {
		t.Fatalf("setup: stale square expected before open")
	}
	m.healthItems = nil
	m.healthChecked = map[string]bool{}
	m.mainPicker = m.rebuildMainMenu()
	if healthSquareOnMainRow(m) {
		t.Fatalf("stale square survived opening Health")
	}
}
