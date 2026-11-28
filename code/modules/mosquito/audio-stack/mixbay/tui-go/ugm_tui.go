// UGM192 panel — the EVO 4 frame for what the ESI actually exposes in
// software. The card is class-compliant with one USB Feature Unit: output
// volume (0..64 = -64..0 dB, L/R joined) and a joined mute. GAIN, MONITOR and
// 48V are front-panel hardware, so they never become rows here.
package main

import (
	"fmt"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"mosquitomarchy.local/mosquitomixbay-tui/drivers"
	"mosquitomarchy.local/mosquitomixbay-tui/meters"
)

const (
	ugmContentW = 62
	// Tab body heights: the controls card is 7 rows, the EVO-style Levels
	// page (titles, readouts, 12-row bars, channel labels) is 15. The panel
	// reserves the taller one so the tab bar never jumps between views.
	ugmBodyRows  = 7
	ugmLevelRows = 2 + 12 + 1
	ugmTotalH    = 2 + ugmLevelRows + 5
)

func (m model) isUGMDevice() bool {
	if m.preset != "" {
		return m.preset == "ugm192"
	}
	return m.deviceID == drivers.DevUGM192
}

// ugmVolFrac maps the UGM192's -64..0 dB scale onto the fader's 0..1.
func ugmVolFrac(spec drivers.Spec, db float64) float64 {
	span := spec.VolMax - spec.VolMin
	if span <= 0 {
		span = 64
	}
	return clampf((db-spec.VolMin)/span, 0, 1)
}

func (m model) ugmView() string {
	w, h := m.contentSize()
	pal := evoPalette()
	c := newEvoCanvas(w, h)
	spec := m.status.Spec
	if spec.ID == "" {
		c.put((w-9)/2, h/2, "loading…", evoDim)
		return c.render(pal)
	}
	sectionW := ugmContentW
	if sectionW > w {
		sectionW = w
	}
	cx := (w - sectionW) / 2
	// The EVO status line must not leak onto the UGM panel.
	u := m.evo
	u.statusMsg = ""
	page, ok := m.currentPage()
	if ok {
		u.window = page.win
	}
	bodyRows := 0
	if m.hasBlock("controlsSingle") {
		bodyRows = ugmBodyRows
	}
	if m.hasBlock("levelsColumns") && ugmLevelRows > bodyRows {
		bodyRows = ugmLevelRows
	}
	if bodyRows == 0 {
		bodyRows = ugmBodyRows
	}
	// A one-model panel keeps its title bar even when an older card's blocks
	// predate the tabBar entry: the bar is the page's chrome, not a tab strip
	// the card can turn off without losing its name and connection dot.
	header := 2
	totalH := header + bodyRows + 5
	if w < 44 || h < totalH {
		c.put(0, 0, fmt.Sprintf("Terminal too small (%dx%d, need 44x%d)", w, h, totalH), evoVal)
		return c.render(pal)
	}
	row := (h - totalH) / 2
	if row < 0 {
		row = 0
	}
	r := &evoRender{c: c, m: m, u: &u, spec: spec}
	if header > 0 {
		if pages := m.pages(); len(pages) == 1 {
			r.singleTabBar(row, cx, sectionW, pages[0].label)
		} else {
			r.ugmTabBar(row, cx, sectionW, u.window == evoWinLevels)
		}
		row += header
	}
	body := row
	tail := ugmBodyRows
	var nav, set []evoHint
	if page.block == "levelsColumns" {
		r.ugmLevelsBody(body, cx, sectionW)
		nav, set = r.levelsHelp()
		tail = ugmLevelRows
		if m.hasBlock("statusBar") {
			r.drawLevelsStatusBar(body+tail, cx, sectionW)
		}
	} else {
		r.ugmControlsBody(body, cx, sectionW)
		nav, set = r.ugmControlsHelp()
		if m.hasBlock("statusBar") {
			r.drawStatusBarWith(body+tail, cx, sectionW, m.numBuf, "dB",
				[]evoHint{{key: "q", desc: " quit"}}, true)
		}
	}
	if m.hasBlock("help") {
		r.drawHelpFooter(body+tail+3, cx, nav, set)
	}
	return c.render(pal)
}

