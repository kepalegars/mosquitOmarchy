package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestAggregateLockRoundTrip(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	s := defaultSettings()
	s.AggregateLock = false
	if err := saveSettings(s); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(filepath.Join(os.Getenv("HOME"), ".config", "live-mode", "settings"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), `AGGREGATE_LOCK="no"`) {
		t.Fatalf("settings file missing the fence key:\n%s", data)
	}
	if got := loadSettings().AggregateLock; got {
		t.Fatal("AGGREGATE_LOCK=no must survive a read")
	}
}

func TestAggregateLockDefaultsOnAndRowNeedsMixbay(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if !defaultSettings().AggregateLock {
		t.Fatal("the fence must be on by default")
	}
	m := initialModel()
	var row struct {
		Value    string
		Disabled bool
	}
	for _, it := range m.mainItems() {
		if it.Value == "aggregate_lock" {
			row.Value, row.Disabled = it.Value, it.Disabled
		}
	}
	if row.Value != "aggregate_lock" {
		t.Fatal("main page must carry the aggregate lock row")
	}
}
