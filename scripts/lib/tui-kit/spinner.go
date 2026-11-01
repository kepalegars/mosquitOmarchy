package tuikit

import "time"

// LoadingFrames is the shared loading spinner: one small filled square that
// moves clockwise through the four corners of the cell. The outer square of
// the ◰ family is deliberately absent — only the moving block is drawn, in the
// host's accent colour. Clockwise order: upper-left, upper-right, lower-right,
// lower-left.
var LoadingFrames = []string{"▘", "▝", "▗", "▖"}

// LoadingGlyph returns frame n of the shared spinner. A host that already
// keeps an animation counter (mosquitomarchy's 140 ms loading tick) calls this
// with its own frame index.
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

// LoadingGlyphAt returns the spinner frame for a point in time. Hosts that
// repaint on a tick but keep no counter can just call this on every render;
// nothing to initialise or reset.
func LoadingGlyphAt(now time.Time) string {
	n := len(LoadingFrames)
	if n == 0 {
		return ""
	}
	ticks := now.UnixNano() / int64(frameInterval)
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
