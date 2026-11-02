package main

import (
	"os"
	"path/filepath"
	"testing"
)

// TestCrashToastOffFollowsTheSwitch: missing state is off on a clean install;
// only an explicit "on" enables the toast.
func TestCrashToastOffFollowsTheSwitch(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HOME", dir)
	if !crashToastOff() {
		t.Fatalf("no flag file should default to off")
	}
	flagDir := filepath.Join(dir, ".local", "state", "mosquitomarchy")
	if err := os.MkdirAll(flagDir, 0o755); err != nil {
		t.Fatal(err)
	}
	flag := filepath.Join(flagDir, "crash-notify")
	if err := os.WriteFile(flag, []byte("on\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if crashToastOff() {
		t.Fatalf("flag file says on, yet toast suppressed")
	}
	if err := os.WriteFile(flag, []byte("off\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if !crashToastOff() {
		t.Fatalf("flag file says off, yet toast would fire")
	}
}
