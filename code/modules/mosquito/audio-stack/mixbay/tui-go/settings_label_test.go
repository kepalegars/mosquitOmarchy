package main

import (
	"strings"
	"testing"
)

// The old "Notify when an interface is connected" row was easy to confuse
// with detection. The name has to say "connection" for the setting the
// watcher actually gates.
func TestConnectionNoticeSettingIsNamedForConnections(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	m := initialModel()
	for _, it := range m.settingsItems() {
		if it.Value != "notify_cards" {
			continue
		}
		if !strings.Contains(strings.ToLower(it.Display), "connection") {
			t.Fatalf("connection notice row reads %q, want 'connection' in the name", it.Display)
		}
		return
	}
	t.Fatal("notify_cards row missing from Settings")
}
