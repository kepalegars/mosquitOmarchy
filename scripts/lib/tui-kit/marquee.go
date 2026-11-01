package tuikit

import (
	"time"

	"github.com/charmbracelet/x/ansi"
)

// Marquee timing. One column per rendered frame, then a short hold at the
// start after the text has fully re-entered, so the eye can re-read the
// beginning. frameInterval is the repaint cadence ThemeWatchCmd already drives
// in every host, so a marquee needs no extra tick of its own.
const (
	frameInterval = 100 * time.Millisecond
	marqueePause  = 3500 * time.Millisecond
)

// The kit has one active picker per TUI; keeping this focus epoch outside the
// delegate survives the fresh Picker values hosts build on every refresh.
var selectedMarqueeKey string
var selectedMarqueeStart time.Time

// MarqueeText fits s into width columns. Text that already fits is returned
// unchanged.
//
// The scrolling strip is the title, ONE blank column, then the title again:
//
//	[title] [title] ...
//
// so while the last character of the first copy goes through the left edge,
// the second copy is already arriving from the right, separated by exactly one
// space. The scroll stops as soon as that second copy's first character sits at
// column 1 (the title is readable again), holds for marqueePause, then repeats.
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
	// Columns 0..total are the first copy leaving; the blank column is at
	// total, and the second copy starts at total+1. Scrolling that far puts
	// its first character at position 1, which is the end of the cycle.
	travel := total + 1
	period := marqueePause + time.Duration(travel)*frameInterval
	t := now.UnixNano() % int64(period)
	pause := int64(marqueePause)

	if t < pause {
		return ansi.Truncate(s, width, "")
	}
	offset := 1 + int((t-pause)/int64(frameInterval))
	if offset > travel {
		offset = travel
	}
	strip := s + " " + s
	return ansi.Truncate(ansi.TruncateLeft(strip, offset, ""), width, "")
}

// selectedMarqueeText starts a complete cycle when the picker cursor changes
// rows. Only the selected row calls this; non-selected rows stay still/clipped.
func selectedMarqueeText(key, s string, width int, now time.Time) string {
	if key != selectedMarqueeKey {
		selectedMarqueeKey, selectedMarqueeStart = key, now
	}
	if width <= 0 || ansi.StringWidth(s) <= width {
		return s
	}
	return MarqueeText(s, width, time.Unix(0, now.Sub(selectedMarqueeStart).Nanoseconds()))
}
