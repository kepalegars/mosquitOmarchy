package main

import (
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"mosquitomarchy.local/mosquitomixbay-tui/drivers"
	"mosquitomarchy.local/mosquitomixbay-tui/profiles"
	tuikit "mosquitomarchy.local/tui-kit"
)

func TestLibraryTabsSplitInstalledAndAvailable(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if _, err := profiles.InstallLocalCard("quantum-es4", "PreSonus Quantum ES 4", "Quantum ES"); err != nil {
		t.Fatal(err)
	}
	m := model{libraryChecked: map[string]bool{"quantum-es4": true},
		libraryIndex: profiles.Index{SchemaVersion: 1, Cards: []profiles.IndexCard{
			{ID: "quantum-es4", Display: "PreSonus Quantum ES 4", Version: "beta"},
			{ID: "evo8", Display: "Audient EVO 8", Version: "v1.0.0", Native: true},
			{ID: "new-card", Display: "New Card", Vendor: "New", Version: "v1"},
		}}}
	installed := ""
	for _, it := range m.libraryItems() {
		installed += it.Display + "\n"
		if it.Value == "back" {
			t.Errorf("library must not carry a Back action row any more: %q", it.Display)
		}
	}
	for _, want := range []string{"Audient EVO 8", "● PreSonus Quantum ES 4", "up to date"} {
		if !strings.Contains(installed, want) {
			t.Errorf("installed tab missing %q in:\n%s", want, installed)
		}
	}
	if strings.Contains(installed, "New Card") {
		t.Errorf("installed tab lists a card that is not installed:\n%s", installed)
	}

	m.libraryTab = libAvailable
	available := ""
	for _, it := range m.libraryItems() {
		// repo rows plus cards embedded in the binary but not published there
		// (the Move); nothing else belongs in Available.
		if it.Value != "" && !strings.HasPrefix(it.Value, "repo:") &&
			!strings.HasPrefix(it.Value, "native:") {
			t.Errorf("available tab holds an unexpected row, got %q", it.Value)
		}
		available += it.Display + "\n"
	}
	if !strings.Contains(available, "New Card") || !strings.Contains(available, "○") {
		t.Errorf("available tab missing the installable card:\n%s", available)
	}
	// The Move ships in the binary, not in the repo: it must still be
	// installable from this tab, offline, and removable again.
	if !strings.Contains(available, "Ableton Move") {
		t.Errorf("available tab missing the embedded Move profile:\n%s", available)
	}
	if strings.Contains(available, "PreSonus Quantum ES 4") || strings.Contains(available, "Audient EVO 8") {
		t.Errorf("available tab lists an installed card:\n%s", available)
	}
}

// Every selectable library row must answer Tab. Tab and Enter share one
// prefix parser, so a future row source that forgets it fails here instead of
// silently ignoring keys as the `native:` Move did.
func TestEveryLibraryRowTogglesWithTab(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if _, err := profiles.InstallLocalCard("quantum-es4", "PreSonus Quantum ES 4", "Quantum ES"); err != nil {
		t.Fatal(err)
	}
	m := model{
		nav:            []screen{scrLibrary},
		libraryChecked: map[string]bool{},
		libraryIndex: profiles.Index{SchemaVersion: 1, Cards: []profiles.IndexCard{
			{ID: "quantum-es4", Display: "PreSonus Quantum ES 4", Version: "beta"},
			{ID: "new-card", Display: "New Card", Vendor: "New", Version: "v1"},
		}},
	}
	for _, tab := range []int{libInstalled, libAvailable} {
		m.libraryTab = tab
		rows := m.libraryItems()
		m.picker = tuikit.NewPicker("", rows)
		for _, it := range rows {
			if it.Value == "" || it.Disabled || it.Heading || strings.HasPrefix(it.Value, "dup:") {
				continue
			}
			id, ok := libraryValueID(it.Value)
			if !ok {
				t.Fatalf("tab %d row %q has no id prefix: Tab would ignore it", tab, it.Value)
			}
			m.libraryChecked = map[string]bool{}
			m.picker = m.picker.SelectValue(it.Value)
			next, _ := m.Update(tuikit.PickerToggleMsg{Value: it.Value})
			if !next.(model).libraryChecked[id] {
				t.Fatalf("tab %d row %q did not toggle with Tab", tab, it.Value)
			}
		}
	}
}

