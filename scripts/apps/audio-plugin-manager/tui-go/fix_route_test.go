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

// ONE toggle on a half-applied row is the override, and it asks first.
//
// Two states cannot describe a partial fix — it is on for some of the plugins,
// so both "on" and "off" are wrong answers for it. The row therefore cycles
// ◐ -> ● -> ○ -> ◐, which makes the FIRST Tab "make it complete". The user had
// to untick and re-tick to express that before, and the row kept drawing ◐ while
// the plan underneath it said every plugin.
func TestOneToggleOnAPartialRowIsTheOverride(t *testing.T) {
	m := partialFixture()
	m.nav = []screen{scrFixChoose}
	m.rebuildFixPicker()

	// The row starts as the half circle.
	rows := fixItemsToPicker(sortedFixItems(m.fixCache, false), m.fixChecked, m.fixOrig, m.fixOverride, map[string]bool{"Plugin windows": true})
	if got := markOf(t, rows, "Saturn 2 EQ page"); got != "◐" {
		t.Fatalf("the row starts as %q, want ◐", got)
	}

	// ONE Tab.
	m.toggleFixValue("wine_saturn_eq")
	rows = fixItemsToPicker(sortedFixItems(m.fixCache, false), m.fixChecked, m.fixOrig, m.fixOverride, map[string]bool{"Plugin windows": true})
	if got := markOf(t, rows, "Saturn 2 EQ page"); got != "●" {
		t.Errorf("after one toggle the row is %q, want ● — the circle should FILL", got)
	}

	// And it asks before doing anything.
	mm, _ := m.Update(tuikit.PickerResultMsg{Value: "wine_saturn_eq"})
	got, _ := mm.(model)
	if got.top() != scrFixApplyConfirm {
		t.Fatalf("one toggle did not ask: top=%d", got.top())
	}
	if len(got.fixPendingApply) != 1 || got.fixPendingApply[0] != "wine_saturn_eq" {
		t.Errorf("the pending apply is %v, want the partial fix", got.fixPendingApply)
	}
	// The dialog says which plugins are about to be written, and that the one
	// already carrying the fix is left alone.
	v := got.confirm.View()
	if !strings.Contains(v, "will NOT be touched") {
		t.Errorf("the dialog does not say the already-fixed plugin is left alone:\n%s", v)
	}
}

// The second toggle takes it the other way — off everywhere it is recorded — and
// the third puts it back to following the record. A three-state row has to come
// back around, or there is no way to change your mind.
func TestAPartialRowCyclesBothWays(t *testing.T) {
	m := partialFixture()
	m.rebuildFixPicker()
	rows := func() []tuikit.PickerItem {
		return fixItemsToPicker(sortedFixItems(m.fixCache, false), m.fixChecked, m.fixOrig, m.fixOverride, map[string]bool{"Plugin windows": true})
	}
	m.toggleFixValue("wine_saturn_eq")
	if got := markOf(t, rows(), "Saturn 2 EQ page"); got != "●" {
		t.Fatalf("toggle 1 = %q, want ●", got)
	}
	m.toggleFixValue("wine_saturn_eq")
	if got := markOf(t, rows(), "Saturn 2 EQ page"); got != "○" {
		t.Errorf("toggle 2 = %q, want ○", got)
	}
	if m.fixOverride["wine_saturn_eq"] != 2 {
		t.Errorf("toggle 2 should be the remove override, got %d", m.fixOverride["wine_saturn_eq"])
	}
	m.toggleFixValue("wine_saturn_eq")
	if got := markOf(t, rows(), "Saturn 2 EQ page"); got != "◐" {
		t.Errorf("toggle 3 = %q, want ◐ back to the recorded state", got)
	}
}

