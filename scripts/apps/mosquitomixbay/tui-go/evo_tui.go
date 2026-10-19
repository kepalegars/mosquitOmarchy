// EVO interface — a faithful Go port of vanzaho/audient-evo-py's evotui.py
// (public domain), wired to this bay's drivers.
//
// The upstream curses layout is reproduced glyph-for-glyph and cell-for-cell
// (tab bar, boxed section cards, half-block sliders, centre-origin pan
// sliders, the 3-line bus-routing diagram, the status bar, the help footer
// and the config file picker). The ONLY deliberate difference is colour: the
// curses colour pairs are replaced by the live Omarchy theme palette, so the
// EVO screens follow the desktop theme instead of fixed ANSI colours.
package main

import (
	"fmt"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"mosquitomarchy.local/mosquitomixbay-tui/drivers"
	tuikit "mosquitomarchy.local/tui-kit"
)

// --- evotui geometry --------------------------------------------------------

const (
	evoSliderW      = 69
	evoBoxIW        = evoSliderW + 2
	evoSliderOff    = 2
	evoPickerListH  = 6
	evoMinSectionIW = 17
	evoMinPanHalf   = 7
	evoColGap       = 1
	evoPanMin       = -100.0
	evoPanMax       = 100.0
	evoPanStep      = 5.0
	evoMixDbMin     = -128.0
	evoMixDbMax     = 6.0
	evoControlsTop  = 3
	evoControlsTail = 5
	evoHsep         = " · "
)

// evotui's box / slider / bus glyphs, verbatim.
const (
	boxTLA, boxHA, boxTRA = '┏', '━', '┓'
	boxVA, boxBLA, boxBRA = '┃', '┗', '┛'
	boxTL, boxH, boxTR    = '┌', '─', '┐'
	boxV, boxBL, boxBR    = '│', '└', '┘'
	busTR, busBL          = '╗', '╚'
	busH                  = '═'
	busJStart, busJTUp    = '╘', '╧'
	busJTDown             = '╦'
	slFull                = '▬'
	arrowR, arrowREmpty   = '▶', '▷'
	arrowD, arrowU        = '↓', '↑'
	evoTabSym             = "Tab"
)

const evoArrows = "←↓↑→"
const evoPM = "±" // ±

// --- colour slots (mirror evotui's C_* pairs) -------------------------------

const (
	cNone = iota
	cGreen
	cRed
	cCyan
	cYellow
	cWhite
	cBlue
)

// --- canvas -----------------------------------------------------------------

type evoStyle struct {
	col       int
	bold, dim bool
	rev       bool
}

var (
	evoDim     = evoStyle{col: cWhite, dim: true}
	evoVal     = evoStyle{col: cWhite}
	evoBold    = evoStyle{col: cWhite, bold: true}
	evoBoldDim = evoStyle{col: cWhite, bold: true, dim: true}
)

type evoCell struct {
	r       rune
	st      evoStyle
	hasRune bool
}

type evoCanvas struct {
	w, h  int
	cells []evoCell
}

func newEvoCanvas(w, h int) *evoCanvas {
	c := &evoCanvas{w: w, h: h, cells: make([]evoCell, w*h)}
	for i := range c.cells {
		c.cells[i] = evoCell{r: ' '}
	}
	return c
}

func (c *evoCanvas) put(x, y int, s string, st evoStyle) {
	if y < 0 || y >= c.h {
		return
	}
	col := 0
	for _, r := range s {
		xx := x + col
		if xx >= 0 && xx < c.w {
			c.cells[y*c.w+xx] = evoCell{r: r, st: st, hasRune: true}
		}
		col++
	}
}

func (c *evoCanvas) repeat(x, y, n int, r rune, st evoStyle) {
	for i := 0; i < n; i++ {
		c.put(x+i, y, string(r), st)
	}
}

// render turns the canvas into styled lines, trimming trailing blanks so a
// sparse frame does not emit kilometres of spaces.
func (c *evoCanvas) render(pal [7]lipgloss.Color) string {
	var b strings.Builder
	for y := 0; y < c.h; y++ {
		end := c.w
		for end > 0 {
			cell := c.cells[y*c.w+end-1]
			if cell.r != ' ' || cell.st != (evoStyle{}) {
				break
			}
			end--
		}
		x := 0
		for x < end {
			cell := c.cells[y*c.w+x]
			j := x + 1
			for j < end && c.cells[y*c.w+j].st == cell.st {
				j++
			}
			var run strings.Builder
			for k := x; k < j; k++ {
				run.WriteRune(c.cells[y*c.w+k].r)
			}
			if cell.st == (evoStyle{}) {
				b.WriteString(run.String())
			} else {
				b.WriteString(evoStyleFor(pal, cell.st).Render(run.String()))
			}
			x = j
		}
		if y < c.h-1 {
			b.WriteByte('\n')
		}
	}
	return b.String()
}

func evoStyleFor(pal [7]lipgloss.Color, st evoStyle) lipgloss.Style {
	s := lipgloss.NewStyle()
	if st.col != cNone {
		s = s.Foreground(pal[st.col])
	}
	if st.bold {
		s = s.Bold(true)
	}
	if st.dim {
		s = s.Faint(true)
	}
	if st.rev {
		s = s.Reverse(true)
	}
	return s
}

// --- model state ------------------------------------------------------------

type evoUI struct {
	spec      drivers.Spec
	window    int // 0 controls, 1 mixer
	sub       int // controls subsection (EVO 8: 0 inputs, 1 outputs)
	cursor    int
	mxSection int
	mxParam   int
	mixBus    int

	numBuf    string
	statusMsg string
	statusErr bool
	statusGen int

	mode       int // 0 normal, 1 save, 2 load
	fileList   []string
	fileCursor int
	fileScroll int
	fileInput  string
}

type evoElement struct {
	key   string
	sub   string // "volume" | "gain" | ""
	label string
	color int
}

type evoGroup struct {
	label    string
	elements []evoElement
}

type evoMxSection struct {
	key    string
	label  string
	color  int
	params []string
}

func evoNumMixerSources(spec drivers.Spec) int { return (spec.MixerInputs - spec.NumInputs) / 2 }

func evoElements(spec drivers.Spec) []evoElement {
	els := []evoElement{{key: "output", sub: "volume", label: "OUT", color: cGreen}}
	for i := 0; i < spec.NumInputs; i++ {
		els = append(els, evoElement{key: fmt.Sprintf("input%d", i+1), sub: "gain", label: fmt.Sprintf("IN %d", i+1), color: cBlue})
	}
	if spec.HasMonitor {
		els = append(els, evoElement{key: "monitor", label: "MONITOR", color: cCyan})
	}
	return els
}

