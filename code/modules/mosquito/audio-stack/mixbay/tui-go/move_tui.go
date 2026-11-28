// Ableton Move page — the UGM192 Levels page, minus everything the card does
// not have.
//
// The Move is a class-compliant USB interface with a fixed 44.1 kHz clock and
// no software mixer: no ALSA volume, mute or gain to drive. So there is no
// Controls tab, only a single Levels tab with Capture/Playback meters, and a
// permanent note saying what the card's clock implies for the rest of the
// graph. That note is the point: a 44.1 kHz interface used beside another card
// running at a different rate is a conflict, and the page is where it is said.
package main

import (
	"fmt"

	tea "github.com/charmbracelet/bubbletea"
	"mosquitomarchy.local/mosquitomixbay-tui/drivers"
)

const moveContentW = 62

const moveNote = "Ableton Move is fixed at 44.1kHz. Using it beside another card at a different sample rate can conflict."

// isMoveDevice reports whether the card page is the Move's. The preset comes
// from the card (ui.preset), so a downloaded Move profile behaves the same as
// the embedded one.
func (m model) isMoveDevice() bool {
	switch m.preset {
	case "move":
		return true
	case "":
		return m.deviceID == drivers.DevMove
	case "auto":
		// The Move is plain ALSA, like the UGM192: the id is what tells them
		// apart, never the backend.
		return m.deviceID == drivers.DevMove
	}
	return false
}

// wrapWords breaks the note into lines that fit the card width. No hyphenation
// and no indentation: a two-line note is all this needs.
func wrapWords(s string, width int) []string {
	if width < 8 {
		width = 8
	}
	var out []string
	line := ""
	for _, w := range splitWords(s) {
		if line == "" {
			line = w
			continue
		}
		if len([]rune(line))+1+len([]rune(w)) <= width {
			line += " " + w
			continue
		}
		out = append(out, line)
		line = w
	}
	if line != "" {
		out = append(out, line)
	}
	return out
}

func splitWords(s string) []string {
	var out []string
	cur := ""
	for _, r := range s {
		if r == ' ' {
			if cur != "" {
				out = append(out, cur)
				cur = ""
			}
			continue
		}
		cur += string(r)
	}
	if cur != "" {
		out = append(out, cur)
	}
	return out
}

func (m model) moveView() string {
	return m.levelsOnlyView(moveNote)
}

// levelsOnlyView is the Levels page for a composition with no controls: the
// Move adds its fixed-rate note, an auto card with only levelsColumns passes
// none.
func (m model) levelsOnlyView(note string) string {
	w, h := m.contentSize()
	pal := evoPalette()
	c := newEvoCanvas(w, h)
	spec := m.status.Spec
	if spec.ID == "" {
		c.put((w-9)/2, h/2, "loading…", evoDim)
		return c.render(pal)
	}
	sectionW := moveContentW
	if sectionW > w {
		sectionW = w
	}
	noteLines := wrapWords(note, sectionW-2)
	// The one-page title bar is always drawn (older Move cards have no tabBar
	// block but still need their name and connection dot).
	header := 2
	// header + levels + status line (2) + note + a gap + help (2)
	totalH := header + ugmLevelRows + 2 + len(noteLines) + 1 + 2
	if w < 44 || h < totalH {
		c.put(0, 0, fmt.Sprintf("Terminal too small (%dx%d, need 44x%d)", w, h, totalH), evoVal)
		return c.render(pal)
	}
	cx := (w - sectionW) / 2
	row := (h - totalH) / 2
	if row < 0 {
		row = 0
	}
	u := m.evo
	u.statusMsg = ""
	r := &evoRender{c: c, m: m, u: &u, spec: spec}

	// Header: a single Levels tab, like the UGM192's, plus the dot and name on
	// the right edge. One tab only, so no key switches it.
	if header > 0 {
		r.singleTabBar(row, cx, sectionW, " Levels ")
	}

	body := row + header
	r.ugmLevelsBody(body, cx, sectionW)
	if m.hasBlock("statusBar") {
		r.drawLevelsStatusBar(body+ugmLevelRows, cx, sectionW)
	}

	ny := body + ugmLevelRows + 2
	for i, line := range noteLines {
		r.put(cx+1, ny+i, line, evoDim)
	}
	if m.hasBlock("help") {
		r.drawHelpFooter(ny+len(noteLines)+1, cx,
			[]evoHint{{key: "Space", desc: " reset peaks"}, {key: "p", desc: " freeze"}, {key: "Esc/h/enter/l", desc: " back"}, {key: "q", desc: " quit"}}, nil)
	}
	return c.render(pal)
}

// moveKey owns the page's keys. There are no controls to edit, so the UGM
// keymap would only offer actions the card does not have (volume, mute); this
// keeps the meter keys and leaving.
func (m *model) moveKey(k string) tea.Cmd {
	switch k {
	case "q":
		return m.evoQuitConfirm()
	case "p":
		m.meterFrozen = !m.meterFrozen
		return nil
	case " ":
		m.resetMeterPeaks()
		return nil
	case "esc", "backspace", "h", "enter", "l":
		m.pop()
		return fetchStatus(m.deviceID)
	}
	return nil
}
