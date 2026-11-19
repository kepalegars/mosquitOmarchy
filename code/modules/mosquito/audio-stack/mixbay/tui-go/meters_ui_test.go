package main

import (
	"math"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"mosquitomarchy.local/mosquitomixbay-tui/drivers"
)

// The Levels page is spec-driven now: EVO 4 must get its own 4-channel
// layout, not the EVO 8's six bars with two dead channels.
func TestEVOMeterBarsFollowSpec(t *testing.T) {
	cases := []struct {
		spec     drivers.Spec
		capture  []string
		playback []string
	}{
		{
			spec:     drivers.EVO4Spec,
			capture:  []string{"IN1", "IN2", "LP3", "LP4"},
			playback: []string{"PC1", "PC2", "LP3", "LP4"},
		},
		{
			spec:     drivers.EVO8Spec,
			capture:  []string{"IN1", "IN2", "IN3", "IN4", "LP5", "LP6"},
			playback: []string{"PC1", "PC2", "PC3", "PC4", "LP5", "LP6"},
		},
	}
	for _, tc := range cases {
		gotC := evoCaptureBarsFor(tc.spec)
		if len(gotC) != len(tc.capture) {
			t.Fatalf("%s capture bars: got %d, want %d", tc.spec.ID, len(gotC), len(tc.capture))
		}
		for i, want := range tc.capture {
			if gotC[i].label != want || gotC[i].ch != i {
				t.Fatalf("%s capture[%d] = %q/%d, want %q/%d", tc.spec.ID, i, gotC[i].label, gotC[i].ch, want, i)
			}
		}
		gotP := evoPlaybackBarsFor(tc.spec)
		if len(gotP) != len(tc.playback) {
			t.Fatalf("%s playback bars: got %d, want %d", tc.spec.ID, len(gotP), len(tc.playback))
		}
		for i, want := range tc.playback {
			if gotP[i].label != want || gotP[i].ch != i {
				t.Fatalf("%s playback[%d] = %q/%d, want %q/%d", tc.spec.ID, i, gotP[i].label, gotP[i].ch, want, i)
			}
		}
	}
}

// fakePWLink puts a scripted pw-link on PATH: four playback and four capture
// ports on an Acme node, plus an unrelated EVO node to prove a declared
// binding never falls back to it.
func fakePWLink(t *testing.T) {
	t.Helper()
	dir := t.TempDir()
	script := `#!/bin/sh
if [ "$1" = "-i" ]; then
cat <<'PORTS'
alsa_output.usb-Acme_Quantum_ES_4-00.pro-output-0:playback_FL
alsa_output.usb-Acme_Quantum_ES_4-00.pro-output-0:playback_FR
alsa_output.usb-Acme_Quantum_ES_4-00.pro-output-0:playback_RL
alsa_output.usb-Acme_Quantum_ES_4-00.pro-output-0:playback_RR
alsa_output.usb-Audient_EVO8-00.pro-output-0:playback_FL
PORTS
else
cat <<'PORTS'
alsa_input.usb-Acme_Quantum_ES_4-00.pro-input-0:capture_FL
alsa_input.usb-Acme_Quantum_ES_4-00.pro-input-0:capture_FR
alsa_input.usb-Acme_Quantum_ES_4-00.pro-input-0:capture_RL
alsa_input.usb-Acme_Quantum_ES_4-00.pro-input-0:capture_RR
PORTS
fi
`
	path := filepath.Join(dir, "pw-link")
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
}

func TestMeterBindingDrivesDiscoveryAndBars(t *testing.T) {
	fakePWLink(t)
	spec := drivers.Spec{
		ID: "quantum-es4", Vendor: "PreSonus",
		Meters: &drivers.MeterSpec{
			Node:     "Quantum ES 4",
			Capture:  []string{"IN1", "IN2", "IN3", "IN4"},
			Playback: []string{"OUT1", "OUT2"},
			FloorDb:  -48,
		},
	}
	srcs := usbMeterSources(spec)
	if len(srcs) != 2 {
		t.Fatalf("sources = %+v", srcs)
	}
	play, in := srcs[0], srcs[1]
	if play.Key != "playback" || !play.Monitor || play.Channels != 2 || !meterNodeMatches(play.Node, "Quantum ES 4", true) {
		t.Fatalf("playback source = %+v", play)
	}
	if in.Key != "input" || in.Channels != 4 || !meterNodeMatches(in.Node, "Quantum ES 4", true) {
		t.Fatalf("input source = %+v", in)
	}

	capBars := evoCaptureBarsFor(spec)
	if len(capBars) != 4 || capBars[3].label != "IN4" || capBars[3].ch != 3 {
		t.Fatalf("capture bars = %+v", capBars)
	}
	playBars := evoPlaybackBarsFor(spec)
	if len(playBars) != 2 || playBars[1].label != "OUT2" {
		t.Fatalf("playback bars = %+v", playBars)
	}
}

func TestMeterBindingNeverFallsBack(t *testing.T) {
	fakePWLink(t)
	spec := drivers.Spec{
		ID: drivers.DevEVO8, Vendor: "Audient",
		Meters: &drivers.MeterSpec{Node: "Absent", Capture: []string{"IN1"}},
	}
	if node, ch := discoverMeterNode(spec, false); node != "" || ch != 0 {
		t.Fatalf("absent binding fell back to %q/%d", node, ch)
	}
	if srcs := usbMeterSources(spec); srcs != nil {
		t.Fatalf("sources = %+v, want none", srcs)
	}
}

func TestMeterFloorIsACardChoice(t *testing.T) {
	if got := meterTicks(-60); len(got) != 6 || got[0] != -60 || got[5] != 0 {
		t.Fatalf("default ticks changed: %v", got)
	}
	if got := meterDB(0.01, -40); got != -40 {
		t.Fatalf("meterDB floor = %v, want -40", got)
	}
	got := meterFraction(0.01, -60)
	if math.Abs(got-1.0/3.0) > 1e-9 {
		t.Fatalf("fraction with -60 = %v, want 1/3", got)
	}
	if got := meterFraction(0.01, -40); got != 0 {
		t.Fatalf("fraction below -40 floor = %v, want 0", got)
	}
}

func TestMeterBindingCanBeOneDirection(t *testing.T) {
	m := evoModel(t, drivers.DevEVO8, evoWinLevels)
	bind := &drivers.MeterSpec{Node: "Acme", Playback: []string{"OUT1", "OUT2"}}
	m.status.Spec.Meters = bind
	m.evo.spec.Meters = bind
	plain := stripANSI(m.evoView())
	if !strings.Contains(plain, "Playback (USB)") || !strings.Contains(plain, "OUT1") {
		t.Fatalf("playback-only Levels view is missing its group:\n%s", plain)
	}
	if strings.Contains(plain, "Capture") {
		t.Fatalf("playback-only binding still renders an empty Capture group:\n%s", plain)
	}
	if evoCaptureBarsFor(m.evo.spec) != nil {
		t.Fatal("empty capture map must not fall back to EVO bars")
	}
}