func evoGroups(spec drivers.Spec) []evoGroup {
	if spec.NumOutPairs == 1 {
		return []evoGroup{{label: "ALL", elements: evoElements(spec)}}
	}
	var inputs, outputs []evoElement
	for i := 0; i < spec.NumInputs; i++ {
		inputs = append(inputs, evoElement{key: fmt.Sprintf("input%d", i+1), sub: "gain", label: fmt.Sprintf("IN %d", i+1), color: cBlue})
	}
	for i := 0; i < spec.NumOutPairs; i++ {
		outputs = append(outputs, evoElement{key: fmt.Sprintf("output%d", i+1), sub: "volume", label: fmt.Sprintf("OUT %d|%d", i*2+1, i*2+2), color: cGreen})
	}
	return []evoGroup{{label: "INPUTS", elements: inputs}, {label: "OUTPUTS", elements: outputs}}
}

func evoHasSubsections(spec drivers.Spec) bool { return len(evoGroups(spec)) > 1 }

func (u *evoUI) activeElements() []evoElement {
	groups := evoGroups(u.spec)
	if evoHasSubsections(u.spec) {
		if u.sub < len(groups) {
			return groups[u.sub].elements
		}
		return groups[0].elements
	}
	return groups[0].elements
}

// evoMixerRows returns the two mixer rows (inputs, stereo sources) in evotui's
// order, with each source's slider list.
func evoMixerRows(spec drivers.Spec) [][]evoMxSection {
	inSliders := []string{"pan", "volume"}
	outSliders := []string{"pan_l", "pan_r", "volume"}
	var inputs []evoMxSection
	for i := 0; i < spec.NumInputs; i++ {
		inputs = append(inputs, evoMxSection{
			key: fmt.Sprintf("input%d", i+1), label: fmt.Sprintf("IN %d", i+1),
			color: cBlue, params: append([]string{}, inSliders...),
		})
	}
	var outputs []evoMxSection
	for i := 0; i < evoNumMixerSources(spec); i++ {
		color := cGreen
		label := fmt.Sprintf("OUT %d|%d", i*2+1, i*2+2)
		if i >= spec.NumOutPairs {
			color = cYellow
			label += " (LOOP)"
		}
		outputs = append(outputs, evoMxSection{key: fmt.Sprintf("output%d_%d", i*2+1, i*2+2), label: label, color: color, params: append([]string{}, outSliders...)})
	}
	return [][]evoMxSection{inputs, outputs}
}

func (u *evoUI) flatMx() []evoMxSection {
	rows := evoMixerRows(u.spec)
	var out []evoMxSection
	for _, r := range rows {
		out = append(out, r...)
	}
	return out
}

// --- value access -----------------------------------------------------------

func (m model) evoElemValue(e evoElement) float64 {
	switch {
	case e.key == "monitor":
		if m.status.Monitor != nil {
			return float64(*m.status.Monitor)
		}
		return 0
	case strings.HasPrefix(e.key, "input"):
		var n int
		fmt.Sscanf(e.key, "input%d", &n)
		for _, in := range m.status.Inputs {
			if in.Name == fmt.Sprintf("input%d", n) {
				return in.GainDb
			}
		}
	case e.key == "output":
		if len(m.status.Outputs) > 0 {
			return m.status.Outputs[0].VolumeDb
		}
	default: // outputN
		var n int
		fmt.Sscanf(e.key, "output%d", &n)
		if n-1 >= 0 && n-1 < len(m.status.Outputs) {
			return m.status.Outputs[n-1].VolumeDb
		}
	}
	return 0
}

func (m model) evoElemMuted(e evoElement) bool {
	if e.key == "monitor" {
		return false
	}
	if strings.HasPrefix(e.key, "input") {
		var n int
		fmt.Sscanf(e.key, "input%d", &n)
		for _, in := range m.status.Inputs {
			if in.Name == fmt.Sprintf("input%d", n) {
				return in.Muted
			}
		}
		return false
	}
	idx := 0
	if e.key != "output" {
		fmt.Sscanf(e.key, "output%d", &idx)
		if idx > 0 {
			idx--
		}
	}
	if idx >= 0 && idx < len(m.status.Outputs) {
		return m.status.Outputs[idx].Muted
	}
	return false
}

func (m model) evoElemPhantom(e evoElement) bool {
	if !strings.HasPrefix(e.key, "input") {
		return false
	}
	var n int
	fmt.Sscanf(e.key, "input%d", &n)
	for _, in := range m.status.Inputs {
		if in.Name == fmt.Sprintf("input%d", n) {
			return in.Phantom
		}
	}
	return false
}

func (m model) evoElemRange(e evoElement) (float64, float64, float64) {
	switch {
	case e.key == "monitor":
		return 0, 100, 1
	case strings.HasPrefix(e.key, "input"):
		return m.status.Spec.GainMin, m.status.Spec.GainMax, 1
	default:
		return m.status.Spec.VolMin, m.status.Spec.VolMax, 1
	}
}

