package main

import (
	"github.com/charmbracelet/lipgloss"
	tuikit "mosquitomarchy.local/tui-kit"
)

// header renders the boxed "mosquito" label (white on theme accent, see
// tuikit.BoxedMosquito) plus an accent-colored subtitle line "live mode
// manager" flush beneath it. The Small-font art and the accent color
// follow the live Omarchy theme (tuikit.ApplyTheme re-stamps the
// package-level colors and every render resolves them fresh). maxW is
// the picker's content width: the "live mode manager" Small art is
// 71 columns, so anything narrower falls back to the one-line label.
func header(maxW int) string {
	return titleLadder(maxW).Render(maxW, headerRowsCap)
}

// contentPolicy is the shared panel-sizing policy (tuikit.ManagerContent), so
// this TUI and the other four cannot drift apart on the arithmetic again.
var contentPolicy = tuikit.ManagerContent

// titleLadder is the home banner: the full stacked boxed mosquito plus the
// "live mode manager" subtitle when the tile allows, then the subtitle alone in
// a compact box, then plain text. Rungs are measured once and chosen by fit, so
// the banner is never rendered too wide and wrapped.
func titleLadder(width int) tuikit.TitleLadder {
	return tuikit.StackedLadder(tuikit.BoxedMosquito(), "live mode manager", width)
}

const (
	// Rows the home screen needs beyond the banner and the list: the version
	// line, the shortcut bar, and the picker's own frame. The last two come
	// from the kit, so they cannot drift from the styles that produce them.
	chromeRows = 1 + tuikit.BarRows + tuikit.FrameRows
	// headerRowsCap is the tallest the banner may be: the full stacked title
	// block. A CAP, not an estimate — the real reserve is whichever rung the
	// ladder picked, measured at homeBannerReserve.
	//
	// The old minBodyRows floor ("always show at least 4 list rows") is gone:
	// a floor cannot promise space the window does not have, and honouring it
	// is what pushed the panel 3 rows past a 16-row window. Deciding whether to
	// show the banner from the available height is LayoutForLadder's job now.
	headerRowsCap = 15
)

// homeHeaderRows is what the home screen actually spends on its banner, in the
// given content width, and it is ONE answer for both the draw and the layout
// budget.
//
// It used to be a pair of constants (15 full / 5 narrow) chosen by a width and
// height threshold, while contentSize() measured the REAL header height
// separately. Those two disagreed: the constants said 15 rows, the header is
// actually 13, and the threshold kept the full banner at heights where the
// arithmetic could not afford it. The result was a home screen taller than the
// terminal, which bubbletea clips FROM THE TOP — so the framed mosquito and the
// "live mode manager" subtitle simply vanished, and the list started at the top
// of the window. That is the bug the user reported.
//
// Deciding it from the arithmetic cannot disagree with itself: the banner is
// drawn if — and only if — what it costs still leaves a usable list.
func (m model) homeHeaderRows(w int) int {
	return m.homeLayout().TitleRows
}

// homeLayout picks the banner rung that fits the window and returns the
// matching budget.
//
// The previous version asked "would the full banner leave a usable list?" and
// answered with a hand-computed subtraction. That is the same question, asked
// in the one place that also has to draw the answer: LayoutForLadder walks the
// ladder top-down by available height, so the banner is the first thing to give
// way as the window shrinks, and the rows it reports are the rows the title
// occupies. A LayoutForLadder budget cannot disagree with a LayoutForLadder
// draw, because they are the same choice.
func (m model) homeLayout() tuikit.Layout {
	w := m.bannerWidth()
	return tuikit.LayoutForLadder(w, m.h, titleLadder(w))
}

// contentWidth is the one width number the panel is sized against.
func (m model) contentWidth() int {
	return contentPolicy.ContentWidth(m.w)
}

// bannerWidth is the width the home banner is DRAWN at.
//
// The banner is centred across the full window, not across the list's own
// content column, so it is drawn at m.w-2. The budget has to be measured at
// that same width: measured at the narrower content column the art can come out
// a different number of rows tall, and a banner that is drawn taller than it
// was budgeted is a screen that overflows.
func (m model) bannerWidth() int {
	w := m.w - 2
	if w < 40 {
		w = m.w
	}
	return w
}