func TestLibraryTabSwitchClearsSelection(t *testing.T) {
	m := model{
		nav:            []screen{scrLibrary},
		libraryChecked: map[string]bool{"quantum-es4": true},
	}
	next, _ := m.libraryKey(tea.KeyMsg{Type: tea.KeyRight})
	got := next.(model)
	if got.libraryTab != libAvailable {
		t.Fatal("right did not open the Available tab")
	}
	if len(got.libraryChecked) != 0 {
		t.Fatal("switching tabs must clear the selection")
	}
}

func TestDevicesLegendMentionsRefresh(t *testing.T) {
	m := model{nav: []screen{scrDevices}}
	hint := stripANSI(m.legendLine(160))
	if !strings.Contains(hint, "r refresh") {
		t.Fatalf("home legend is missing r refresh: %q", hint)
	}
	if strings.Contains(hint, "settings") {
		t.Fatalf("home legend still mentions settings: %q", hint)
	}
}

func TestPresetRoutesRenderer(t *testing.T) {
	m := model{deviceID: "some-imported-card", preset: "evo8"}
	if !m.isEvoDevice() || m.isUGMDevice() {
		t.Fatal("evo8 preset did not route to the EVO renderer")
	}
	m.preset = "ugm192"
	if m.isEvoDevice() || !m.isUGMDevice() {
		t.Fatal("ugm192 preset did not route to the UGM panel")
	}
	m.preset = "auto"
	m.status.Spec.Backend = drivers.BackendEvoRaw
	if !m.isEvoDevice() {
		t.Fatal("auto preset ignored the evo-raw backend")
	}
	m.status.Spec.Backend = drivers.BackendALSA
	if m.isEvoDevice() {
		t.Fatal("auto preset routed ALSA to the EVO frame")
	}
}

func TestPresetBlocksAreKnown(t *testing.T) {
	known := map[string]bool{}
	for _, b := range profiles.Blocks {
		known[b] = true
	}
	for preset, blocks := range presetBlockSets {
		if len(blocks) == 0 {
			t.Fatalf("preset %s has no blocks", preset)
		}
		for _, b := range blocks {
			if !known[b] {
				t.Errorf("preset %s uses unknown block %q", preset, b)
			}
		}
	}
	for _, p := range profiles.Presets {
		if _, ok := presetBlockSets[p]; !ok {
			t.Errorf("profile preset %q has no renderer composition", p)
		}
	}
}

func TestProfilesSquareBlinkAndUpdate(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	badge := func(m model) string {
		for _, it := range m.settingsItems() {
			if it.Value == "profiles" {
				return it.TrailingBadge
			}
		}
		return ""
	}
	m := model{profileChecking: true, profileBlink: 0}
	if got := badge(m); got != "■" {
		t.Fatalf("checking should blink on: %q", got)
	}
	m.profileBlink = 1
	if got := badge(m); got != " " {
		t.Fatalf("checking should blink off without moving the row: %q", got)
	}
	m.profileChecking = false
	if got := badge(m); got != "" {
		t.Fatalf("idle square should be empty, got %q", got)
	}
	if _, err := profiles.InstallLocalCard("quantum-es4", "PreSonus Quantum ES 4", "Quantum ES"); err != nil {
		t.Fatal(err)
	}
	m.libraryIndex = profiles.Index{SchemaVersion: 1, Cards: []profiles.IndexCard{
		{ID: "quantum-es4", Display: "PreSonus Quantum ES 4", Version: "v9"},
	}}
	if got := badge(m); got != "■" {
		t.Fatalf("update available should hold the square solid, got %q", got)
	}
	// A repo card that is not installed is news too: the row is the gateway
	// to the profiles tab, so the square must be visible on arrival.
	m.libraryIndex.Cards = append(m.libraryIndex.Cards, profiles.IndexCard{
		ID: "new-card", Display: "New Card", Version: "v1",
	})
	m.libraryIndex.Cards = m.libraryIndex.Cards[1:] // only the uninstalled card remains
	if got := badge(m); got != "■" {
		t.Fatalf("new repo profile should show the square, got %q", got)
	}
}

func TestSettingsListsProfilesThenFoundation(t *testing.T) {
	old := levelsGuardEnabled
	levelsGuardEnabled = func() bool { return true } // no install notice row
	t.Cleanup(func() { levelsGuardEnabled = old })
	m := model{}
	items := m.settingsItems()
	if len(items) < 2 || items[0].Value != "profiles" || items[1].Value != "foundation" {
		t.Fatalf("settings order = %v, want profiles then foundation", []string{items[0].Value, items[1].Value})
	}
}

