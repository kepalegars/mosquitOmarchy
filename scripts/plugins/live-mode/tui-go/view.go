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
	return tuikit.MosquitoStackedHeader(tuikit.BoxedMosquito(), "live mode manager", maxW)
}

const (
	// Rows the home screen needs beyond the banner and the list: the version
	// line, the shortcut bar, and the picker's own frame. The last two come
	// from the kit, so they cannot drift from the styles that produce them.
	chromeRows = 1 + tuikit.BarRows + tuikit.FrameRows
	// The fewest body rows worth showing; below this the banner gives way to
	// the subtitle, and below THAT the list takes what is left.
	minBodyRows = 4
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
	full := lipgloss.Height(header(w))
	if m.h-full-chromeRows < minBodyRows {
		return lipgloss.Height(tuikit.MosquitoSubtitle("live mode manager", w))
	}
	return full
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
	homeTitle := func() string {
		// Center the banner across the FULL window width (m.w - 2), the same
		// rule as the mosquitomarchy home screen — the content width (92-col
		// cap) would center it inside the content lane only, and because the
		// version row makes the title block exactly window-wide, FrameScreen
		// skips its own re-centering pass, so the banner would stick left.
		w := m.bannerWidth()
		if m.homeBannerReserve() > lipgloss.Height(tuikit.MosquitoSubtitle("live mode manager", w)) {
			return lipgloss.NewStyle().Width(w).Align(lipgloss.Center).Render(header(w))
		}
		return lipgloss.NewStyle().Width(w).Align(lipgloss.Center).
			Render(tuikit.MosquitoSubtitle("live mode manager", w))
	}
	switch m.top() {
	case scrMain:
		version = "v" + appVersion
		title = homeTitle()
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
	w := m.w - 8
	if w > 92 {
		w = 92
	}
	if w < 20 {
		w = m.w
	}
	h := m.h - 8
	if h > 26 {
		h = 26
	}
	if h < 8 {
		h = m.h - 4
	}
	if m.top() == scrMain {
		// The home budget, counted from every row the screen spends on
		// something other than the list:
		//
		//   the banner          homeHeaderRows, the SAME answer the draw uses
		//   the version line    FrameScreenVersion prepends it to the title
		//   the shortcut bar    one row (a toast replaces it, same height)
		//   the shortcut bar    BarRows, the notification line plus the hint
		//   the picker's frame  FrameRows, which Picker.View adds to whatever
		//                      height it was given
		//
		// Missing the frame rows is what made the home screen taller than the
		// window: the kit centres the body in the gap but lets it overflow the
		// BOTTOM, so a body that is two rows too tall pushes the whole screen
		// past the last terminal row — and a terminal that receives more lines
		// than it has SCROLLS, taking the title out of view. That is the report:
		// no boxed mosquito, no "live mode manager" subtitle.
		banner := m.homeHeaderRows(m.bannerWidth())
		avail := m.h - banner - 1 /*version*/ - tuikit.BarRows - tuikit.FrameRows
		if avail > 26 {
			avail = 26
		}
		if avail < 4 {
			avail = 4
		}
		h = avail
	}
	return w, h
}