func clampf(v, lo, hi float64) float64 {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

func (m model) evoElemFrac(e evoElement, val float64) float64 {
	lo, hi, _ := m.evoElemRange(e)
	if hi == lo {
		return 0
	}
	return clampf((val-lo)/(hi-lo), 0, 1)
}

func (m model) evoMxCell(section, param string) float64 {
	c := m.status.Mixer[drivers.MixerKey(section, m.evo.mixBus)]
	switch param {
	case "volume":
		return c.VolumeDb
	case "pan":
		return c.Pan
	case "pan_l":
		return c.PanL
	case "pan_r":
		return c.PanR
	}
	return 0
}

// --- renderer ---------------------------------------------------------------

type evoHint struct {
	key, desc string
	col       int
}

type evoRender struct {
	c         *evoCanvas
	m         model
	u         *evoUI
	spec      drivers.Spec
	boxAttr   evoStyle
	boxActive bool
}

func (r *evoRender) put(x, y int, s string, st evoStyle) { r.c.put(x, y, s, st) }

func evoPalette() [7]lipgloss.Color {
	var p [7]lipgloss.Color
	p[cGreen] = tuikit.ColorGreen
	p[cRed] = tuikit.ColorRed
	p[cCyan] = tuikit.ColorCyan
	p[cYellow] = tuikit.ColorYellow
	p[cWhite] = tuikit.ColorSubtle
	p[cBlue] = tuikit.ColorBlue
	return p
}

func evoSecDim(spec drivers.Spec) (int, int) {
	if spec.NumOutPairs == 1 {
		return evoMinSectionIW + 10, evoMinPanHalf + 5
	}
	return evoMinSectionIW, evoMinPanHalf
}

func (r *evoRender) sectionIW() int { iw, _ := evoSecDim(r.spec); return iw }
func (r *evoRender) panHalf() int   { _, ph := evoSecDim(r.spec); return ph }
func (r *evoRender) maxPan() int    { return 2 }
func (r *evoRender) sectionH() int  { return r.maxPan()*2 + 5 }

func (r *evoRender) boxTop(row, cx int, label string, active bool, iw int, attr *evoStyle) {
	var st evoStyle
	switch {
	case attr != nil:
		st = *attr
	case active:
		st = evoStyle{col: cWhite, bold: true}
	default:
		st = evoStyle{col: cWhite, dim: true}
	}
	h, d, e := boxTL, boxH, boxTR
	if active {
		h, d, e = boxTLA, boxHA, boxTRA
	}
	dashes := iw - len([]rune(label)) - 2
	if dashes < 0 {
		dashes = 0
	}
	r.put(cx, row, string(h)+" ", st)
	r.put(cx+2, row, label, st)
	r.put(cx+2+len([]rune(label)), row, " "+strings.Repeat(string(d), dashes)+string(e), st)
	r.boxAttr = st
	r.boxActive = active
}

func (r *evoRender) boxSide(row, cx, iw int) {
	v := boxV
	if r.boxActive {
		v = boxVA
	}
	r.put(cx, row, string(v), r.boxAttr)
	r.put(cx+iw+1, row, string(v), r.boxAttr)
}

func (r *evoRender) boxBot(row, cx, iw int) {
	bl, d, br := boxBL, boxH, boxBR
	if r.boxActive {
		bl, d, br = boxBLA, boxHA, boxBRA
	}
	r.put(cx, row, string(bl)+strings.Repeat(string(d), iw)+string(br), r.boxAttr)
}

// hslider is evotui's half-block fader: 2 cells per slider cell, the odd cell
// shown as a half block, filled red when muted.
func (r *evoRender) hslider(row, x int, frac float64, muted, sel bool, color, w int) {
	slots := w * 2
	filled := int(math.Round(float64(slots) * frac))
	if filled < 0 {
		filled = 0
	}
	if filled > slots {
		filled = slots
	}
	full, partial := filled/2, filled%2
	fillCol := color
	if muted {
		fillCol = cRed
	}
	fillSt := evoStyle{col: fillCol, dim: !sel}
	emptySt := evoStyle{col: cWhite, dim: !sel}
	pos := x
	if full > 0 {
		r.c.repeat(pos, row, full, slFull, fillSt)
		pos += full
	}
	if partial > 0 {
		r.put(pos, row, string(boxHA), fillSt)
		pos++
	}
	if empty := w - full - partial; empty > 0 {
		r.c.repeat(pos, row, empty, boxH, emptySt)
	}
}

// panSlider is evotui's centre-origin pan fader: fill grows from ±100 toward
// the centre, with a bold centre tick.
func (r *evoRender) panSlider(row, x int, frac float64, sel bool, color, w int) {
	half := w / 2
	fillSt := evoStyle{col: color, dim: !sel}
	emptySt := evoStyle{col: cWhite, dim: !sel}
	r.c.repeat(x, row, w, boxH, emptySt)
	leftSlots := int(math.Round((1 - frac) * float64(half) * 2))
	if leftSlots < 0 {
		leftSlots = 0
	}
	if leftSlots > half*2 {
		leftSlots = half * 2
	}
	rightSlots := half*2 - leftSlots
	lf, lp := leftSlots/2, leftSlots%2
	rf, rp := rightSlots/2, rightSlots%2
	if lf > 0 {
		r.c.repeat(x+half-lf, row, lf, slFull, fillSt)
	}
	if lp > 0 {
		r.put(x+half-lf-1, row, string(boxHA), fillSt)
	}
	if rf > 0 {
		r.c.repeat(x+half+1, row, rf, slFull, fillSt)
	}
	if rp > 0 {
		r.put(x+half+1+rf, row, string(boxHA), fillSt)
	}
	r.put(x+half, row, string(boxV), evoStyle{col: cWhite, bold: true})
}

func (r *evoRender) muteInd(row, x int, muted bool) {
	if muted {
		r.put(x, row, "[M]", evoStyle{col: cRed, bold: true})
	} else {
		r.put(x, row, "[m]", evoDim)
	}
}

func (r *evoRender) phantomInd(row, x int, on bool) {
	if on {
		r.put(x, row, "[48V]", evoStyle{col: cYellow, bold: true})
	} else {
		r.put(x, row, "[48v]", evoDim)
	}
}

func (r *evoRender) drawTabBar(row, cx, sectionW int) {
	const ctrlLabel, mixLabel = " CONTROLS ", " MIXER "
	dim := evoDim
	rev := evoStyle{col: cWhite, bold: true, rev: true}
	controls := r.u.window == 0
	ctrlAttr, mixAttr := dim, rev
	if controls {
		ctrlAttr, mixAttr = rev, dim
	}
	r.put(cx+1, row, ctrlLabel, ctrlAttr)
	mixX := cx + 1 + len([]rune(ctrlLabel)) + 1
	r.put(mixX, row, mixLabel, mixAttr)
	name := r.spec.Display
	r.put(cx+sectionW-len([]rune(name)), row, name, dim)
	r.c.repeat(cx, row+1, sectionW, boxH, dim)
	activeX, activeW := cx+1, len([]rune(ctrlLabel))
	if !controls {
		activeX, activeW = mixX, len([]rune(mixLabel))
	}
	r.put(activeX, row+1, strings.Repeat(" ", activeW), dim)
}

func (r *evoRender) drawSection(row, cx, idx, sw, bw int, forceInactive bool) int {
	els := r.u.activeElements()
	e := els[idx]
	active := r.u.cursor == idx && !forceInactive
	val := r.m.evoElemValue(e)
	frac := r.m.evoElemFrac(e, val)
	muted := r.m.evoElemMuted(e)
	r.boxTop(row, cx, e.label, active, bw, nil)
	row++
	r.boxSide(row, cx, bw)
	if e.sub == "" {
		r.panSlider(row, cx+evoSliderOff, frac, active, e.color, sw)
	} else {
		r.hslider(row, cx+evoSliderOff, frac, muted, active, e.color, sw)
	}
	row++
	r.boxSide(row, cx, bw)
	lblAttr := evoDim
	if active {
		lblAttr = evoBold
	}
	dialActive := active && r.u.numBuf != ""
	if e.sub == "" {
		r.put(cx+evoSliderOff, row, "IN", lblAttr)
		pct := fmt.Sprintf("Mix: %3.0f%%", val)
		mid := cx + evoSliderOff + (sw-len([]rune(pct)))/2
		attr := lblAttr
		if dialActive {
			attr = evoStyle{col: cYellow, bold: true}
		}
		r.put(mid, row, pct, attr)
		r.put(cx+evoSliderOff+sw-3, row, "OUT", lblAttr)
	} else {
		vlabel := "Gain:"
		if strings.HasPrefix(e.key, "output") {
			vlabel = "Vol:"
		}
		valStr := fmt.Sprintf("%-5s %+6.1f dB", vlabel, val)
		attr := lblAttr
		switch {
		case dialActive:
			attr = evoStyle{col: cYellow, bold: true}
		case muted:
			attr = evoStyle{col: cRed}
		}
		r.put(cx+evoSliderOff, row, valStr, attr)
		if strings.HasPrefix(e.key, "input") {
			r.phantomInd(row, cx+bw-9, r.m.evoElemPhantom(e))
		}
		if e.key != "monitor" {
			r.muteInd(row, cx+bw-3, muted)
		}
	}
	row++
	r.boxBot(row, cx, bw)
	return row + 1
}

func (r *evoRender) drawControlsBody(row, cx, mixerW int) int {
	if evoHasSubsections(r.spec) {
		return r.drawControlsTwoCol(row, cx, mixerW)
	}
	bw := mixerW - 2
	sw := bw - evoSliderOff
	els := r.u.activeElements()
	for idx := range els {
		row = r.drawSection(row, cx, idx, sw, bw, false)
		if idx < len(els)-1 {
			row++
		}
	}
	return row + 1
}

func (r *evoRender) drawControlsTwoCol(row, cx, mixerW int) int {
	colW := (mixerW - evoColGap) / 2
	colBw := colW - 2
	colSw := colBw - evoSliderOff
	saved := r.u.sub
	groups := evoGroups(r.spec)
	drawCol := func(sub, colX int) int {
		r.u.sub = sub
		rrow := row
		els := groups[sub].elements
		for idx := range els {
			rrow = r.drawSection(rrow, colX, idx, colSw, colBw, saved != sub)
			if idx < len(els)-1 {
				rrow++
			}
		}
		return rrow
	}
	left := drawCol(0, cx)
	right := drawCol(1, cx+colW+evoColGap)
	r.u.sub = saved
	if right > left {
		return right + 1
	}
	return left + 1
}

func (r *evoRender) drawMixerSection(topRow, cx, secIdx int, compact bool) {
	sections := r.u.flatMx()
	s := sections[secIdx]
	selSec := r.u.mxSection == secIdx
	var panIdx []int
	volIdx := -1
	for i, p := range s.params {
		if strings.HasPrefix(p, "pan") {
			panIdx = append(panIdx, i)
		}
		if p == "volume" {
			volIdx = i
		}
	}
	volVal := r.m.evoMxCell(s.key, "volume")
	connected := volVal > evoMixDbMin
	var boxAttr *evoStyle
	if connected {
		st := evoStyle{col: cCyan}
		if selSec {
			st.bold = true
		}
		boxAttr = &st
	}
	siw := r.sectionIW()
	r.boxTop(topRow, cx, s.label, selSec, siw, boxAttr)
	row := topRow + 1
	slots := len(panIdx)
	if !compact {
		slots = r.maxPan()
	}
	panW := 2*r.panHalf() + 1
	for slot := 0; slot < slots; slot++ {
		r.boxSide(row, cx, siw)
		if slot < len(panIdx) {
			pi := panIdx[slot]
			p := s.params[pi]
			val := r.m.evoMxCell(s.key, p)
			sel := selSec && r.u.mxParam == pi
			r.panSlider(row, cx+2, (val-evoPanMin)/(evoPanMax-evoPanMin), sel, s.color, panW)
		}
		row++
		r.boxSide(row, cx, siw)
		if slot < len(panIdx) {
			pi := panIdx[slot]
			p := s.params[pi]
			val := r.m.evoMxCell(s.key, p)
			sel := selSec && r.u.mxParam == pi
			plabel := "Pan"
			if p == "pan_l" {
				plabel = "Pan L"
			} else if p == "pan_r" {
				plabel = "Pan R"
			}
			attr := evoDim
			if sel {
				attr = evoBold
			}
			if sel && r.u.numBuf != "" {
				attr = evoStyle{col: cYellow, bold: true}
			}
			txt := fmt.Sprintf("%-*s %+5.0f", siw-8, plabel+":", val)
			if len([]rune(txt)) > siw-2 {
				txt = string([]rune(txt)[:siw-2])
			}
			r.put(cx+2, row, txt, attr)
		}
		row++
	}
	r.boxSide(row, cx, siw)
	row++
	volFrac := clampf((volVal-evoMixDbMin)/(evoMixDbMax-evoMixDbMin), 0, 1)
	volSel := selSec && r.u.mxParam == volIdx
	r.boxSide(row, cx, siw)
	r.hslider(row, cx+2, volFrac, false, volSel, s.color, siw-2)
	row++
	r.boxSide(row, cx, siw)
	volAttr := evoDim
	if volSel {
		volAttr = evoBold
	}
	if volSel && r.u.numBuf != "" {
		volAttr = evoStyle{col: cYellow, bold: true}
	}
	vtxt := fmt.Sprintf("%-*s %+6.1f dB", siw-12, "Vol:", volVal)
	if len([]rune(vtxt)) > siw-2 {
		vtxt = string([]rune(vtxt)[:siw-2])
	}
	r.put(cx+2, row, vtxt, volAttr)
	row++
	r.boxBot(row, cx, siw)
}

func evoMixOutputLabel(spec drivers.Spec, i int) string {
	left := i*2 + 1
	if spec.NumOutPairs == 1 {
		left = spec.NumInputs + 1
	}
	return fmt.Sprintf("%d|%d", left, left+1)
}

func (r *evoRender) drawBusRoute(row, cx, width int) {
	secOW := r.sectionIW() + 3
	dim := evoDim
	busAttr := evoStyle{col: cCyan, bold: true}
	rows := evoMixerRows(r.spec)
	wall := map[int]bool{}
	for i, s := range rows[0] {
		if r.m.evoMxCell(s.key, "volume") > evoMixDbMin {
			wall[i*secOW] = true
		}
	}
	outWall := map[int]bool{}
	for i, s := range rows[1] {
		if r.m.evoMxCell(s.key, "volume") > evoMixDbMin {
			outWall[i*secOW+r.sectionIW()+1] = true
		}
	}
	busChars := func(n int) string {
		var sb strings.Builder
		for p := 0; p < n; p++ {
			up, down := wall[p], outWall[p]
			switch {
			case p == 0 && !up:
				sb.WriteRune(' ')
			case p == 0:
				sb.WriteRune(busJStart)
			case up && down:
				sb.WriteRune(busJTDown)
			case up:
				sb.WriteRune(busJTUp)
			case down:
				sb.WriteRune(busJTDown)
			default:
				sb.WriteRune(busH)
			}
		}
		return sb.String()
	}
	if r.spec.NumOutPairs == 1 {
		label := fmt.Sprintf(" MIX %s ", evoMixOutputLabel(r.spec, 0))
		jx := cx + width - len([]rune(label)) - 1
		r.put(cx, row+1, busChars(width), busAttr)
		r.put(jx, row+1, label, busAttr)
		return
	}
	var mixLabels []string
	for i := 0; i < r.spec.NumOutPairs; i++ {
		mixLabels = append(mixLabels, "MIX "+evoMixOutputLabel(r.spec, i))
	}
	labelW := 0
	for _, l := range mixLabels {
		if len([]rune(l)) > labelW {
			labelW = len([]rune(l))
		}
	}
	jx := cx + width - (3 + labelW)
	mixOutput := r.u.mixBus
	a0, a1 := dim, dim
	if mixOutput == 0 {
		a0 = evoStyle{col: cCyan, bold: true}
	}
	if mixOutput == 1 {
		a1 = evoStyle{col: cCyan, bold: true}
	}
	r.put(cx, row+1, busChars(jx-cx), busAttr)
	if len(mixLabels) > 0 {
		pre := string(arrowREmpty)
		junc := string(busH)
		if mixOutput == 0 {
			pre = string(arrowR)
		} else {
			junc = string(busTR)
		}
		r.put(jx, row+1, junc+pre+" "+mixLabels[0], a0)
	}
	if len(mixLabels) > 1 {
		pre := string(arrowREmpty)
		if mixOutput == 1 {
			pre = string(arrowR)
		}
		r.put(jx, row+2, string(busBL)+pre+" "+mixLabels[1], a1)
	}
}

func (r *evoRender) drawMixerBody(row, cx int) int {
	secOW := r.sectionIW() + 3
	rows := evoMixerRows(r.spec)
	flat := 0
	for i := range rows[0] {
		r.drawMixerSection(row, cx+i*secOW, flat, true)
		flat++
	}
	row += r.sectionH() - 2
	maxRowLen := len(rows[0])
	if len(rows[1]) > maxRowLen {
		maxRowLen = len(rows[1])
	}
	r.drawBusRoute(row, cx, maxRowLen*secOW-1)
	row += 3
	for i := range rows[1] {
		r.drawMixerSection(row, cx+i*secOW, flat, false)
		flat++
	}
	return row + r.sectionH() + 1
}

func (r *evoRender) drawHints(row, col int, hints []evoHint, dim evoStyle) int {
	for i, h := range hints {
		if i > 0 {
			r.put(col, row, evoHsep, dim)
			col += len([]rune(evoHsep))
		}
		kc := h.col
		if kc == cNone {
			kc = cWhite
		}
		r.put(col, row, h.key, evoStyle{col: kc, bold: true})
		col += len([]rune(h.key))
		r.put(col, row, h.desc, dim)
		col += len([]rune(h.desc))
	}
	return col
}

func (r *evoRender) currentUnit() string {
	if r.u.window == 0 {
		els := r.u.activeElements()
		if r.u.cursor < len(els) && els[r.u.cursor].sub == "" {
			return "%"
		}
		return "dB"
	}
	sections := r.u.flatMx()
	if r.u.mxSection < len(sections) {
		ps := sections[r.u.mxSection].params
		if r.u.mxParam < len(ps) && ps[r.u.mxParam] == "volume" {
			return "dB"
		}
	}
	return ""
}

func (r *evoRender) drawStatusBar(row, cx, sectionW int) int {
	dim := evoDim
	if r.u.numBuf != "" {
		attr := evoStyle{col: cYellow}
		prefix := "= " + r.u.numBuf
		r.put(cx+evoSliderOff, row, prefix, attr)
		r.put(cx+evoSliderOff+len([]rune(prefix))+1, row, " "+r.currentUnit(), attr)
	} else if r.u.statusMsg != "" {
		attr := evoStyle{col: cYellow}
		if r.u.statusErr {
			attr = evoStyle{col: cRed, bold: true}
		}
		r.put(cx+evoSliderOff, row, r.u.statusMsg, attr)
	}
	row++
	hints := []evoHint{{key: "s", desc: " save"}, {key: "o", desc: " load"}, {key: "q", desc: " quit"}}
	if r.u.numBuf != "" {
		hints = append([]evoHint{
			{key: "↵", desc: ":set", col: cYellow},
			{key: "Esc", desc: ":cancel", col: cYellow},
		}, hints...)
	}
	hintsW := 1
	for _, h := range hints {
		hintsW += len([]rune(h.key)) + len([]rune(h.desc))
	}
	hintsW += len([]rune(evoHsep))*(len(hints)-1) + 1
	dashes := sectionW - 1 - hintsW
	if dashes < 0 {
		dashes = 0
	}
	r.c.repeat(cx, row, dashes, boxH, dim)
	r.put(cx+sectionW-1, row, string(boxH), dim)
	r.drawHints(row, cx+dashes+1, hints, dim)
	return row + 1
}

func (r *evoRender) controlsHelp() ([]evoHint, []evoHint) {
	var nav []evoHint
	if evoHasSubsections(r.spec) {
		nav = []evoHint{{key: "hjkl", desc: " " + evoArrows}}
	} else {
		nav = []evoHint{{key: "jk", desc: " " + string(arrowD) + string(arrowU)}}
	}
	nav = append(nav, evoHint{key: evoTabSym, desc: " tab"})
	set := []evoHint{
		{key: "[]", desc: " " + evoPM + "1"},
		{key: "{}", desc: " " + evoPM + "5"},
		{key: "0-9", desc: " dial"},
	}
	els := r.u.activeElements()
	if r.u.cursor < len(els) {
		e := els[r.u.cursor]
		if e.key != "monitor" {
			set = append(set, evoHint{key: "m", desc: " mute"})
		}
		if strings.HasPrefix(e.key, "input") {
			set = append(set, evoHint{key: "P", desc: " 48V"})
		}
	}
	return nav, set
}

func (r *evoRender) mixerHelp() ([]evoHint, []evoHint) {
	sections := r.u.flatMx()
	param := ""
	if r.u.mxSection < len(sections) {
		ps := sections[r.u.mxSection].params
		if r.u.mxParam < len(ps) {
			param = ps[r.u.mxParam]
		}
	}
	step, big := "1", "5"
	if param != "volume" {
		step, big = "5", "25"
	}
	nav := []evoHint{
		{key: "hjkl", desc: " " + evoArrows},
		{key: "Space", desc: " next"},
		{key: evoTabSym, desc: " tab"},
	}
	set := []evoHint{
		{key: "[]", desc: " " + evoPM + step},
		{key: "{}", desc: " " + evoPM + big},
		{key: "0-9", desc: " dial"},
	}
	if r.spec.NumOutPairs > 1 {
		set = append(set, evoHint{key: "m", desc: " mix", col: cCyan})
	}
	return nav, set
}

func (r *evoRender) drawHelpFooter(row, cx int, nav, set []evoHint) int {
	r.drawHints(row, cx+1, nav, evoDim)
	r.drawHints(row+1, cx+1, set, evoDim)
	return row + 2
}

func evoControlsBodyH(spec drivers.Spec) int {
	groups := evoGroups(spec)
	if len(groups) > 1 {
		h := 0
		for _, g := range groups {
			n := len(g.elements)
			if v := n*4 + (n - 1); v > h {
				h = v
			}
		}
		return h + 1
	}
	n := len(groups[0].elements)
	return n*4 + (n - 1)
}

func (m model) evoConfigDir() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "audient-evo-py", m.status.Spec.ID)
}

