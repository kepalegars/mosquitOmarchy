package main

import (
	"fmt"
	"math"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"mosquitomarchy.local/mosquitomixbay-tui/drivers"
	"mosquitomarchy.local/mosquitomixbay-tui/meters"
)

// The EVO 8's USB names are stable: 6 capture channels (IN 1-4 + LOOP 5|6)
// and 6 playback monitor channels (PC 1|2, PC 3|4, LOOP). Never point the
// playback meter at the analog OUT controls: the USB monitor is the only
// signal PipeWire can observe.
const (
	evo8OutNode = "alsa_output.usb-Audient_EVO8-00.pro-output-0"
	evo8InNode  = "alsa_input.usb-Audient_EVO8-00.pro-input-0"
)

type meterStartedMsg struct{ engine *meters.Engine }
type meterSnapshotMsg struct {
	engine *meters.Engine
	snap   meters.Snapshot
}
type meterClosedMsg struct{ engine *meters.Engine }

func meterSources() []meters.Source {
	return []meters.Source{
		{Key: meters.KeyPlayback, Node: evo8OutNode, Channels: 6, Monitor: true},
		{Key: meters.KeyInput, Node: evo8InNode, Channels: 6},
	}
}

func startMetersCmd() tea.Cmd {
	return func() tea.Msg { return meterStartedMsg{engine: meters.Start(meterSources())} }
}

func waitMetersCmd(e *meters.Engine) tea.Cmd {
	return func() tea.Msg {
		snap, ok := <-e.Updates()
		if !ok {
			return meterClosedMsg{engine: e}
		}
		return meterSnapshotMsg{engine: e, snap: snap}
	}
}

func (m model) wantsMeters() bool {
	if m.quit || !m.session.live || !m.status.Online {
		return false
	}
	if !m.isEvoDevice() || m.evo.spec.ID != drivers.DevEVO8 {
		return false
	}
	switch m.top() {
	case scrControls, scrMixer:
		return true
	}
	return false
}

func (m *model) syncMeters() tea.Cmd {
	if !m.wantsMeters() {
		if m.meter != nil {
			m.meter.Stop()
			m.meter = nil
		}
		return nil
	}
	if m.meter == nil && !m.meterStarting {
		m.meterStarting = true
		return startMetersCmd()
	}
	return nil
}

func (m model) meterLevels(key string) []float64 {
	if key == meters.KeyInput {
		return m.meterSnap.Input
	}
	return m.meterSnap.Playback
}

func (m model) meterLevel(key string, ch int) float64 {
	v := m.meterLevels(key)
	if ch >= 0 && ch < len(v) {
		return v[ch]
	}
	return 0
}

func (m model) meterPeak(key string, ch int) float64 {
	var arr *[6]float64
	if key == meters.KeyInput {
		arr = &m.meterPeakIn
	} else {
		arr = &m.meterPeakOut
	}
	if arr == nil || ch < 0 || ch >= len(arr) {
		return 0
	}
	return arr[ch]
}

// evoLevelsKey owns the Levels tab so Tab/Esc can leave it and the mixer's
// number-entry state can never leak into a meter-only screen.
func (m *model) evoLevelsKey(k string) tea.Cmd {
	switch k {
	case "tab", "esc":
		m.evo.window = evoWinControls
		if m.top() == scrMixer {
			m.pop()
		}
		m.evo.numBuf = ""
		return nil
	case "p":
		m.meterFrozen = !m.meterFrozen
		return nil
	case " ":
		m.meterPeakIn, m.meterPeakOut = [6]float64{}, [6]float64{}
		if m.meter != nil {
			m.meter.ResetPeaks()
		}
		return nil
	case "q":
		return m.evoQuitConfirm()
	}
	return nil
}

func meterDB(level float64) float64 {
	if level <= 1e-5 {
		return -60
	}
	db := 20 * math.Log10(level)
	if db < -60 {
		db = -60
	}
	if db > 0 {
		db = 0
	}
	return db
}

func meterDBShort(level float64) string {
	if level <= 1e-5 {
		return " -∞"
	}
	db := meterDB(level)
	if db > -0.5 {
		db = 0
	}
	return fmt.Sprintf("%3.0f", db)
}

func meterFraction(level float64) float64 {
	return clampf((meterDB(level)+60)/60, 0, 1)
}

func meterColor(db float64) int {
	switch {
	case db >= -3:
		return cRed
	case db >= -12:
		return cYellow
	default:
		return cGreen
	}
}

type evoMeterBar struct {
	label string
	key   string
	ch    int
}

