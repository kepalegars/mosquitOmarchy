// Ableton Move page — the UGM192 Levels page, minus everything the card does
// not have.
//
// The Move is a class-compliant USB interface with a fixed 44.1 kHz clock and
// no software mixer: no ALSA volume, mute or gain to drive. So there is no
// Controls tab and no tab bar at all — only Capture/Playback meters, and a
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
	note := wrapWords(moveNote, sectionW-2)
	// header (2) + levels + status line (2) + note + a gap + help (2)
	totalH := 2 + ugmLevelRows + 2 + len(note) + 1 + 2
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

	// Header: dot + name on the right edge, the same convention the other
	// cards use. No tabs: there is only one view.
	dot, dotAttr := "● ", evoStyle{col: cAccent}
	if !m.status.Online {
		dot, dotAttr = "○ ", evoStyle{col: cRed}
	}
	name := spec.Display
	if spec.Version != "" {
		name += " - " + spec.Version
	}
	rightX := cx + sectionW - len([]rune(name)) - len([]rune(dot))
	r.put(rightX, row, dot, dotAttr)
	r.put(rightX+len([]rune(dot)), row, name, evoStyle{col: cAccent, bold: true})
	r.c.repeat(cx, row+1, sectionW, boxH, evoStyle{col: cAccent})

	body := row + 2
	r.ugmLevelsBody(body, cx, sectionW)
	r.drawLevelsStatusBar(body+ugmLevelRows, cx, sectionW)

	ny := body + ugmLevelRows + 2
	for i, line := range note {
		r.put(cx+1, ny+i, line, evoDim)
	}
	r.drawHelpFooter(ny+len(note)+1, cx,
		[]evoHint{{key: "Space", desc: " reset peaks"}, {key: "p", desc: " freeze"}, {key: "q", desc: " quit"}}, nil)
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
	case "esc", "backspace":
		m.pop()
		return fetchStatus(m.deviceID)
	}
	return nil
}