func (m model) evoScanFiles() []string {
	entries, err := os.ReadDir(m.evoConfigDir())
	if err != nil {
		return nil
	}
	var out []string
	for _, e := range entries {
		n := e.Name()
		if e.IsDir() || strings.HasPrefix(n, ".") || !strings.HasSuffix(n, ".json") {
			continue
		}
		out = append(out, n)
	}
	sort.Strings(out)
	return out
}

// evoView renders the EVO screens with evotui's exact frame.
func (m model) evoView() string {
	w, h := m.contentSize()
	pal := evoPalette()
	if m.evo.mode != 0 {
		return m.evoFilePicker(w, h, pal)
	}
	spec := m.status.Spec
	rows := evoMixerRows(spec)
	maxRowLen := len(rows[0])
	if len(rows[1]) > maxRowLen {
		maxRowLen = len(rows[1])
	}
	siw, _ := evoSecDim(spec)
	mixerW := maxRowLen*(siw+3) - 1
	cx := (w - mixerW) / 2
	if cx < 0 {
		cx = 0
	}
	totalH := evoControlsTop + evoControlsBodyH(spec) + evoControlsTail
	c := newEvoCanvas(w, h)
	if h < totalH || w < mixerW {
		msg := fmt.Sprintf("Terminal too small (%dx%d, need %dx%d)", w, h, mixerW, totalH)
		c.put(0, 0, msg, evoVal)
		return c.render(pal)
	}
	row := (h - totalH) / 2
	if row < 0 {
		row = 0
	}
	r := &evoRender{c: c, m: m, u: &m.evo, spec: spec}
	r.drawTabBar(row, cx, mixerW)
	row += 3
	var nav, set []evoHint
	if m.evo.window == 0 {
		row = r.drawControlsBody(row, cx, mixerW)
		nav, set = r.controlsHelp()
	} else {
		row = r.drawMixerBody(row, cx)
		nav, set = r.mixerHelp()
	}
	row = r.drawStatusBar(row, cx, mixerW)
	r.drawHelpFooter(row+1, cx, nav, set)
	return c.render(pal)
}

