package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestParseAppListKeepsNamesWithSpacesAndOldFormat(t *testing.T) {
	if got := parseAppList("Visual Studio Code|Steam|Discord"); len(got) != 3 || got[0] != "Visual Studio Code" {
		t.Fatalf("pipe list parsed as %q", got)
	}
	if got := parseAppList("Steam Discord"); len(got) != 2 || got[1] != "Discord" {
		t.Fatalf("legacy list parsed as %q", got)
	}
}

func TestDesktopAppNameSkipsHiddenAndNonApps(t *testing.T) {
	dir := t.TempDir()
	write := func(name, body string) string {
		path := filepath.Join(dir, name)
		if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
		return path
	}
	if got, ok := desktopAppName(write("ok.desktop", "[Desktop Entry]\nType=Application\nName=Visual Studio Code\nExec=code %f\n")); !ok || got != "Visual Studio Code" {
		t.Fatalf("visible app = %q, %v", got, ok)
	}
	if _, ok := desktopAppName(write("hidden.desktop", "[Desktop Entry]\nType=Application\nName=Hidden\nNoDisplay=true\n")); ok {
		t.Error("NoDisplay entry listed")
	}
	if _, ok := desktopAppName(write("link.desktop", "[Desktop Entry]\nType=Link\nName=Link\n")); ok {
		t.Error("non-Application entry listed")
	}
}

func TestSelectedAppsStartWithAddRow(t *testing.T) {
	items := defaultSettings().selectedAppItems()
	if len(items) == 0 || items[0].Value != "add_app" {
		t.Fatalf("selected apps page does not start with the add row: %#v", items)
	}
}

// Superwhisper is the one background app a session closes by default: it had
// been replaced by six app names the machine never ran.
func TestTheDefaultCloseListIsSuperwhisper(t *testing.T) {
	s := defaultSettings()
	if len(s.CloseAppsList) != 1 || s.CloseAppsList[0] != "Superwhisper" {
		t.Fatalf("default close list = %q, want [Superwhisper]", s.CloseAppsList)
	}
}

// Relaunching closed apps is opt-in: absence in the file means off, and a
// written "yes" survives a round trip.
func TestRelaunchClosedAppsIsOptInAndPersists(t *testing.T) {
	if defaultSettings().RelaunchApps {
		t.Fatal("relaunch must default to off")
	}
	path := isolateSettings(t)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("RELAUNCH_APPS=\"no\"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if loadSettings().RelaunchApps {
		t.Fatal("RELAUNCH_APPS=no read as on")
	}
	s := defaultSettings()
	s.RelaunchApps = true
	if err := saveSettings(s); err != nil {
		t.Fatal(err)
	}
	if !loadSettings().RelaunchApps {
		t.Fatal("RELAUNCH_APPS=yes lost on round trip")
	}
}

func TestAllAppsUseFilledOrHollowCircle(t *testing.T) {
	s := defaultSettings()
	for _, it := range s.allAppItems() {
		if !strings.HasPrefix(it.Display, "● ") && !strings.HasPrefix(it.Display, "○ ") {
			t.Fatalf("app row %q lacks a ●/○ mark", it.Display)
		}
	}
}

// The security hardening and the PipeWire lock are on by default, and only an
// explicit "no" turns them off.
func TestPasswordlessSudoAndPipewireLockDefaultOnAndPersist(t *testing.T) {
	s := defaultSettings()
	if !s.DisablePasswordlessSudo || !s.PipewireAutolock {
		t.Fatalf("defaults = sudo %v / pipewire lock %v, want both on", s.DisablePasswordlessSudo, s.PipewireAutolock)
	}
	path := isolateSettings(t)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("DISABLE_PASSWORDLESS_SUDO=\"no\"\nPIPEWIRE_AUTOLOCK=\"no\"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	got := loadSettings()
	if got.DisablePasswordlessSudo || got.PipewireAutolock {
		t.Fatalf("explicit no ignored: %+v", got)
	}
	if err := saveSettings(got); err != nil {
		t.Fatal(err)
	}
	got = loadSettings()
	if got.DisablePasswordlessSudo || got.PipewireAutolock {
		t.Fatalf("round trip flipped: %+v", got)
	}
}
