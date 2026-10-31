package tuikit

import (
	"time"

	"github.com/charmbracelet/x/ansi"
)

// Marquee timing. One column per rendered frame, then a short hold at the
// start after the text jumps back, so the eye can re-read the beginning.
// frameInterval is the repaint cadence ThemeWatchCmd already drives in every
// host, so a marquee needs no extra tick of its own.
const (
	frameInterval = 100 * time.Millisecond
	marqueePause  = 1200 * time.Millisecond
)

// MarqueeText fits s into width columns. Text that already fits is returned
// unchanged. Text that does not scrolls left one column per frame, jumps back
// to the start at the end, holds there for marqueePause, and repeats forever.
//
// Pure in now: every row derives its window from the clock at render time, so
// the kit needs no per-row state and a test can drive the cycle explicitly.
func MarqueeText(s string, width int, now time.Time) string {
	if width <= 0 {
		return ""
	}
	total := ansi.StringWidth(s)
	if total <= width {
		return s
	}
	travel := total - width
	period := marqueePause + time.Duration(travel)*frameInterval
	t := now.UnixNano() % int64(period)
	var offset int
	if t >= int64(marqueePause) {
		offset = 1 + int((t-int64(marqueePause))/int64(frameInterval))
		if offset > travel {
			offset = travel
		}
	}
	return ansi.Truncate(ansi.TruncateLeft(s, offset, ""), width, "")
}
