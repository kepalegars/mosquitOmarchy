package main

import (
	"fmt"
	"strings"
	"time"

	"github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	tuikit "mosquitomarchy.local/tui-kit"
)

const pollInterval = 500 * time.Millisecond

type tickMsg time.Time
type statusExpireMsg struct{ seq int }

// model rendered a live mirror of the jamjamjam backend snapshot: the
// detected key/beat, the guitar neck, and the chord progression. The analysis
// hold is owned by the global RIGHT CTRL shortcut (see jamjamjam-analyze):
// the backend flags `hold`, and this view mirrors it; holding it releases the
// recorder and freezes the accumulated progression. The metronome (m) clicks
// at the heard BPM.
type model struct {
	w, h         int
	state        State
	loadErr      string
	age          float64
	status       string
	statusSeq    int
	hold         bool
	analyzeStart time.Time
	metronome    bool
	help         bool
	settings     bool
	splashUntil  time.Time
	firstTick    bool
	config       Config
	quit         bool
}

const splashDuration = 1500 * time.Millisecond

func initialModel() model {
	return model{
		splashUntil: time.Now().Add(splashDuration),
		config:      loadLocalConfig(),
	}
}

func (m model) Init() tea.Cmd {
	_ = writeTuiPid()
	return tea.Batch(m.refreshCmd(), m.statusExpireCmd(), tuikit.ThemeWatchCmd())
}

// refreshCmd re-polls the state snapshot.
func (m model) refreshCmd() tea.Cmd {
	return tea.Tick(pollInterval, func(t time.Time) tea.Msg { return tickMsg(t) })
}

// statusExpireCmd clears a transient status line (reset acknowledged, …).
func (m model) statusExpireCmd() tea.Cmd {
	seq := m.statusSeq
	return tea.Tick(3*time.Second, func(time.Time) tea.Msg { return statusExpireMsg{seq: seq} })
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.w, m.h = msg.Width, msg.Height
		return m, nil
	case tea.KeyMsg:
		if m.settings {
			switch msg.String() {
			case "esc", "q", "s":
				m.settings = false
			case "n":
				if m.config.NoteNaming == "flats" {
					m.config.NoteNaming = "sharps"
				} else {
					m.config.NoteNaming = "flats"
				}
				_ = saveLocalConfigSafe(m.config)
				_ = writeConfig(m.config.NoteNaming)
			}
			return m, nil
		}
		if m.help {
			switch msg.String() {
			case "q", "esc", "?":
				m.help = false
			}
			return m, nil
		}
		switch msg.String() {
		case "ctrl+c", "q", "esc":
			m.releaseHold()
			m.quit = true
			return m, tea.Quit
		case "?":
			m.help = true
			return m, nil
		case "s":
			m.settings = true
			return m, nil
		case "m":
			m.toggleMetronome()
			return m, m.statusExpireCmd()
		case "r":
			if err := writeReset(); err != nil {
				m.status = "reset failed: " + err.Error()
			} else {
				m.status = "analysis reset"
			}
			m.statusSeq++
			return m, m.statusExpireCmd()
		}
	case tuikit.ThemeTickMsg:
		tuikit.ApplyTheme()
		return m, tuikit.ThemeWatchCmd()
	case tickMsg:
		st, err := loadState()
		m.state = st
		m.age = stateAge()
		if !m.firstTick {
			m.firstTick = true
			m.hold = st.Hold
			m.metronome = st.Metronome.Enabled
			m.config = st.Config
			if st.Hold {
				m.analyzeStart = time.Now()
			}
		} else if st.Hold != m.hold {
			// A hold toggled outside the TUI (the global RIGHT CTRL
			// shortcut) is adopted so the red logo box and the analysis
			// progress follow the backend.
			m.hold = st.Hold
			if st.Hold {
				m.analyzeStart = time.Now()
			}
		}
		if err != nil {
			m.loadErr = err.Error()
		} else {
			m.loadErr = ""
		}
		return m, m.refreshCmd()
	case statusExpireMsg:
		if msg.seq == m.statusSeq {
			m.status = ""
		}
		return m, nil
	}
	return m, nil
}

