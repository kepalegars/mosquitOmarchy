package tuikit

// responsive.go — THE fit rule every mosquito TUI screen obeys.
//
// ## Why this file exists
//
// Five TUIs (mosquitomarchy, Move Manager, Audio Plugin Manager, jamjamjam,
// live-mode) were each carrying their own hand-rolled contentSize() and its own
// idea of what the chrome costs. They disagreed, and the disagreement showed up
// as content spilling off the bottom of a small tiled window: the Move Manager
// overflowed by 4 rows at h=18, the Audio Plugin Manager by 2, and this TUI by
// up to 17. Separately, the boxed "mosquitomarchy" wordmark is 121 columns wide
// and was rendered UNCONDITIONALLY — inside a 100-column tile lipgloss hard-
// wrapped it mid-glyph and the word became unreadable.
//
// Both failures have the same root cause: nothing measured the title, so
// nothing could give way. This file is the single place that measures.
//
// ## The rule
//
// A screen is exactly three blocks:
//
//	title  (variable rows, degrades as the window shrinks)
//	body   (everything that is not chrome)
//	bar    (BarRows — never negotiable, it holds the shortcuts)
//
//  1. MEASURE, never guess. A host asks for a Layout and gets back the body
//     budget that is actually left. BarRows and Picker.FrameRows are subtracted
//     for it, so no host can forget one.
//  2. NEVER HARD-WRAP box art. Wrapping a 121-column wordmark at 100 does not
//     shrink it, it destroys it. Titles go down a LADDER instead: the largest
//     form that fits both dimensions, or a smaller one, or plain text.
//  3. NEVER let the body push the chrome off. If a body is somehow taller than
//     its budget, FrameScreen clips it to the gap — the title and the shortcut
//     bar survive, because an interface that is missing its bar is an interface
//     the user cannot escape with the keyboard.
//
// ## Font and DPI
//
// Nothing here reads a font size, and that is deliberate. A TUI only ever sees
// CELL dimensions (width x height in characters), which is what Bubble Tea
// reports. Changing Omarchy's font size, the Hyprland scale or the monitor DPI
// changes how many CELLS fit in the window, not the layout arithmetic: a bigger
// font means fewer cells, which means a smaller Layout, which means a lower rung
// of the title ladder. So "the TUI overflows at h=18" is a real bug at 18 cells,
// not an artefact of the font — it reproduces with any font. What a font setting
// changes is only WHICH cell budget you land on.
//
// ## Nerd Fonts
//
// The kit deliberately uses NO Private Use Area glyphs — no U+E0B0 powerline
// separators, no fontawesome icons. Everything is U+2500..U+25FF box drawing and
// geometric shapes plus U+2713/U+2717, which every monospace font ships. That is
// asserted by TestKitUsesNoNerdFontGlyphs, so a later "let's add a nicer icon"
// cannot quietly make the TUIs render tofu on a stock font. Nothing to install,
// nothing to detect, nothing that breaks on a machine missing it.

import (
	"strings"

	"github.com/charmbracelet/lipgloss"
)

// Layout is a measured screen budget. Construct it with NewLayout and hand
// ContentSize to your picker; do not re-derive the arithmetic.
type Layout struct {
	W, H      int // the window, in cells
	TitleRows int // rows the title block took (0 = none)
	BarRows   int // rows reserved at the bottom (BottomBar)
	FrameRows int // rows the picker's own frame adds around its list

	// bodyRows is private so the invariant is one place: NewLayout and
	// ContentSize can never disagree about it.
	bodyRows int
	// chosen is the ladder rung LayoutForLadder selected (0 = the most
	// decorative form). -1 when the title is plain text.
	chosen int
}

// NewLayout measures the title and subtracts every fixed cost, so BodyRows is
// what is genuinely left for list rows.
//
// A frame row is only counted when there is room for at least one list row: a
// picker needs at least one row to show anything, and spending 2 rows on a
// frame in a 3-row window leaves a picker with nothing in it.
func NewLayout(w, h, titleRows int) Layout {
	l := Layout{W: w, H: h, TitleRows: titleRows, BarRows: BarRows, FrameRows: FrameRows}
	n := h - titleRows - l.BarRows - l.FrameRows
	if n < 1 {
		// No room for a real list behind a frame: drop the frame and give the
		// bare minimum, rather than showing a framed box with nothing in it.
		l.FrameRows = 0
		n = h - titleRows - l.BarRows
	}
	if n < 1 {
		n = 1
	}
	l.bodyRows = n
	return l
}

