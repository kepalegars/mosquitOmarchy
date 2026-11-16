package main

import (
	"math"
	"strings"
	"testing"

	"mosquitomarchy.local/mosquitomixbay-tui/drivers"
)

func ugmModel(t *testing.T) model {
	t.Helper()
	m := initialModel()
	m.deviceID = drivers.DevUGM192
	m.nav = []screen{scrDevices, scrControls}
	m.w, m.h = 100, 26
	m.session = liveSession{live: true, online: true}
	m.status = drivers.Status{
		Spec:   drivers.UGM192Spec,
		Online: true,
		Outputs: []drivers.OutputState{
			{Name: "output", VolumeDb: -23},
		},
	}
	return m
}

func TestUGMVolumeFraction(t *testing.T) {
	if got := ugmVolFrac(drivers.UGM192Spec, -64); got != 0 {
		t.Errorf("-64 dB = %v, want 0", got)
	}
	if got := ugmVolFrac(drivers.UGM192Spec, -23); math.Abs(got-41.0/64.0) > 1e-9 {
		t.Errorf("-23 dB = %v, want 41/64", got)
	}
	if got := ugmVolFrac(drivers.UGM192Spec, 0); got != 1 {
		t.Errorf("0 dB = %v, want 1", got)
	}
}

// The panel is the EVO 4 frame with only the software control: no ALSA/model
// subtitle, no LEVELS card on the controls page, no save/load, and q quit on
// the separator line like evotui.
func TestUGMPanelUsesEvoFrame(t *testing.T) {
	out := stripANSI(ugmModel(t).ugmView())
	for _, want := range []string{
		"ESI UGM192 - v1.0.0", " Controls ", " Levels ",
		"OUTPUT 1|2", "Vol:", "-23.0 dB", "[m]", "q quit", "Ctrl+←→",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("panel missing %q", want)
		}
	}
	for _, unwanted := range []string{
		"ALSA", "2 IN / 1 OUT", "MUTE", "LEVELS", "Mixer",
		"save", "load", "Offline",
	} {
		if strings.Contains(out, unwanted) {
			t.Errorf("panel still shows %q", unwanted)
		}
	}
}

// The Levels tab is the EVO 8 vertical meter page: dB barometer, Capture
// group (IN1/IN2) and Playback group (OUT1/OUT2).
func TestUGMLevelsTabListsChannels(t *testing.T) {
	m := ugmModel(t)
	m.evo.window = evoWinLevels
	out := stripANSI(m.ugmView())
	for _, want := range []string{
		"Capture", "Playback (USB)", "IN1", "IN2", "OUT1", "OUT2",
		"-60", "p freeze", "Tab view",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("levels tab missing %q", want)
		}
	}
	if strings.Contains(out, "OUTPUT 1|2") {
		t.Error("levels tab still draws the controls card")
	}
	if !strings.Contains(out, "░░░") {
		t.Error("levels tab has no vertical bar cells")
	}
}

func TestUGMTabAndControlKeys(t *testing.T) {
	m := ugmModel(t)
	m.ugmKey("tab")
	if m.evo.window != evoWinLevels {
		t.Fatal("Tab did not open Levels")
	}
	m.ugmKey("tab")
	if m.evo.window != evoWinControls {
		t.Fatal("Tab did not return to Controls")
	}
	if cmd := m.ugmKey("ctrl+right"); cmd == nil {
		t.Error("Ctrl+Right must adjust the volume")
	}
	if cmd := m.ugmKey("r"); cmd == nil {
		t.Error("r must reset the volume")
	}
	m.ugmKey("q")
	if m.top() != scrConfirm {
		t.Fatal("q did not open the quit confirmation")
	}
}
