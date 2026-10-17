package main

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/lipgloss"
	"mosquitomarchy.local/mosquitomixbay-tui/drivers"
	tuikit "mosquitomarchy.local/tui-kit"
)

func (m model) isEvoDevice() bool {
	return m.deviceID == drivers.DevEVO8 || m.deviceID == drivers.DevEVO4
}

func (m model) visualBody(w int) string {
	if !m.isEvoDevice() {
		return m.picker.View()
	}
	if m.top() == scrControls {
		return m.evoControlsBody(w)
	}
	if m.top() == scrMixer {
		return m.evoMixerBody(w)
	}
	return m.picker.View()
}

func (m model) evoControlsBody(w int) string {
	st := m.status
	if len(st.Inputs) == 0 || len(st.Outputs) == 0 {
		return m.picker.View()
	}
	selected := m.picker.SelectedValue()
	activeInput := -1
	activeOutput := -1
	activeMonitor := false
	switch {
	case strings.HasPrefix(selected, "gain:"), strings.HasPrefix(selected, "mute:input"), strings.HasPrefix(selected, "phantom:"):
		t := strings.TrimPrefix(strings.TrimPrefix(selected, "gain:"), "mute:")
		t = strings.TrimPrefix(t, "phantom:")
		var n int
		fmt.Sscanf(t, "input%d", &n)
		activeInput = n - 1
	case strings.HasPrefix(selected, "vol:"), strings.HasPrefix(selected, "mute:output"):
		if strings.HasPrefix(selected, "vol:") {
			var i int
			fmt.Sscanf(selected, "vol:%d", &i)
			activeOutput = i
		}
	case selected == "monitor":
		activeMonitor = true
	}

	cardW := w / 2
	if cardW < 34 {
		cardW = w
	}
	if w >= 70 {
		// Two columns.
		left := m.evoInputColumn(st, activeInput, cardW)
		right := m.evoOutputColumn(st, activeOutput, activeMonitor, cardW)
		return joinColumns(left, right, 2)
	}
	// Narrow: stack.
	parts := []string{}
	for i, in := range st.Inputs {
		parts = append(parts, evoInputCard(in, i, i == activeInput, w))
	}
	for i, o := range st.Outputs {
		parts = append(parts, evoOutputCard(o, i, i == activeOutput, activeMonitor && st.Monitor != nil && i == 0, st.Monitor, w))
	}
	return strings.Join(parts, "\n")
}

func (m model) evoInputColumn(st drivers.Status, active int, w int) string {
	cards := []string{}
	for i, in := range st.Inputs {
		cards = append(cards, evoInputCard(in, i, i == active, w))
	}
	return strings.Join(cards, "\n")
}

func (m model) evoOutputColumn(st drivers.Status, active int, activeMon bool, w int) string {
	cards := []string{}
	for i, o := range st.Outputs {
		mon := (*int)(nil)
		if st.Monitor != nil {
			mon = st.Monitor
		}
		cards = append(cards, evoOutputCard(o, i, i == active, activeMon, mon, w))
	}
	if st.Monitor != nil {
		// EVO4 blend card (single output pair case kept above via card).
	}
	return strings.Join(cards, "\n")
}

func evoInputCard(in drivers.InputState, idx int, active bool, w int) string {
	inner := w - 2
	if inner < 24 {
		inner = 24
	}
	w = inner + 2
	frac := (in.GainDb - 0) / 58.0
	if frac < 0 {
		frac = 0
	}
	if frac > 1 {
		frac = 1
	}
	bar := sliderBar(frac, inner-4)
	muteInd := tuikit.StyleMuted.Render("[m]")
	if in.Muted {
		muteInd = tuikit.StyleAccent.Bold(true).Render("[M]")
	}
	phInd := tuikit.StyleHelp.Render("[48v]")
	if in.Phantom {
		phInd = tuikit.StyleAccent.Bold(true).Render("[48V]")
	}
	borderStyle := tuikit.StyleMuted
	if active {
		borderStyle = tuikit.StyleAccent.Bold(true)
	}
	top := borderStyle.Render("┌" + padTitle(fmt.Sprintf(" IN %d ", idx+1), inner) + "┐")
	mid1 := "│ " + padR(bar, inner-2) + " │"
	mid2 := "│ " + padR(fmt.Sprintf("gain %s", dbFmt(in.GainDb)), inner-10) + " " + muteInd + " " + phInd + " │"
	bot := borderStyle.Render("└" + strings.Repeat("─", inner) + "┘")
	return top + "\n" + mid1 + "\n" + mid2 + "\n" + bot
}