// ugmTabBar is the EVO tab bar with only the two views the UGM192 has.
func (r *evoRender) ugmTabBar(row, cx, sectionW int, levels bool) {
	const ctrlLabel, levLabel = " Controls ", " Levels "
	lineAttr := evoStyle{col: cAccent}
	active := evoStyle{col: cOnAccent, bg: cAccent, bold: true}
	ctrlAttr, levAttr := evoVal, evoVal
	if levels {
		levAttr = active
	} else {
		ctrlAttr = active
	}
	r.put(cx+1, row, ctrlLabel, ctrlAttr)
	levX := cx + 1 + len([]rune(ctrlLabel)) + 1
	r.put(levX, row, levLabel, levAttr)
	r.cardTitle(row, cx, sectionW)

	r.c.repeat(cx, row+1, sectionW, boxH, lineAttr)
	activeX, activeW := cx+1, len([]rune(ctrlLabel))
	if levels {
		activeX, activeW = levX, len([]rune(levLabel))
	}
	r.put(activeX, row+1, strings.Repeat(" ", activeW), lineAttr)
}

// singleTabBar is the same bar for a page with one view: the tab still says
// where the page is, and the card name keeps the right edge.
func (r *evoRender) singleTabBar(row, cx, sectionW int, label string) {
	lineAttr := evoStyle{col: cAccent}
	r.put(cx+1, row, label, evoStyle{col: cOnAccent, bg: cAccent, bold: true})
	r.cardTitle(row, cx, sectionW)
	r.c.repeat(cx, row+1, sectionW, boxH, lineAttr)
	r.put(cx+1, row+1, strings.Repeat(" ", len([]rune(label))), lineAttr)
}

// cardTitle draws the online dot and the card name against the right edge.
func (r *evoRender) cardTitle(row, cx, sectionW int) {
	name := r.spec.Display
	if r.spec.Version != "" {
		name += " - " + r.spec.Version
	}
	dot := "● "
	dotAttr := evoStyle{col: cAccent}
	nameAttr := evoStyle{col: cAccent, bold: true}
	if !r.m.status.Online {
		dot = "○ "
		if r.u.dotLit {
			dotAttr.col = cRed
		}
	} else if !r.u.dotLit {
		dotAttr = evoVal
	}
	rightX := cx + sectionW - len([]rune(name)) - len([]rune(dot))
	r.put(rightX, row, dot, dotAttr)
	r.put(rightX+len([]rune(dot)), row, name, nameAttr)
}

// ugmControlsBody draws the single software control exactly like an EVO
// section: fader, value + [m], then the USB meter row.
func (r *evoRender) ugmControlsBody(row, cx, sectionW int) {
	bw := sectionW - 2
	sw := bw - evoSliderOff
	var out drivers.OutputState
	if len(r.m.status.Outputs) > 0 {
		out = r.m.status.Outputs[0]
	}
	r.boxTop(row, cx, " OUTPUT 1|2 ", true, bw, nil)
	r.boxSide(row+1, cx, bw)
	r.hslider(row+1, cx+evoSliderOff, ugmVolFrac(r.spec, out.VolumeDb), out.Muted, true, cGreen, sw)

	r.boxSide(row+2, cx, bw)
	attr := evoBold
	if out.Muted {
		attr = evoStyle{col: cRed}
	}
	r.put(cx+evoSliderOff, row+2, fmt.Sprintf("%-5s %+6.1f dB", "Vol:", out.VolumeDb), attr)
	r.muteInd(row+2, cx+bw-3, out.Muted)

	r.boxSide(row+3, cx, bw)
	r.drawKeyMeter(row+3, cx+2, bw-2, "output", cGreen)
	r.boxBot(row+4, cx, bw)
}

