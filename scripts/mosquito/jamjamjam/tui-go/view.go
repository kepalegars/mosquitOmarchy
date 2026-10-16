package main

import (
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/charmbracelet/lipgloss"
	tuikit "mosquitomarchy.local/tui-kit"
)

// lipglossJoin puts `right` on the right edge of a `w`-wide line, eliding
// left when there is no room.
func lipglossJoin(left, right string, w int) string {
	right = lipgloss.NewStyle().Width(lipgloss.Width(right)).Render(right)
	avail := w - lipgloss.Width(right) - 1
	if avail < 4 {
		avail = 4
	}
	left = lipgloss.NewStyle().Width(avail).Render(left)
	return left + " " + right
}

// Neck styles: white string lines, grey fret lines, same-colour ruler digits.
var (
	styleString  = lipgloss.NewStyle().Foreground(tuikit.ColorHeader).Bold(true)
	styleFret    = lipgloss.NewStyle().Foreground(tuikit.ColorMuted)
	styleFretNum = lipgloss.NewStyle().Foreground(tuikit.ColorHeader).Bold(true)
	styleDegree  = lipgloss.NewStyle().Foreground(tuikit.ColorHeader)
	styleRoot    = lipgloss.NewStyle().Foreground(tuikit.ColorAccent).Bold(true)
)

func (m model) centerText(s string) string {
	return lipgloss.NewStyle().Width(m.w).Align(lipgloss.Center).Render(s)
}

func (m model) body() string {
	lines := []string{}
	// The splash wordmark floats in the body (so it sits below the header bar
	// and is vertically centred with the rest), horizontally centred between
	// the top of the screen and the fretboard.
	if mark := m.logoWordmark(); mark != "" {
		lines = append(lines, mark)
	}
	lines = append(lines, m.centerLine())
	if n := m.neckView(); n != "" {
		lines = append(lines, n)
	} else {
		lines = append(lines, m.centerText(tuikit.StyleMuted.Render("no scale yet — play some music while listening")))
	}
	// Detected progression (or the live analysis progress) below the neck.
	lines = append(lines, m.chordView())
	return strings.Join(lines, "\n")
}

// centerBlockText centres a multi-line block (a figlet wordmark, a boxed
// wordmark) as a whole by adding one uniform left margin, so the art keeps its
// own internal alignment instead of each line being centred independently.
func (m model) centerBlockText(s string) string {
	if s == "" || m.w <= 0 {
		return s
	}
	lines := strings.Split(s, "\n")
	maxw := 0
	for _, l := range lines {
		if w := lipgloss.Width(l); w > maxw {
			maxw = w
		}
	}
	if maxw <= 0 {
		return s
	}
	pad := (m.w - maxw) / 2
	if pad < 0 {
		pad = 0
	}
	prefix := strings.Repeat(" ", pad)
	for i := range lines {
		lines[i] = prefix + lines[i]
	}
	return strings.Join(lines, "\n")
}

// centerLine shows the detected scale and the chord heard right now, centred.
func (m model) centerLine() string {
	label := m.state.Guitar.Label
	if label == "" {
		label = "—"
	}
	out := tuikit.StyleAccent.Render(label)
	// The live chord estimate has its own line below the neck (where the
	// progression used to be), so this line stays scale-only.
	return m.centerText(out)
}

// analyzeLabel is the plain text of the bottom-right analysis button.
func (m model) analyzeLabel() string {
	if m.hold {
		return "analyzing…"
	}
	return "hold Right Ctrl to analyze"
}

// analyzeButton renders the right-aligned analysis hint on the bottom row. It
// is display-only: analysis is started exclusively with the global RIGHT CTRL.
func (m model) analyzeButton() string {
	if m.hold {
		return tuikit.StyleOK.Render("⏺ " + m.analyzeLabel())
	}
	return tuikit.StyleHelp.Render(m.analyzeLabel())
}