// BodyRows is how many list rows fit. Always >= 1.
func (l Layout) BodyRows() int { return l.bodyRows }

// ContentWidth is the width a body block may use: the window minus the frame's
// own horizontal padding (2 columns, one each side of the box).
func (l Layout) ContentWidth() int {
	w := l.W - 2
	if w < 8 {
		w = l.W
	}
	if w < 8 {
		w = 8
	}
	return w
}

// ContentSize is the (width, height) to hand a Picker. This is the whole point
// of the type: the two numbers that every host used to get wrong.
func (l Layout) ContentSize() (int, int) {
	return l.ContentWidth(), l.bodyRows
}

// TitleFits reports whether a block of the given width and height can be used
// as the title at all: it must be narrower than the content width and leave the
// bar plus at least one body row.
func (l Layout) TitleFits(w, h int) bool {
	return w <= l.ContentWidth() && h <= l.H-l.BarRows-1
}

// LayoutForLadder is the entry point a host should use for a decorated title.
//
// It picks the largest rung of the ladder that leaves room for the bar AND at
// least one body row, and returns a Layout whose TitleRows matches the rung it
// chose — so the budget and the drawn title can never disagree, and a host never
// has to reimplement the subtraction. Pass the result to RenderLadder to draw.
//
// The ladder is walked top-down by *available* height (window minus the bar and
// the single body row a list needs), which is the whole fix for "the title
// scrolled off the top of a short window": the title gives way first.
func LayoutForLadder(w, h int, ladder TitleLadder) Layout {
	avail := h - BarRows - 1
	if avail < 0 {
		avail = 0
	}
	cw := NewLayout(w, h, 0).ContentWidth()
	best := -1
	for i, f := range ladder {
		if f.Width <= cw && f.Rows <= avail {
			best = i
		}
	}
	if best < 0 {
		// Nothing fits the budget. Fall back to the smallest rung and let
		// Render truncate rather than wrap; a clipped one-liner beats a
		// shredded 9-row wordmark.
		best = len(ladder) - 1
	}
	l := NewLayout(w, h, ladder[best].Rows)
	l.chosen = best
	return l
}

// chosenRung reports which rung LayoutForLadder selected, for RenderLadder.
func (l Layout) chosenRung() int { return l.chosen }

// RenderLadder draws exactly the rung LayoutForLadder budgeted for, at the
// available height. Use this instead of ladder.Render(w, h) so the two can
// never pick different forms.
func (l Layout) RenderLadder(w int, ladder TitleLadder) string {
	avail := l.H - l.BarRows - 1
	if avail < 0 {
		avail = 0
	}
	cw := l.ContentWidth()
	i := l.chosen
	if i < 0 || i >= len(ladder) {
		i = len(ladder) - 1
	}
	f := ladder[i]
	if f.Width <= cw && f.Rows <= avail {
		return f.Art
	}
	if f.Width <= cw {
		// Too tall for the window: fall back to any rung that is both narrow
		// enough and short enough, else truncate this one to one row.
		for _, g := range ladder {
			if g.Width <= cw && g.Rows <= avail {
				return g.Art
			}
		}
		return TruncateLine(strings.Split(f.Art, "\n")[0], cw)
	}
	return TruncateLine(f.Art, cw)
}

// ── Title ladder ──────────────────────────────────────────────────────
//
// A title is a list of forms, widest/most decorative first. Render picks the
// first that fits BOTH dimensions. It never pads art out to the width, and it
// never lets lipgloss wrap it: a form either fits or it is skipped.

// TitleForm is one rung of the ladder.
type TitleForm struct {
	Art   string // the rendered block
	Width int    // its natural visible width
	Rows  int    // how many rows it takes
}

// NewTitleForm measures a form. Measuring here rather than at each call site is
// what makes the ladder correct: a caller cannot forget.
func NewTitleForm(art string) TitleForm {
	return TitleForm{Art: art, Width: lipgloss.Width(art), Rows: lipgloss.Height(art)}
}

// TitleLadder degrades a title as the window shrinks.
type TitleLadder []TitleForm

