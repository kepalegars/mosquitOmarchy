package main

import (
	"fmt"
	"math"
	"os/exec"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"mosquitomarchy.local/mosquitomixbay-tui/drivers"
	"mosquitomarchy.local/mosquitomixbay-tui/meters"
)

// EVO USB meters. The node names carry the card's serial/model suffix and
// vary with the ALSA/UCM profile, so discover them from the live PipeWire
// graph instead of hardcoding one machine's name. A card that declares
// hardware.meters supplies the node fragment and channel map; the native
// EVO/UGM fallbacks stay for cards that predate the binding.
const evoMaxMeterChannels = drivers.MaxMeterChannels

type meterStartedMsg struct{ engine *meters.Engine }
type meterSnapshotMsg struct {
	engine *meters.Engine
	snap   meters.Snapshot
}
type meterClosedMsg struct{ engine *meters.Engine }

// usbMeterSources builds the captures for a supported USB interface.
// Playback is observed on the sink monitor, capture on the source: never on
// the analog OUT controls, which are not in the USB stream. A card's
// hardware.meters binding replaces the native discovery; an empty direction
// simply has no source, and a declared-but-missing node yields no meter at
// all rather than half a panel.
func usbMeterSources(spec drivers.Spec) []meters.Source {
	m := spec.Meters
	if m == nil {
		outNode, outCh := discoverMeterNode(spec, true)
		inNode, inCh := discoverMeterNode(spec, false)
		if outNode == "" || inNode == "" {
			return nil
		}
		return []meters.Source{
			{Key: meters.KeyPlayback, Node: outNode, Channels: outCh, Monitor: true},
			{Key: meters.KeyInput, Node: inNode, Channels: inCh},
		}
	}
	var out []meters.Source
	if len(m.Playback) > 0 {
		node, ch := discoverMeterNode(spec, true)
		if node == "" {
			return nil
		}
		out = append(out, meters.Source{Key: meters.KeyPlayback, Node: node, Channels: ch, Monitor: true})
	}
	if len(m.Capture) > 0 {
		node, ch := discoverMeterNode(spec, false)
		if node == "" {
			return nil
		}
		out = append(out, meters.Source{Key: meters.KeyInput, Node: node, Channels: ch})
	}
	return out
}

// meterNodeMatches compares a pw-link node name to the card filter. A
// declared binding accepts the human spelling ("Quantum ES 4") against
// PipeWire's underscored form; the native fallback keeps its exact substring
// behaviour.
func meterNodeMatches(node, want string, declared bool) bool {
	if want == "" {
		return true
	}
	if !declared {
		return strings.Contains(node, want)
	}
	return strings.Contains(meterFold(node), meterFold(want))
}

func meterFold(s string) string {
	var b strings.Builder
	for _, r := range strings.ToLower(s) {
		switch r {
		case '_', '-', '.', ' ':
		default:
			b.WriteRune(r)
		}
	}
	return b.String()
}

