// Command mosquito-hotspot-tui is the hotspot settings TUI: SSID, password
// and band for the mosquito-hotspot backend, opened from the Wi-Fi panel's
// gear button. One centered form (FrameScreen centers the body): arrows move,
// Enter edits (SSID/password) or cycles (band). There is no save button and
// no success chatter: quitting writes back silently when something changed
// (password on stdin, never argv), and cancelling is just quitting. Reset
// removes the NetworkManager profile so the next open starts from the
// defaults again. --qr prints a scannable code for the current settings and
// leaves, which is what the panel's "Show QR code" row opens.
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

// hotspotArt is the hand-drawn ASCII banner ("HOTSPOT", block letters —
// there is no figlet-style font in tui-kit, only the mosquito wordmarks,
// so this one lives here). All lines share the same visible width so the
// centered frame keeps it straight.
var hotspotArt = []string{
	"█░█ █▀█ ▀█▀ █▀▀ █▀█ █▀█ ▀█▀",
	"█▀█ █░█ ░█░ ▀▀█ █▀▀ █░█ ░█░",
	"▀░▀ ▀▀▀ ░▀░ ▀▀▀ ▀░░ ▀▀▀ ░▀░",
}

type model struct {
	w, h       int
	ssid       string
	password   string
	band       string // "a" (5 GHz) | "bg" (2.4 GHz)
	active     bool
	configured bool
	// The values the form opened with: quitting saves back silently only
	// when something actually changed.
	origSsid, origPassword, origBand string
	row                              int // 0 ssid, 1 password, 2 band, 3 quit
	editing                          int // -1 form, 0 ssid, 1 password
	input                            tuikit.TextInput
	toast                            tuikit.Toast
}

type saveResultMsg struct {
	err error
}

func initialModel() model {
	st := loadStatus()
	m := model{editing: -1, band: "a"}
	if st.Configured {
		// Stored profiles can carry multi-line garbage (seen live); the
		// form only ever shows and saves the first line.
		m.ssid = cleanLine(st.Ssid)
		m.password = cleanLine(st.Password)
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
	m.origSsid, m.origPassword, m.origBand = m.ssid, m.password, m.band
	return m
}

// dirty reports whether the form differs from what the backend reported.
func (m model) dirty() bool {
	return m.ssid != m.origSsid || m.password != m.origPassword || m.band != m.origBand
}

func cleanLine(s string) string {
	if i := strings.IndexAny(s, "\r\n"); i >= 0 {
		s = s[:i]
	}
	return strings.TrimSpace(s)
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
		if m.editing >= 0 {
			return m.updateInput(msg)
		}
		switch msg.String() {
		case "ctrl+c", "esc", "q":
			return m.quit()
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
		// The quiet quit: success AND failure both leave silently, per the
		// no-chatter rule. A failed save keeps nothing — the form is gone
		// with the terminal — which is exactly why invalid input never
		// reaches this point (quit() holds the form open with a hint).
		return m, tea.Quit
	}
	return m, nil
}

// quit leaves, saving back silently first when the form changed. Invalid
// input holds the form open with a hint instead: quitting on garbage would
// silently throw the user's edits away.
func (m model) quit() (tea.Model, tea.Cmd) {
	if !m.dirty() {
		return m, tea.Quit
	}
	if strings.TrimSpace(m.ssid) == "" {
		m.toast, _ = m.toast.SetWarn("network name is empty — fix it or it stays unsaved")
		return m, nil
	}
	if len(m.password) < 8 {
		m.toast, _ = m.toast.SetWarn("password needs 8+ characters — fix it or it stays unsaved")
		return m, nil
	}
	return m, saveCmd(m.ssid, m.password, m.band)
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
		return m.quit()
	case 4:
		return m, resetCmd()
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

// resetCmd drops the hotspot profile; the next status read then reports
// "not configured" and the form refills the defaults on the next open.
func resetCmd() tea.Cmd {
	return func() tea.Msg {
		var con string
		out, err := exec.Command(backendBin(), "status").Output()
		if err == nil {
			var st struct {
				Name string `json:"name"`
			}
			_ = json.Unmarshal(out, &st)
			con = st.Name
		}
		if con == "" {
			con = "mosquito-hotspot"
		}
		if out, err := exec.Command("nmcli", "connection", "delete", "id", con).CombinedOutput(); err != nil {
			msg := strings.TrimSpace(string(out))
			if msg == "" {
				msg = err.Error()
			}
			return saveResultMsg{err: fmt.Errorf("%s", msg)}
		}
		return saveResultMsg{}
	}
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
	// Plain art, no accent fill: on a dark theme the accent block read as a
	// shadow behind the letters and made the banner smudge. Same characters,
	// no style — the frame around it is decoration enough.
	for _, l := range hotspotArt {
		b.WriteString(l + "\n")
	}
	b.WriteString("\n")
	if m.editing >= 0 {
		b.WriteString(m.input.View())
		if t := m.toast.View(); t != "" {
			b.WriteString("\n\n" + t)
		}
		return tuikit.FrameScreen(m.w, m.h, "", b.String(), "enter confirm · esc back")
	}
	rows := []struct {
		label string
		value string
	}{
		{"Network name", m.ssid},
		{"Password", maskPassword(m.password)},
		{"Band", bandLabel(m.band)},
		{"Quit", ""},
		{"Reset settings", ""},
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
		b.WriteString("\nnot set up yet — showing defaults\n")
	}
	if t := m.toast.View(); t != "" {
		b.WriteString("\n" + t)
	}
	bar := "↑↓ choose · enter edit · esc quit"
	return tuikit.FrameScreen(m.w, m.h, "", b.String(), bar)
}

func maskPassword(p string) string {
	if p == "" {
		return "(empty)"
	}
	return "••••••••"
}

// qr prints a scannable code for the CURRENT settings (a fresh profile uses
// the defaults) and exits — the panel's "Show QR code" row opens it in a
// terminal. WIFI:T:WPA;S:<ssid>;P:<pw>;; is the understood shape.
func qr() int {
	st := loadStatus()
	m := model{ssid: hostnameDefault(), password: "12345678", band: "a"}
	if st.Configured {
		m.ssid, m.password, m.band = cleanLine(st.Ssid), cleanLine(st.Password), st.Band
	}
	payload := "WIFI:T:WPA;S:" + m.ssid + ";P:" + m.password + ";;"
	out, err := exec.Command("qrencode", "-t", "ANSIUTF8", payload).Output()
	if err != nil {
		fmt.Fprintln(os.Stderr, "mosquito-hotspot-tui: qrencode:", err)
		return 1
	}
	fmt.Print(string(out))
	fmt.Printf("\n%s · %s\n", m.ssid, bandLabel(m.band))
	return 0
}

func main() {
	if len(os.Args) > 1 && os.Args[1] == "--qr" {
		os.Exit(qr())
	}
	m := initialModel()
	p := tea.NewProgram(m, tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		fmt.Fprintln(os.Stderr, "mosquito-hotspot-tui:", err)
		os.Exit(1)
	}
}