// The install notice is the only place a fully absent Levels Guard is
// mentioned: no helper and no plugin means Mixbay loses its exclusive volume
// control. A partial install is the watcher's repair notice instead.
func TestSettingsNoticeOnlyWhenLevelsGuardMissing(t *testing.T) {
	old := levelsGuardEnabled
	t.Cleanup(func() { levelsGuardEnabled = old })
	levelsGuardEnabled = func() bool { return false }
	m := model{}
	items := m.settingsItems()
	if len(items) < 2 || !items[0].Disabled || items[0].Value != "" ||
		!strings.Contains(items[0].Display, "Levels Guard is not installed") {
		t.Fatalf("missing Levels Guard notice: %+v", items[:2])
	}
	if !strings.Contains(items[1].Display, "cannot work without it") {
		t.Fatalf("notice does not say what breaks: %q", items[1].Display)
	}
	levelsGuardEnabled = func() bool { return true }
	for _, it := range m.settingsItems() {
		if strings.Contains(it.Display, "Levels Guard") {
			t.Fatalf("installed Levels Guard still shows the notice: %q", it.Display)
		}
	}
}

func TestLibraryShowsUpdateAndRefreshToast(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if _, err := profiles.InstallLocalCard("quantum-es4", "PreSonus Quantum ES 4", "Quantum ES"); err != nil {
		t.Fatal(err)
	}
	ix := profiles.Index{SchemaVersion: 1, Cards: []profiles.IndexCard{
		{ID: "quantum-es4", Display: "PreSonus Quantum ES 4", Version: "v9"},
	}}
	m := model{nav: []screen{scrLibrary}, libraryManual: true}
	next, _ := m.update(libraryIndexMsg{ix: ix})
	got := next.(model)
	rows := ""
	updates := 0
	for _, it := range got.libraryItems() {
		rows += it.Display + "\n"
		if it.Value == "card:quantum-es4" {
			if it.TrailingBadge != "■" {
				t.Errorf("out-of-date card must carry the solid square, got %q", it.TrailingBadge)
			}
			updates++
		}
	}
	if !strings.Contains(rows, "update v9") ||
		strings.Contains(rows, "built in") || strings.Contains(rows, "downloaded") {
		t.Fatalf("installed row state is wrong:\n%s", rows)
	}
	if updates != 1 {
		t.Fatalf("expected one installed quantum-es4 row, got %d", updates)
	}
	if toast := stripANSI(got.toast.View()); !strings.Contains(toast, "Repo checked") || !strings.Contains(toast, "1 update") {
		t.Fatalf("refresh gave no feedback: %q", toast)
	}
}

func TestLibraryNavigationMoves(t *testing.T) {
	m := model{
		nav:            []screen{scrLibrary},
		libraryChecked: map[string]bool{},
		dupPrompted:    map[string]bool{},
	}
	m.picker = tuikit.NewPicker("", []tuikit.PickerItem{
		{Display: "first", Value: "a"},
		{Display: "second", Value: "b"},
	})
	next, _ := m.libraryKey(tea.KeyMsg{Type: tea.KeyDown})
	if got := next.(model).picker.SelectedValue(); got != "b" {
		t.Fatalf("down did not move the picker (selected %q)", got)
	}
}

func TestDuplicatePromptSkipsOnce(t *testing.T) {
	m := model{nav: []screen{scrDevices}, dupPrompted: map[string]bool{}}
	d := profiles.Duplicate{
		KeepID: "quantum-es4", KeepDisplay: "PreSonus Quantum ES 4",
		RemoveID: "beta-quantum-es-4", RemoveDisplay: "PreSonus Quantum ES 4",
	}
	m.promptDuplicate(d)
	if m.top() != scrConfirm {
		t.Fatal("duplicate warning did not open a confirmation")
	}
	m.pop()
	m.promptDuplicate(d)
	if m.top() == scrConfirm {
		t.Fatal("same duplicate prompted twice in one session")
	}
}

