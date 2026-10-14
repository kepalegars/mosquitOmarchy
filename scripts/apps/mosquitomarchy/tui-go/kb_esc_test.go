package main

import (
	"strings"
	"testing"

	tuikit "mosquitomarchy.local/tui-kit"
)

// Esc on the custom-command inputs must leave the flow back to the
// categories. It used to toast and stay put, so Esc could never leave: every
// press just re-toasted on the same input, with no way back.
func TestEscLeavesTheCustomKeybindingFlow(t *testing.T) {
	for _, step := range []int{0, 1} {
		m := initialModel()
		m.nav = []screen{scrMain, scrKB, scrKBCat, scrKBInput}
		m.w, m.h = 100, 34
		m.kbInputStep = step
		mm, _ := m.update(tuikit.InputResultMsg{Canceled: true})
		if mm.top() != scrKBCat {
			t.Fatalf("step %d: Esc stayed on the input, top=%v", step, mm.top())
		}
		if mm.kbInputStep != 0 {
			t.Fatalf("step %d: input step not reset", step)
		}
	}
}

// The mosquito add-shortcut category: one opener per row through the same
// entry points as the Omarchy menu, no shell-launcher duplicate.
func TestMosquitoShortcutCategory(t *testing.T) {
	var cat *struct {
		ID    string
		Title string
		Items []KbCatItem
	}
	for i := range kbCatalog {
		if kbCatalog[i].ID == "mosquito" {
			c := kbCatalog[i]
			cat = &c
		}
	}
	if cat == nil {
		t.Fatal("no mosquito category in the add-shortcut catalog")
	}
	if kbCatLabel(cat.Title) != "mosquito" {
		t.Fatalf("category label = %q, want mosquito", kbCatLabel(cat.Title))
	}
	seen := map[string]bool{}
	for _, it := range cat.Items {
		seen[it.Label] = true
	}
	if !seen["mosquitOmarchy"] || !seen["JamJamJam"] {
		t.Fatalf("mosquito category = %v, want mosquitOmarchy + JamJamJam", seen)
	}
	for _, it := range cat.Items {
		if it.Label == "mosquitOmarchy (shell launcher)" {
			t.Fatal("shell launcher duplicate still present")
		}
	}
}

// Every add-shortcut category reads alphabetically by label, enforced here
// so no future addition can break the order.
func TestKbCatalogReadsAlphabetically(t *testing.T) {
	for _, c := range kbCatalog {
		for i := 1; i < len(c.Items); i++ {
			a, b := c.Items[i-1].Label, c.Items[i].Label
			if strings.ToLower(a) > strings.ToLower(b) {
				t.Fatalf("category %q: %q before %q", c.ID, a, b)
			}
		}
	}
}
