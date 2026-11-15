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
		if it.Value != "" && !strings.HasPrefix(it.Value, "repo:") {
			t.Errorf("available tab must only hold repo rows, got %q", it.Value)
		}
		available += it.Display + "\n"
	}
	if !strings.Contains(available, "New Card") || !strings.Contains(available, "○") {
		t.Errorf("available tab missing the installable card:\n%s", available)
	}
	if strings.Contains(available, "PreSonus Quantum ES 4") || strings.Contains(available, "Audient EVO 8") {
		t.Errorf("available tab lists an installed card:\n%s", available)
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
