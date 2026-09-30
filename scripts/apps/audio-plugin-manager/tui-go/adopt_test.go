package main

import (
	"strings"
	"testing"
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
// DOES open a screen, once, and it is one row per plugin.
func TestSweepOpensOneRowPerPluginWhenThereIsSomethingToAdopt(t *testing.T) {
	m := initialModel()
	m.nav = []screen{scrMain}
	mm, _ := m.update(reconcileOrphansMsg{items: []Item{
		{Display: "FabFilter One", Value: "vst:vst2:/x/One.dll", Formats: "vst2,vst3"},
		{Display: "FabFilter Pro-Q 4", Value: "vst:vst3:/x/ProQ.vst3", Formats: "vst3"},
	}})
	got, _ := mm.(model)
	if got.top() != scrReconcileOrphansTick {
		t.Fatalf("with two orphans no screen appeared (top=%d)", got.top())
	}
	if n := len(got.picker.Items()); n != 2 {
		t.Errorf("the screen shows %d rows for 2 plugins", n)
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
