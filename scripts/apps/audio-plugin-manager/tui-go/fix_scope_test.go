package main

import (
	"fmt"
	"strings"
	"testing"

	tuikit "mosquitomarchy.local/tui-kit"
)

// A vendor-wide visit where a fix reaches only SOME of the suite.
//
// This is the real shape, taken from a real machine: FabFilter's suite has
// twenty-one products, the window-retitle fix is recorded on all of them, and
// a handful of fixes live in the catalog of a single product (Saturn 2's EQ
// page, Pro-DS's display) — a fix that reaches one product of twenty-one and is
// on that one is PARTIAL within the suite, and the merge used to report it as
// simply applied.
func partialFixture() model {
	return model{
		nav: []screen{scrFixChoose}, w: 100, h: 40,
		fixVendor: "FabFilter",
		fixScope:  "FabFilter",
		fixCache: []FixItem{
			{ID: "wine_gui_input", Title: "Retitle the window", Category: "Plugin windows", Applied: true,
				AppliedTo:  []string{"FabFilter One", "FabFilter Pro-Q 4", "FabFilter Saturn 2"},
				Candidates: 3},
			{ID: "wine_saturn_eq", Title: "Saturn 2 EQ page scaling", Category: "Plugin windows", Applied: true,
				AppliedTo:  []string{"FabFilter Saturn 2"},
				Candidates: 3},
			{ID: "wine_banner", Title: "Hide the banner", Category: "Plugin windows"},
		},
		fixVendorPlugins: []string{"FabFilter One", "FabFilter Pro-Q 4", "FabFilter Saturn 2"},
		fixAppliedBy: map[string][]string{
			"wine_gui_input": {"FabFilter One", "FabFilter Pro-Q 4", "FabFilter Saturn 2"},
			"wine_saturn_eq": {"FabFilter Saturn 2"},
		},
		fixCandidate:      map[string]int{"wine_gui_input": 3, "wine_saturn_eq": 3, "wine_banner": 3},
		fixChecked:        map[string]bool{"wine_gui_input": true, "wine_saturn_eq": true, "wine_banner": false},
		fixOrig:           map[string]bool{"wine_gui_input": true, "wine_saturn_eq": true, "wine_banner": false},
		fixAppliedPlugins: map[string]bool{},
	}
}

// markOf reads the row's mark. It lives in Badge, not in the label: the kit
// owns a fixed badge column, and baking the mark into the label gave every
// child a different width and therefore a different starting column from its
// category.
func markOf(t *testing.T, rows []tuikit.PickerItem, title string) string {
	t.Helper()
	for _, r := range rows {
		if strings.Contains(r.Display, title) {
			return r.Badge
		}
	}
	t.Fatalf("no row for %q", title)
	return ""
}

// ◐ for a fix that is on some of the plugins in view and not the others, ● for
// one that is on all of them, ○ for one that is on none.
func TestPartialFixShowsALeftHalfCircle(t *testing.T) {
	m := partialFixture()
	rows := fixItemsToPicker(sortedFixItems(m.fixCache, false), m.fixChecked, m.fixOrig, m.fixOverride, map[string]bool{"Plugin windows": true})
	if got := markOf(t, rows, "Saturn 2 EQ page"); got != "◐" {
		t.Errorf("a fix on 1 of 3 plugins shows %q, want ◐", got)
	}
	if got := markOf(t, rows, "Retitle the window"); got != "●" {
		t.Errorf("a fix on all 3 plugins shows %q, want ●", got)
	}
	if got := markOf(t, rows, "Hide the banner"); got != "○" {
		t.Errorf("an unapplied fix shows %q, want ○", got)
	}
}

// ◐ describes the RECORDED state, so a row the user has just touched shows the
// plain mark: once you have ticked or unticked it you have an opinion, and the
// partial marker would misreport your intent as the machine's history.
func TestTouchingAPartialRowShowsThePlainMark(t *testing.T) {
	m := partialFixture()
	// Unticked: the user is about to REMOVE it, which is all-or-nothing here.
	m.fixChecked = map[string]bool{"wine_gui_input": true, "wine_saturn_eq": false}
	rows := fixItemsToPicker(sortedFixItems(m.fixCache, false), m.fixChecked, m.fixOrig, m.fixOverride, map[string]bool{"Plugin windows": true})
	if got := markOf(t, rows, "Saturn 2 EQ page"); got != "○" {
		t.Errorf("an unticked partial row shows %q, want ○", got)
	}
}