var evoCaptureBars = []evoMeterBar{
	{label: "IN1", key: meters.KeyInput, ch: 0},
	{label: "IN2", key: meters.KeyInput, ch: 1},
	{label: "IN3", key: meters.KeyInput, ch: 2},
	{label: "IN4", key: meters.KeyInput, ch: 3},
	{label: "LP5", key: meters.KeyInput, ch: 4},
	{label: "LP6", key: meters.KeyInput, ch: 5},
}

var evoPlaybackBars = []evoMeterBar{
	{label: "PC1", key: meters.KeyPlayback, ch: 0},
	{label: "PC2", key: meters.KeyPlayback, ch: 1},
	{label: "PC3", key: meters.KeyPlayback, ch: 2},
	{label: "PC4", key: meters.KeyPlayback, ch: 3},
	{label: "LP5", key: meters.KeyPlayback, ch: 4},
	{label: "LP6", key: meters.KeyPlayback, ch: 5},
}

func (m model) meterStatus() (string, int) {
	if !m.isEvoDevice() || m.evo.spec.ID != drivers.DevEVO8 {
		return "Meters need the live EVO 8 USB streams.", cYellow
	}
	if !m.session.live || !m.status.Online {
		return "EVO 8 is offline — reconnect to meter.", cYellow
	}
	if m.meterStarting && m.meter == nil {
		return "Starting USB capture…", cNone
	}
	if len(m.meterSnap.Errors) > 0 {
		return strings.Join(m.meterSnap.Errors, " · "), cRed
	}
	if m.meterFrozen {
		return "meters frozen", cAccent
	}
	return "", cNone
}

func (r *evoRender) levelsHelp() ([]evoHint, []evoHint) {
	return []evoHint{
		{key: evoTabSym, desc: " view"},
		{key: "Esc", desc: " controls"},
		{key: "Space", desc: " reset peaks"},
		{key: "p", desc: " freeze"},
		{key: "q", desc: " quit"},
	}, nil
}

func (r *evoRender) drawLevelsBody(row, cx, sectionW int) int {
	const (
		barW     = 4
		gap      = 1
		groupW   = 6*barW + 5*gap
		scaleW   = 7
		groupGap = 3
		totalW   = scaleW + groupW*2 + groupGap
	)
	bodyRow := row
	x := cx + (sectionW-totalW)/2
	if x < cx {
		x = cx
	}
	captureX := x + scaleW
	playbackX := captureX + groupW + groupGap

	title := "USB DIGITAL METERS"
	r.put(x+totalW-len([]rune(title)), row, title, evoDim)
	row++
	r.put(captureX+(groupW-len([]rune("CAPTURE")))/2, row, "CAPTURE", evoStyle{col: cAccent, bold: true})
	r.put(playbackX+(groupW-len([]rune("PLAYBACK")))/2, row, "PLAYBACK", evoStyle{col: cAccent, bold: true})
	row++
	readoutRow := row
	row++
	barTop := row
	const barRows = 18
	barBot := barTop + barRows - 1

	for y := barTop; y <= barBot; y++ {
		r.put(x+5, y, "│", evoVal)
	}
	for _, db := range []float64{-60, -40, -20, -12, -6, 0} {
		y := barBot - int(math.Round((db+60)/60*float64(barRows-1)))
		if y < barTop {
			y = barTop
		}
		if y > barBot {
			y = barBot
		}
		label := fmt.Sprintf("%g", db)
		if db == 0 {
			label = "0"
		}
		r.put(x, y, fmt.Sprintf("%4s", label), evoVal)
		r.put(x+5, y, "┤", evoVal)
	}

	draw := func(bars []evoMeterBar, groupX int) {
		for i, b := range bars {
			bx := groupX + i*(barW+gap)
			level := r.m.meterLevel(b.key, b.ch)
			peak := r.m.meterPeak(b.key, b.ch)
			attr := evoDim
			if level > 1e-5 {
				attr = evoStyle{col: meterColor(meterDB(level))}
			}
			r.put(bx+(barW-len([]rune(b.label))+1)/2, readoutRow, meterDBShort(level), attr)
			r.drawVerticalBar(bx, barTop, barBot, barW, level, peak)
			r.put(bx+(barW-len([]rune(b.label))+1)/2, barBot+1, b.label, evoDim)
		}
	}
	draw(evoCaptureBars, captureX)
	draw(evoPlaybackBars, playbackX)

	return bodyRow + evoControlsBodyH(r.spec)
}

