package main

import (
	"encoding/json"
	"fmt"
	"os/exec"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"mosquitomarchy.local/mosquitomixbay-tui/drivers"
	tuikit "mosquitomarchy.local/tui-kit"
)

// Add an audio interface — scan connected USB cards, offer the ones Mixbay
// does not support natively as beta interfaces. The first slice only stores
// the card and runs it through ALSA level 1; the reverse-engineering harness
// is the next slice (see betaReverseText).
type scanCard struct {
	Name    string
	Match   string
	Profile string
}

type scanMsg struct {
	cards []scanCard
	err   error
}

type betaAddMsg struct {
	name string
	err  error
}

func scanCardsCmd() tea.Cmd {
	return func() tea.Msg {
		// Keep the connection log in sync with the scan, including native
		// cards the user is not adding this time.
		_ = exec.Command("mixbay-audio-foundation", "--track").Run()
		out, err := exec.Command("pactl", "-f", "json", "list", "cards").Output()
		if err != nil {
			return scanMsg{err: err}
		}
		var raw []struct {
			Name          string            `json:"name"`
			ActiveProfile string            `json:"active_profile"`
			Properties    map[string]string `json:"properties"`
		}
		if err := json.Unmarshal(out, &raw); err != nil {
			return scanMsg{err: err}
		}
		var cards []scanCard
		for _, c := range raw {
			// USB audio only: internal PCI/platform cards and the ALSA
			// loopback are not interfaces the user can reverse-engineer.
			if !strings.HasPrefix(c.Name, "alsa_card.usb-") {
				continue
			}
			desc := c.Properties["device.description"]
			cardName := c.Properties["alsa.card_name"]
			if desc == "" {
				desc = cardName
			}
			if desc == "" {
				desc = c.Name
			}
			match := cardName
			if match == "" {
				match = desc
			}
			if isNativeCard(desc + " " + cardName + " " + c.Name) {
				continue
			}
			cards = append(cards, scanCard{Name: desc, Match: match, Profile: c.ActiveProfile})
		}
		return scanMsg{cards: cards}
	}
}

func isNativeCard(s string) bool {
	l := strings.ToLower(s)
	for _, native := range []string{
		"evo8", "evo 8", "evo4", "evo 4",
		"solid state logic", "ssl 12", "ssl12",
		"fireface", "ucx ii", "ucx2", "ugm192", "ugm 192",
	} {
		if strings.Contains(l, native) {
			return true
		}
	}
	return false
}

func betaAddCmd(name, match string) tea.Cmd {
	return func() tea.Msg {
		_, err := drivers.AddBetaDevice(name, match)
		return betaAddMsg{name: name, err: err}
	}
}

// reverseHarnessMsg is the result of the real usbmon capture harness. The
// harness owns the terminal (sudo prompt, guided prompts), so the TUI only
// reports the outcome and lets the user inspect the saved session.
type reverseHarnessMsg struct{ err error }

func reverseHarnessCmd(name, match string) tea.Cmd {
	path, err := exec.LookPath("mixbay-reverse")
	if err != nil {
		return func() tea.Msg {
			return reverseHarnessMsg{err: fmt.Errorf("mixbay-reverse not installed — re-run setup-mosquitomixbay.sh")}
		}
	}
	args := []string{"capture"}
	if name != "" {
		args = append(args, "--name", name)
	}
	if match != "" {
		args = append(args, "--match", match)
	}
	c := exec.Command(path, args...)
	return tea.ExecProcess(c, func(err error) tea.Msg { return reverseHarnessMsg{err: err} })
}

func (m model) addInterfaceItems() []tuikit.PickerItem {
	items := []tuikit.PickerItem{{Display: "CONNECTED, NOT NATIVE", Heading: true}}
	for i, c := range m.scanCards {
		items = append(items, tuikit.PickerItem{
			Display: fmt.Sprintf("  %-32s %s", c.Name, c.Profile),
			Value:   fmt.Sprintf("scan:%d", i),
		})
	}
	if m.scanLoading && len(m.scanCards) == 0 {
		items = append(items, tuikit.PickerItem{Display: "  scanning…", Disabled: true})
	}
	if !m.scanLoading && len(m.scanCards) == 0 {
		items = append(items, tuikit.PickerItem{Display: "  no unsupported USB interface found", Disabled: true})
	}
	items = append(items,
		tuikit.PickerItem{Display: "Refresh", Value: "refresh"},
		tuikit.PickerItem{Display: "Back", Value: "back"},
	)
	return items
}
