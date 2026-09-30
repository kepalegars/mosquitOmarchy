package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// HOME is redirected in every test that touches the settings file, so a failing
// or half-finished test can never write the user's real
// ~/.config/live-mode/settings.
func isolateSettings(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("HOME", dir)
	return filepath.Join(dir, ".config", "live-mode", "settings")
}

// The fence is OFF unless asked for, and that default is the whole point.
//
// It used to be unconditional, and the user hit
//
//	error: failed to init transaction (unable to lock database)
//
// for as long as a live session lasted. Live mode installs nothing, so the
// lock protected nothing and only got in the way. Putting it back is only
// defensible if it cannot happen by accident.
func TestThePackageFenceIsOffByDefault(t *testing.T) {
	isolateSettings(t)
	if defaultSettings().FencePackages {
		t.Error("the fence defaults to ON")
	}
	if err := saveSettings(defaultSettings()); err != nil {
		t.Fatal(err)
	}
	if loadSettings().FencePackages {
		t.Error("a freshly written file turned the fence on")
	}
}

// An unrecognised value must leave the fence OFF, not flip it. This is matched
// on "yes" rather than "!= no" precisely because defaulting a
// safety-aversive setting ON because the file says nothing is the mistake the
// fence already made once.
func TestAnUnknownFenceValueLeavesItOff(t *testing.T) {
	path := isolateSettings(t)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	for _, v := range []string{"peut-etre", "", "1", "true", "no", "NO"} {
		if err := os.WriteFile(path, []byte("FENCE_PACKAGES=\""+v+"\"\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		if loadSettings().FencePackages {
			t.Errorf("FENCE_PACKAGES=%q turned the fence ON", v)
		}
	}
	if err := os.WriteFile(path, []byte("FENCE_PACKAGES=\"yes\"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if !loadSettings().FencePackages {
		t.Error(`FENCE_PACKAGES="yes" did not turn the fence on`)
	}
}

// The row is on the manager's main page, worded so the consequence is obvious
// before it is switched on: it does not add anything, it BLOCKS.
func TestTheFenceHasARowOnTheMainPage(t *testing.T) {
	m := initialModel()
	for _, it := range m.mainItems() {
		if it.Value == "fence" {
			if !strings.Contains(it.Display, "Block package installation") {
				t.Errorf("the row does not say what it does: %q", it.Display)
			}
			return
		}
	}
	t.Fatal("no fence row on the main page")
}

// The round trip has to keep working through save AND load, since the manager
// writes the whole file every time any setting changes.
func TestTheFenceSurvivesAWriteAndARead(t *testing.T) {
	isolateSettings(t)
	s := defaultSettings()
	s.FencePackages = true
	if err := saveSettings(s); err != nil {
		t.Fatal(err)
	}
	if !loadSettings().FencePackages {
		t.Error("the fence did not survive a write and a read")
	}
	// And turning it back off has to persist too.
	s.FencePackages = false
	if err := saveSettings(s); err != nil {
		t.Fatal(err)
	}
	if loadSettings().FencePackages {
		t.Error("turning the fence back off did not persist")
	}
}
