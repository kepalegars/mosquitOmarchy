package main

import (
	"strings"
	"testing"

	tuikit "mosquitomarchy.local/tui-kit"
)

// Esc has to be able to leave the plugin-fixes page, whichever route you took
// into a fix list.
//
// The vendor route used to REPLACE the nav stack instead of pushing, so
// scrFixPluginPick became the bottom of it, and pop() is a no-op at depth 1 —
// Esc on that screen could never go anywhere. It read as being stuck, and it
// was: the only way out was to pick another fix.
func TestEscLeavesTheVendorFixRoute(t *testing.T) {
	m := partialFixture()
	// The real stack when the user is on the plugin list and picks a suite.
	m.nav = []screen{scrMain, scrFixPluginPick}
	m.fixPluginCache = []PluginItem{
		{Kind: "folder", Value: "vendor:FabFilter", Display: "FabFilter"},
		{Kind: "plugin", Value: "vst:vst2:/x/One.dll", Display: "FabFilter One", Vendor: "FabFilter", Parent: "vendor:FabFilter"},
	}
	m.pluginChecked = map[string]bool{}
	m.pluginOrig = map[string]bool{}

	// Enter on the vendor row.
	mm, _ := m.Update(tuikit.PickerResultMsg{Value: "vendor:FabFilter"})
	got, _ := mm.(model)
	if got.top() != scrFixChoose {
		t.Fatalf("Enter on a vendor did not open the fixes list (top=%d)", got.top())
	}
	if got.fixVendor != "FabFilter" {
		t.Fatal("the vendor scope was not recorded")
	}

	// Back out of the fixes list.
	mm2, _ := got.Update(tuikit.PickerResultMsg{Canceled: true})
	got2, _ := mm2.(model)
	if got2.top() != scrFixPluginPick {
		t.Fatalf("Esc from the fixes list landed on %d", got2.top())
	}
	// And back out of the plugin chooser, to the screen we came from. This is
	// the step that could not happen before.
	mm3, _ := got2.Update(tuikit.PickerResultMsg{Canceled: true})
	got3, _ := mm3.(model)
	if got3.top() != scrMain {
		t.Fatalf("Esc from the plugin chooser landed on %d, want the main menu", got3.top())
	}
}

// The same guarantee for the single-plugin route, so the fix is not a one-off.
func TestEscLeavesTheSinglePluginFixRoute(t *testing.T) {
	m := model{
		nav: []screen{scrMain, scrFixPluginPick, scrFixChoose},
		fixPluginCache: []PluginItem{
			{Kind: "plugin", Value: "vst:vst2:/x/One.dll", Display: "FabFilter One"},
		},
		pluginChecked: map[string]bool{}, pluginOrig: map[string]bool{},
	}
	mm, _ := m.Update(tuikit.PickerResultMsg{Canceled: true})
	got, _ := mm.(model)
	if got.top() != scrFixPluginPick {
		t.Fatalf("Esc landed on %d", got.top())
	}
	mm2, _ := got.Update(tuikit.PickerResultMsg{Canceled: true})
	got2, _ := mm2.(model)
	if got2.top() != scrMain {
		t.Fatalf("Esc landed on %d, want the main menu", got2.top())
	}
}

// The half circle exists to say "not all of them". Acting on that row has to do
// something, and it has to ask first.
//
// The delta used to be `checked && !applied`, so a partial fix — on for some of
// the plugins, marked on — produced no change at all. Enter answered "no change"
// and wrote nothing, so the one row that existed to report an unfinished job
// was the one row that could never be started.
func TestOverridingAPartialFixAsksFirst(t *testing.T) {
	m := partialFixture()
	m.nav = []screen{scrFixChoose}
	// The user unticks and re-ticks the half-circle row: a decision to complete
	// it rather than leave it as it is.
	m.fixTouched = map[string]bool{"wine_saturn_eq": true}

	mm, _ := m.Update(tuikit.PickerResultMsg{Value: "wine_saturn_eq"})
	got, _ := mm.(model)
	if got.top() != scrFixApplyConfirm {
		t.Fatalf("overriding a partial fix did not ask: top=%d", got.top())
	}
	if len(got.fixPendingApply) != 1 || got.fixPendingApply[0] != "wine_saturn_eq" {
		t.Errorf("the pending apply is %v, want the partial fix", got.fixPendingApply)
	}
	// The dialog has to say WHICH plugins are about to be written, and that
	// the other one is not being touched.
	v := got.confirm.View()
	if !strings.Contains(v, "already applied") {
		t.Errorf("the dialog does not separate the already-fixed plugin:\n%s", v)
	}
}

// Untouched partial rows must stay quiet, or every Enter on the page would
// re-offer to complete every half-filled row the catalog happens to hold.
func TestUntouchedPartialRowsAreNotPending(t *testing.T) {
	m := partialFixture()
	m.nav = []screen{scrFixChoose}
	mm, _ := m.Update(tuikit.PickerResultMsg{Value: "wine_banner"})
	got, _ := mm.(model)
	if got.top() == scrFixApplyConfirm {
		t.Errorf("an untouched page opened the apply dialog: %v", got.fixPendingApply)
	}
	if !strings.Contains(got.toast.View(), "no change") {
		t.Errorf("expected the no-change answer, got %q", got.toast.View())
	}
}

// Completing a partial fix names the plugins still missing it. Saturn 2 is the
// only one carrying it, so the dialog has to say the suite is not left alone.
func TestCompletingAPartialFixNamesTheWholeSuite(t *testing.T) {
	m := partialFixture()
	c := m.fixApplyConfirm([]string{"wine_saturn_eq"}, nil)
	v := c.View()
	for _, n := range m.fixVendorPlugins {
		if !strings.Contains(v, n) {
			t.Errorf("%s is missing from the dialog:\n%s", n, v)
		}
	}
	if !strings.Contains(v, "FabFilter Saturn 2") || !strings.Contains(v, "already applied") {
		t.Errorf("the dialog does not mark the plugin that already has it:\n%s", v)
	}
}
