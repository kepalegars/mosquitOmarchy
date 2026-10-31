package main

import (
	"os"
	"path/filepath"
	"testing"
)

// TestFirstRunSilentWhenReady: with no marker but shortcut AND menu entry
// already present, the first-run question stays silent (and marks itself
// asked). With either missing, it asks.
func TestFirstRunSilentWhenReady(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("XDG_CONFIG_HOME", filepath.Join(home, ".config"))
	write := func(rel, body string) {
		p := filepath.Join(home, ".config", rel)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	// Neither present: asks.
	if msg := firstRunCmd()(); msg == nil {
		t.Fatalf("no shortcut/menu, yet silent")
	}
	// Only the shortcut: still asks.
	write("hypr/bindings.lua", `o.bind("SUPER + ALT + M", "mosquitOmarchy", "/home/u/.local/bin/mosquitomarchy", {})`)
	if msg := firstRunCmd()(); msg == nil {
		t.Fatalf("menu entry missing, yet silent")
	}
	// Both present: silent, and never asks again afterwards.
	write("omarchy/extensions/omarchy-menu.jsonc", `{"setup.mosquito.manager": {}}`)
	if msg := firstRunCmd()(); msg != nil {
		t.Fatalf("everything present, yet asks: %v", msg)
	}
	if _, err := os.Stat(shortcutMarkerPath()); err != nil {
		t.Fatalf("marker not recorded: %v", err)
	}
	if msg := firstRunCmd()(); msg != nil {
		t.Fatalf("asks twice: %v", msg)
	}
}