func (r *evoRender) drawVerticalBar(x, top, bot, width int, level, peak float64) {
	rows := bot - top + 1
	full := int(math.Round(float64(rows) * meterFraction(level)))
	fillTop := bot - full + 1
	peakPos := int(math.Round(float64(rows) * meterFraction(peak)))
	peakRow := bot - peakPos + 1
	for y := top; y <= bot; y++ {
		for col := 0; col < width; col++ {
			if y >= fillTop {
				db := -60 + 60*float64(bot-y+1)/float64(rows)
				r.c.put(x+col, y, "█", evoStyle{col: meterColor(db)})
			} else {
				r.c.put(x+col, y, "░", evoStyle{col: cBorder, dim: true})
			}
		}
	}
	if peakPos > 0 {
		st := evoStyle{col: cWhite}
		if peakRow >= fillTop {
			db := -60 + 60*float64(bot-peakRow+1)/float64(rows)
			st.bg = meterColor(db)
		}
		for col := 0; col < width; col++ {
			r.c.put(x+col, peakRow, "─", st)
		}
	}
}

func (r *evoRender) drawLevelsStatusBar(row, cx, sectionW int) int {
	if msg, col := r.m.meterStatus(); msg != "" {
		attr := evoDim
		if col != cNone {
			attr = evoStyle{col: col}
		}
		r.put(cx+evoSliderOff, row, msg, attr)
	}
	row++
	lineAttr := evoStyle{col: cAccent}
	r.c.repeat(cx, row, sectionW-1, boxH, lineAttr)
	r.put(cx+sectionW-1, row, string(boxH), lineAttr)
	return row + 1
}

// evoMeterChannels maps a control/mixer row key to the USB capture channels
// that feed it. Playback pairs are the monitor of the USB output; inputs are
// the hardware capture channels.
func evoMeterChannels(key string) (string, []int) {
	if strings.HasPrefix(key, "input") {
		var n int
		if _, err := fmt.Sscanf(key, "input%d", &n); err == nil && n >= 1 && n <= 6 {
			return meters.KeyInput, []int{n - 1}
		}
		return "", nil
	}
	if strings.HasPrefix(key, "output") {
		var l, r int
		if _, err := fmt.Sscanf(key, "output%d_%d", &l, &r); err == nil && l >= 1 && r == l+1 {
			pair := (l - 1) / 2
			return meters.KeyPlayback, []int{pair * 2, pair*2 + 1}
		}
		var n int
		if key == "output" {
			return meters.KeyPlayback, []int{0, 1}
		}
		if _, err := fmt.Sscanf(key, "output%d", &n); err == nil && n >= 1 {
			return meters.KeyPlayback, []int{(n - 1) * 2, (n-1)*2 + 1}
		}
	}
	return "", nil
}

func (r *evoRender) drawMiniBar(row, x, width int, level, peak float64, col int) {
	if width < 1 {
		return
	}
	full := int(math.Round(float64(width) * meterFraction(level)))
	peakPos := int(math.Round(float64(width) * meterFraction(peak)))
	fill := evoStyle{col: col}
	empty := evoStyle{col: cBorder, dim: true}
	mark := evoStyle{col: cWhite, bold: true}
	for i := 0; i < width; i++ {
		switch {
		case i < full:
			r.c.put(x+i, row, "▮", fill)
		case i == peakPos && peakPos >= full:
			r.c.put(x+i, row, "│", mark)
		default:
			r.c.put(x+i, row, "▯", empty)
		}
	}
}

func (r *evoRender) drawKeyMeter(row, x, width int, key string, col int) {
	src, chans := evoMeterChannels(key)
	if src == "" || len(chans) == 0 || width < 4 {
		if key == "monitor" {
			r.put(x, row, "no USB meter", evoDim)
		}
		return
	}
	if len(chans) == 2 {
		const label = "USB "
		r.put(x, row, label, evoDim)
		x += len([]rune(label))
		avail := width - len([]rune(label)) - 1
		bw := avail / 2
		r.drawMiniBar(row, x, bw, r.m.meterLevel(src, chans[0]), r.m.meterPeak(src, chans[0]), col)
		x += bw
		r.put(x, row, " ", evoDim)
		x++
		r.drawMiniBar(row, x, avail-bw, r.m.meterLevel(src, chans[1]), r.m.meterPeak(src, chans[1]), col)
		return
	}
	r.drawMiniBar(row, x, width, r.m.meterLevel(src, chans[0]), r.m.meterPeak(src, chans[0]), col)
}
