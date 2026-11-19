package main

import (
	"strings"
	"testing"

	"mosquitomarchy.local/mosquitomixbay-tui/drivers"
)

// A declared composition is authoritative for the tabs: removing Mixer and
// Levels leaves the EVO frame on Controls, and Tab has nowhere else to go.
func TestDeclaredBlocksChooseThePages(t *testing.T) {
	m := evoModel(t, drivers.DevEVO8, evoWinControls)
	m.blocks = []string{"tabBar", "controlsGrid", "statusBar", "help"}
	plain := stripANSI(m.evoView())
	if !strings.Contains(plain, "Controls") {
		t.Fatal("controls page missing")
	}
	for _, gone := range []string{"Mixer", "Levels"} {
		if strings.Contains(plain, gone) {
			t.Fatalf("removed block %q still rendered", gone)
		}
	}
	m.evoKey("tab")
	if m.evo.window != evoWinControls || m.top() != scrControls {
		t.Fatalf("tab left the only page: window=%d top=%v", m.evo.window, m.top())
	}
}

// statusBar and help are optional: dropping them removes those rows, not the
// body.
func TestStatusAndHelpBlocksAreOptional(t *testing.T) {
	m := evoModel(t, drivers.DevEVO8, evoWinControls)
	m.blocks = []string{"tabBar", "controlsGrid"}
	plain := stripANSI(m.evoView())
	if strings.Contains(plain, "save") || strings.Contains(plain, "reset") {
		t.Fatalf("status/help rows still drawn without their blocks:\n%s", plain)
	}
	if !strings.Contains(plain, "IN 1") {
		t.Fatalf("controls body disappeared with its blocks present:\n%s", plain)
	}
}

// Undeclared blocks keep the preset default, so an older card (or a test that
// only sets a preset) still gets every tab.
func TestUndeclaredBlocksKeepThePresetDefault(t *testing.T) {
	m := evoModel(t, drivers.DevEVO8, evoWinControls)
	m.blocks = nil
	plain := stripANSI(m.evoView())
	for _, want := range []string{"Controls", "Mixer", "Levels"} {
		if !strings.Contains(plain, want) {
			t.Fatalf("default composition is missing %q", want)
		}
	}
}

// A single-pair card that composes controlsSingle gets the UGM-style panel
// instead of the generic picker, but only while the card can drive volume or
// mute.
func TestSinglePairUsesTheSinglePanel(t *testing.T) {
	m := initialModel()
	m.w, m.h = 100, 30
	m.deviceID = "some-single-pair"
	m.preset = "single-pair"
	m.blocks = []string{"tabBar", "controlsSingle", "statusBar", "help"}
	m.status = drivers.Status{Spec: drivers.UGM192Spec, Online: true}
	m.nav = []screen{scrDevices, scrControls}
	if got := m.controlModel(); got != modelSingle {
		t.Fatalf("control model = %q, want %q", got, modelSingle)
	}
	plain := stripANSI(m.View())
	if !strings.Contains(plain, "OUTPUT 1|2") || !strings.Contains(plain, "Vol:") {
		t.Fatalf("single panel missing:\n%s", plain)
	}
	if strings.Contains(plain, "Levels") {
		t.Fatalf("card did not ask for Levels:\n%s", plain)
	}

	// No volume/mute capability: fall back to the picker's controls, never
	// to faders whose write would fail.
	m.status.Spec.Caps.Volume = false
	m.status.Spec.Caps.Mute = false
	if got := m.controlModel(); got != "" {
		t.Fatalf("control model = %q, want the picker", got)
	}
}

// An auto card that composes the grid (SSL 12) renders the EVO frame; the
// caps keep the preamps it cannot drive off the page.
func TestAutoCardBlocksChooseTheGrid(t *testing.T) {
	m := initialModel()
	m.w, m.h = 150, 40
	m.deviceID = "some-ssl12"
	m.preset = "auto"
	m.blocks = []string{"tabBar", "controlsGrid", "mixerGrid", "statusBar", "help"}
	m.status = drivers.Status{Spec: drivers.SSL12Spec, Online: true}
	m.nav = []screen{scrDevices, scrControls}
	m.evoEnter()
	if got := m.controlModel(); got != modelGrid {
		t.Fatalf("control model = %q, want %q", got, modelGrid)
	}
	plain := stripANSI(m.evoView())
	for _, want := range []string{"Controls", "Mixer", "OUT 1|2"} {
		if !strings.Contains(plain, want) {
			t.Fatalf("grid missing %q:\n%s", want, plain)
		}
	}
	if strings.Contains(plain, "Levels") {
		t.Fatalf("card did not ask for Levels:\n%s", plain)
	}
	if strings.Contains(plain, "IN 1") {
		t.Fatalf("preamps are not in the card's caps:\n%s", plain)
	}
}

// An action-only card (no controls, no mixer) stays on the picker so its
// openers remain reachable.
func TestActionOnlyCardStaysOnThePicker(t *testing.T) {
	m := initialModel()
	m.deviceID = "some-rme"
	m.preset = "auto"
	m.blocks = []string{"controlsGrid", "statusBar", "help"}
	m.status = drivers.Status{Spec: drivers.FirefaceSpec, Online: true}
	if got := m.controlModel(); got != "" {
		t.Fatalf("control model = %q, want the picker", got)
	}
}
