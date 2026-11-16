package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"sort"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"mosquitomarchy.local/mosquitomixbay-tui/drivers"
	"mosquitomarchy.local/mosquitomixbay-tui/profiles"
	tuikit "mosquitomarchy.local/tui-kit"
)

// Add an audio interface — scan connected USB cards, offer the ones Mixbay
// does not support natively as beta interfaces. The real guided usbmon harness
// is launched right after the card is stored (see reverseHarnessCmd).
type scanCard struct {
	Name  string
	Match string
}

// usbCardsFromPactl extracts the connected USB interfaces from
// `pactl -f json list cards`. Both the Add-interface scan and the hotplug
// check read the same fields, so the extraction lives here once.
func usbCardsFromPactl(raw []byte) ([]scanCard, error) {
	var cards []struct {
		Name       string            `json:"name"`
		Properties map[string]string `json:"properties"`
	}
	if err := json.Unmarshal(raw, &cards); err != nil {
		return nil, err
	}
	var out []scanCard
	for _, c := range cards {
		// USB audio only: internal PCI/platform cards and the ALSA loopback
		// are not interfaces the user can reverse-engineer.
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
		out = append(out, scanCard{Name: desc, Match: match})
	}
	return out, nil
}

type scanMsg struct {
	cards []scanCard
	err   error
}

type betaAddMsg struct {
	name  string
	match string
	err   error
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
		all, err := usbCardsFromPactl(out)
		if err != nil {
			return scanMsg{err: err}
		}
		var cards []scanCard
		for _, c := range all {
			if isNativeCard(c.Name + " " + c.Match) {
				continue
			}
			cards = append(cards, c)
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
		return betaAddMsg{name: name, match: match, err: err}
	}
}

// hotplugMsg carries the profiles the repo offers for the interfaces
// connected right now. key is a stable signature of that set, so the repo is
// only checked when a card appears or disappears.
type hotplugMsg struct {
	ok     bool
	key    string
	offers []profiles.Offer
}

// hotplugCheckCmd looks at the cards connected NOW (the pactl view, not the
// persistent connection log: an unplugged card must never prompt) and asks the
// repo index which supported profiles are missing.
func hotplugCheckCmd() tea.Cmd {
	return func() tea.Msg {
		_ = exec.Command("mixbay-audio-foundation", "--track").Run()
		out, err := exec.Command("pactl", "-f", "json", "list", "cards").Output()
		if err != nil {
			return hotplugMsg{}
		}
		cards, err := usbCardsFromPactl(out)
		if err != nil {
			return hotplugMsg{}
		}
		var keyParts []string
		entries := make([]profiles.ConnEntry, 0, len(cards))
		for _, c := range cards {
			keyParts = append(keyParts, c.Name+"|"+c.Match)
			entries = append(entries, profiles.ConnEntry{Name: c.Name, Match: c.Match})
		}
		sort.Strings(keyParts)
		key := strings.Join(keyParts, "\n")
		if key == "" {
			return hotplugMsg{ok: true}
		}
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		offers, err := profiles.CheckUpdates(ctx, entries)
		if err != nil {
			// No index and no cache: leave key empty so the next check retries.
			return hotplugMsg{}
		}
		return hotplugMsg{ok: true, key: key, offers: offers}
	}
}

// reverseHarnessMsg is the result of the real usbmon capture harness. The
// harness owns the terminal (sudo prompt, guided prompts), so the TUI only
// reports the outcome and returns to the main menu.
type reverseHarnessMsg struct{ err error }

func reverseHarnessCmd(name, match string, guided bool) tea.Cmd {
	path, err := exec.LookPath("mixbay-reverse")
	if err != nil {
		return func() tea.Msg {
			return reverseHarnessMsg{err: fmt.Errorf("mixbay-reverse not installed — re-run setup-mosquitomixbay.sh")}
		}
	}
	args := []string{"capture"}
	if guided {
		args = append(args, "--guided")
	}
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
	items := []tuikit.PickerItem{{Display: "Connected, not native", Heading: true}}
	for i, c := range m.scanCards {
		items = append(items, tuikit.PickerItem{
			Display: "  " + c.Name,
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
