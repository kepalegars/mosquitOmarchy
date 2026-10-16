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
// BarRows is what BottomBar occupies: the notification line and the shortcut
// hint, one each. A toast replaces the notification line, never adds to it, so
// the height is constant and a host can budget for it.
//
// It belongs here for the same reason as Picker.FrameRows: every host that
// composes a screen has to subtract these two, and a host that counts one and
// not the other ships a screen that is one row too tall — which is enough for a
// terminal to scroll the title off the top.
const BarRows = 2

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
	// The hint is TRUNCATED to the window width, never wrapped. BottomBar is
	// contractually BarRows tall and every layout budget subtracts exactly that
	// many, so a hint long enough to wrap turned a two-row bar into a three- or
	// five-row one and pushed the screen past the window, where the terminal
	// scrolls the title away.
	//
	// Measured: at 20 columns the shortcut list
	// "↑/k up · ↓/j down · enter select · esc back · ? help" wrapped onto three
	// lines and an 8-row window rendered 13. Truncating a hint loses the tail
	// of a line the user can always read on the help screen; wrapping it loses
	// the title. That is not a close call.
	return lipgloss.NewStyle().Width(w).Align(lipgloss.Center).Render(notify) +
		"\n" + TruncateLine(hint, w)
}

// FrameScreenVersion is FrameScreen with a small version label pinned to
// the very top-left corner of the interface (its own first row, column 0),
// in the same muted style as the shortcut hints.
//
// DESIGN RULE — where the version lives, and when it shows:
//
//   - The version is WINDOW chrome, never title chrome: it sits on row 0,
//     detached from the title block, so it is always at the same place no
//     matter which TUI or which page is on screen. The title+body block is
//     centred in the rows below it.
//   - The version shows on content screens ONLY — never on a confirm/info
//     modal screen (close prompts, patch applies, help popups). A version
//     string floating over a modal reads as part of the question; hosts
//     pass "" there. The modal owns the whole window while it is up.
//   - Hosts budget their pickers against the full window height as before:
//     the version row comes out of the same centering slack every other
//     screen already leaves, and FrameScreen clips an over-tall body before
//     it ever touches the version row or the bar.
func FrameScreenVersion(w, h int, title, body, bar, version string) string {
	if version == "" {
		return FrameScreen(w, h, title, body, bar)
	}
	if w <= 0 || h <= 0 {
		return version + "\n" + FrameScreen(w, h, title, body, bar)
	}
	ver := StyleHelp.Render(version)
	pad := w - lipgloss.Width(ver)
	if pad < 0 {
		pad = 0
	}
	return ver + strings.Repeat(" ", pad) + "\n" + FrameScreen(w, h-1, title, body, bar)
}

// FrameScreen composes a full TUI screen into the universal layout rule:
//
//  1. the title block sits directly above the body content, with one blank
//     row between them, and the title+body block is vertically CENTRED in
//     the window as a single unit — the title reads as the body's own
//     heading, never as a header glued to the top edge with a void below;
//  2. the shortcut bar is pinned to the very last row, single line;
//     when a toast is active the host passes the toast line in this
//     slot instead, so a notification never pushes the layout around
//     (the bar is a fixed one-row floor, not part of the centred body).
//
// Title, body and shortcut are each re-padded to the window's full width
// with Align+Width so mixed-width content inside them (the boxed mosquito
// art, the picker rows, the modal border) always reads as one centered
// block.
//
// The body is CLIPPED to the space left by the title and the bar. That is a
// safety net, not the mechanism: a host sizes its picker from a Layout (see
// responsive.go) so the body fits by construction. When one does not — a
// long list, a smaller tile than anything was tested at — the body's last
// rows are dropped and the title and the shortcut bar survive. Losing the
// bottom of a list is recoverable; losing the bar means the user cannot see
// or use the shortcuts, and the screen scrolls the title off the top. An
// interface is never sacrificed to the content inside it.
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

	// The title and the body travel together: one blank row between them,
	// then the whole block is centred in the space above the bar. Clip an
	// over-tall body to what is left — keeping title+bar on screen is worth
	// more than keeping the body's tail.
	avail := h - barH
	blockH := titleH
	if bodyH > 0 {
		blockH += 1 + bodyH
	}
	if blockH > avail && avail > 0 {
		// Shrink the body first; the title is never clipped.
		bodyH = avail - titleH - 1
		if bodyH < 0 {
			bodyH = 0
		}
		if bodyH > 0 {
			body = clipToRows(body, bodyH)
		} else {
			body = ""
			bodyH = 0
		}
		blockH = titleH
		if bodyH > 0 {
			blockH += 1 + bodyH
		}
	}
	topPad := avail - blockH
	if topPad < 0 {
		topPad = 0
	}
	botPad := 0
	// Split the spare space above and below the block so it sits centred;
	// the title stays glued to its body either way.
	topPad, botPad = topPad/2, topPad-topPad/2
	out := ""
	for i := 0; i < topPad; i++ {
		out += "\n"
	}
	out += title
	if bodyH > 0 {
		out += "\n\n" + body
	}
	for i := 0; i < botPad; i++ {
		out += "\n"
	}
	if barH > 0 {
		// Guarantee the bar starts on its own line: when the body exactly
		// fills the space there is no bottom padding, and without this the
		// bar's first line would concatenate onto the body's last line.
		if !strings.HasSuffix(out, "\n") {
			out += "\n"
		}
		out += bar
	}
	return out
}