// discoverMeterNode finds the ALSA node of this interface in the live graph
// and its channel count. `playback` selects the sink (pw-link -i, input
// ports) or the source (pw-link -o, output ports). When several nodes match
// (UCM stereo + raw pro node), the widest one wins: that is the one carrying
// every USB channel the meters need.
func discoverMeterNode(spec drivers.Spec, playback bool) (string, int) {
	args := []string{"-o"}
	if playback {
		args = []string{"-i"}
	}
	declared := spec.Meters != nil && spec.Meters.Node != ""
	out, err := exec.Command("pw-link", args...).Output()
	if err == nil {
		prefix := "alsa_output.usb-"
		if !playback {
			prefix = "alsa_input.usb-"
		}
		// Keep a model filter so two cards on one machine cannot cross-meter.
		want := ""
		if declared {
			want = spec.Meters.Node
		} else {
			switch spec.ID {
			case drivers.DevEVO8:
				want = "EVO8"
			case drivers.DevEVO4:
				want = "EVO4"
			case drivers.DevUGM192:
				want = "UGM192"
			}
		}
		counts := map[string]int{}
		for _, line := range strings.Split(string(out), "\n") {
			line = strings.TrimSpace(line)
			i := strings.IndexByte(line, ':')
			if i <= 0 {
				continue
			}
			node := line[:i]
			if !strings.HasPrefix(node, prefix) {
				continue
			}
			if declared {
				if !meterNodeMatches(node, want, true) {
					continue
				}
			} else if want != "" {
				if !strings.Contains(node, want) {
					continue
				}
			} else if !strings.Contains(node, spec.Vendor) {
				continue
			}
			counts[node]++
		}
		best, bestN := "", 0
		for node, n := range counts {
			if n > bestN {
				best, bestN = node, n
			}
		}
		if best != "" && bestN > 0 {
			if declared {
				labels := spec.Meters.Capture
				if playback {
					labels = spec.Meters.Playback
				}
				// The map is the contract: never meter more channels than
				// the card labels, even if the node exposes more ports.
				if len(labels) > 0 && len(labels) < bestN {
					bestN = len(labels)
				}
			}
			if bestN > evoMaxMeterChannels {
				bestN = evoMaxMeterChannels
			}
			return best, bestN
		}
	}
	// A declared binding never falls back to another card's node names.
	if declared {
		return "", 0
	}
	// Fallback: the stable pro-audio names seen on the reference EVOs.
	suffix := "8"
	channels := 6
	if spec.ID == drivers.DevEVO4 {
		suffix = "4"
		channels = 4
	}
	if spec.ID != drivers.DevEVO8 && spec.ID != drivers.DevEVO4 {
		return "", 0
	}
	if playback {
		return "alsa_output.usb-Audient_EVO" + suffix + "-00.pro-output-0", channels
	}
	return "alsa_input.usb-Audient_EVO" + suffix + "-00.pro-input-0", channels
}

func startMetersCmd(spec drivers.Spec) tea.Cmd {
	return func() tea.Msg {
		sources := usbMeterSources(spec)
		if len(sources) == 0 {
			return meterStartedMsg{engine: nil}
		}
		return meterStartedMsg{engine: meters.Start(sources)}
	}
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
	// A composition without a Levels block has nowhere to draw a meter; the
	// EVO control rows hide theirs too, so don't hold a USB capture open.
	if !m.hasBlock("levelsColumns") {
		return false
	}
	switch m.controlModel() {
	case modelGrid:
		return m.top() == scrControls || m.top() == scrMixer
	case modelSingle, modelLevels:
		return m.top() == scrControls
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
		return startMetersCmd(m.status.Spec)
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
	var arr *[evoMaxMeterChannels]float64
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
	case "tab", "esc", "backspace":
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
		m.resetMeterPeaks()
		return nil
	case "q":
		return m.evoQuitConfirm()
	}
	return nil
}

func (m model) meterFloor() float64 {
	if s := m.status.Spec.Meters; s != nil && s.FloorDb < 0 {
		return s.FloorDb
	}
	return -60
}

func meterDB(level, floor float64) float64 {
	if level <= 1e-5 {
		return floor
	}
	db := 20 * math.Log10(level)
	if db < floor {
		db = floor
	}
	if db > 0 {
		db = 0
	}
	return db
}

func meterDBShort(level, floor float64) string {
	if level <= 1e-5 {
		return " -∞"
	}
	db := meterDB(level, floor)
	if db > -0.5 {
		db = 0
	}
	return fmt.Sprintf("%3.0f", db)
}

