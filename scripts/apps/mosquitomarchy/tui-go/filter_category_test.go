package main

import "testing"

// TestFilterCategoryNameListsItsOptions: typing a category name shows every
// option of that category, not just the rows carrying the word in their own
// label.
func TestFilterCategoryNameListsItsOptions(t *testing.T) {
	m := flatSetup()
	m.filterText = "mosquito"
	m.setupPicker = m.rebuildSetup()
	want := []string{
		setupValue("mosquito", "live-mode"),
	}
	for _, v := range want {
		if indexOfValue(m.setupPicker, v) < 0 {
			t.Fatalf("row %q missing when filtering by its category", v)
		}
	}
	// And a leaf query still matches leaves only.
	m.filterText = "reaper"
	m.setupPicker = m.rebuildSetup()
	if indexOfValue(m.setupPicker, setupValue("apps", "reaper")) < 0 {
		t.Fatalf("reaper row missing when filtering by its name")
	}
	if indexOfValue(m.setupPicker, setupValue("apps", "extracto")) >= 0 {
		t.Fatalf("extracto row should not match the reaper query")
	}
}
