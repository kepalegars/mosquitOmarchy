package main

import (
	"strings"
	"testing"

	tuikit "mosquitomarchy.local/tui-kit"
)

// A machine whose plugins predate the manager has an EMPTY log, so every one of
// them counts as an orphan and the startup sweep offers them again on EVERY
// launch. The user saw all of their plugins come back on each start.
//
// Adopt-once is the answer, and it lives in Settings because it is a one-shot
// action on the log, not something to be asked about repeatedly.
func TestAdoptPluginsIsOfferedInSettings(t *testing.T) {
	m := initialModel()
	found := false
	for _, it := range settingsItems(m.status) {
		if it.Value == "adopt_plugins" {
			found = true
			if !strings.Contains(strings.ToLower(it.Display), "track") {
				t.Errorf("the row does not say what it does: %q", it.Display)
			}
		}
	}
	if !found {
		t.Fatal("Settings has no adopt-plugins row")
	}
}

// Both startup sweeps must be able to come back with NOTHING, and then NOT
// push a screen at all. That is what "no longer a nag" means: the sweep runs,
// finds the log consistent with the disk, and leaves the user on the menu they
// were on.
//
// The check is on the NAV STACK, not on popping: the sweep is fired from the
// main menu before any reconcile screen exists, so "nothing to do" has to mean
// "nothing pushed", not "pushed and immediately popped".
func TestSweepsCanReturnNothing(t *testing.T) {
	m := initialModel()
	m.nav = []screen{scrMain}
	mm, _ := m.update(reconcileOrphansMsg{})
	got, _ := mm.(model)
	if got.top() != scrMain {
		t.Errorf("no orphans, yet a screen appeared (top=%d)", got.top())
	}

	mm2, _ := got.update(reconcileMissingMsg{})
	got2, _ := mm2.(model)
	if got2.top() != scrMain {
		t.Errorf("nothing missing, yet a screen appeared (top=%d)", got2.top())
	}
}

// And the converse, which is what the user actually hit: a pile of orphans
// DOES open a screen, once — grouped in one format folder per format, every
// folder open so its plugins read directly.
func TestSweepOpensFormatFoldersWhenThereIsSomethingToAdopt(t *testing.T) {
	m := initialModel()
	m.nav = []screen{scrMain}
	mm, _ := m.update(reconcileOrphansMsg{items: []Item{
		{Display: "FabFilter One", Value: "vst:vst2:/x/One.dll", Formats: "vst2,vst3"},
		{Display: "FabFilter Pro-Q 4", Value: "vst:vst3:/x/ProQ.vst3", Formats: "vst3"},
		{Display: "Some LV2", Value: "native:/home/u/.lv2/some.lv2", Formats: "lv2"},
	}})
	got, _ := mm.(model)
	if got.top() != scrReconcileOrphansTick {
		t.Fatalf("with three orphans no screen appeared (top=%d)", got.top())
	}
	// One's primary format is vst2, so the folders are vst2, vst3 and
	// lv2: 3 folders + 3 plugins = 6 rows.
	vals := map[string]bool{}
	for _, it := range got.picker.Items() {
		vals[it.Value] = true
	}
	for _, want := range []string{"orphan-folder:vst2", "orphan-folder:vst3", "orphan-folder:lv2",
		"vst:vst2:/x/One.dll", "vst:vst3:/x/ProQ.vst3", "native:/home/u/.lv2/some.lv2"} {
		if !vals[want] {
			t.Errorf("missing row %q (have %v)", want, vals)
		}
	}
	// A format with no orphans has no folder.
	if vals["orphan-folder:clap"] {
		t.Error("empty clap folder shown with no clap orphans")
	}
}

