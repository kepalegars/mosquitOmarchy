package main

import (
	"strings"
	"testing"

	tuikit "mosquitomarchy.local/tui-kit"
)

func settingRow(t *testing.T, value string) tuikit.PickerItem {
	t.Helper()
	m := initialModel()
	for _, it := range m.settingsItems() {
		if it.Value == value {
			return it
		}
	}
	t.Fatalf("%s row missing from Settings", value)
	return tuikit.PickerItem{}
}

// The connection notice row took a few names while chasing the watcher
// switches; keep the one the user settled on.
func TestConnectionNoticeSettingName(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if got := settingRow(t, "notify_cards").Display; got != "Notify when an interface is connected: on" {
		t.Fatalf("connection notice row reads %q", got)
	}
}

// Detection owns every watcher notice setting. With detection off, keeping
// notices on screen is meaningless and must be greyed like the other two rows.
func TestStickyNoticeGreyedWithDetection(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	m := initialModel()
	sticky := func() tuikit.PickerItem {
		for _, it := range m.settingsItems() {
			if it.Value == "notify_sticky" {
				return it
			}
		}
		t.Fatal("notify_sticky row missing")
		return tuikit.PickerItem{}
	}
	m.ui.DetectCards = false
	if it := sticky(); !it.Disabled {
		t.Fatalf("%q must be greyed when detection is off", it.Display)
	}
	m.ui.DetectCards = true
	m.ui.WatcherMode = watcherOff
	if it := sticky(); !it.Disabled {
		t.Fatalf("%q must be greyed when the watcher is off", it.Display)
	}
	m.ui.WatcherMode = watcherAlways
	if it := sticky(); it.Disabled {
		t.Fatalf("%q must be selectable when detection and watcher are on", it.Display)
	}
}

func TestDetectSettingName(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if got := settingRow(t, "detect_cards").Display; !strings.Contains(got, "interface") {
		t.Fatalf("detection row reads %q, want 'interface' in the name", got)
	}
}