func meterFraction(level, floor float64) float64 {
	return clampf((meterDB(level, floor)-floor)/(0-floor), 0, 1)
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

func meterBars(labels []string, key string) []evoMeterBar {
	if len(labels) == 0 {
		return nil
	}
	bars := make([]evoMeterBar, 0, len(labels))
	for i, label := range labels {
		bars = append(bars, evoMeterBar{label: label, key: key, ch: i})
	}
	return bars
}

// evoCaptureBarsFor lists the USB capture channels the Levels page shows:
// the card's declared channel map when it has one, else the hardware inputs
// followed by the two loopback-capture channels. The layout follows the
// device spec, so the EVO 4 gets IN1/IN2 + LP3/LP4 and the EVO 8 IN1-4 +
// LP5/LP6 instead of a hardcoded six-bar panel.
func evoCaptureBarsFor(spec drivers.Spec) []evoMeterBar {
	if spec.Meters != nil {
		return meterBars(spec.Meters.Capture, meters.KeyInput)
	}
	bars := make([]evoMeterBar, 0, spec.NumInputs+2)
	for i := 0; i < spec.NumInputs; i++ {
		bars = append(bars, evoMeterBar{
			label: fmt.Sprintf("IN%d", i+1),
			key:   meters.KeyInput,
			ch:    i,
		})
	}
	for i := 0; i < 2; i++ {
		bars = append(bars, evoMeterBar{
			label: fmt.Sprintf("LP%d", spec.NumInputs+i+1),
			key:   meters.KeyInput,
			ch:    spec.NumInputs + i,
		})
	}
	return bars
}

// evoPlaybackBarsFor lists the USB playback monitor channels: the card's
// declared channel map when it has one, else the output pairs the card
// exposes, then the loopback output pair. EVO 4 = PC1/PC2 + LP3/LP4;
// EVO 8 = PC1-4 + LP5/LP6.
func evoPlaybackBarsFor(spec drivers.Spec) []evoMeterBar {
	if spec.Meters != nil {
		return meterBars(spec.Meters.Playback, meters.KeyPlayback)
	}
	pairs := spec.NumOutPairs * 2
	bars := make([]evoMeterBar, 0, pairs+2)
	for i := 0; i < pairs; i++ {
		bars = append(bars, evoMeterBar{
			label: fmt.Sprintf("PC%d", i+1),
			key:   meters.KeyPlayback,
			ch:    i,
		})
	}
	for i := 0; i < 2; i++ {
		bars = append(bars, evoMeterBar{
			label: fmt.Sprintf("LP%d", pairs+i+1),
			key:   meters.KeyPlayback,
			ch:    pairs + i,
		})
	}
	return bars
}

func (m model) meterStatus() (string, int) {
	if !m.hasBlock("levelsColumns") {
		return "Meters need the live USB streams.", cYellow
	}
	if !m.session.live || !m.status.Online {
		return "Interface offline — reconnect to meter.", cYellow
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
		scaleW   = 7
		groupGap = 3
	)
	capBars := evoCaptureBarsFor(r.spec)
	playBars := evoPlaybackBarsFor(r.spec)
	bodyRow := row
	groupW := func(n int) int { return n*barW + (n-1)*gap }
	capW, playW := groupW(len(capBars)), groupW(len(playBars))
	totalW := scaleW
	if len(capBars) > 0 {
		totalW += capW
	}
	if len(playBars) > 0 {
		if len(capBars) > 0 {
			totalW += groupGap
		}
		totalW += playW
	}
	x := cx + (sectionW-totalW)/2
	if x < cx {
		x = cx
	}
	next := x + scaleW
	if len(capBars) > 0 {
		captureX := next
		r.put(captureX+(capW-len([]rune("Capture")))/2, row, "Capture", evoStyle{col: cAccent, bold: true})
		next += capW + groupGap
	}
	if len(playBars) > 0 {
		playbackTitle := "Playback (USB)"
		r.put(next+(playW-len([]rune(playbackTitle)))/2, row, playbackTitle, evoStyle{col: cAccent, bold: true})
	}
	row++
	readoutRow := row
	row++
	barTop := row
	const barRows = 18
	barBot := barTop + barRows - 1

	r.drawMeterScale(x, barTop, barBot, r.m.meterFloor())
	next = x + scaleW
	if len(capBars) > 0 {
		r.drawMeterColumns(next, readoutRow, barTop, barBot, barW, gap, capBars)
		next += capW + groupGap
	}
	if len(playBars) > 0 {
		r.drawMeterColumns(next, readoutRow, barTop, barBot, barW, gap, playBars)
	}

	return bodyRow + evoControlsBodyH(r.u.groups())
}

// drawMeterScale is the dB barometer on the left of a Levels page.
func (r *evoRender) drawMeterScale(x, barTop, barBot int, floor float64) {
	rows := barBot - barTop + 1
	for _, db := range meterTicks(floor) {
		y := barBot - int(math.Round((db-floor)/(0-floor)*float64(rows-1)))
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
		r.put(x+5, y, "──", evoVal)
	}
}

// meterTicks keeps the reference EVO scale unchanged (-60 is the default)
// and spreads proportional ticks when a card declares another floor.
func meterTicks(floor float64) []float64 {
	if floor == -60 {
		return []float64{-60, -40, -20, -12, -6, 0}
	}
	ticks := []float64{floor, floor * 2 / 3, floor / 3}
	for _, db := range []float64{-12, -6, 0} {
		if db > floor {
			ticks = append(ticks, db)
		}
	}
	return ticks
}

// drawMeterColumns draws one group of vertical meters: dB readout above,
// bar, then the channel label underneath.
func (r *evoRender) drawMeterColumns(groupX, readoutRow, barTop, barBot, barW, gap int, bars []evoMeterBar) {
	floor := r.m.meterFloor()
	for i, b := range bars {
		bx := groupX + i*(barW+gap)
		level := r.m.meterLevel(b.key, b.ch)
		peak := r.m.meterPeak(b.key, b.ch)
		attr := evoDim
		if level > 1e-5 {
			attr = evoStyle{col: meterColor(meterDB(level, floor))}
		}
		r.put(bx+(barW-len([]rune(b.label))+1)/2, readoutRow, meterDBShort(level, floor), attr)
		r.drawVerticalBar(bx, barTop, barBot, barW, level, peak, floor)
		r.put(bx+(barW-len([]rune(b.label))+1)/2, barBot+1, b.label, evoDim)
	}
}

func (r *evoRender) drawVerticalBar(x, top, bot, width int, level, peak, floor float64) {
	rows := bot - top + 1
	full := int(math.Round(float64(rows) * meterFraction(level, floor)))
	fillTop := bot - full + 1
	peakPos := int(math.Round(float64(rows) * meterFraction(peak, floor)))
	peakRow := bot - peakPos + 1
	for y := top; y <= bot; y++ {
		for col := 0; col < width; col++ {
			if y >= fillTop {
				db := floor + (0-floor)*float64(bot-y+1)/float64(rows)
				r.c.put(x+col, y, "█", evoStyle{col: meterColor(db)})
			} else {
				r.c.put(x+col, y, "░", evoStyle{col: cBorder, dim: true})
			}
		}
	}
	if peakPos > 0 {
		st := evoStyle{col: cWhite}
		if peakRow >= fillTop {
			db := floor + (0-floor)*float64(bot-peakRow+1)/float64(rows)
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
func evoMeterChannels(spec drivers.Spec, key string) (string, []int) {
	if strings.HasPrefix(key, "input") {
		var l, r int
		if _, err := fmt.Sscanf(key, "input%d_%d", &l, &r); err == nil && l >= 1 && r == l+1 && r <= spec.NumInputs {
			return meters.KeyInput, []int{l - 1, r - 1}
		}
		var n int
		if _, err := fmt.Sscanf(key, "input%d", &n); err == nil && n >= 1 && n <= spec.NumInputs {
			return meters.KeyInput, []int{n - 1}
		}
		return "", nil
	}
	if strings.HasPrefix(key, "output") {
		var ch int
		if _, err := fmt.Sscanf(key, "outputch%d", &ch); err == nil && ch >= 1 {
			return meters.KeyPlayback, []int{ch - 1}
		}
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
	floor := r.m.meterFloor()
	full := int(math.Round(float64(width) * meterFraction(level, floor)))
	peakPos := int(math.Round(float64(width) * meterFraction(peak, floor)))
	fill := evoStyle{col: col}
	empty := evoStyle{col: cBorder, dim: true}
	mark := evoStyle{col: cWhite, bold: true}
	for i := 0; i < width; i++ {
		switch {
		case i < full:
			r.c.put(x+i, row, "▮", fill)
		case i == peakPos && peakPos > 0 && peakPos >= full:
			r.c.put(x+i, row, "│", mark)
		default:
			r.c.put(x+i, row, "▯", empty)
		}
	}
}

func (r *evoRender) drawKeyMeter(row, x, width int, key string, col int) {
	src, chans := evoMeterChannels(r.spec, key)
	if src == "" || len(chans) == 0 || width < 4 {
		if key == "monitor" {
			r.put(x, row, "no USB meter", evoDim)
		}
		return
	}
	if len(chans) == 2 {
		label := "USB "
		if src == meters.KeyInput {
			label = "IN  "
		}
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
