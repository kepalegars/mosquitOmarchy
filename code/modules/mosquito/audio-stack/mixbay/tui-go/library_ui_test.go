package main

import (
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"mosquitomarchy.local/mosquitomixbay-tui/drivers"
	"mosquitomarchy.local/mosquitomixbay-tui/profiles"
	tuikit "mosquitomarchy.local/tui-kit"
)

func TestLibraryListsInstalledAndAvailable(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if _, err := profiles.InstallLocalCard("quantum-es4", "PreSonus Quantum ES 4", "Quantum ES"); err != nil {
		t.Fatal(err)
	}
	m := model{
		libraryChecked: map[string]bool{"quantum-es4": true},
		libraryIndex: profiles.Index{SchemaVersion: 1, Cards: []profiles.IndexCard{
			{ID: "quantum-es4", Display: "PreSonus Quantum ES 4", Version: "beta"},
		}},
	}
	joined := ""
	for _, it := range m.libraryItems() {
		joined += it.Display + "\n"
		if it.Value == "back" && strings.HasPrefix(it.Display, " ") {
			t.Errorf("Back row must not be indented: %q", it.Display)
		}
	}
	for _, want := range []string{"Installed profiles", "Audient EVO 8", "● PreSonus Quantum ES 4", "up to date"} {
		if !strings.Contains(joined, want) {
			t.Errorf("library missing %q in:\n%s", want, joined)
		}
	}
	if strings.Contains(joined, "update") {
		t.Errorf("installed same-version card still offered as update:\n%s", joined)
	}
}

func TestDevicesLegendMentionsRefresh(t *testing.T) {
	m := model{nav: []screen{scrDevices}}
	if !strings.Contains(stripANSI(m.legendLine(160)), "r refresh") {
		t.Fatalf("home legend is missing r refresh: %q", stripANSI(m.legendLine(160)))
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

func TestOfferPromptsOnce(t *testing.T) {
	m := model{nav: []screen{scrDevices}, libraryChecked: map[string]bool{}}
	offers := []profiles.Offer{{ID: "quantum-es4", Display: "PreSonus Quantum ES 4", Version: "v1.1.0", Kind: "install"}}
	m.promptNextOffer(offers)
	if m.top() != scrConfirm || !m.profilePrompted {
		t.Fatal("offer did not open a confirmation")
	}
	m.pop()
	m.promptNextOffer(offers)
	if m.top() == scrConfirm {
		t.Fatal("offer prompted twice in one session")
	}
}
