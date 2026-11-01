package tuikit

import (
	"strings"
	"testing"
	"time"
)

func TestLoadingGlyph(t *testing.T) {
	want := []string{"▘", "▝", "▗", "▖"} // clockwise
	if len(LoadingFrames) != len(want) {
		t.Fatalf("frames = %q, want %q", LoadingFrames, want)
	}
	for i, w := range want {
		if got := LoadingGlyph(i); got != w {
			t.Fatalf("frame %d = %q, want %q", i, got, w)
		}
	}
	if got := LoadingGlyph(5); got != "▝" {
		t.Fatalf("wrapped frame = %q, want ▝", got)
	}
	if got := LoadingGlyph(-1); got != "▖" {
		t.Fatalf("negative frame = %q, want ▖", got)
	}
	// The old ◰ family drew a large outline square; the shared spinner must
	// draw only the moving block.
	for _, f := range LoadingFrames {
		if strings.ContainsAny(f, "◰◳◲◱■□") {
			t.Fatalf("frame %q still contains an outer square", f)
		}
	}
}

func TestLoadingGlyphAt(t *testing.T) {
	base := time.Unix(100, 0)
	first := LoadingGlyphAt(base)
	for i := 0; i < len(LoadingFrames)*4; i++ {
		got := LoadingGlyphAt(base.Add(time.Duration(i) * frameInterval))
		if got == "" {
			t.Fatalf("frame at %d is empty", i)
		}
	}
	// A full lap returns to the same frame.
	lap := time.Duration(len(LoadingFrames)) * frameInterval
	if got := LoadingGlyphAt(base.Add(lap)); got != first {
		t.Fatalf("one lap = %q, want %q", got, first)
	}
}
