package tuikit

import "time"

// LoadingFrames is the shared loading indicator: the solid square blinks on
// and off. It is the same square the pending-update marker uses, so every TUI
// has one identical footprint; the off frame is a space (not an empty string)
// so a PickerItem's trailing badge never shifts the row.
var LoadingFrames = []string{"■", " "}

// loadingBlinkInterval is the on/off period for hosts that use the time-based
// helper. Slower than the marquee frame on purpose: a blink is a state, not an
// animation.
const loadingBlinkInterval = 500 * time.Millisecond

// LoadingGlyph returns frame n of the shared blink. A host that already keeps
// an animation counter (mosquitomarchy's loading tick) calls this with its own
// frame index.
func LoadingGlyph(frame int) string {
	n := len(LoadingFrames)
	if n == 0 {
		return ""
	}
	frame %= n
	if frame < 0 {
		frame += n
	}
	return LoadingFrames[frame]
}

// LoadingGlyphAt returns the blink frame for a point in time. Hosts that
// repaint on a tick but keep no counter can just call this on every render;
// nothing to initialise or reset.
func LoadingGlyphAt(now time.Time) string {
	n := len(LoadingFrames)
	if n == 0 {
		return ""
	}
	ticks := now.UnixNano() / int64(loadingBlinkInterval)
	if ticks < 0 {
		ticks = -ticks
	}
	return LoadingFrames[int(ticks%int64(n))]
}

// LoadingGlyphStyled is LoadingGlyph already rendered in the theme accent, for
// hosts that draw it themselves instead of through a PickerItem's
// TrailingBadge (which applies the accent automatically).
func LoadingGlyphStyled(frame int) string {
	return StyleAccent.Render(LoadingGlyph(frame))
}