// NewTitleLadder measures each form, keeping the given order (most decorative
// first). Empty strings are dropped rather than counted as one blank row.
func NewTitleLadder(arts ...string) TitleLadder {
	var l TitleLadder
	for _, a := range arts {
		if strings.TrimSpace(a) == "" {
			continue
		}
		l = append(l, NewTitleForm(a))
	}
	return l
}

// Render returns the largest form that fits w columns and h rows. When nothing
// fits it returns the LAST form anyway: a slightly-too-wide plain title is
// recoverable, an empty title is not, and the last rung is by construction the
// one that fits the most places.
func (t TitleLadder) Render(w, h int) string {
	if len(t) == 0 {
		return ""
	}
	for _, f := range t {
		if f.Width <= w && f.Rows <= h {
			return f.Art
		}
	}
	last := t[len(t)-1]
	if last.Width <= w {
		return last.Art
	}
	// Last rung still too wide (a genuinely tiny tile): truncate rather than
	// wrap. One clipped line beats six ragged ones.
	return TruncateLine(last.Art, w)
}

// Rows is the height Render would use at w x h, for the Layout budget. Call it
// with the same w/h you will pass to Render, then build the Layout from it —
// that is the order that keeps the two in agreement.
func (t TitleLadder) Rows(w, h int) int {
	if len(t) == 0 {
		return 0
	}
	for _, f := range t {
		if f.Width <= w && f.Rows <= h {
			return f.Rows
		}
	}
	last := t[len(t)-1]
	if last.Width <= w {
		return last.Rows
	}
	return 1
}

// TruncateLine cuts a single line to w visible columns, never wrapping it.
// Box art must go through this, never through lipgloss's Width(), which wraps.
func TruncateLine(s string, w int) string {
	if w <= 0 {
		return ""
	}
	if lipgloss.Width(s) <= w {
		return s
	}
	var b strings.Builder
	used := 0
	for _, r := range s {
		rw := lipgloss.Width(string(r))
		if used+rw > w {
			break
		}
		b.WriteRune(r)
		used += rw
	}
	return b.String()
}

// ── Composed titles ───────────────────────────────────────────────────

// CompactTitle wraps text in a single-line box: 3 rows, roughly len(text)+4
// columns. It is the middle rung between the 9-row figlet wordmark and plain
// text, and it needs no embedded art — so it stays correct at any width and
// cannot rot like a hand-generated banner.
func CompactTitle(text string) string {
	inner := lipgloss.Width(text) + 2
	if inner < 3 {
		inner = 3
	}
	// Square corners, not rounded (U+256D..U+2570): the rounded range is
	// standard Unicode but is the part of box drawing some older monospace
	// fonts leave blank, and this is the fallback rung — the one that has to
	// survive a machine with an unusual font.
	top := "┌" + strings.Repeat("─", inner) + "┐"
	mid := "│" + StyleAccent.Bold(true).Render(" "+text+" ") + "│"
	bot := "└" + strings.Repeat("─", inner) + "┘"
	// The mid row is styled, so its visible width is the styled width: pad the
	// border row to the same total so the box is a clean rectangle.
	total := inner + 2
	return padLines(top, total) + "\n" + mid + "\n" + padLines(bot, total)
}

func padLines(s string, w int) string {
	lines := strings.Split(s, "\n")
	for i, l := range lines {
		if pad := w - lipgloss.Width(l); pad > 0 {
			lines[i] = l + strings.Repeat(" ", pad)
		}
	}
	return strings.Join(lines, "\n")
}

// MosquitOmarchyTitleLadder is the title ladder for the mosquitomarchy setup
// TUI: the 121-column figlet wordmark when the tile is wide enough, a compact
// single-line box when it is not, then plain text.
//
// Before this existed the wordmark was rendered unconditionally and lipgloss
// hard-wrapped it at the window width, which turned the title into shredded
// glyph fragments in any tile narrower than 121 columns — i.e. most tiles.
func MosquitOmarchyTitleLadder() TitleLadder {
	return NewTitleLadder(
		BoxedMosquitOmarchy(),
		CompactTitle("mosquitomarchy"),
		StyleAccent.Bold(true).Render("mosquitomarchy"),
	)
}

// MosquitoTitleLadder is the same ladder for the four managers, whose wordmark
// is "mosquito" (69 columns) rather than the full name.
func MosquitoTitleLadder() TitleLadder {
	return NewTitleLadder(
		BoxedMosquito(),
		CompactTitle("mosquito"),
		StyleAccent.Bold(true).Render("mosquito"),
	)
}