// A row that is NOT partial keeps the plain two-state Tab it always had.
func TestAFullRowKeepsItsPlainToggle(t *testing.T) {
	m := partialFixture()
	m.rebuildFixPicker()
	rows := func() []tuikit.PickerItem {
		return fixItemsToPicker(sortedFixItems(m.fixCache, false), m.fixChecked, m.fixOrig, m.fixOverride, map[string]bool{"Plugin windows": true})
	}
	if got := markOf(t, rows(), "Retitle the window"); got != "●" {
		t.Fatalf("the full row starts as %q, want ●", got)
	}
	m.toggleFixValue("wine_gui_input")
	if got := markOf(t, rows(), "Retitle the window"); got != "○" {
		t.Errorf("a plain row toggled to %q, want ○", got)
	}
	if m.fixOverride["wine_gui_input"] != 0 {
		t.Errorf("a non-partial row should not use the override, got %d", m.fixOverride["wine_gui_input"])
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

// Completing a partial fix must write ONLY to the plugins that do not have it.
//
// This is the whole point. Completing a half-applied fix used to go through the
// vendor-wide "apply to every plugin of the folder" call, so the two plugins
// that already carried it were rewritten as well and the row went from ◐ to ●
// in one step. The user reported exactly that: changing the state of a fix
// already present in the group overrode the whole group's settings.
func TestCompletingAPartialFixWritesOnlyToTheMissingPlugins(t *testing.T) {
	m := partialFixture()
	c := m.fixApplyConfirm([]string{"wine_saturn_eq"}, nil)
	v := c.View()

	// Saturn 2 is the one that HAS it, so it must not be in the list of what
	// will be written.
	if strings.Contains(v, "will be written") && strings.Contains(v, "FabFilter Saturn 2") {
		// Only acceptable if the wording makes it an explicit exclusion, which
		// it does not: the list is what will be touched.
		t.Errorf("the dialog offers to rewrite the plugin that already has the fix:\n%s", v)
	}
	// The two that do NOT have it are the whole point of the operation.
	for _, n := range []string{"FabFilter One", "FabFilter Pro-Q 4"} {
		if !strings.Contains(v, n) {
			t.Errorf("%s is missing from the dialog:\n%s", n, v)
		}
	}
}

// And the execution targets those two, not the suite.
func TestCompletingAPartialFixAppliesToTheMissingPluginsOnly(t *testing.T) {
	m := partialFixture()
	got := m.fixApplyLabels("wine_saturn_eq")
	want := []string{"FabFilter One", "FabFilter Pro-Q 4"}
	if len(got) != len(want) {
		t.Fatalf("apply targets = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("apply targets = %v, want %v", got, want)
			break
		}
	}
}

// Un-ticking a partial fix strips it from the plugins that DO have it — the
// other half of the same rule.
func TestUntickingAPartialFixStripsOnlyTheOnesThatHaveIt(t *testing.T) {
	m := partialFixture()
	got := m.fixRemoveLabels("wine_saturn_eq")
	if len(got) != 1 || got[0] != "FabFilter Saturn 2" {
		t.Errorf("remove targets = %v, want [FabFilter Saturn 2]", got)
	}
}

// A fix that is on NOWHERE in the selection still means "the whole suite", which
// is the gesture the vendor visit exists for. The targeted path must not have
// narrowed that.
func TestAnUnappliedFixStillTargetsTheWholeSuite(t *testing.T) {
	m := partialFixture()
	got := m.fixApplyLabels("wine_banner")
	if len(got) != len(m.fixVendorPlugins) {
		t.Errorf("an unapplied fix targets %d plugin(s), want the whole suite (%d)", len(got), len(m.fixVendorPlugins))
	}
}

// And un-ticking a full fix on a vendor visit has to work at all. It used to
// fall through to a removal naming no plugin — m.fixPlugin is empty on a vendor
// visit — and fail with "plugin required".
func TestUntickingAFullFixOnAVendorVisitHasTargets(t *testing.T) {
	m := partialFixture()
	got := m.fixRemoveLabels("wine_gui_input")
	if len(got) != 3 {
		t.Errorf("removing a fully-applied fix targets %v, want every plugin that has it", got)
	}
}

// The dialog must still name what it is about to touch.
func TestPartialDialogNamesThePluginsItWillTouch(t *testing.T) {
	m := partialFixture()
	c := m.fixApplyConfirm([]string{"wine_saturn_eq"}, nil)
	v := c.View()
	if !strings.Contains(v, "plugin") {
		t.Errorf("the dialog never says how many plugins are involved:\n%s", v)
	}
}
