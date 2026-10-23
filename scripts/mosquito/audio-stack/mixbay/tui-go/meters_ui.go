package main

import (
	"fmt"
	"math"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"mosquitomarchy.local/mosquitomixbay-tui/drivers"
	"mosquitomarchy.local/mosquitomixbay-tui/meters"
	tuikit "mosquitomarchy.local/tui-kit"
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
	if !m.focused || m.quit || !m.session.live || !m.status.Online {
		return false
	}
	if !m.isEvoDevice() || m.evo.spec.ID != drivers.DevEVO8 {
		return false
	}
	switch m.top() {
	case scrControls, scrMixer, scrLevels:
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

func (m model) levelsKey(k string) tea.Cmd {
	switch k {
	case "esc", "v":
		m.pop()
		return nil
	case "p":
		m.meterFrozen = !m.meterFrozen
		return nil
	case " ":
		m.meterPeakIn, m.meterPeakOut = [6]float64{}, [6]float64{}
		return nil
	case "q":
		m.confirm = tuikit.NewConfirm("Quit mosquito-mixbay?", "No", "Yes")
		m.confirmAct = func() tea.Cmd {
			m.quit = true
			return tea.Quit
		}
		m.push(scrConfirm)
		return nil
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

func meterDBString(level float64) string {
	if level <= 1e-5 {
		return "  -inf"
	}
	return fmt.Sprintf("%6.1f", meterDB(level))
}

func meterFraction(level float64) float64 {
	return clampf((meterDB(level)+60)/60, 0, 1)
}

func meterColor(db float64) lipgloss.Color {
	switch {
	case db >= -3:
		return tuikit.ColorRed
	case db >= -12:
		return tuikit.ColorYellow
	default:
		return tuikit.ColorGreen
	}
}

func meterBarStyled(level, peak float64, width int) string {
	if width < 1 {
		return ""
	}
	full := int(math.Round(float64(width) * meterFraction(level)))
	peakPos := int(math.Round(float64(width) * meterFraction(peak)))
	fill := lipgloss.NewStyle().Foreground(meterColor(meterDB(level)))
	empty := lipgloss.NewStyle().Foreground(tuikit.ColorBorder)
	mark := lipgloss.NewStyle().Foreground(tuikit.ColorOnSurface).Bold(true)
	var b strings.Builder
	for i := 0; i < width; i++ {
		switch {
		case i < full:
			b.WriteString(fill.Render("▮"))
		case i == peakPos && peakPos >= full:
			b.WriteString(mark.Render("│"))
		default:
			b.WriteString(empty.Render("▯"))
		}
	}
	return b.String()
}

func padStyled(s string, width int) string {
	if w := lipgloss.Width(s); w < width {
		return s + strings.Repeat(" ", width-w)
	}
	return s
}

func meterLabel(label string, width int) string {
	label = tuikit.TruncateLine(label, width)
	return padStyled(tuikit.StyleMuted.Render(label), width)
}

type meterRowDef struct {
	label  string
	chans  []int
	stereo bool
}

var inputMeterRows = []meterRowDef{
	{label: "IN 1", chans: []int{0}},
	{label: "IN 2", chans: []int{1}},
	{label: "IN 3", chans: []int{2}},
	{label: "IN 4", chans: []int{3}},
	{label: "LOOP 5|6", chans: []int{4, 5}, stereo: true},
}

var playbackMeterRows = []meterRowDef{
	{label: "PC 1|2", chans: []int{0, 1}, stereo: true},
	{label: "PC 3|4", chans: []int{2, 3}, stereo: true},
	{label: "LOOP", chans: []int{4, 5}, stereo: true},
}

func (m model) meterRows(key string, defs []meterRowDef, labelW, barW int) []string {
	out := make([]string, 0, len(defs))
	for _, d := range defs {
		levels := m.meterLevels(key)
		if len(levels) == 0 {
			levels = make([]float64, 6)
		}
		maxLvl, maxPeak := 0.0, 0.0
		for _, ch := range d.chans {
			if ch < len(levels) && levels[ch] > maxLvl {
				maxLvl = levels[ch]
			}
			if p := m.meterPeak(key, ch); p > maxPeak {
				maxPeak = p
			}
		}
		var bars string
		if d.stereo && len(d.chans) > 1 {
			bw := (barW - 1) / 2
			bars = meterBarStyled(m.meterLevel(key, d.chans[0]), m.meterPeak(key, d.chans[0]), bw) +
				" " + meterBarStyled(m.meterLevel(key, d.chans[1]), m.meterPeak(key, d.chans[1]), barW-bw-1)
		} else {
			bars = meterBarStyled(maxLvl, maxPeak, barW)
		}
		out = append(out, meterLabel(d.label, labelW)+" "+bars+" "+tuikit.StyleHelp.Render(meterDBString(maxLvl)))
	}
	return out
}

func (m model) levelsBody(w int) []string {
	labelW, barW, gap := 9, 20, 3
	colW := (w - gap) / 2
	barW = colW - labelW - 8
	if barW < 8 {
		barW = 8
	}
	if barW > 30 {
		barW = 30
	}
	left := []string{tuikit.StyleAccent.Render("CAPTURE  interface → computer")}
	left = append(left, m.meterRows(meters.KeyInput, inputMeterRows, labelW, barW)...)
	right := []string{tuikit.StyleAccent.Render("PLAYBACK  computer → interface (USB)")}
	right = append(right, m.meterRows(meters.KeyPlayback, playbackMeterRows, labelW, barW)...)

	if w < 78 {
		return append(append(left, ""), right...)
	}
	colL := labelW + barW + 8
	if colL < 34 {
		colL = 34
	}
	if colL > w-gap-20 {
		colL = w - gap - 20
	}
	var out []string
	n := len(left)
	if len(right) > n {
		n = len(right)
	}
	for i := 0; i < n; i++ {
		l, rr := "", ""
		if i < len(left) {
			l = left[i]
		}
		if i < len(right) {
			rr = right[i]
		}
		out = append(out, padStyled(l, colL)+strings.Repeat(" ", gap)+rr)
	}
	return out
}

func (m model) meterStatusLine() string {
	if !m.isEvoDevice() || m.evo.spec.ID != drivers.DevEVO8 {
		return tuikit.StyleWarn.Render("Meters need the live EVO 8 USB streams.")
	}
	if !m.session.live || !m.status.Online {
		return tuikit.StyleWarn.Render("EVO 8 is offline — reconnect to meter.")
	}
	if m.meterStarting && m.meter == nil {
		return tuikit.StyleMuted.Render("Starting USB capture…")
	}
	if len(m.meterSnap.Errors) > 0 {
		return tuikit.StyleErr.Render(strings.Join(m.meterSnap.Errors, " · "))
	}
	if m.meterFrozen {
		return tuikit.StyleAccent.Render("peak hold frozen")
	}
	return ""
}

func (m model) levelsView() string {
	w, h := m.contentSize()
	lines := []string{screenTitle("Levels — USB digital meters (analog OUT not metered)", w), ""}
	lines = append(lines, m.levelsBody(w)...)
	if status := m.meterStatusLine(); status != "" {
		lines = append(lines, "", status)
	}
	lines = append(lines, "", tuikit.StyleHelp.Render("esc/v back · space reset peaks · p freeze peaks · q quit"))
	content := strings.Join(lines, "\n")

	ch := h - 1
	if ch < 1 {
		ch = 1
	}
	content = lipgloss.PlaceVertical(ch, lipgloss.Center, content)
	return versionRow(w) + "\n" + content
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
