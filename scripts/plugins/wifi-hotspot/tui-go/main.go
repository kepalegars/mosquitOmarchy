// Command mosquito-hotspot-tui is the hotspot settings TUI: SSID, password
// and band for the mosquito-hotspot backend, opened from the Wi-Fi panel's
// gear button. One centered form (FrameScreen centers the body): arrows move,
// Enter edits (SSID/password) or cycles (band), Save writes through the
// backend (password on stdin, never argv), Esc cancels.
//
// When no hotspot profile exists yet the fields come prefilled with the
// working defaults: this machine's hostname, 12345678, 5 GHz.
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	tuikit "mosquitomarchy.local/tui-kit"
)

type hotspotStatus struct {
	Ssid       string `json:"ssid"`
	Password   string `json:"password"`
	Band       string `json:"band"`
	Configured bool   `json:"configured"`
	Active     bool   `json:"active"`
}

func backendBin() string {
	if p := os.Getenv("MOSQUITO_HOTSPOT"); p != "" {
		return p
	}
	if home, err := os.UserHomeDir(); err == nil {
		return filepath.Join(home, ".local", "bin", "mosquito-hotspot")
	}
	return "mosquito-hotspot"
}

func loadStatus() hotspotStatus {
	out, err := exec.Command(backendBin(), "status").Output()
	if err != nil {
		return hotspotStatus{}
	}
	var st hotspotStatus
	_ = json.Unmarshal(out, &st)
	return st
}

func hostnameDefault() string {
	h, err := os.Hostname()
	if err != nil || h == "" {
		return "mosquito-hotspot"
	}
	if i := strings.Index(h, "."); i > 0 {
		h = h[:i]
	}
	return h
}

type model struct {
	w, h       int
	ssid       string
	password   string
	band       string // "a" (5 GHz) | "bg" (2.4 GHz)
	active     bool
	configured bool
	row        int // 0 ssid, 1 password, 2 band, 3 save, 4 cancel
	editing    int // -1 form, 0 ssid, 1 password
	input      tuikit.TextInput
	toast      tuikit.Toast
	done       bool
	doneMsg    string
	doneErr    bool
}

type saveResultMsg struct {
	err error
	out string
}

func initialModel() model {
	st := loadStatus()
	m := model{editing: -1, band: "a"}
	if st.Configured {
		m.ssid = st.Ssid
		m.password = st.Password
		if st.Band == "bg" || st.Band == "a" {
			m.band = st.Band
		}
	} else {
		m.ssid = hostnameDefault()
		m.password = "12345678"
		m.band = "a"
	}
	m.active = st.Active
	m.configured = st.Configured
	return m
}

func (m model) Init() tea.Cmd { return nil }

func bandLabel(b string) string {
	if b == "a" {
		return "5 GHz"
	}
	return "2.4 GHz"
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.w, m.h = msg.Width, msg.Height
		return m, nil
	case tea.KeyMsg:
		if m.done {
			return m, tea.Quit
		}
		if m.editing >= 0 {
			return m.updateInput(msg)
		}
		switch msg.String() {
		case "ctrl+c", "esc":
			return m, tea.Quit
		case "up", "k":
			m.row = (m.row + 4) % 5
			return m, nil
		case "down", "j":
			m.row = (m.row + 1) % 5
			return m, nil
		case "enter":
			return m.activate()
		}
		return m, nil
	case tuikit.InputResultMsg:
		return m.inputDone(msg)
	case saveResultMsg:
		if msg.err != nil {
			m.done = true
			m.doneErr = true
			m.doneMsg = msg.err.Error()
			return m, nil
		}
		m.done = true
		m.doneMsg = "hotspot saved — toggle it on from the Wi-Fi panel"
		return m, nil
	}
	return m, nil
}

