package main

import "testing"

// The fixes catalog splits into generic fixes (no `plugin`) and
// product-specific fixes (scoped to one product). The picker must show the
// generic ones first in their own categories, then a separator + "Plugin
// specific fixes" title, then one group per product labelled by the product
// name alone.
func TestFixPickerSplitsPluginSpecificBelow(t *testing.T) {
	items := []FixItem{
		// generic (no plugin) — should stay up top, in their categories
		{ID: "cursor_no_warp", Title: "Cursor", Scope: "global", Category: "Cursor"},
		{ID: "wine_gui_input", Title: "Wine GUI input", Scope: "plugin", Category: "Plugin windows"},
		// product-specific — must move to the bottom, grouped by plugin name
		{ID: "wine_tooltip", Title: "Ableton/Wine tooltips", Scope: "plugin", Category: "CrispyTuner specific", Plugin: "CrispyTuner"},
		{ID: "serum_fix", Title: "DirectComposition", Scope: "plugin", Category: "Serum 2 specific", Plugin: "Serum 2"},
	}
	checked := map[string]bool{}
	// Expand every group so children render.
	expanded := map[string]bool{
		"Cursor": true, "Plugin windows": true, "CrispyTuner": true, "Serum 2": true,
	}

	rows := fixItemsToPicker(items, checked, expanded)
	var displays []string
	for _, r := range rows {
		displays = append(displays, r.Display)
	}

	find := func(sub string) int {
		for i, d := range displays {
			if d == sub {
				return i
			}
		}
		return -1
	}

	sep := find(fixSeparator())
	title := find("Plugin specific fixes")
	if sep == -1 {
		t.Fatalf("separator row missing; got %v", displays)
	}
	if title == -1 {
		t.Fatalf("'Plugin specific fixes' title row missing; got %v", displays)
	}
	if title != sep+1 {
		t.Errorf("title must directly follow the separator; sep=%d title=%d", sep, title)
	}
	// The separator is non-selectable; the title is an accent heading.
	if !rows[sep].Disabled {
		t.Errorf("separator must be a Disabled row")
	}
	if !rows[title].Accent {
		t.Errorf("title must use the theme accent (PickerItem.Accent)")
	}

	// Generic category headers must appear BEFORE the separator.
	for _, cat := range []string{"▾ ○  Cursor", "▾ ○  Plugin windows"} {
		i := find(cat)
		if i == -1 || i > sep {
			t.Errorf("generic category %q should be above the separator (i=%d sep=%d)", cat, i, sep)
		}
	}
	// Product groups must appear AFTER the title, labelled by plugin name only.
	crispy := find("▾ ○  CrispyTuner")
	serum := find("▾ ○  Serum 2")
	if crispy == -1 || crispy < title {
		t.Errorf("CrispyTuner group should be under the specific title (i=%d title=%d)", crispy, title)
	}
	if serum == -1 || serum < title {
		t.Errorf("Serum 2 group should be under the specific title (i=%d title=%d)", serum, title)
	}
	// The catalog's own "<Product> specific" category label must NOT be used.
	for _, d := range displays {
		if d == "▾ ○  CrispyTuner specific" || d == "▾ ○  Serum 2 specific" {
			t.Errorf("must not render the catalog category label %q; the plugin name is the label", d)
		}
	}
}

// A catalog with no product-specific fixes must render exactly as before: no
// separator, no title, no extra section.
func TestFixPickerNoSpecificNoSection(t *testing.T) {
	items := []FixItem{
		{ID: "cursor_no_warp", Title: "Cursor", Scope: "global", Category: "Cursor"},
		{ID: "wine_gui_input", Title: "Wine GUI input", Scope: "plugin", Category: "Plugin windows"},
	}
	rows := fixItemsToPicker(items, map[string]bool{}, map[string]bool{"Cursor": true, "Plugin windows": true})
	for _, r := range rows {
		if r.Value == fixSeparatorValue || r.Value == fixSpecificTitleValue {
			t.Errorf("no specific fixes → no separator/title, got %q", r.Display)
		}
	}
}