func evoOutputCard(o drivers.OutputState, idx int, active bool, activeMon bool, mon *int, w int) string {
	inner := w - 2
	if inner < 24 {
		inner = 24
	}
	w = inner + 2
	frac := (o.VolumeDb + 96) / 96.0
	if frac < 0 {
		frac = 0
	}
	if frac > 1 {
		frac = 1
	}
	bar := sliderBar(frac, inner-4)
	muteInd := tuikit.StyleMuted.Render("[m]")
	if o.Muted {
		muteInd = tuikit.StyleAccent.Bold(true).Render("[M]")
	}
	borderStyle := tuikit.StyleMuted
	if active {
		borderStyle = tuikit.StyleAccent.Bold(true)
	}
	label := fmt.Sprintf(" OUT %d|%d ", idx*2+1, idx*2+2)
	top := borderStyle.Render("┌" + padTitle(label, inner) + "┐")
	mid1 := "│ " + padR(bar, inner-2) + " │"
	mid2 := "│ " + padR(fmt.Sprintf("vol %s", dbFmt(o.VolumeDb)), inner-6) + " " + muteInd + " │"
	bot := borderStyle.Render("└" + strings.Repeat("─", inner) + "┘")
	lines := []string{top, mid1, mid2, bot}
	if mon != nil && idx == 0 {
		mfrac := float64(*mon) / 100.0
		mbar := sliderBar(mfrac, inner-4)
		mtop := borderStyle.Render("┌" + padTitle(" MONITOR ", inner) + "┐")
		mmid := "│ " + padR(mbar, inner-2) + " │"
		mval := "│ " + padR(fmt.Sprintf("%d%% (0=in · 100=playback)", *mon), inner-2) + " │"
		mbot := borderStyle.Render("└" + strings.Repeat("─", inner) + "┘")
		lines = append(lines, mtop, mmid, mval, mbot)
	}
	return strings.Join(lines, "\n")
}

func (m model) evoMixerBody(w int) string {
	st := m.status
	if len(st.Mixer) == 0 {
		return m.picker.View()
	}
	parts := []string{}
	busLine := tuikit.StyleAccent.Bold(true).Render(fmt.Sprintf("MIX bus: %s  (←/→ switch bus)", drivers.BusLabel(m.mixBus)))
	parts = append(parts, centerLine(busLine, w))
	for _, k := range drivers.MixerSources(st.Spec, m.mixBus) {
		c, ok := st.Mixer[k]
		if !ok {
			continue
		}
		frac := (c.VolumeDb - (mixDbMinEvo)) / (mixDbMaxEvo - (mixDbMinEvo))
		if frac < 0 {
			frac = 0
		}
		if frac > 1 {
			frac = 1
		}
		// pan frac
		panFrac := (c.Pan + 100) / 200.0
		if panFrac < 0 {
			panFrac = 0
		}
		if panFrac > 1 {
			panFrac = 1
		}
		title := k
		volPrefix := fmt.Sprintf("vol %s  ", dbFmt(c.VolumeDb))
		panPrefix := fmt.Sprintf("pan %+.0f     ", c.Pan)
		volBar := sliderBar(frac, w-4-lipgloss.Width(volPrefix))
		panBar := sliderBar(panFrac, w-4-lipgloss.Width(panPrefix))
		card := []string{
			tuikit.StyleMuted.Render("┌" + padTitle(" "+title+" ", w-2) + "┐"),
			"│ " + padR(volPrefix+volBar, w-4) + " │",
			"│ " + padR(panPrefix+panBar, w-4) + " │",
			tuikit.StyleMuted.Render("└" + strings.Repeat("─", w-2) + "┘"),
		}
		parts = append(parts, strings.Join(card, "\n"))
	}
	return strings.Join(parts, "\n")
}

const mixDbMinEvo = -128.0
const mixDbMaxEvo = 6.0

func sliderBar(frac float64, width int) string {
	if width < 4 {
		width = 4
	}
	filled := int(frac * float64(width))
	if filled < 0 {
		filled = 0
	}
	if filled > width {
		filled = width
	}
	return strings.Repeat("█", filled) + strings.Repeat("░", width-filled)
}

func padR(s string, n int) string {
	if pad := n - lipgloss.Width(s); pad > 0 {
		return s + strings.Repeat(" ", pad)
	}
	return s
}

func padTitle(s string, inner int) string {
	if lipgloss.Width(s) >= inner {
		return s
	}
	left := (inner - lipgloss.Width(s)) / 2
	right := inner - lipgloss.Width(s) - left
	return strings.Repeat("─", left) + s + strings.Repeat("─", right)
}

func centerLine(s string, w int) string {
	return lipglossCenter(s, w)
}

func joinColumns(left, right string, gap int) string {
	l := strings.Split(left, "\n")
	r := strings.Split(right, "\n")
	n := len(l)
	if len(r) > n {
		n = len(r)
	}
	for len(l) < n {
		l = append(l, "")
	}
	for len(r) < n {
		r = append(r, "")
	}
	sep := strings.Repeat(" ", gap)
	out := make([]string, n)
	for i := 0; i < n; i++ {
		out[i] = l[i] + sep + r[i]
	}
	return strings.Join(out, "\n")
}

func lipglossCenter(s string, w int) string {
	// fallback simple
	pad := (w - len(stripANSI2(s))) / 2
	if pad < 0 {
		pad = 0
	}
	return strings.Repeat(" ", pad) + s
}

func stripANSI2(s string) string {
	out := ""
	inEsc := false
	for _, r := range s {
		if r == 0x1b {
			inEsc = true
			continue
		}
		if inEsc {
			if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') {
				inEsc = false
			}
			continue
		}
		out += string(r)
	}
	return out
}