func (m model) activate() (tea.Model, tea.Cmd) {
	switch m.row {
	case 0:
		m.editing = 0
		m.input = tuikit.NewTextInput("Network name:", m.ssid)
		return m, m.input.Init()
	case 1:
		m.editing = 1
		m.input = tuikit.NewPasswordInput("Password (8+ characters):", "")
		return m, m.input.Init()
	case 2:
		if m.band == "a" {
			m.band = "bg"
		} else {
			m.band = "a"
		}
		return m, nil
	case 3:
		return m, saveCmd(m.ssid, m.password, m.band)
	case 4:
		return m, tea.Quit
	}
	return m, nil
}

func (m *model) updateInput(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	var cmd tea.Cmd
	m.input, cmd = m.input.Update(msg)
	return m, cmd
}

func (m model) inputDone(msg tuikit.InputResultMsg) (tea.Model, tea.Cmd) {
	if msg.Canceled {
		m.editing = -1
		return m, nil
	}
	if m.editing == 0 {
		if strings.TrimSpace(msg.Value) != "" {
			m.ssid = strings.TrimSpace(msg.Value)
		}
	} else if m.editing == 1 {
		if msg.Value != "" {
			m.password = msg.Value
		}
	}
	m.editing = -1
	return m, nil
}

func saveCmd(ssid, password, band string) tea.Cmd {
	return func() tea.Msg {
		if strings.TrimSpace(ssid) == "" {
			return saveResultMsg{err: fmt.Errorf("network name is empty")}
		}
		if len(password) < 8 {
			return saveResultMsg{err: fmt.Errorf("password needs 8+ characters")}
		}
		cmd := exec.Command(backendBin(), "save", ssid, band)
		cmd.Stdin = bytes.NewBufferString(password + "\n")
		var serr bytes.Buffer
		cmd.Stderr = &serr
		if err := cmd.Run(); err != nil {
			msg := strings.TrimSpace(serr.String())
			if msg == "" {
				msg = err.Error()
			}
			return saveResultMsg{err: fmt.Errorf("%s", msg)}
		}
		return saveResultMsg{}
	}
}

func (m model) View() string {
	var b strings.Builder
	if m.done {
		mark := "✓ "
		if m.doneErr {
			mark = "! "
		}
		b.WriteString(mark + m.doneMsg + "\n\npress any key to close")
		return tuikit.FrameScreen(m.w, m.h, "Hotspot settings", b.String(), "enter save · esc cancel")
	}
	if m.editing >= 0 {
		b.WriteString(m.input.View())
		if t := m.toast.View(); t != "" {
			b.WriteString("\n\n" + t)
		}
		return tuikit.FrameScreen(m.w, m.h, "Hotspot settings", b.String(), "enter confirm · esc back")
	}
	rows := []struct {
		label string
		value string
	}{
		{"Network name", m.ssid},
		{"Password", maskPassword(m.password)},
		{"Band", bandLabel(m.band)},
		{"Save", ""},
		{"Cancel", ""},
	}
	for i, r := range rows {
		cursor := "  "
		if i == m.row {
			cursor = "▶ "
		}
		line := cursor + r.label
		if r.value != "" {
			line += "  " + r.value
		}
		if i == m.row {
			line = tuikit.StyleAccent.Render(line)
		}
		b.WriteString(line + "\n")
	}
	if !m.configured {
		b.WriteString("\nnot set up yet — showing defaults (this hostname, 12345678, 5 GHz)\n")
	} else {
		b.WriteString("\nhotspot profile exists — values above are current\n")
	}
	if t := m.toast.View(); t != "" {
		b.WriteString("\n" + t)
	}
	bar := "↑↓ choose · enter edit/save · esc cancel"
	return tuikit.FrameScreen(m.w, m.h, "Hotspot settings", b.String(), bar)
}

func maskPassword(p string) string {
	if p == "" {
		return "(empty — kept/confirmed on save)"
	}
	return "••••••••"
}

func main() {
	m := initialModel()
	p := tea.NewProgram(m, tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		fmt.Fprintln(os.Stderr, "mosquito-hotspot-tui:", err)
		os.Exit(1)
	}
}