// releaseHold stops the progression scout.
func (m *model) releaseHold() {
	if !m.hold {
		return
	}
	m.hold = false
	if err := writeHold(false); err != nil {
		m.status = "hold release failed: " + err.Error()
	}
}

func (m *model) toggleMetronome() {
	if m.metronome {
		m.metronome = false
		if err := writeMetronome(false); err != nil {
			m.status = "metronome toggle failed: " + err.Error()
			return
		}
		m.status = "metronome off"
		return
	}
	m.metronome = true
	if err := writeMetronome(true); err != nil {
		m.status = "metronome toggle failed: " + err.Error()
		return
	}
	if bpm := m.state.Analyzer.BPM; bpm > 0 {
		m.status = fmt.Sprintf("metronome on @ %.0f BPM", bpm)
	} else {
		m.status = "metronome on (no BPM yet — hold to find the beat)"
	}
}

// saveLocalConfigSafe is a thin wrapper kept for symmetry with the config
// writes done through the backend.
func saveLocalConfigSafe(cfg Config) error {
	saveLocalConfig(cfg)
	return nil
}

// appVersion is the version of this SCRIPT (the jamjamjam-plugin module),
// shown top-left on the first page only.
const appVersion = "1.0.0"

func (m model) View() string {
	if m.quit {
		return ""
	}
	if m.w == 0 || m.h == 0 {
		return "loading…"
	}
	if time.Now().Before(m.splashUntil) {
		// Splash: the same boxed "mosquito jamjamjam" title block every
		// mosquito TUI shows, for a beat or two before the panel appears.
		return tuikit.FrameScreen(m.w, m.h, "",
			tuikit.BoxedMosquito()+"\n"+tuikit.MosquitoSubtitle("jamjamjam", m.w), "")
	}
	if m.settings {
		return m.settingsView()
	}
	if m.help {
		return m.helpView()
	}
	if m.age < 0 {
		title := tuikit.StyleAccent.Render("jamjamjam")
		body := tuikit.StyleMuted.Render("waiting for the backend (analysis not running)…")
		return tuikit.FrameScreen(m.w, m.h, title, body,
			tuikit.BottomBar(m.status, tuikit.StyleHelp.Render("q quit"), m.w))
	}
	title := m.titleLine()
	body := m.body()
	bar := tuikit.BottomBar(m.status, m.hintBar(), m.w)
	return tuikit.FrameScreenVersion(m.w, m.h, title, body, bar, "v"+appVersion)
}

// logoWordmark renders the "jamjamjam" subtitle art, horizontally centred as a
// block and framed by a red box while the analysis hold is active.
func (m model) logoWordmark() string {
	art := tuikit.MosquitoSubtitle("jamjamjam", m.w)
	if art == "" {
		return ""
	}
	if m.hold {
		// True theme red (ColorRed, not the warm orange ColorErr): the box
		// around the wordmark must read as an unmistakable "recording" red.
		art = lipgloss.NewStyle().
			Border(lipgloss.RoundedBorder()).
			BorderForeground(tuikit.ColorRed).
			Padding(0, 2).
			Render(art)
	}
	return m.centerBlockText(art)
}

// hintBar builds the single greyed shortcut line with the analyze button
// right-aligned on the same row.
func (m model) hintBar() string {
	hint := tuikit.StyleHelp.Render("hold Right Ctrl · m metronome · r reset · s settings · ? help · q quit")
	button := m.analyzeButton()
	return lipglossJoin(hint, button, m.w)
}