func TestUninstallRecapIncludesEmbeddedCards(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if _, err := profiles.InstallLocalCard("quantum-es4", "PreSonus Quantum ES 4", "Quantum ES"); err != nil {
		t.Fatal(err)
	}
	m := model{nav: []screen{scrLibrary}, dupPrompted: map[string]bool{}}
	m.promptUninstall([]string{"quantum-es4", "evo8"})
	if m.top() != scrConfirm {
		t.Fatal("uninstall did not ask for confirmation")
	}
	text := stripANSI(m.confirm.View())
	for _, want := range []string{"Uninstall 2 profile", "PreSonus Quantum ES 4", "Audient EVO 8"} {
		if !strings.Contains(text, want) {
			t.Errorf("uninstall recap missing %q:\n%s", want, text)
		}
	}
	if strings.Contains(text, "built in") {
		t.Errorf("uninstall recap still talks about built-in cards:\n%s", text)
	}
}

// A card with no integration must not hear about douze or oscmix. The last RME
// profile, on the other hand, must say oscmix goes with it.
func TestUninstallRecapNamesOnlyTheCardsIntegration(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if _, err := profiles.InstallLocalCard("ugm192-test", "ESI UGM192", "UGM192"); err != nil {
		t.Fatal(err)
	}
	note := uninstallIntegrationNotes([]string{"ugm192-test"})
	if note != "" {
		t.Fatalf("card without integration got a note: %q", note)
	}
	last := uninstallIntegrationNotes([]string{"fireface-ucx2"})
	if !strings.Contains(last, "oscmix is removed completely") {
		t.Fatalf("last RME card note = %q", last)
	}
	if strings.Contains(last, "douze") {
		t.Fatalf("RME note mentions douze: %q", last)
	}
}

func TestUninstallRecapKeepsSharedOscmix(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	first, ok := profiles.NativeCard("fireface-ucx2")
	if !ok {
		t.Fatal("native RME card missing")
	}
	second := first
	second.Spec.ID = "fireface-ucx"
	second.Spec.Display = "RME Fireface UCX"
	if err := profiles.DeployCard(second); err != nil {
		t.Fatal(err)
	}
	note := uninstallIntegrationNotes([]string{"fireface-ucx2"})
	if !strings.Contains(note, "shared with the other installed RME cards") {
		t.Fatalf("shared oscmix note = %q", note)
	}
	if strings.Contains(note, "removed completely") {
		t.Fatalf("shared oscmix wrongly removed: %q", note)
	}
}

func TestInstallWithLocalUIOffersBackup(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if _, err := profiles.InstallLocalCard("quantum-es4", "PreSonus Quantum ES 4", "Quantum ES"); err != nil {
		t.Fatal(err)
	}
	if err := profiles.SaveUserLayout("quantum-es4", []byte(`{"preset":"auto"}`)); err != nil {
		t.Fatal(err)
	}
	m := model{
		nav:            []screen{scrLibrary},
		libraryChecked: map[string]bool{},
		libraryIndex:   profiles.Index{SchemaVersion: 1},
		libraryTab:     libAvailable,
	}
	m.picker = tuikit.NewPicker("", []tuikit.PickerItem{{Display: "quantum", Value: "repo:quantum-es4"}})
	next, _ := m.libraryKey(tea.KeyMsg{Type: tea.KeyEnter})
	got := next.(model)
	if got.top() != scrConfirm {
		t.Fatal("a local layout must open a backup confirmation")
	}
	text := stripANSI(got.confirm.View())
	for _, want := range []string{"quantum-es4 has a local layout", "backed up to", "before the repo layout replaces it", "Continue?"} {
		if !strings.Contains(text, want) {
			t.Errorf("backup prompt missing %q:\n%s", want, text)
		}
	}
	if got.libraryLoading {
		t.Fatal("nothing should start before the confirmation")
	}
}

func TestUpstreamUpdateWarnsAndDeploysDirect(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if _, err := profiles.InstallLocalCard("quantum-es4", "PreSonus Quantum ES 4", "Quantum ES"); err != nil {
		t.Fatal(err)
	}
	up, _, err := profiles.Effective("quantum-es4")
	if err != nil {
		t.Fatal(err)
	}
	up.Spec.Version = "v9"
	m := model{
		nav:            []screen{scrLibrary},
		libraryChecked: map[string]bool{},
		libraryIndex: profiles.Index{SchemaVersion: 1, Cards: []profiles.IndexCard{
			{ID: "quantum-es4", Display: "PreSonus Quantum ES 4", Version: "beta"},
		}},
		libraryUpstream: map[string]profiles.Card{"quantum-es4": up},
	}
	m.picker = tuikit.NewPicker("", []tuikit.PickerItem{{Display: "quantum", Value: "card:quantum-es4"}})
	next, _ := m.libraryKey(tea.KeyMsg{Type: tea.KeyEnter})
	got := next.(model)
	if got.top() != scrConfirm {
		t.Fatal("a direct upstream update must ask for confirmation")
	}
	text := stripANSI(got.confirm.View())
	for _, want := range []string{"Quantum", "v9", "github.com/kepalegars/mosquito-mixbay-profiles", "uninstall the profile and install it again"} {
		if !strings.Contains(text, want) {
			t.Errorf("upstream warning missing %q:\n%s", want, text)
		}
	}
}

