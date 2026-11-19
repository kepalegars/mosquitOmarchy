package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
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
	// Key is the stable pactl card name (alsa_card.usb-…). The watcher uses
	// it to remember an unsupported card across events.
	Key   string
	Name  string
	Match string
	// USB is device.product.name, the string the reverse harness matches on.
	// Match stays the ALSA card name, which is what the card spec stores.
	USB string
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
		out = append(out, scanCard{
			Key: c.Name, Name: desc, Match: match,
			USB: c.Properties["device.product.name"],
		})
	}
	return out, nil
}

type scanMsg struct {
	cards []scanCard
	err   error
}

type betaAddMsg struct {
	name    string
	match   string
	usb     string
	inputs  int
	outputs int
	err     error
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

func betaAddCmd(name, match, usb string) tea.Cmd {
	return func() tea.Msg {
		dev, err := drivers.AddBetaDevice(name, match)
		// The harness speaks output *channels*; a card declares pairs.
		return betaAddMsg{
			name: name, match: match, usb: usb,
			inputs: dev.Inputs, outputs: dev.Outputs * 2, err: err,
		}
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

// cardsChangedMsg is a PipeWire card event (plug, unplug or profile change).
// retry marks the subscription dropping out, so the caller re-arms on a timer
// instead of spinning through failed processes.
type cardsChangedMsg struct{ retry bool }

// cardEventCmd waits for the next PipeWire card event instead of polling: an
// idle Mixbay costs nothing, and a card is noticed as soon as PipeWire sees it.
func cardEventCmd() tea.Cmd {
	return func() tea.Msg {
		cmd := exec.Command("pactl", "subscribe")
		stdout, err := cmd.StdoutPipe()
		if err != nil {
			return cardsChangedMsg{retry: true}
		}
		if err := cmd.Start(); err != nil {
			return cardsChangedMsg{retry: true}
		}
		defer func() {
			_ = cmd.Process.Kill()
			_ = cmd.Wait()
		}()
		sc := bufio.NewScanner(stdout)
		for sc.Scan() {
			if strings.Contains(sc.Text(), "on card") {
				return cardsChangedMsg{}
			}
		}
		return cardsChangedMsg{retry: true}
	}
}

// pendingInstallFile is the notification's click request. A config file (not
// /tmp) means a click that launches Mixbay survives the window taking a while.
func pendingInstallFile() string {
	return filepath.Join(profiles.ConfigDir(), "pending-install.json")
}

// pendingOpenFile is the same hand-off for a card that is already installed:
// the click only has to land on its page, not download anything.
func pendingOpenFile() string {
	return filepath.Join(profiles.ConfigDir(), "pending-open.json")
}

// takePending consumes one click request, so it runs exactly once.
func takePending(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	_ = os.Remove(path)
	var req struct {
		ID string `json:"id"`
	}
	if json.Unmarshal(data, &req) != nil {
		return ""
	}
	return req.ID
}

// takePendingInstall consumes the request, so one click installs once.
func takePendingInstall() string { return takePending(pendingInstallFile()) }

// takePendingOpen consumes a "show this card" request.
func takePendingOpen() string { return takePending(pendingOpenFile()) }

// installRequestMsg starts the profile install a notification click asked for.
type installRequestMsg struct{ id string }

// cardOpenMsg lands on an installed card's page.
type cardOpenMsg struct{ id string }

// cardSignal is SIGUSR1 from mixbay-startup --install-card/--open-card:
// Mixbay is already open, so a new process cannot be launched to pick the
// request file up.
var cardSignal = make(chan os.Signal, 1)

func init() { signal.Notify(cardSignal, syscall.SIGUSR1) }

type cardRequestedMsg struct{}

func cardSignalCmd() tea.Cmd {
	return func() tea.Msg {
		<-cardSignal
		return cardRequestedMsg{}
	}
}

// reverseHarnessMsg is the result of the real usbmon capture harness. The
// harness owns the terminal (sudo prompt, guided prompts), so the TUI only
// reports the outcome and returns to the main menu.
type reverseHarnessMsg struct{ err error }

// harnessArgs is what the TUI knows about the card before any capture. Inputs
// and outputs are the counts the stored card can actually drive; the harness
// must not propose more.
type harnessArgs struct {
	Name, Match, USB string
	Inputs, Outputs  int
	Guided           bool
}

func reverseHarnessCmd(a harnessArgs) tea.Cmd {
	path, err := exec.LookPath("mixbay-reverse")
	if err != nil {
		return func() tea.Msg {
			return reverseHarnessMsg{err: fmt.Errorf("mixbay-reverse not installed — re-run setup-mosquitomixbay.sh")}
		}
	}
	args := []string{"capture"}
	if a.Guided {
		args = append(args, "--guided")
	}
	if a.Name != "" {
		args = append(args, "--name", a.Name)
	}
	if a.Match != "" {
		args = append(args, "--match", a.Match)
	}
	if a.USB != "" {
		args = append(args, "--usb", a.USB)
	}
	if a.Inputs > 0 {
		args = append(args, "--inputs", strconv.Itoa(a.Inputs))
	}
	if a.Outputs > 0 {
		args = append(args, "--outputs", strconv.Itoa(a.Outputs))
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
