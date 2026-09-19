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
	return tuikit.BoxedMosquito() + tuikit.MosquitoSubtitle("live mode manager", maxW)
}

const (
	headerRows       = 15 // 8 framed-mosquito rows + 5 subtitle rows + slack
	narrowHeaderRows = 5  // subtitle only
)

// homeBannerReserve is the row budget the home screen keeps for the boxed
// "mosquito" title (or just the subtitle on short/narrow terminals) so
// bubbletea never clips its top rows.
func (m model) homeBannerReserve() int {
	if m.w < 74 {
		return narrowHeaderRows
	}
	if m.h < 22 {
		return narrowHeaderRows
	}
	return headerRows
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
		w := m.contentSizeW()
		if m.homeBannerReserve() == headerRows {
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
		th := lipgloss.Height(header(w))
		reserved := m.h - th - 2 /*bar: notify+hint*/ - 2 /*frame pad*/ - 2 /*spare*/
		if reserved > 26 {
			reserved = 26
		}
		if reserved >= 8 {
			h = reserved
		}
	}
	return w, h
}
