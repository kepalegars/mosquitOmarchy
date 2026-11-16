package main

import (
	"strings"
	"testing"

	"mosquitomarchy.local/mosquitomixbay-tui/drivers"
)

func moveModel(t *testing.T) model {
	t.Helper()
	m := initialModel()
	m.deviceID = drivers.DevMove
	m.nav = []screen{scrDevices, scrControls}
	m.w, m.h = 100, 30
	m.session = liveSession{live: true, online: true}
	m.status = drivers.Status{Spec: drivers.MoveSpec, Online: true}
	return m
}

// The Move page is the Levels page only, and the 44.1 kHz limitation is on
// screen even when the card is online: that note is the whole point.
func TestMovePageShowsLevelsAndTheRateNote(t *testing.T) {
	out := stripANSI(moveModel(t).moveView())
	for _, want := range []string{"Ableton Move", "Capture", "Playback (USB)", "44.1kHz", "reset peaks"} {
		if !strings.Contains(out, want) {
			t.Fatalf("Move page is missing %q:\n%s", want, out)
		}
	}
	if strings.Contains(out, "Controls") {
		t.Fatalf("Move page must not offer a Controls tab (no software mixer):\n%s", out)
	}
}

// The preset routes to the Move renderer even when the id is a downloaded
// card with the same preset.
func TestMovePresetRoutesToMovePage(t *testing.T) {
	m := model{deviceID: "some-imported-card", preset: "move"}
	if !m.isMoveDevice() || m.isUGMDevice() || m.isEvoDevice() {
		t.Fatal("move preset did not route to the Move page")
	}
	m.preset = "auto"
	m.deviceID = drivers.DevMove
	if !m.isMoveDevice() {
		t.Fatal("move device id did not route to the Move page")
	}
}

func TestWrapWordsFitsTheWidth(t *testing.T) {
	lines := wrapWords(moveNote, 60)
	if len(lines) < 2 {
		t.Fatalf("note was not wrapped: %v", lines)
	}
	for _, l := range lines {
		if len([]rune(l)) > 60 {
			t.Fatalf("line %q is %d columns", l, len([]rune(l)))
		}
	}
}