// SubtitleLadder degrades a module subtitle the same way, then falls back to a
// plain accent one-liner. maxW is the content width from the Layout.
func SubtitleLadder(text string, maxW int) TitleLadder {
	return NewTitleLadder(
		MosquitoSubtitle(text, maxW),
		StyleMuted.Render(text),
	)
}

// clipToRows keeps the FIRST n lines of a block. Used by FrameScreen to protect
// the chrome from an over-tall body.
func clipToRows(s string, n int) string {
	if n <= 0 {
		return ""
	}
	lines := strings.Split(s, "\n")
	if len(lines) <= n {
		return s
	}
	return strings.Join(lines[:n], "\n")
}

// ── The shared sizing policy ──────────────────────────────────────────
//
// The five TUIs all show one centered panel and all want it to read as a
// natural-size object rather than a box stretched edge to edge. Each used to
// carry its own copy of that arithmetic, and the copies disagreed: the move
// manager subtracted a 1-row status line, the audio manager subtracted a 2-row
// bar, live-mode counted a version line nobody else has. Every one of them
// also derived the title height by RENDERING the header first — so when the
// header was itself too wide, it was measured after lipgloss had wrapped it,
// and the measurement described the damage instead of preventing it.
//
// ContentPolicy is the single copy. Title height is passed IN, already
// measured off a ladder rung that was chosen to fit, never re-derived here.

// ContentPolicy is how a TUI sizes its central panel.
type ContentPolicy struct {
	MaxW      int // widest the panel is allowed to get, in columns
	MaxH      int // tallest the panel is allowed to get, in rows
	WidthPad  int // columns of margin the panel keeps from the window edge
	SpareRows int // rows kept empty so a full list is not flush against the bar
	ExtraRows int // rows this screen needs beyond bar+frame (status line, filter box)
}

// ManagerContent is the policy the four manager TUIs share. Defaults are the
// numbers that were already in use, so migrating does not resize anything a
// user is used to seeing — it only stops the arithmetic from diverging.
var ManagerContent = ContentPolicy{MaxW: 92, MaxH: 26, WidthPad: 8, SpareRows: 2}

// Layout measures a screen against this policy and returns the Layout. Use it
// with LayoutForLadder so the title you budget for is the title you draw.
func (p ContentPolicy) Layout(w, h, titleRows int) Layout {
	// SpareRows is NOT folded in here: it is subtracted by Size, after the
	// caps, so a panel at MaxH still keeps its breathing room.
	return NewLayout(w, h, titleRows+p.ExtraRows)
}

// Size is Layout.ContentSize with the width and height caps applied.
func (p ContentPolicy) Size(w, h, titleRows int) (int, int) {
	cw := w - p.WidthPad
	if cw > p.MaxW {
		cw = p.MaxW
	}
	if cw < 20 {
		cw = w
	}
	if cw < 20 && w < 20 {
		cw = w
	}
	l := p.Layout(w, h, titleRows)
	ch := l.BodyRows() - p.SpareRows
	if ch > p.MaxH {
		ch = p.MaxH
	}
	if ch < 1 {
		ch = 1
	}
	return cw, ch
}

// StackedLadder builds the ladder for a banner with a subtitle under it, which
// is what the four managers draw: the full stacked art when the tile is big
// enough, then the subtitle alone in a compact box, then plain text.
//
// width is the content width the stacked art may use. It must be the SAME
// number the policy will hand the panel, otherwise the ladder measures the
// banner against one width and the panel is laid out against another.
func StackedLadder(art, subtitle string, width int) TitleLadder {
	return NewTitleLadder(
		MosquitoStackedHeader(art, subtitle, width),
		CompactTitle(subtitle),
		StyleAccent.Bold(true).Render(subtitle),
	)
}

// ContentWidth is the one width number a screen measures against: the policy's
// margin and cap applied to the window. The title ladder and the panel must be
// sized against THIS and not against the raw window width, or the ladder
// accepts a banner the panel cannot hold.
func (p ContentPolicy) ContentWidth(w int) int {
	cw := w - p.WidthPad
	if cw > p.MaxW {
		cw = p.MaxW
	}
	if cw < 20 {
		cw = w
	}
	if cw < 1 {
		cw = 1
	}
	return cw
}
