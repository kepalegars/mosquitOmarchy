package main

import "testing"

// A GLOBAL fix is recorded under the marker "__global__", which the per-plugin
// list filters out on purpose. That filter used to be the only source the fixes
// screen had, so an applied global fix read as "not applied": its list was
// empty, and empty is exactly what off looks like.
//
// These tests pin the two halves: a global fix is never PARTIAL, and its mark
// comes from the separate global-state map.
func TestGlobalFixIsNeverPartial(t *testing.T) {
	g := FixItem{ID: "cursor_no_warp", Scope: "global", AppliedTo: nil, Candidates: 21}
	if g.IsPartial() {
		t.Error("a global fix must never be partial — it is on for the whole desktop or off")
	}
	// Even when a merge hands it a plugin list, a global scope must ignore it.
	g2 := FixItem{ID: "cursor_no_warp", Scope: "global", AppliedTo: []string{"a"}, Candidates: 21}
	if g2.IsPartial() {
		t.Error("a global fix with a stray AppliedTo must still not be partial")
	}
	// A per-plugin fix keeps the ◐ behaviour.
	p := FixItem{ID: "wine_gui_input", Scope: "plugin", AppliedTo: []string{"a"}, Candidates: 21}
	if !p.IsPartial() {
		t.Error("a per-plugin fix on 1 of 21 must still be partial")
	}
}

func TestGlobalFixMarkFollowsGlobalState(t *testing.T) {
	it := FixItem{ID: "cursor_no_warp", Scope: "global"}
	checked := map[string]bool{"cursor_no_warp": true}
	orig := map[string]bool{"cursor_no_warp": true}

	on := fixMarkOf(it, checked, orig, nil, map[string]bool{"cursor_no_warp": true})
	if on != "●" {
		t.Errorf("an applied global fix drew %q, want ●", on)
	}
	off := fixMarkOf(it, checked, orig, nil, map[string]bool{})
	if off != "●" {
		t.Errorf("with the global state empty it still drew %q; the mark must not come from the per-plugin map alone", off)
	}
}

func TestFixAppliedNoteGlobalSaysGlobal(t *testing.T) {
	m := model{fixGlobalApplied: map[string]bool{"cursor_no_warp": true}, fixVendor: "FabFilter", fixVendorPlugins: []string{"a", "b"}}
	n := m.fixAppliedNote(FixItem{ID: "cursor_no_warp", Scope: "global"})
	if !contains(n, "already applied") || !contains(n, "global rule") {
		t.Errorf("note = %q, want an explicit 'already applied / global rule' line", n)
	}
	m2 := model{fixVendor: "FabFilter", fixVendorPlugins: []string{"a"}}
	n2 := m2.fixAppliedNote(FixItem{ID: "cursor_no_warp", Scope: "global"})
	if !contains(n2, "not applied") {
		t.Errorf("note = %q, want 'not applied' when the global state is empty", n2)
	}
}

func contains(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}