// titleLine is the compact header: key/BPM left, tuner + input right.
func (m model) titleLine() string {
	left := ""
	key := m.state.Analyzer.Key
	if key == "" {
		left += tuikit.StyleMuted.Render("key —")
	} else {
		left += tuikit.StyleHeader.Render("KEY "+key) +
			fmt.Sprintf(" (%.0f%%)", m.state.Analyzer.KeyConfidence*100)
	}
	if m.state.Analyzer.BPM > 0 {
		left += "  " + tuikit.StyleHeader.Render(fmt.Sprintf("BPM %.0f", m.state.Analyzer.BPM))
	} else {
		left += "  " + tuikit.StyleMuted.Render("BPM --")
	}
	if sig := m.state.Analyzer.TimeSignature; sig != "" {
		left += "  " + tuikit.StyleMuted.Render(sig)
	}
	if m.state.NeedsReset {
		left += "  " + tuikit.StyleWarn.Render("reset recommended")
	}
	right := m.tunerText()
	if m.state.Metronome.Enabled {
		right += "  " + tuikit.StyleWarn.Render(fmt.Sprintf("♪ M %.0f", m.state.Metronome.BPM))
	}
	return lipglossJoin(left, right, m.w)
}

// tunerText renders the microphone tuner. The whole tuner is always shown
// (note + cents + needle gauge); with no note it reads "no note" rather than a
// bare dash. No input-source label sits next to it.
func (m model) tunerText() string {
	if !m.state.Mic.Available || m.state.Mic.Muted {
		return tuikit.StyleWarn.Render("TUNER mic muted") + " " + tuikit.StyleMuted.Render(m.tunerGauge(0, false))
	}
	t := m.state.Tuner
	if !t.Active {
		return tuikit.StyleMuted.Render("TUNER no note") + " " + tuikit.StyleMuted.Render(m.tunerGauge(0, false))
	}
	note := fmt.Sprintf("%s%d", t.Note, t.Octave)
	cents := fmt.Sprintf("%+d¢", t.Cents)
	return tuikit.StyleMuted.Render("TUNER ") + tuikit.StyleAccent.Render(note) +
		" " + tuikit.StyleMuted.Render(cents) + " " + tuikit.StyleMuted.Render(m.tunerGauge(t.Cents, true))
}

// helpView is the "?" overlay: a compact boxed list of the shortcuts.
func (m model) helpView() string {
	rows := []string{
		tuikit.StyleHeader.Render("HOLD") + "  " + tuikit.StyleMuted.Render("hold Right Ctrl to record the chord progression"),
		tuikit.StyleHeader.Render("m") + "  " + tuikit.StyleMuted.Render("toggle the metronome (clicks at the detected BPM)"),
		tuikit.StyleHeader.Render("r") + "  " + tuikit.StyleMuted.Render("reset the analysis (key, BPM, chord memory)"),
		tuikit.StyleHeader.Render("s") + "  " + tuikit.StyleMuted.Render("settings (note naming)"),
		tuikit.StyleHeader.Render("?") + "  " + tuikit.StyleMuted.Render("toggle this help"),
		tuikit.StyleHeader.Render("esc / q") + "  " + tuikit.StyleMuted.Render("quit"),
		"",
		tuikit.StyleMuted.Render("On the neck: R = root, digits = scale degrees, high strings on top."),
	}
	body := strings.Join(rows, "\n")
	return tuikit.FrameScreen(m.w, m.h, tuikit.StyleAccent.Render("jamjamjam · help"), body,
		tuikit.BottomBar("", tuikit.StyleHelp.Render("? / esc / q close"), m.w))
}

// settingsView is the "s" overlay: the TUI-owned settings.
func (m model) settingsView() string {
	rows := []string{
		tuikit.StyleHeader.Render("NOTE NAMING") + "  " + tuikit.StyleAccent.Render("["+m.config.NoteNaming+"]") +
			"   " + tuikit.StyleMuted.Render("press n to toggle flats/sharps"),
		"",
		tuikit.StyleMuted.Render("esc / s back · q quit"),
	}
	body := strings.Join(rows, "\n")
	return tuikit.FrameScreen(m.w, m.h, tuikit.StyleAccent.Render("jamjamjam · settings"), body,
		tuikit.BottomBar(m.status, tuikit.StyleHelp.Render("n naming · esc back"), m.w))
}
