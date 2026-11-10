package main

import (
	"os"
	"path/filepath"
	"testing"
)

// The overwrite question must only appear when a real output exists: the path
// the picker predicts has to be the one pacpl writes (same directory, final
// extension replaced by the lowercase format).
func TestOutputPathMatchesPacplNaming(t *testing.T) {
	cases := []struct{ file, format, want string }{
		{"/music/song.mp4", "mp3", "/music/song.mp3"},
		{"/music/Live set.flac", "wav", "/music/Live set.wav"},
		{"/music/a.b.c.wav", "ogg", "/music/a.b.c.ogg"},
	}
	for _, c := range cases {
		if got := outputPath(c.file, c.format); got != c.want {
			t.Errorf("outputPath(%q, %q) = %q, want %q", c.file, c.format, got, c.want)
		}
	}
}

func TestExistingOutputsOnlyExisting(t *testing.T) {
	dir := t.TempDir()
	fresh := filepath.Join(dir, "fresh.mp4")
	done := filepath.Join(dir, "done.mp4")
	for _, f := range []string{fresh, done, filepath.Join(dir, "done.mp3")} {
		if err := os.WriteFile(f, nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	got := existingOutputs([]string{fresh, done}, "mp3")
	if len(got) != 1 || got[0] != filepath.Join(dir, "done.mp3") {
		t.Fatalf("existingOutputs = %v, want [%s]", got, filepath.Join(dir, "done.mp3"))
	}
	if got := existingOutputs([]string{fresh}, "mp3"); len(got) != 0 {
		t.Fatalf("a missing output must not trigger the overwrite question, got %v", got)
	}
}