// A fix that reaches a single product is NOT partial, however big the suite is:
// "part of it" has to mean part of what the fix can actually reach. This is the
// CrispyTuner case — one product, and the tooltip fix is on it, so it is done.
func TestProductSpecificFixIsNeverPartial(t *testing.T) {
	it := FixItem{ID: "x", Applied: true, AppliedTo: []string{"CrispyTuner"}, Candidates: 1}
	if it.IsPartial() {
		t.Error("a fix reaching one plugin reports itself as partial")
	}
	no := FixItem{ID: "x"}
	if no.IsPartial() {
		t.Error("an unapplied fix reports itself as partial")
	}
	all := FixItem{ID: "x", Applied: true, AppliedTo: []string{"a", "b"}, Candidates: 2}
	if all.IsPartial() {
		t.Error("a fix on everything it reaches reports itself as partial")
	}
}

// The title says what the fixes are about. A single-plugin visit names the
// plugin; a whole-suite visit names the suite and says it is the whole suite.
func TestFixesTitleNamesTheScope(t *testing.T) {
	m := partialFixture()
	m.rebuildFixPicker()
	v := m.View()
	if !strings.Contains(v, "Choose the fixes to apply or remove to every FabFilter plugin") {
		t.Errorf("a vendor visit does not say it is the whole suite:\n%s", firstLines(v, 4))
	}

	m2 := model{nav: []screen{scrFixChoose}, w: 100, h: 40, fixScope: "CrispyTuner",
		fixCache: m.fixCache, fixChecked: m.fixChecked, fixOrig: m.fixOrig}
	m2.rebuildFixPicker()
	if v2 := m2.View(); !strings.Contains(v2, "Choose the fixes to apply or remove to CrispyTuner") {
		t.Errorf("a single-plugin visit does not name the plugin:\n%s", firstLines(v2, 4))
	}
}

// The title used to print the picker VALUE, which is a full path — and the
// empty string on a vendor visit, leaving a dangling "for ".
func TestTitleNeverPrintsAPickerValue(t *testing.T) {
	m := model{
		nav:        []screen{scrFixChoose},
		w:          100,
		h:          40,
		fixPlugin:  "vst:vst3:/home/someone/Music/Audio Plugins/vst3/CrispyTuner/CrispyTuner.vst3",
		fixScope:   "CrispyTuner",
		fixCache:   []FixItem{{ID: "a", Title: "Fix", Category: "c"}},
		fixChecked: map[string]bool{}, fixOrig: map[string]bool{},
	}
	m.rebuildFixPicker()
	v := m.View()
	if strings.Contains(v, "/home/someone") {
		t.Errorf("the title leaks the plugin's path:\n%s", firstLines(v, 4))
	}
}

func firstLines(s string, n int) string {
	lines := strings.Split(s, "\n")
	if len(lines) > n {
		lines = lines[:n]
	}
	return strings.Join(lines, "\n")
}

// The confirmation is the last moment the blast radius is visible, so it has to
// name the plugins. "to every FabFilter plugin" does not tell the user that
// this is twenty-one rewrites of a third-party binary.
func TestApplyConfirmationNamesThePlugins(t *testing.T) {
	m := partialFixture()
	v := m.fixApplyConfirm([]string{"wine_banner"}, nil).View()
	for _, n := range m.fixVendorPlugins {
		if !strings.Contains(v, n) {
			t.Errorf("%s is missing from the confirmation:\n%s", n, v)
		}
	}
	if !strings.Contains(v, "3 plugins of the FabFilter suite") {
		t.Errorf("the confirmation does not state the size of the change:\n%s", v)
	}
}

// Twenty-one plugins do not fit a dialog, so the list is a window that says so
// rather than a silent truncation.
func TestApplyConfirmationListScrollsWhenTheSuiteIsBig(t *testing.T) {
	m := partialFixture()
	m.fixCache = []FixItem{{ID: "wine_banner", Title: "Hide the banner", Category: "c"}}
	m.fixAppliedBy = map[string][]string{}
	m.fixVendorPlugins = nil
	for i := 0; i < 21; i++ {
		m.fixVendorPlugins = append(m.fixVendorPlugins, "FabFilter Product "+string(rune('A'+i)))
	}
	c := m.fixApplyConfirm([]string{"wine_banner"}, nil)
	if _, maxRows := c.ListBoundsForTest(); maxRows >= 21 {
		t.Errorf("the window is %d rows for 21 plugins: nothing scrolls", maxRows)
	}
	v := c.View()
	if !strings.Contains(v, "to scroll") {
		t.Errorf("a cut-short list does not admit it:\n%s", v)
	}
}

// Answering no must write nothing. This is the whole reason the dialog exists,
// so it is worth pinning: Canceled and No are different messages and both have
// to leave the marks alone.
func TestDecliningTheApplyChangesNothing(t *testing.T) {
	m := partialFixture()
	m.nav = []screen{scrFixChoose, scrFixApplyConfirm}
	m.fixPendingApply = []string{"wine_banner"}
	m.confirm = m.fixApplyConfirm([]string{"wine_banner"}, nil)

	before := fmt.Sprint(m.fixChecked)
	for _, msg := range []tuikit.ConfirmResultMsg{{Canceled: true}, {Yes: false}} {
		mm, cmd := m.Update(msg)
		got, _ := mm.(model)
		if cmd != nil {
			t.Errorf("%+v started a command: %v", msg, cmd)
		}
		if got.top() != scrFixChoose {
			t.Errorf("%+v left the screen at %d, want the fixes list", msg, got.top())
		}
		if fmt.Sprint(got.fixChecked) != before {
			t.Errorf("%+v moved the marks: %s -> %s", msg, before, fmt.Sprint(got.fixChecked))
		}
		if got.loading {
			t.Errorf("%+v started the runner", msg)
		}
	}
}

