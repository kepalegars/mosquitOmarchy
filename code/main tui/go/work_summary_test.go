package main

import (
	"strings"
	"testing"
	"time"
)

// Every run must end with the operation it was announced as, plus a duration.
// The point is the pairing: the Working screen title and the end prompt both
// read workOp, so they cannot drift apart.
func TestWorkFinishedTextNamesTheOperation(t *testing.T) {
	cases := []struct {
		sub  string
		want string
	}{
		{"apply", "Setup"},
		{"uninstall", "Uninstall"},
		{"preinstalls-remove", "Uninstall"},
		{"restore", "Restore"},
		{"update-modules", "Update"},
		{"update-repo", "Update"},
		{"backup", "Backup"},
		{"heal", "Repair"},
		{"kb-remove", "Keybindings"},
		{"theme-create", "Theme"},
	}
	for _, c := range cases {
		if got := operationName(c.sub); got != c.want {
			t.Errorf("operationName(%q) = %q, want %q", c.sub, got, c.want)
		}
	}

	m := model{workOp: operationName("uninstall"), workStart: time.Now().Add(-65 * time.Second)}
	if got := m.workFinishedText(false); got != "Uninstall finished in 1m 05s" {
		t.Fatalf("success text = %q", got)
	}
	if got := m.workFinishedText(true); !strings.HasPrefix(got, "Uninstall finished with errors in 1m 05s") {
		t.Fatalf("failure text = %q", got)
	}
}

// A model built without startWorking must not report "in 2562047h…".
func TestWorkFinishedTextWithoutStartTime(t *testing.T) {
	m := model{workOp: "Update"}
	if got := m.workFinishedText(false); got != "Update finished in 0s" {
		t.Fatalf("text = %q", got)
	}
}
