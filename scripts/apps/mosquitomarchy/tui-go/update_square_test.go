package main

import "testing"

// updateSquareOnMainRow reports whether the main menu's Update row currently
// carries the pending-update square.
func updateSquareOnMainRow(m model) bool {
	for _, it := range m.mainPicker.items {
		if it.Value == "update" {
			return it.TrailingBadge == "■"
		}
	}
	return false
}

// TestUpdateSquareFollowsChecks: the main-menu square appears as soon as a
// check reporting something lands — whatever screen is on top — and clears
// as soon as a check reporting nothing lands. Regression test: the menu was
// only rebuilt when it was the current screen, so the square showed up late
// (or never) and stayed stuck after an apply finished under the confirm.
func TestUpdateSquareFollowsChecks(t *testing.T) {
	m := initialModel()
	m.nav = []screen{scrMain, scrUpdate}
	m.w, m.h = 100, 34
	m.mainPicker = m.rebuildMainMenu()
	if updateSquareOnMainRow(m) {
		t.Fatalf("square present before any check")
	}
	m, _ = m.update(queryMsg{kind: "update", update: UpdateRec{RepoUpdate: true}})
	if !updateSquareOnMainRow(m) {
		t.Fatalf("square missing although the check found a repo update (top=%v)", m.top())
	}
	m, _ = m.update(queryMsg{kind: "update", update: UpdateRec{}})
	if updateSquareOnMainRow(m) {
		t.Fatalf("square stuck after a clean check")
	}
}