// chordView renders the real-time chord estimate below the fretboard. Chord
// progression accumulation is set aside for now, so this is a live read-out of
// the chord heard right now (name + notes), refreshed every analysis pass.
func (m model) chordView() string {
	if m.hold {
		elapsed := time.Since(m.analyzeStart)
		if elapsed < 0 {
			elapsed = 0
		}
		txt := fmt.Sprintf("analyzing… %.1fs", elapsed.Seconds())
		return m.centerText(tuikit.StyleOK.Render(txt))
	}
	if m.state.NeedsReset {
		return m.centerText(tuikit.StyleWarn.Render("reset required before analyzing new data (press r)"))
	}
	if m.state.Analyzer.SongChanged {
		return m.centerText(tuikit.StyleWarn.Render("⟳ new song detected — press r to reset the analysis"))
	}
	chord := m.state.Analyzer.CurrentChord
	if chord == "" {
		if m.state.Analyzer.NoSignal {
			return m.centerText(tuikit.StyleMuted.Render("no music — could not find the chord"))
		}
		return m.centerText(tuikit.StyleMuted.Render("listening for a chord…"))
	}
	line := tuikit.StyleHeader.Render("CHORD ") + tuikit.StyleAccent.Render(chord)
	if notes := strings.Join(m.state.Analyzer.ChordNotes, " "); notes != "" {
		line += "   " + tuikit.StyleMuted.Render(notes)
	}
	return m.centerText(line)
}

// tunerGauge draws a ±50¢ needle meter used by the header tuner: a track
// with a center marker and a needle, flanked by ♭/♯ labels. When `active` is
// false the track is drawn with no needle (the tuner idles without a reading).
func (m model) tunerGauge(cents int, active bool) string {
	cells := 17
	half := cells / 2
	pos := half + int((float64(cents)/50.0)*float64(half))
	if pos < 0 {
		pos = 0
	}
	if pos > cells-1 {
		pos = cells - 1
	}
	b := []rune(strings.Repeat("·", cells))
	b[half] = '│'
	if active {
		b[pos] = '●'
	}
	return "♭" + string(b) + "♯"
}

// rulerRow is the fret-number ruler shown below the neck. The vertical fret
// lines stop at the strings, so the ruler keeps the same alignment with a
// space where each `│` sat — the lines never run into the numbers.
func (m model) rulerRow() string {
	builder := strings.Builder{}
	builder.WriteString("   ")
	for fret := 0; fret <= 12; fret++ {
		builder.WriteString(" ")
		builder.WriteString(styleFretNum.Render(fmt.Sprintf("%3d", fret)))
	}
	return builder.String()
}

// neckView renders the guitar neck with the high strings on top and the low
// strings at the bottom (tab orientation, as on the instrument when looking
// down): white horizontal string lines, grey vertical fret lines, degrees
// sitting on the strings (R = root). A fret-number ruler frames it top/bottom.
func (m model) neckView() string {
	g := m.state.Guitar
	if len(g.Strings) != 6 {
		return ""
	}
	matrix := make([][]int, 6)
	for i := range matrix {
		matrix[i] = make([]int, 13)
	}
	for _, d := range g.Dots {
		if d.String >= 0 && d.String < 6 && d.Fret >= 0 && d.Fret <= 12 {
			matrix[d.String][d.Fret] = d.Degree
		}
	}
	ruler := m.centerText(m.rulerRow())
	rows := []string{}
	for si := 0; si < 6; si++ {
		builder := strings.Builder{}
		builder.WriteString(styleString.Render(fmt.Sprintf("%-3s", g.Strings[si].Name)))
		for fret := 0; fret <= 12; fret++ {
			deg := matrix[si][fret]
			builder.WriteString(styleFret.Render("│"))
			switch {
			case deg == 0:
				builder.WriteString(styleString.Render("───"))
			case deg == 1:
				builder.WriteString(styleRoot.Render("─R─"))
			default:
				builder.WriteString(styleDegree.Render("─" + itoa(deg) + "─"))
			}
		}
		rows = append(rows, m.centerText(builder.String()))
	}
	// Fret numbers only below the neck (the lines stop at the strings).
	rows = append(rows, ruler)
	return strings.Join(rows, "\n")
}

// itoa avoids repeated fmt.Sprint in tight loops.
func itoa(n int) string { return strconv.Itoa(n) }