// ugmLevelsBody is the EVO 8 Levels page reduced to what the card carries:
// Capture (IN1/IN2) left, Playback (USB) right, dB barometer on the left.
func (r *evoRender) ugmLevelsBody(row, cx, sectionW int) {
	const (
		barW     = 4
		gap      = 1
		scaleW   = 7
		groupGap = 3
		barRows  = 12
	)
	capBars := []evoMeterBar{
		{label: "IN1", key: meters.KeyInput, ch: 0},
		{label: "IN2", key: meters.KeyInput, ch: 1},
	}
	playBars := []evoMeterBar{
		{label: "OUT1", key: meters.KeyPlayback, ch: 0},
		{label: "OUT2", key: meters.KeyPlayback, ch: 1},
	}
	groupW := len(capBars)*barW + (len(capBars)-1)*gap
	totalW := scaleW + groupW*2 + groupGap
	x := cx + (sectionW-totalW)/2
	if x < cx {
		x = cx
	}
	captureX := x + scaleW
	playbackX := captureX + groupW + groupGap

	r.put(captureX+(groupW-len([]rune("Capture")))/2, row, "Capture", evoStyle{col: cAccent, bold: true})
	playbackTitle := "Playback (USB)"
	r.put(playbackX+(groupW-len([]rune(playbackTitle)))/2, row, playbackTitle, evoStyle{col: cAccent, bold: true})
	readoutRow := row + 1
	barTop := row + 2
	barBot := barTop + barRows - 1
	r.drawMeterScale(x, barTop, barBot, r.m.meterFloor())
	r.drawMeterColumns(captureX, readoutRow, barTop, barBot, barW, gap, capBars)
	r.drawMeterColumns(playbackX, readoutRow, barTop, barBot, barW, gap, playBars)
}

func (r *evoRender) ugmControlsHelp() ([]evoHint, []evoHint) {
	return []evoHint{
		{key: "Tab", desc: " view"},
		{key: "m", desc: " mute"},
	}, []evoHint{
		{key: "Ctrl+←→", desc: " ±5"},
		{key: "Ctrl+Shift+←→", desc: " ±1"},
		{key: "0-9", desc: " dial"},
		{key: "r", desc: " reset"},
	}
}

func (m *model) ugmKey(k string) tea.Cmd {
	dev := m.deviceID
	if m.evo.window == evoWinLevels {
		switch k {
		case "q":
			return m.evoQuitConfirm()
		case "tab":
			m.cyclePage()
			return nil
		case "esc", "backspace", "h":
			if m.hasBlock("controlsSingle") {
				m.evo.window = evoWinControls
				return nil
			}
			m.pop()
			return fetchStatus(dev)
		case "p":
			m.meterFrozen = !m.meterFrozen
			return nil
		case " ":
			m.resetMeterPeaks()
			return nil
		}
		return nil
	}
	switch k {
	case "q":
		return m.evoQuitConfirm()
	case "esc", "backspace", "h":
		if m.numBuf != "" {
			if k == "backspace" {
				m.numBuf = m.numBuf[:len(m.numBuf)-1]
			} else {
				m.cancelNumeric()
			}
			return nil
		}
		m.pop()
		return fetchStatus(dev)
	case "tab":
		m.cyclePage()
		m.cancelNumeric()
		return nil
	case "m":
		return m.activateControl("mute:output")
	case "r":
		return m.applyCmd(dev, func(d drivers.Driver) error {
			return d.SetVolume(0, m.status.Spec.VolMin)
		}, "volume reset")
	case "enter", "l":
		if m.numBuf != "" {
			return m.finishNumeric()
		}
		return nil
	}
	if dir, coarse, ok := evoAdjustKey(k); ok {
		return m.nudgeControlStep("vol:0", dir > 0, evoAdjustStep("volume", coarse))
	}
	if len(k) == 1 && m.startNumeric(k, "vol:0") {
		return nil
	}
	return nil
}

func (m *model) resetMeterPeaks() {
	m.meterPeakIn, m.meterPeakOut = [evoMaxMeterChannels]float64{}, [evoMaxMeterChannels]float64{}
	if m.meter != nil {
		m.meter.ResetPeaks()
	}
}