func TestLibrarySearchFiltersBothTabs(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	m := model{
		nav:            []screen{scrLibrary},
		libraryChecked: map[string]bool{},
		libraryTab:     libAvailable,
		libraryIndex: profiles.Index{SchemaVersion: 1, Cards: []profiles.IndexCard{
			{ID: "fireface-802", Display: "RME Fireface 802", Vendor: "RME", Version: "v0.1.0"},
			{ID: "quantum-es4", Display: "PreSonus Quantum ES 4", Vendor: "PreSonus", Version: "v0.1.0"},
		}},
	}
	m.picker = tuikit.NewPicker("", m.libraryItems())
	open, _ := m.libraryKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("F")})
	got := open.(model)
	if !got.libraryFilterOpen {
		t.Fatal("F did not open the search zone")
	}
	filtered, _ := got.libraryKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("fire")})
	got = filtered.(model)
	rows := ""
	for _, it := range got.libraryItems() {
		rows += it.Display + "\n"
	}
	if !strings.Contains(rows, "RME Fireface 802") || strings.Contains(rows, "Quantum") {
		t.Fatalf("available search did not narrow the list:\n%s", rows)
	}
	// Closing clears the text and restores the full list.
	closed, _ := got.libraryKey(tea.KeyMsg{Type: tea.KeyEsc})
	got = closed.(model)
	if got.libraryFilterOpen || got.libraryFilterText != "" {
		t.Fatal("esc did not close and clear the search")
	}
	if !strings.Contains(got.availableItems()[0].Display, "Fireface 802") {
		t.Fatalf("full list not restored: %+v", got.availableItems())
	}

	// Installed tab: the same key filters installed cards (seeded EVO/SSL…).
	got.libraryTab = libInstalled
	got.libraryFilterText = "ssl"
	if rows := got.libraryItems(); len(rows) != 1 || !strings.Contains(rows[0].Display, "SSL 12") {
		t.Fatalf("installed search = %+v", rows)
	}
	if got := got.libraryFilterBar(80); strings.Count(got, "\n") != libraryFilterRows-1 {
		t.Fatalf("search frame is %d rows, want %d", strings.Count(got, "\n")+1, libraryFilterRows)
	}
}

func TestRepoNewsSaysAvailable(t *testing.T) {
	if got := repoNewsLabel(1, 7); !strings.Contains(got, "1 update") || !strings.Contains(got, "7 available") || strings.Contains(got, "download") {
		t.Fatalf("repo check label = %q", got)
	}
}

func TestInfoShowsVersionsAndCredits(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if _, err := profiles.InstallLocalCard("quantum-es4", "PreSonus Quantum ES 4", "Quantum ES"); err != nil {
		t.Fatal(err)
	}
	m := model{libraryIndex: profiles.Index{SchemaVersion: 1, Cards: []profiles.IndexCard{
		{ID: "quantum-es4", Display: "PreSonus Quantum ES 4", Version: "v9",
			Credits: profiles.Credits{Author: "mosquito", Contributors: []string{"@someone"}}},
		{ID: "new-card", Display: "New Card", Vendor: "New", Version: "v1",
			Credits: profiles.Credits{Author: "mosquito"}},
	}}}
	installed := m.libraryDetail("quantum-es4")
	for _, want := range []string{"installed  beta", "repo       v9", "update available", "credits    mosquito, @someone"} {
		if !strings.Contains(installed, want) {
			t.Errorf("installed info missing %q:\n%s", want, installed)
		}
	}
	available := m.libraryDetail("new-card")
	for _, want := range []string{"installed  not installed", "repo       v1", "credits    mosquito"} {
		if !strings.Contains(available, want) {
			t.Errorf("available info missing %q:\n%s", want, available)
		}
	}
}
