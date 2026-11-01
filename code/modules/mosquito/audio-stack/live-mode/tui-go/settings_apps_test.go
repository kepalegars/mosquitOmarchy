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

func TestAllAppsUseFilledOrHollowCircle(t *testing.T) {
	s := defaultSettings()
	for _, it := range s.allAppItems() {
		if !strings.HasPrefix(it.Display, "● ") && !strings.HasPrefix(it.Display, "○ ") {
			t.Fatalf("app row %q lacks a ●/○ mark", it.Display)
		}
	}
}
