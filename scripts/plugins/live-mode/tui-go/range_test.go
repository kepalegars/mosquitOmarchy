package main

import (
	"testing"

	tuikit "mosquitomarchy.local/tui-kit"
)

// A Tab-held range over the apps list joins every known app on the way to
// the close-at-start set; unknown values are ignored, listed ones stay.
func TestAppsRangeJoinsKnownApps(t *testing.T) {
	m := initialModel()
	m.nav = []screen{scrMain, scrApps}
	m.settings.CloseAppsList = []string{"Steam"}
	mm, _ := m.update(tuikit.PickerRangeMsg{
		Values: []string{"kDrive", "qBittorrent", "no-such-app"},
		Anchor: "kDrive",
	})
	got, _ := mm.(model)
	for _, want := range []string{"Steam", "kDrive", "qBittorrent"} {
		if !hasApp(got.settings.CloseAppsList, want) {
			t.Fatalf("%s missing after range: %v", want, got.settings.CloseAppsList)
		}
	}
	if hasApp(got.settings.CloseAppsList, "no-such-app") {
		t.Fatalf("unknown value joined the list: %v", got.settings.CloseAppsList)
	}
}