func (m model) evoFilePicker(w, h int, pal [7]lipgloss.Color) string {
	c := newEvoCanvas(w, h)
	u := &m.evo
	boxW := evoBoxIW + 2
	cx := (w - boxW) / 2
	if cx < 0 {
		cx = 0
	}
	action := "SAVE"
	if u.mode == 2 {
		action = "LOAD"
	}
	totalH := evoPickerListH + 3
	if u.mode == 1 {
		totalH++
	}
	row := (h - totalH) / 2
	if row < 0 {
		row = 0
	}
	dim := evoDim
	pathStr := m.evoConfigDir() + "/"
	maxPath := evoBoxIW - len([]rune(action)) - 5
	if maxPath < 4 {
		maxPath = 4
	}
	if len([]rune(pathStr)) > maxPath {
		rr := []rune(pathStr)
		pathStr = "…" + string(rr[len(rr)-(maxPath-1):])
	}
	title := action + " " + pathStr
	titleDashes := evoBoxIW - len([]rune(title)) - 3
	if titleDashes < 0 {
		titleDashes = 0
	}
	c.put(cx, row, string(boxTL)+string(boxH)+" ", dim)
	c.put(cx+3, row, title, dim)
	c.put(cx+3+len([]rune(title)), row, " "+strings.Repeat(string(boxH), titleDashes)+string(boxTR), dim)
	row++
	r := &evoRender{c: c, m: m, u: u, spec: m.status.Spec, boxAttr: dim}
	r.boxSide(row, cx, evoBoxIW)
	row++
	for i := 0; i < evoPickerListH; i++ {
		r.boxSide(row, cx, evoBoxIW)
		abs := u.fileScroll + i
		if len(u.fileList) == 0 && i == 0 {
			c.put(cx+evoSliderOff, row, "(no configs found)", dim)
		} else if abs < len(u.fileList) {
			f := u.fileList[abs]
			sel := abs == u.fileCursor
			pre := "  "
			if sel {
				pre = string(arrowR) + " "
			}
			attr := evoDim
			if sel {
				attr = evoBold
			}
			text := pre + f
			if rr := []rune(text); len(rr) > evoBoxIW-2 {
				text = string(rr[:evoBoxIW-2])
			}
			c.put(cx+evoSliderOff, row, text, attr)
		}
		row++
	}
	if u.mode == 1 {
		r.boxSide(row, cx, evoBoxIW)
		fileX := cx + evoSliderOff
		c.put(fileX, row, "File: ", dim)
		fileX += 6
		c.put(fileX, row, u.fileInput, evoBold)
		fileX += len([]rune(u.fileInput))
		c.put(fileX, row, ".json", dim)
		row++
	}
	act := "save"
	if u.mode == 2 {
		act = "load"
	}
	hints := []evoHint{
		{key: "Tab", desc: " " + string(arrowD) + string(arrowU)},
		{key: "↵", desc: " " + act},
		{key: "Esc", desc: " cancel"},
	}
	contentW := len([]rune(evoHsep)) * (len(hints) - 1)
	for _, hh := range hints {
		contentW += len([]rune(hh.key)) + len([]rune(hh.desc))
	}
	botDashes := evoBoxIW - (1 + contentW + 2)
	if botDashes < 0 {
		botDashes = 0
	}
	c.put(cx, row, string(boxBL)+strings.Repeat(string(boxH), botDashes), dim)
	col := cx + 1 + botDashes + 1
	col = r.drawHints(row, col, hints, dim)
	c.put(col, row, " "+string(boxH), dim)
	c.put(cx+evoBoxIW+1, row, string(boxBR), dim)
	return c.render(pal)
}

