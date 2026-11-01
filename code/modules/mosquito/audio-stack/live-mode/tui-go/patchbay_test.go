package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The patchbay slot defaults to mixbay+qpwgraph: mosquito mixbay as the
// session's desk tool plus qpwgraph as the PipeWire graph, parked together.
// A fresh machine that never touched the settings must already prefer it.
func TestThePatchbayDefaultsToBoth(t *testing.T) {
	isolateSettings(t)
	if got := defaultSettings().PatchbayApp; got != PatchbayBoth {
		t.Errorf("default patchbay = %q, want %q", got, PatchbayBoth)
	}
	if err := saveSettings(defaultSettings()); err != nil {
		t.Fatal(err)
	}
	if got := loadSettings().PatchbayApp; got != PatchbayBoth {
		t.Errorf("freshly written file reads patchbay = %q, want %q", got, PatchbayBoth)
	}
}

// An unrecognised value must fall back to the combo default, never to an app
// name the launcher cannot resolve.
func TestAnUnknownPatchbayValueFallsBackToBoth(t *testing.T) {
	path := isolateSettings(t)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	for _, v := range []string{"peut-etre", "", "jack", "MIXBAY"} {
		if err := os.WriteFile(path, []byte("PATCHBAY_APP=\""+v+"\"\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		if got := loadSettings().PatchbayApp; got != PatchbayBoth {
			t.Errorf("PATCHBAY_APP=%q read as %q, want %q", v, got, PatchbayBoth)
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
// consequence (which apps a session parks) is obvious before activation.
func TestThePatchbayHasARowOnTheMainPage(t *testing.T) {
	isolateSettings(t)
	m := initialModel()
	for _, it := range m.mainItems() {
		if it.Value == "patchbay" {
			if !strings.Contains(it.Display, "mixbay + qpwgraph") {
				t.Errorf("the row does not show the combo default: %q", it.Display)
			}
			return
		}
	}
	t.Fatal("no patchbay row on the main page")
}

// With neither mixbay nor qpwgraph on the machine, the routing and patchbay
// rows stay greyed out and inert; installing either one re-enables them.
func TestScratchpadRowsLockWithoutProviders(t *testing.T) {
	isolateSettings(t)
	old := lookPath
	lookPath = func(string) (string, error) { return "", os.ErrNotExist }
	defer func() { lookPath = old }()

	m := initialModel()
	for _, want := range []string{"routing", "patchbay"} {
		var found bool
		for _, it := range m.mainItems() {
			if it.Value != want {
				continue
			}
			found = true
			if !it.Disabled {
				t.Errorf("row %q is not disabled with no provider installed", want)
			}
		}
		if !found {
			t.Fatalf("no %q row on the main page", want)
		}
	}
}

// With a provider present the rows are enabled again.
func TestScratchpadRowsUnlockWithAProvider(t *testing.T) {
	isolateSettings(t)
	old := lookPath
	lookPath = func(file string) (string, error) {
		if file == "qpwgraph" {
			return "/usr/bin/qpwgraph", nil
		}
		return "", os.ErrNotExist
	}
	defer func() { lookPath = old }()

	m := initialModel()
	for _, it := range m.mainItems() {
		if (it.Value == "routing" || it.Value == "patchbay") && it.Disabled {
			t.Errorf("row %q is disabled even though qpwgraph is present", it.Value)
		}
	}
}
