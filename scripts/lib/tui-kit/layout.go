package tuikit

import (
	"strings"

	"github.com/charmbracelet/lipgloss"
)

// BottomBar renders a screen's bottom region as a reserved notification row
// pinned immediately above the single-line shortcut hint. A toast gets its
// own line so it NEVER covers the shortcuts (the user's rule: "notifications
// should not hide shortcuts, be just above/below") and is horizontally
// centred. The notification row is ALWAYS reserved — even with an empty
// notification — so a toast appearing or auto-disappearing never shifts the
// body or the title. Hosts must therefore reserve two rows for the bar in
// their contentSize budget (see the three managers' contentSize()).
func BottomBar(notify, hint string, w int) string {
	if notify == "" {
		notify = " "
	}
	if hint == "" {
		return notify
	}
	if w <= 0 {
		return notify + "\n" + hint
	}
	return lipgloss.NewStyle().Width(w).Align(lipgloss.Center).Render(notify) + "\n" + hint
}

// FrameScreenVersion is FrameScreen with a small version label pinned to the
// very top-left corner of the interface (its own first row, column 0), in the
// same muted style as the shortcut hints. Hosts use it on their FIRST screen
// only — the version is the version of the SCRIPT/module, not of the app it
// manages. It prepends a dedicated row so it never overwrites a one-line
// screen title (FrameScreen then pins that row to the top).
func FrameScreenVersion(w, h int, title, body, bar, version string) string {
	if w > 0 && version != "" {
		ver := StyleHelp.Render(version)
		pad := w - lipgloss.Width(ver)
		if pad < 0 {
			pad = 0
		}
		title = ver + strings.Repeat(" ", pad) + "\n" + title
	}
	return FrameScreen(w, h, title, body, bar)
}

// FrameScreen composes a full TUI screen into the universal layout rule:
//
//  1. the title block is pinned to the very top of the window,
//     horizontally centred across its full width;
//  2. the body content is LEFT where it fits, horizontally centred, and
//     vertically CENTRED in the remaining space between the title and
//     the shortcut bar (this is the universal centering rule — body
//     content floats in the gap, never glues to the title and never to
//     the shortcut bar);
//  3. the shortcut bar is pinned to the very last row, single line;
//     when a toast is active the host passes the toast line in this
//     slot instead, so a notification never pushes the layout around
//     (the bar is a fixed one-row floor, not part of the centred body).
//
// Title, body and shortcut are each re-padded to the window's full width
// with Align+Width so mixed-width content inside them (the boxed mosquito
// art, the picker rows, the modal border) always reads as one centered
// block. The function never widens or narrows any line — it only adds
// horizontal/vertical padding, so nothing is ever clipped even when the
// body is slightly taller than the gap (the overflow clips at the bottom
// rather than shifting the title; the hosts size their pickers to the
// FrameScreen budget so this never triggers in practice).
func FrameScreen(w, h int, title, body, bar string) string {
	if w <= 0 || h <= 0 {
		return title + "\n" + body + "\n" + bar
	}
	// Horizontal pass: pad every line of every block to exactly w. Full
	// block first (Align centers each line inside the padded width).
	centerBlock := func(s string) string {
		if lipgloss.Width(s) == w {
			return s
		}
		return lipgloss.NewStyle().Width(w).Align(lipgloss.Center).Render(s)
	}
	title = centerBlock(title)
	body = centerBlock(body)
	if bar != "" {
		bar = centerBlock(bar)
	}

	titleH := lipgloss.Height(title)
	barH := lipgloss.Height(bar)
	bodyH := lipgloss.Height(body)

	// Vertical pass: the body gets the gap between title and bar,
	// centred — with zero padding once the body is taller than the gap
	// (no negative rows, no silent clipping of the bar itself, the body
	// simply overflows the window bottom which hosts avoid by budget).
	gap := h - titleH - barH
	if gap < 0 {
		gap = 0
	}
	topPad := (gap - bodyH) / 2
	botPad := gap - bodyH - topPad
	if topPad < 0 {
		topPad = 0
	}
	if botPad < 0 {
		botPad = 0
	}
	out := title
	if titleH > 0 {
		out += "\n"
	}
	for i := 0; i < topPad; i++ {
		out += "\n"
	}
	out += body
	for i := 0; i < botPad; i++ {
		out += "\n"
	}
	if barH > 0 {
		// Guarantee the bar starts on its own line: when the body exactly
		// fills the gap there is no bottom padding, and without this the
		// bar's first line would concatenate onto the body's last line.
		if !strings.HasSuffix(out, "\n") {
			out += "\n"
		}
		out += bar
	}
	return out
}
