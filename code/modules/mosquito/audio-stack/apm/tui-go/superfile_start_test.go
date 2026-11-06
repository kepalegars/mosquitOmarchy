package main

import (
	"os"
	"path/filepath"
	"testing"
)

// A stale downloads folder (moved, deleted, or on a disconnected drive) must
// not reach superfile: it draws a red full-screen error for a path it cannot
// stat. The picker falls back to the home folder instead.
func TestExistingDirOrHome(t *testing.T) {
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatalf("home: %v", err)
	}
	tmp := t.TempDir()

	if got := existingDirOrHome(tmp); got != tmp {
		t.Fatalf("existing dir changed: got %q, want %q", got, tmp)
	}
	if got := existingDirOrHome(filepath.Join(tmp, "missing")); got != home {
		t.Fatalf("missing dir did not fall back to home: got %q, want %q", got, home)
	}
	if got := existingDirOrHome(""); got != home {
		t.Fatalf("empty dir did not fall back to home: got %q, want %q", got, home)
	}
	file := filepath.Join(tmp, "file")
	if err := os.WriteFile(file, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if got := existingDirOrHome(file); got != home {
		t.Fatalf("file path did not fall back to home: got %q, want %q", got, home)
	}
}
