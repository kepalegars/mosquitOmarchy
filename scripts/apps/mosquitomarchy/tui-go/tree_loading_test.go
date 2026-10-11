package main

import "testing"

// TestTreeLoadingSurvivesBlink: while a tree fetch is in flight the picker
// keeps its loading row, even when the 600ms mosquito blink rebuilds it.
// Regression test: the blink rebuilt from not-yet-arrived data and wiped the
// indicator, so slow trees (uninstall) showed a blank page with no loading
// sign at all.
func TestTreeLoadingSurvivesBlink(t *testing.T) {
	m := initialModel()
	m.nav = []screen{scrMain, scrSetup}
	m.w, m.h = 100, 34
	m.treeMode = "uninstall"
	m.treeLoading = true
	m.setupPicker = loadingTreePicker(m)
	m, _ = m.update(blinkMsg{})
	m.setupPicker = m.rebuildSetup()
	found := false
	for _, it := range m.setupPicker.items {
		if it.Display == "loading…" {
			found = true
		}
	}
	if !found {
		t.Fatalf("loading row wiped while treeLoading")
	}
	// Arrival clears the flag and the real tree paints.
	m, _ = m.update(setupMsg{folders: []FolderRec{{Folder: "apps", Label: "Apps"}}})
	if m.treeLoading {
		t.Fatalf("treeLoading still set after arrival")
	}
}
