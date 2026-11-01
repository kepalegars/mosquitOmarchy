package main

import (
	"os"
	"path/filepath"
	"testing"
)

// TestCrashToastOffFollowsTheSwitch: the same flag file the Settings toggle
// writes gates the TUI's own crash toast. Missing file (or anything but
// "off") means notify; only an explicit "off" silences.
func TestCrashToastOffFollowsTheSwitch(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HOME", dir)
	if crashToastOff() {
		t.Fatalf("no flag file, yet toast suppressed")
	}
	flagDir := filepath.Join(dir, ".local", "state", "mosquitomarchy")
	if err := os.MkdirAll(flagDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(flagDir, "crash-notify"), []byte("off\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if !crashToastOff() {
		t.Fatalf("flag file says off, yet toast would fire")
	}
}
