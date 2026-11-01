package tuikit

import (
	"strings"
	"testing"
	"time"
)

// TestMarqueeText drives one full cycle: hold at the start, scroll the title
// and its next copy together (one blank column between them), stop when the
// second copy's first character reaches position 1, then hold and repeat.
func TestMarqueeText(t *testing.T) {
	const text = "abcdefghij"
	const width = 5
	base := time.Unix(0, 0)
	period := marqueePause + time.Duration(len(text)+1)*frameInterval

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
	// Last frame where the first copy's last character is still visible.
	if got := MarqueeText(text, width, base.Add(marqueePause+8*frameInterval)); got != "j abc" {
		t.Fatalf("before the last character leaves = %q, want j abc", got)
	}
	// The LAST character is hidden through the left edge, and the title is
	// already coming back after exactly one blank column.
	if got := MarqueeText(text, width, base.Add(marqueePause+9*frameInterval)); got != " abcd" {
		t.Fatalf("last character left = %q, want one space then the new copy", got)
	}
	if strings.Contains(MarqueeText(text, width, base.Add(marqueePause+9*frameInterval)), "j") {
		t.Fatal("the last character must be gone through the left edge")
	}
	// The second copy's first character reaches position 1: end of the cycle.
	if got := MarqueeText(text, width, base.Add(marqueePause+10*frameInterval)); got != "abcde" {
		t.Fatalf("completed re-entry = %q, want the start again", got)
	}
	// A full period later the window is back at the held start.
	if got := MarqueeText(text, width, base.Add(period)); got != "abcde" {
		t.Fatalf("loop = %q, want the start again", got)
	}
	// A narrow window must never show a fully blank frame: the gap is one
	// column, and the next copy follows immediately.
	for i := 0; i <= len(text)+1; i++ {
		got := MarqueeText(text, width, base.Add(marqueePause+time.Duration(i)*frameInterval))
		if strings.TrimSpace(got) == "" && width > 1 {
			t.Fatalf("frame %d is blank: %q", i, got)
		}
	}
}

func TestSelectedMarqueeStartsAndCompletesEachFocusCycle(t *testing.T) {
	const text = "abcdefghij"
	const width = 5
	base := time.Unix(100, 0)
	key := "selected-marquee-test"
	period := marqueePause + time.Duration(len(text)+1)*frameInterval

	if got := selectedMarqueeText(key, text, width, base); got != "abcde" {
		t.Fatalf("focus start = %q, want beginning", got)
	}
	if got := selectedMarqueeText(key, text, width, base.Add(marqueePause)); got != "bcdef" {
		t.Fatalf("scroll start = %q, want bcdef", got)
	}
	if got := selectedMarqueeText(key, text, width, base.Add(period)); got != "abcde" {
		t.Fatalf("completed cycle = %q, want beginning", got)
	}
	// Moving the selection to another row starts its own complete trip, rather
	// than inheriting the previous row's global scroll offset.
	if got := selectedMarqueeText(key+"-next", text, width, base.Add(period+3*frameInterval)); got != "abcde" {
		t.Fatalf("new focus inherited the previous offset: %q", got)
	}
}