// homeBannerReserve is what the banner costs, at the width it is drawn at.
func (m model) homeBannerReserve() int {
	return m.homeHeaderRows(m.bannerWidth())
}

// subScreenTitleRows: every screen except the home menu uses a single accent
// line as its title.
const subScreenTitleRows = 1

// homeTitle renders the pinned-top banner. Centered across the full window,
// not the content lane: the version row makes the title block exactly
// window-wide, so FrameScreen skips its own re-centering pass and a narrower
// block would stick left. It draws the same rung homeBannerReserve budgeted
// for, so the reserved rows and the drawn rows agree by construction.
func (m model) homeTitle() string {
	w := m.bannerWidth()
	title := m.homeLayout().RenderLadder(w, titleLadder(w))
	return lipgloss.NewStyle().Width(w).Align(lipgloss.Center).Render(title)
}

// appVersion is the version of this SCRIPT (the live-mode module).
const appVersion = "1.0.0"

func (m model) View() string {
	if m.quit {
		return ""
	}
	// Defensive: render the active picker at the CURRENT screen's budget so
	// a picker sized for a previous screen's one-line title can never
	// overflow under the 8-row home banner (the "interface too high, title
	// hidden briefly" bug on returning to page 1). m is a value copy.
	m.picker = m.picker.SetSize(m.contentSize())
	m.appsPicker = m.appsPicker.SetSize(m.contentSize())
	var body, title, bar string
	var version string
	// The toast lives on its own reserved row just ABOVE the shortcut hint
	// (tuikit.BottomBar), so a notification never hides the shortcuts and
	// never moves the interface when it auto-disappears.
	barLine := func(hint string) string {
		return tuikit.BottomBar(m.toast.View(), hint, m.contentSizeW())
	}
	switch m.top() {
	case scrMain:
		version = "v" + appVersion
		title = m.homeTitle()
		if m.w == 0 || m.h == 0 {
			body = "loading…"
		} else {
			body = m.picker.View()
			bar = barLine(m.picker.ShortcutsHint())
		}
	case scrApps:
		title = lipgloss.NewStyle().Width(m.contentSizeW()).Align(lipgloss.Center).
			Render(tuikit.StyleAccent.Bold(true).Render("Background apps — Tab toggles · Enter saves"))
		body = m.appsPicker.View()
		bar = barLine(m.appsPicker.ShortcutsHint())
	case scrQuit:
		// Quit confirmation alone on the screen — the home title stays
		// hidden (same rule as every other manager's confirm dialog:
		// only the dialog is shown, nothing else).
		title = ""
		body = m.confirm.View()
		bar = barLine(m.confirm.ShortcutsHint())
	}
	if m.w == 0 || m.h == 0 {
		return title + "\n" + body + "\n" + bar
	}
	return tuikit.FrameScreenVersion(m.w, m.h, title, body, bar, version)
}

func (m model) contentSizeW() int {
	w, _ := m.contentSize()
	return w
}

// contentSize mirrors the other managers: caps the picker's own rendering
// box so the manager reads as a centered panel. Home budget computed from
// the real title height (see the move manager's contentSize rationale).
func (m model) contentSize() (int, int) {
	if m.top() != scrMain {
		return contentPolicy.Size(m.w, m.h, subScreenTitleRows)
	}
	// The home budget, from the shared policy. Counted from every row the
	// screen spends on something other than the list — banner, version line,
	// shortcut bar, picker frame — which the kit now measures in one place.
	//
	// This used to end with "if avail < 4 { avail = 4 }": a floor that showed
	// four list rows whether or not four rows were free. At h=16 the panel was
	// four rows tall with one row of gap, so it overflowed the window by three
	// and the terminal scrolled the title away. A floor cannot promise space
	// that is not there, so it is gone; FrameScreen clipping the body is what
	// protects the interface now.
	return contentPolicy.Size(m.w, m.h, m.homeLayout().TitleRows)
}