// --- keys -------------------------------------------------------------------

func (u *evoUI) setStatus(msg string, err bool) {
	u.statusMsg, u.statusErr = msg, err
	u.statusGen++
}

// evoStatusExpireMsg clears an EVO status line once its timer fires. The TUI's
// View runs on a model copy, so the status cannot be aged out at draw time the
// way evotui's curses loop does; a tick carries the expiry instead.
type evoStatusExpireMsg struct{ gen int }

func evoStatusTick(gen int) tea.Cmd {
	return tea.Tick(3*time.Second, func(time.Time) tea.Msg { return evoStatusExpireMsg{gen: gen} })
}

// evoStatus sets a status line and returns the cmd that will expire it.
func (u *evoUI) evoStatus(msg string, err bool) tea.Cmd {
	u.setStatus(msg, err)
	return evoStatusTick(u.statusGen)
}

// isEvoDevice reports whether the selected interface is an Audient EVO
// (EVO 4 / EVO 8). Those screens are drawn by the faithful evotui port in
// this file instead of the tui-kit picker.
func (m model) isEvoDevice() bool {
	return m.deviceID == drivers.DevEVO8 || m.deviceID == drivers.DevEVO4
}

func (m *model) evoEnter() {
	if !m.isEvoDevice() {
		return
	}
	m.evo.spec = m.status.Spec
	m.evo.window = 0
	m.evo.sub = 0
	m.evo.cursor = 0
	m.evo.mxSection = 0
	m.evo.mxParam = 1
	m.evo.mixBus = 0
	m.evo.numBuf = ""
	m.evo.mode = 0
}