// Tab on a folder checks everything under it; Enter with nothing checked
// warns instead of tracking; the confirm names the batch.
func TestOrphanFolderTabAndConfirm(t *testing.T) {
	m := initialModel()
	m.nav = []screen{scrMain}
	mm, _ := m.update(reconcileOrphansMsg{items: []Item{
		{Display: "One", Value: "vst:vst2:/x/One.dll", Formats: "vst2"},
		{Display: "Two", Value: "vst:vst2:/x/Two.dll", Formats: "vst2"},
	}})
	got, _ := mm.(model)
	// Enter with nothing tab-checked: no confirm, no tracking.
	mm2, _ := got.update(tuikit.PickerResultMsg{Value: "vst:vst2:/x/One.dll"})
	got2, _ := mm2.(model)
	if got2.top() == scrOrphansConfirm {
		t.Fatal("confirm opened with nothing checked")
	}
	// Tab on the folder checks both children.
	mm3, _ := got2.update(tuikit.PickerToggleMsg{Value: "orphan-folder:vst2"})
	got3, _ := mm3.(model)
	if !got3.orphanChecked["vst:vst2:/x/One.dll"] || !got3.orphanChecked["vst:vst2:/x/Two.dll"] {
		t.Fatalf("folder tab did not check both: %v", got3.orphanChecked)
	}
	// Enter opens the batch confirm, not a tracking call.
	mm4, _ := got3.update(tuikit.PickerResultMsg{Value: "vst:vst2:/x/One.dll"})
	got4, _ := mm4.(model)
	if got4.top() != scrOrphansConfirm {
		t.Fatalf("no batch confirm (top=%d)", got4.top())
	}
	// Declining tracks nothing.
	mm5, _ := got4.update(tuikit.ConfirmResultMsg{Yes: false})
	got5, _ := mm5.(model)
	if got5.top() != scrReconcileOrphansTick {
		t.Fatalf("declined confirm did not return to the list (top=%d)", got5.top())
	}
}

// Adopting is a result, not a screen to work through: once the log is up to
// date there is nothing left to pick, so it reports and goes back.
func TestAdoptingReportsAndReturns(t *testing.T) {
	m := initialModel()
	m.loading = true
	mm, _ := m.update(adoptPluginsMsg{n: 23})
	got, _ := mm.(model)
	if got.loading {
		t.Error("the spinner is still running after the adoption finished")
	}
	if !strings.Contains(got.toast.View(), "23") {
		t.Errorf("the toast does not say how many were tracked: %q", got.toast.View())
	}
	// A second run with nothing to do says so rather than claiming success.
	mm2, _ := got.update(adoptPluginsMsg{n: 0})
	got2, _ := mm2.(model)
	if !strings.Contains(strings.ToLower(got2.toast.View()), "already") {
		t.Errorf("a no-op adoption should say everything is already tracked: %q", got2.toast.View())
	}
}

// A failed adoption must say so. Silently claiming success would leave the
// user believing the startup nagging was fixed when it was not.
func TestAdoptionFailureIsReported(t *testing.T) {
	m := initialModel()
	m.loading = true
	mm, _ := m.update(adoptPluginsMsg{err: errBoom{}})
	got, _ := mm.(model)
	if got.loading {
		t.Error("the spinner is still running after a failure")
	}
	if strings.Contains(got.toast.View(), "tracked") &&
		!strings.Contains(got.toast.View(), "could not") {
		t.Errorf("a failure reads like a success: %q", got.toast.View())
	}
}

type errBoom struct{}

func (errBoom) Error() string { return "boom" }

// Selecting a whole folder fills its square (▢ becomes ▣), exactly like
// mosquitomarchy's Setup/Uninstall folders — no ○/● circles on folders,
// circles are leaf marks.
func TestFolderSquareFillsWhenFull(t *testing.T) {
	items := []Item{
		{Display: "One", Value: "vst:vst2:/x/One.dll", Formats: "vst2"},
		{Display: "Two", Value: "vst:vst2:/x/Two.dll", Formats: "vst2"},
	}
	tree := orphanTree(items)
	checked := map[string]bool{}
	rows := treeItemsToPicker(tree, checked, map[string]bool{"orphan-folder:vst2": true})
	for _, r := range rows {
		if r.Value == "orphan-folder:vst2" && r.Filled {
			t.Fatal("empty folder renders filled")
		}
	}
	checked["vst:vst2:/x/One.dll"] = true
	checked["vst:vst2:/x/Two.dll"] = true
	rows = treeItemsToPicker(tree, checked, map[string]bool{"orphan-folder:vst2": true})
	found := false
	for _, r := range rows {
		if r.Value == "orphan-folder:vst2" {
			found = true
			if !r.Filled {
				t.Fatal("full folder does not render filled")
			}
		}
	}
	if !found {
		t.Fatal("folder row missing")
	}
}

// The track confirm must render: a missing View case left it an empty body
// (black screen), with Esc the only way out and tracking impossible.
func TestOrphansConfirmRenders(t *testing.T) {
	m := initialModel()
	m.nav = []screen{scrMain, scrReconcileOrphansTick, scrOrphansConfirm}
	m.w, m.h = 100, 34
	m.confirm = tuikit.NewConfirm("Track 2 plugins?", "No", "Yes")
	if v := m.View(); v == "" {
		t.Fatal("orphans confirm renders nothing")
	} else if !strings.Contains(v, "Track 2 plugins?") {
		t.Fatalf("orphans confirm missing its question:\n%s", v)
	}
}
