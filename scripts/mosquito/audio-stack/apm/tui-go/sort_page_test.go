package main

import "testing"

// Each page keeps its OWN sort, and it survives the visit.
func TestSortIsPerPage(t *testing.T) {
	if got := sortModesFor("uninstall"); len(got) != 2 {
		t.Errorf("the uninstall page offers %d orders (%v), want vendor+name only", len(got), got)
	}
	if got := sortModesFor("plugins"); len(got) != 4 {
		t.Errorf("the installed-plugins page offers %d orders, want 4", len(got))
	}

	// Stepping within a page wraps inside that page and never lands on an order
	// the page does not offer.
	cur := "vendor"
	for i := 0; i < 6; i++ {
		cur = stepSortModeFor("uninstall", cur, 1)
		if cur != "vendor" && cur != "name" {
			t.Fatalf("the uninstall page cycled to %q", cur)
		}
	}
	cur = "vendor"
	for i := 0; i < 5; i++ {
		cur = stepSortModeFor("plugins", cur, 1)
	}
	if cur != "name" {
		t.Errorf("five steps from vendor on the plugins page gave %q, want name", cur)
	}
}

// The two screens of the Fixes flow share one key on purpose — they are the
// same page at two steps — but the three pages must not share with each other,
// or they drift back into one value and `s` looks broken again.
func TestPagesMapToDistinctKeys(t *testing.T) {
	seen := map[string]screen{}
	for _, s := range []screen{scrPluginList, scrUninstallPick, scrFixPluginPick, scrFixChoose} {
		p := sortPage(s)
		if first, dup := seen[p]; dup {
			t.Logf("screens %d and %d share %q, which is intended for one flow", first, s, p)
			continue
		}
		seen[p] = s
	}
	if len(seen) != 3 {
		t.Errorf("%d distinct sort keys for 3 pages: %v", len(seen), seen)
	}
}