func (m *model) evoKey(k string) tea.Cmd {
	u := &m.evo
	if u.mode != 0 {
		return m.evoPickerKey(k)
	}
	switch k {
	case "q":
		m.confirm = tuikit.NewConfirm("Quit mosquito-mixbay?", "No", "Yes")
		m.confirmAct = func() tea.Cmd {
			m.quit = true
			return tea.Quit
		}
		m.push(scrConfirm)
		return nil
	case "esc":
		if u.numBuf != "" {
			u.numBuf = ""
			return nil
		}
		if u.statusMsg != "" {
			u.statusMsg = ""
			return nil
		}
		m.pop()
		return fetchStatus(m.deviceID)
	case "s":
		u.mode, u.fileInput = 1, "config"
		u.fileList = m.evoScanFiles()
		u.fileCursor, u.fileScroll = 0, 0
		return nil
	case "o":
		files := m.evoScanFiles()
		if len(files) == 0 {
			return m.evo.evoStatus("No configs in "+m.evoConfigDir(), true)
		}
		u.mode, u.fileList, u.fileCursor, u.fileScroll = 2, files, 0, 0
		return nil
	case "tab":
		if u.window == 0 {
			u.window = 1
			m.push(scrMixer)
		} else {
			u.window = 0
			m.pop()
		}
		u.numBuf = ""
		return nil
	case "backspace":
		if u.numBuf != "" {
			u.numBuf = u.numBuf[:len(u.numBuf)-1]
		}
		return nil
	case "enter":
		if u.numBuf == "" {
			return nil
		}
		v, err := strconv.ParseFloat(u.numBuf, 64)
		u.numBuf = ""
		if err != nil {
			return nil
		}
		if u.window == 0 {
			return m.evoSetVal(v)
		}
		return m.evoMxSetVal(v)
	}
	if len(k) == 1 {
		c := k[0]
		if c == '-' && u.numBuf == "" {
			u.numBuf = "-"
			return nil
		}
		if c == '.' && !strings.Contains(u.numBuf, ".") && len(u.numBuf) < 8 {
			u.numBuf += "."
			return nil
		}
		if c >= '0' && c <= '9' && len(u.numBuf) < 8 {
			u.numBuf += k
			return nil
		}
	}
	if u.window == 0 {
		return m.evoControlsKey(k)
	}
	return m.evoMixerKey(k)
}

func (m *model) evoControlsKey(k string) tea.Cmd {
	els := m.evo.activeElements()
	ngroups := len(evoGroups(m.evo.spec))
	switch k {
	case "j", "J", "down":
		m.evo.cursor = (m.evo.cursor + 1) % len(els)
	case "k", "K", "up":
		m.evo.cursor = (m.evo.cursor - 1 + len(els)) % len(els)
	case "l", "L", "right":
		if ngroups > 1 {
			m.evo.sub = (m.evo.sub + 1) % ngroups
			m.evo.cursor = 0
		}
	case "h", "H", "left":
		if ngroups > 1 {
			m.evo.sub = (m.evo.sub - 1 + ngroups) % ngroups
			m.evo.cursor = 0
		}
	case "m":
		return m.evoToggleMute()
	case "P":
		return m.evoTogglePhantom()
	case "]":
		return m.evoAdjust(1)
	case "[":
		return m.evoAdjust(-1)
	case "}":
		return m.evoAdjust(5)
	case "{":
		return m.evoAdjust(-5)
	}
	return nil
}

func (m *model) evoAdjust(delta float64) tea.Cmd {
	els := m.evo.activeElements()
	if m.evo.cursor >= len(els) {
		return nil
	}
	e := els[m.evo.cursor]
	_, _, step := m.evoElemRange(e)
	return m.evoSetVal(m.evoElemValue(e) + delta*step)
}

func (m *model) evoSetVal(val float64) tea.Cmd {
	els := m.evo.activeElements()
	if m.evo.cursor >= len(els) {
		return nil
	}
	e := els[m.evo.cursor]
	lo, hi, _ := m.evoElemRange(e)
	val = clampf(val, lo, hi)
	dev := m.deviceID
	switch {
	case e.key == "monitor":
		return applyCmd(dev, func(d drivers.Driver) error { return d.SetMonitor(int(math.Round(val))) }, "")
	case e.key == "output":
		return applyCmd(dev, func(d drivers.Driver) error { return d.SetVolume(0, val) }, "")
	case strings.HasPrefix(e.key, "output"):
		var n int
		fmt.Sscanf(e.key, "output%d", &n)
		return applyCmd(dev, func(d drivers.Driver) error { return d.SetVolume(n-1, val) }, "")
	case strings.HasPrefix(e.key, "input"):
		var n int
		fmt.Sscanf(e.key, "input%d", &n)
		return applyCmd(dev, func(d drivers.Driver) error { return d.SetGain(n, val) }, "")
	}
	return nil
}

func (m *model) evoToggleMute() tea.Cmd {
	els := m.evo.activeElements()
	if m.evo.cursor >= len(els) {
		return nil
	}
	e := els[m.evo.cursor]
	if e.key == "monitor" {
		return nil
	}
	on := !m.evoElemMuted(e)
	return applyCmd(m.deviceID, func(d drivers.Driver) error { return d.SetMute(e.key, on) }, "")
}

func (m *model) evoTogglePhantom() tea.Cmd {
	els := m.evo.activeElements()
	if m.evo.cursor >= len(els) {
		return nil
	}
	e := els[m.evo.cursor]
	if !strings.HasPrefix(e.key, "input") {
		return nil
	}
	var n int
	fmt.Sscanf(e.key, "input%d", &n)
	on := !m.evoElemPhantom(e)
	return applyCmd(m.deviceID, func(d drivers.Driver) error { return d.SetPhantom(n, on) }, "")
}

func evoColOffset(row int, rows [][]evoMxSection) int {
	off := 0
	for r := 0; r < row; r++ {
		off += len(rows[r])
	}
	return off
}

func (m *model) evoMxRowCol() (int, int) {
	idx := m.evo.mxSection
	rows := evoMixerRows(m.evo.spec)
	for r, row := range rows {
		if idx < len(row) {
			return r, idx
		}
		idx -= len(row)
	}
	return 0, 0
}

func (m *model) evoSelectMx(idx int) {
	sections := m.evo.flatMx()
	if idx < 0 || idx >= len(sections) {
		return
	}
	m.evo.mxSection = idx
	m.evo.mxParam = len(sections[idx].params) - 1
}

