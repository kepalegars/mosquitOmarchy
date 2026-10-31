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
		{Display: "DEFAULT", Heading: true},
		{Display: "  Default audio interface: " + def, Value: "default"},
		{Display: "CARDS", Heading: true},
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

// betaReverseText explains the real harness. The capture/replay code is
// harness/mixbay-reverse.py, deployed as ~/.local/bin/mixbay-reverse; the TUI
// launches it through ExecProcess so sudo and the guided prompts own the
// terminal.
func betaReverseText(name string) string {
	return `Reverse engineering — ` + name + `

The real harness is installed as mixbay-reverse. It captures usbmon traffic,
diffs a quiet baseline against one action you perform, and saves the observed
transfers. Replay sends ONLY captured bytes, in the captured order, after a
confirmation.

From a terminal:

  mixbay-reverse list
  mixbay-reverse capture --name "` + name + `"
  mixbay-reverse sessions
  mixbay-reverse show <label>
  mixbay-reverse replay --label <label> --dry-run
  mixbay-reverse replay --label <label> --yes

Protocol:

  1. Quiet baseline (default 3 s), card and vendor app untouched.
  2. You perform ONE action (one knob, one switch, one button).
  3. Action capture (default 6 s), then a diff:
       - new transfer (e.g. a SET_CUR),
       - same request with a different payload (a knob changing value),
       - identical periodic polling is ignored.
  4. Label it (gain:input1, volume:output1, phantom:input1, …) and save.
  5. Review capture.txt; replay with --dry-run first, then --yes.

For a vendor app that only runs on Windows, run it in a Windows VM with USB
passthrough. The host still sees the transfers through usbmon. Captures live in
~/.config/mosquitomixbay/reverse/<card>/<timestamp>/.

Known traps: read-modify-write sequences, timing, multi-byte HID reports, and
firmware that re-enumerates. Never send invented frames. Nothing is written to
the card until a captured sequence is replayed and verified. Until then the
beta row stays "beta" and only exposes volume/mute.
`
}

// ssl12SetupCmd suspends the TUI and runs the douze installer in the real
// terminal, so gum/pkexec/sudo prompts keep working. The wrapper is deployed
// by setup-mosquitomixbay.sh with the repo path baked in.
type ssl12SetupMsg struct{ err error }

func ssl12SetupCmd() tea.Cmd {
	c := exec.Command("mixbay-setup-ssl12")
	return tea.ExecProcess(c, func(err error) tea.Msg { return ssl12SetupMsg{err: err} })
}