// And answering yes must actually run the vendor-wide apply.
func TestAcceptingTheApplyRunsTheVendorSync(t *testing.T) {
	m := partialFixture()
	m.nav = []screen{scrFixChoose, scrFixApplyConfirm}
	m.fixPendingApply = []string{"wine_banner"}
	m.confirm = m.fixApplyConfirm([]string{"wine_banner"}, nil)
	mm, cmd := m.Update(tuikit.ConfirmResultMsg{Yes: true})
	got, _ := mm.(model)
	if cmd == nil {
		t.Fatal("yes did not start the apply")
	}
	if !got.loading {
		t.Error("the runner is not showing")
	}
	if got.top() != scrFixChoose {
		t.Errorf("the dialog is still up (top=%d)", got.top())
	}
}

// The info for a fix said "already APPLIED for this plugin" and stopped there,
// which is exactly wrong on a vendor visit: the fix is not applied "for this
// plugin", it is applied to SOME of the suite's plugins and not the others.
func TestFixInfoNamesTheScopeItIsAppliedIn(t *testing.T) {
	one := model{fixScope: "CrispyTuner", fixAppliedBy: map[string][]string{"f": {"CrispyTuner"}}}
	if got := one.fixAppliedNote(FixItem{ID: "f", Applied: true}); !strings.Contains(got, "already applied for CrispyTuner") {
		t.Errorf("a single-plugin visit says %q", got)
	}
	if got := one.fixAppliedNote(FixItem{ID: "f"}); !strings.Contains(got, "not applied yet") {
		t.Errorf("an unapplied single-plugin visit says %q", got)
	}

	all := []string{"FabFilter One", "FabFilter Pro-Q 4", "FabFilter Saturn 2", "CrispyTuner"}
	folder := func(with ...string) model {
		return model{fixVendor: "FabFilter", fixScope: "FabFilter", fixVendorPlugins: all,
			fixAppliedBy: map[string][]string{"f": with}}
	}
	if got := folder().fixAppliedNote(FixItem{ID: "f"}); !strings.Contains(got, "not applied to any of the 4 FabFilter plugins") {
		t.Errorf("nothing applied says %q", got)
	}
	if got := folder(all...).fixAppliedNote(FixItem{ID: "f", Applied: true}); !strings.Contains(got, "already applied to all 4 FabFilter plugins") {
		t.Errorf("fully applied says %q", got)
	}

	// Partial: the sentence, plus the MINORITY side named — because the two
	// lists are complements and the odd one out is the actionable name.
	got := folder(all[:3]...).fixAppliedNote(FixItem{ID: "f", Applied: true})
	if !strings.Contains(got, "partially applied — 3 of the 4 FabFilter plugins") {
		t.Errorf("partial says %q", got)
	}
	if !strings.Contains(got, "1 without it") || !strings.Contains(got, "CrispyTuner") {
		t.Errorf("partial should name the single plugin lacking it, got %q", got)
	}
	if strings.Contains(got, "FabFilter One") {
		t.Errorf("partial should not list the eighteen it already has, got %q", got)
	}

	// And when it is the OTHER side that is the minority, that is what gets
	// named — the choice is by length, not by a fixed preference.
	got2 := folder(all[:1]...).fixAppliedNote(FixItem{ID: "f", Applied: true})
	if !strings.Contains(got2, "1 with it") || !strings.Contains(got2, "FabFilter One") {
		t.Errorf("one-of-four should name the one that has it, got %q", got2)
	}
}

// A long minority is capped and says so. Nineteen identical-looking plugin
// names is not an answer; a count plus the odd one out is.
func TestFixInfoCapsALongList(t *testing.T) {
	var many []string
	var plugs []string
	for i := 0; i < 12; i++ {
		n := fmt.Sprintf("Suite Product %02d", i)
		plugs = append(plugs, n)
		if i < 10 {
			many = append(many, n)
		}
	}
	m := model{fixVendor: "Suite", fixScope: "Suite", fixVendorPlugins: plugs,
		fixAppliedBy: map[string][]string{"f": many}}
	got := m.fixAppliedNote(FixItem{ID: "f", Applied: true})
	if !strings.Contains(got, "2 without it") {
		t.Errorf("the minority is the two missing ones, got %q", got)
	}
	if strings.Count(got, "Suite Product") > 3 {
		t.Errorf("the list was not capped: %q", got)
	}
}