func (m *model) evoMixerKey(k string) tea.Cmd {
	rows := evoMixerRows(m.evo.spec)
	r, c := m.evoMxRowCol()
	sections := m.evo.flatMx()
	if m.evo.mxSection >= len(sections) {
		return nil
	}
	nparams := len(sections[m.evo.mxSection].params)
	switch k {
	case "l", "L", "right":
		if c+1 < len(rows[r]) {
			m.evoSelectMx(evoColOffset(r, rows) + c + 1)
		} else {
			m.evoSelectMx(evoColOffset(r, rows))
		}
	case "h", "H", "left":
		if c > 0 {
			m.evoSelectMx(evoColOffset(r, rows) + c - 1)
		} else {
			m.evoSelectMx(evoColOffset(r, rows) + len(rows[r]) - 1)
		}
	case "j", "J", "down":
		if len(rows) > 1 {
			nr := (r + 1) % len(rows)
			cc := c
			if cc >= len(rows[nr]) {
				cc = len(rows[nr]) - 1
			}
			m.evoSelectMx(evoColOffset(nr, rows) + cc)
		}
	case "k", "K", "up":
		if len(rows) > 1 {
			nr := (r - 1 + len(rows)) % len(rows)
			cc := c
			if cc >= len(rows[nr]) {
				cc = len(rows[nr]) - 1
			}
			m.evoSelectMx(evoColOffset(nr, rows) + cc)
		}
	case "m":
		if m.evo.spec.NumOutPairs > 1 {
			m.evo.mixBus = (m.evo.mixBus + 1) % m.evo.spec.NumOutPairs
		}
	case " ":
		m.evo.mxParam = (m.evo.mxParam + 1) % nparams
	case "]":
		return m.evoMxAdjust(1)
	case "[":
		return m.evoMxAdjust(-1)
	case "}":
		return m.evoMxAdjust(5)
	case "{":
		return m.evoMxAdjust(-5)
	}
	return nil
}

func evoMxStep(param string) float64 {
	if param == "volume" {
		return 1
	}
	return evoPanStep
}

func (m *model) evoMxAdjust(delta float64) tea.Cmd {
	sections := m.evo.flatMx()
	if m.evo.mxSection >= len(sections) {
		return nil
	}
	s := sections[m.evo.mxSection]
	if m.evo.mxParam >= len(s.params) {
		return nil
	}
	param := s.params[m.evo.mxParam]
	return m.evoMxSetValTo(s.key, param, m.evoMxCell(s.key, param)+delta*evoMxStep(param))
}

func (m *model) evoMxSetVal(v float64) tea.Cmd {
	sections := m.evo.flatMx()
	if m.evo.mxSection >= len(sections) {
		return nil
	}
	s := sections[m.evo.mxSection]
	if m.evo.mxParam >= len(s.params) {
		return nil
	}
	return m.evoMxSetValTo(s.key, s.params[m.evo.mxParam], v)
}

func (m *model) evoMxSetValTo(key, param string, val float64) tea.Cmd {
	c := m.status.Mixer[drivers.MixerKey(key, m.evo.mixBus)]
	vol, pan, panL, panR := c.VolumeDb, c.Pan, c.PanL, c.PanR
	switch param {
	case "volume":
		vol = clampf(val, evoMixDbMin, evoMixDbMax)
	case "pan":
		pan = clampf(val, evoPanMin, evoPanMax)
	case "pan_l":
		panL = clampf(val, evoPanMin, evoPanMax)
	case "pan_r":
		panR = clampf(val, evoPanMin, evoPanMax)
	}
	dev := m.deviceID
	bus := m.evo.mixBus
	var n int
	if _, err := fmt.Sscanf(key, "input%d", &n); err == nil {
		return applyCmd(dev, func(d drivers.Driver) error { return d.SetMixerInput(n, vol, pan, bus) }, "")
	}
	var l, rr int
	if _, err := fmt.Sscanf(key, "output%d_%d", &l, &rr); err == nil {
		return applyCmd(dev, func(d drivers.Driver) error { return d.SetMixerOutput((l-1)/2, vol, panL, panR, bus) }, "")
	}
	return nil
}

func (u *evoUI) pickerMove(delta int, wrap bool) {
	n := len(u.fileList)
	if n == 0 {
		return
	}
	if wrap {
		u.fileCursor = (u.fileCursor + delta + n) % n
	} else {
		u.fileCursor += delta
		if u.fileCursor < 0 {
			u.fileCursor = 0
		}
		if u.fileCursor > n-1 {
			u.fileCursor = n - 1
		}
	}
	if u.fileCursor < u.fileScroll {
		u.fileScroll = u.fileCursor
	} else if u.fileCursor >= u.fileScroll+evoPickerListH {
		u.fileScroll = u.fileCursor - evoPickerListH + 1
	}
}

func (m *model) evoPickerKey(k string) tea.Cmd {
	u := &m.evo
	moved := false
	switch k {
	case "esc":
		u.mode = 0
		return nil
	case "up":
		u.pickerMove(-1, false)
		moved = true
	case "down":
		u.pickerMove(1, false)
		moved = true
	case "shift+tab":
		u.pickerMove(-1, true)
		moved = true
	case "tab":
		u.pickerMove(1, true)
		moved = true
	case "enter":
		if u.mode == 2 {
			if len(u.fileList) > 0 && u.fileCursor < len(u.fileList) {
				path := filepath.Join(m.evoConfigDir(), u.fileList[u.fileCursor])
				u.mode = 0
				return tea.Batch(
					m.evo.evoStatus("loading "+u.fileList[u.fileCursor], false),
					m.evoLoadFrom(path),
				)
			}
			u.mode = 0
			return nil
		}
		name := strings.TrimSpace(u.fileInput)
		u.mode = 0
		if name != "" {
			return m.evoSaveTo(filepath.Join(m.evoConfigDir(), name+".json"))
		}
		return nil
	case "backspace":
		if u.mode == 1 && len(u.fileInput) > 0 {
			u.fileInput = u.fileInput[:len(u.fileInput)-1]
		}
	default:
		if u.mode == 1 && len(k) == 1 {
			c := k[0]
			if c >= 32 && c <= 126 {
				maxLen := evoBoxIW - len("File: ") - len(".json") - 1
				if len(u.fileInput) < maxLen {
					u.fileInput += k
				}
			}
		}
	}
	if moved && u.mode == 1 && len(u.fileList) > 0 && u.fileCursor < len(u.fileList) {
		u.fileInput = strings.TrimSuffix(u.fileList[u.fileCursor], ".json")
	}
	return nil
}

func (m *model) evoSaveTo(path string) tea.Cmd {
	dev := m.deviceID
	return applyCmd(dev, func(d drivers.Driver) error {
		if s, ok := d.(interface{ SaveTo(string) error }); ok {
			return s.SaveTo(path)
		}
		return d.Save()
	}, "saved "+filepath.Base(path))
}

func (m *model) evoLoadFrom(path string) tea.Cmd {
	dev := m.deviceID
	return applyCmd(dev, func(d drivers.Driver) error {
		if l, ok := d.(interface{ LoadFrom(string) error }); ok {
			return l.LoadFrom(path)
		}
		return d.Load()
	}, "")
}
