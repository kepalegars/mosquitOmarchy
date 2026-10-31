package tuikit

import (
	"testing"
	"time"
)

// TestMarqueeText drives one full cycle: hold at the start, scroll to the
// tail, jump back to the start, hold, repeat. Time is explicit so the
// assertion never depends on the wall clock.
func TestMarqueeText(t *testing.T) {
	const text = "abcdefghij"
	const width = 5
	base := time.Unix(0, 0)

	if got := MarqueeText("abcde", width, base); got != "abcde" {
		t.Fatalf("text that fits = %q, want unchanged", got)
	}
	if got := MarqueeText(text, 0, base); got != "" {
		t.Fatalf("zero width = %q, want empty", got)
	}

	// Held at the beginning for the pause.
	for _, at := range []time.Duration{0, marqueePause - time.Millisecond} {
		if got := MarqueeText(text, width, base.Add(at)); got != "abcde" {
			t.Fatalf("at %v = %q, want the held start", at, got)
		}
	}

	// One column per frame once the pause is over.
	if got := MarqueeText(text, width, base.Add(marqueePause)); got != "bcdef" {
		t.Fatalf("first scroll frame = %q, want bcdef", got)
	}
	// Last window before the wrap: the tail fills the width.
	if got := MarqueeText(text, width, base.Add(marqueePause+4*frameInterval)); got != "fghij" {
		t.Fatalf("tail = %q, want fghij", got)
	}

	// A full period later the window is back at the held start.
	period := marqueePause + 5*frameInterval
	if got := MarqueeText(text, width, base.Add(period)); got != "abcde" {
		t.Fatalf("loop = %q, want the start again", got)
	}
}
