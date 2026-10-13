package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The patchbay slot defaults to mixbay: the mosquito USB audio bay is the
// session's desk tool, qpwgraph only the fallback. A fresh machine that
// never touched the settings must already prefer it.
func TestThePatchbayDefaultsToMixbay(t *testing.T) {
	isolateSettings(t)
	if got := defaultSettings().PatchbayApp; got != "mixbay" {
		t.Errorf("default patchbay = %q, want mixbay", got)
	}
	if err := saveSettings(defaultSettings()); err != nil {
		t.Fatal(err)
	}
	if got := loadSettings().PatchbayApp; got != "mixbay" {
		t.Errorf("freshly written file reads patchbay = %q, want mixbay", got)
	}
}

// An unrecognised value must fall back to mixbay, never to an app name the
// launcher cannot resolve.
func TestAnUnknownPatchbayValueFallsBackToMixbay(t *testing.T) {
	path := isolateSettings(t)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	for _, v := range []string{"peut-etre", "", "jack", "MIXBAY"} {
		if err := os.WriteFile(path, []byte("PATCHBAY_APP=\""+v+"\"\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		if got := loadSettings().PatchbayApp; got != "mixbay" {
			t.Errorf("PATCHBAY_APP=%q read as %q, want mixbay", v, got)
		}
	}
}

// The choice has to survive a write and a read, since the manager rewrites
// the whole file on every settings change.
func TestThePatchbayChoiceSurvivesAWriteAndARead(t *testing.T) {
	isolateSettings(t)
	s := defaultSettings()
	s.PatchbayApp = "qpwgraph"
	if err := saveSettings(s); err != nil {
		t.Fatal(err)
	}
	if got := loadSettings().PatchbayApp; got != "qpwgraph" {
		t.Errorf("round trip gave %q, want qpwgraph", got)
	}
}

// The row is on the manager's main page, showing the current choice so the
// consequence (which app a session parks) is obvious before activation.
func TestThePatchbayHasARowOnTheMainPage(t *testing.T) {
	m := initialModel()
	for _, it := range m.mainItems() {
		if it.Value == "patchbay" {
			if !strings.Contains(it.Display, "mixbay") {
				t.Errorf("the row does not show the choice: %q", it.Display)
			}
			return
		}
	}
	t.Fatal("no patchbay row on the main page")
}
