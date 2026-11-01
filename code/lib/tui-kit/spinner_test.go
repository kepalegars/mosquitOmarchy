package tuikit

import (
	"testing"
	"time"
)

func TestLoadingGlyph(t *testing.T) {
	want := []string{"■", " "} // solid square on, then off
	if len(LoadingFrames) != len(want) {
		t.Fatalf("frames = %q, want %q", LoadingFrames, want)
	}
	for i, w := range want {
		if got := LoadingGlyph(i); got != w {
			t.Fatalf("frame %d = %q, want %q", i, got, w)
		}
	}
	if got := LoadingGlyph(2); got != "■" {
		t.Fatalf("wrapped frame = %q, want ■", got)
	}
	if got := LoadingGlyph(-1); got != " " {
		t.Fatalf("negative frame = %q, want the off frame", got)
	}
	// The off frame keeps a cell of width so the trailing badge cannot shift.
	if len(LoadingFrames[1]) != 1 {
		t.Fatalf("off frame width = %d, want 1", len(LoadingFrames[1]))
	}
}

func TestLoadingGlyphAt(t *testing.T) {
	base := time.Unix(100, 0)
	first := LoadingGlyphAt(base)
	if first != "■" && first != " " {
		t.Fatalf("unexpected frame %q", first)
	}
	// One blink period later the phase is back where it started.
	if got := LoadingGlyphAt(base.Add(loadingBlinkInterval * time.Duration(len(LoadingFrames)))); got != first {
		t.Fatalf("one full blink = %q, want %q", got, first)
	}
	// The two phases must differ.
	if got := LoadingGlyphAt(base.Add(loadingBlinkInterval)); got == first {
		t.Fatalf("blink did not toggle: %q", got)
	}
}
