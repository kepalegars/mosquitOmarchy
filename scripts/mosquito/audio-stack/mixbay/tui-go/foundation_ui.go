package main

import (
	"encoding/json"
	"fmt"
	"os/exec"

	tea "github.com/charmbracelet/bubbletea"
	tuikit "mosquitomarchy.local/tui-kit"
)

// foundationCard is one row of the Settings → Audio foundation menu.
type foundationCard struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Version   string `json:"version"`
	Installed bool   `json:"installed"`
	Online    bool   `json:"online"`
	Beta      bool   `json:"beta"`
	Rate      *int   `json:"rate"`
}

type foundationState struct {
	OK          bool             `json:"ok"`
	Default     string           `json:"default"`
	Devices     []foundationCard `json:"devices"`
	Connections []foundationCard `json:"connections"`
}

type foundationMsg struct {
	state foundationState
	err   error
}

func foundationStatusCmd() tea.Cmd {
	return func() tea.Msg {
		out, err := exec.Command("mixbay-audio-foundation", "--status", "--json").Output()
		if err != nil {
			return foundationMsg{err: err}
		}
		var st foundationState
		if err := json.Unmarshal(out, &st); err != nil {
			return foundationMsg{err: err}
		}
		return foundationMsg{state: st}
	}
}

// foundationActionMsg is the result of an install/remove/set-default action.
type foundationActionMsg struct {
	action string
	id     string
	err    error
}

// foundationActionCmd runs apply/remove in the real terminal (sudo/pkexec and
// gum prompts must stay usable) and adds --restart: the menu warning already
// told the user the audio graph may cut for a second.
func foundationActionCmd(action, id string) tea.Cmd {
	args := []string{"--" + action, "--device", id, "--restart"}
	c := exec.Command("mixbay-audio-foundation", args...)
	return tea.ExecProcess(c, func(err error) tea.Msg {
		return foundationActionMsg{action: action, id: id, err: err}
	})
}

func foundationSetDefaultCmd(id string) tea.Cmd {
	return func() tea.Msg {
		err := exec.Command("mixbay-audio-foundation", "--set-default", id).Run()
		return foundationActionMsg{action: "default", id: id, err: err}
	}
}

func foundationResetHistoryCmd() tea.Cmd {
	return func() tea.Msg {
		err := exec.Command("mixbay-audio-foundation", "--reset-history").Run()
		return foundationActionMsg{action: "reset", err: err}
	}
}

type startupMsg struct{ err error }

// startupApplyCmd re-reads ui.json and writes/removes the autostart line.
func startupApplyCmd() tea.Cmd {
	return func() tea.Msg {
		err := exec.Command("mixbay-startup", "--apply").Run()
		return startupMsg{err: err}
	}
}

func (m model) foundationItems() []tuikit.PickerItem {
	def := "none"
	for _, c := range m.foundation.Connections {
		if c.ID == m.foundation.Default {
			def = c.Name
			break
		}
	}
	if def == "none" && m.foundation.Default != "" {
		def = m.foundation.Default
	}
	items := []tuikit.PickerItem{
		{Display: "Default", Heading: true},
		{Display: "  Default audio interface: " + def, Value: "default"},
		{Display: "Cards", Heading: true},
	}
	for _, c := range m.foundation.Devices {
		installed := "not set"
		if c.Installed {
			installed = "installed"
		}
		online := "offline"
		if c.Online {
			online = "online"
		}
		rate := ""
		if c.Rate != nil {
			rate = fmt.Sprintf(" %d Hz", *c.Rate)
		}
		flag := ""
		if c.Beta {
			flag = "  [beta]"
		}
		items = append(items, tuikit.PickerItem{
			Display: fmt.Sprintf("  %-38s %-8s %-9s %-7s%s", cardLabel(c.Name, c.Version), installed, online, rate, flag),
			Value:   "card:" + c.ID,
		})
	}
	if m.foundationLoading && len(m.foundation.Devices) == 0 {
		items = append(items, tuikit.PickerItem{Display: "  loading…", Disabled: true})
	}
	items = append(items,
		tuikit.PickerItem{Display: "Refresh", Value: "refresh"},
		tuikit.PickerItem{Display: "Reset connection history", Value: "reset-history"},
		tuikit.PickerItem{Display: "Back", Value: "back"},
	)
	return items
}

func cardLabel(name, version string) string {
	if version == "" {
		return name
	}
	return name + " - " + version
}

func (m model) foundationDefaultItems() []tuikit.PickerItem {
	var items []tuikit.PickerItem
	for _, c := range m.foundation.Connections {
		mark := "  "
		if c.ID == m.foundation.Default {
			mark = "● "
		}
		items = append(items, tuikit.PickerItem{
			Display: mark + cardLabel(c.Name, c.Version),
			Value:   "card:" + c.ID,
		})
	}
	if len(items) == 0 {
		items = append(items, tuikit.PickerItem{Display: "  no interface in the connection history", Disabled: true})
	}
	items = append(items, tuikit.PickerItem{Display: "Back", Value: "back"})
	return items
}

func (m model) foundationCardByID(id string) (foundationCard, bool) {
	for _, c := range m.foundation.Devices {
		if c.ID == id {
			return c, true
		}
	}
	return foundationCard{}, false
}

// ssl12SetupCmd suspends the TUI and runs the douze installer in the real
// terminal, so gum/pkexec/sudo prompts keep working. The wrapper is deployed
// by setup-mosquitomixbay.sh with the repo path baked in.
type ssl12SetupMsg struct{ err error }

func ssl12SetupCmd() tea.Cmd {
	c := exec.Command("mixbay-setup-ssl12")
	return tea.ExecProcess(c, func(err error) tea.Msg { return ssl12SetupMsg{err: err} })
}
