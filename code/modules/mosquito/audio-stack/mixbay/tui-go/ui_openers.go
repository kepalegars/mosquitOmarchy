// Which UI a card's "Open UI & Use it" opens.
//
// The profile lists the UIs it offers (ui.openers), but only by id and label:
// the launcher is one of Mixbay's own, so a downloaded card still cannot name
// a command. Profiles written before this feature fall back to the oscmix
// defaults, which keeps an already-installed copy working after an update.
package main

import (
	tea "github.com/charmbracelet/bubbletea"
	"mosquitomarchy.local/mosquitomixbay-tui/profiles"
)

// uiLaunchers is the closed set of opener ids a profile may name.
var uiLaunchers = map[string]string{
	"web": "mixbay-oscmix-web",
	"gtk": "mixbay-oscmix-gtk",
	"qt":  "mixbay-oscmix-qt",
}

var defaultUILabels = map[string]string{
	"web": "Web UI",
	"gtk": "GTK mixer",
	"qt":  "Qt mixer",
}

// uiRowValue is the Controls row that cycles the default UI.
const uiRowValue = "default-ui"

// cardUI is one way to open a card's interface that exists on this machine.
type cardUI struct {
	ID    string
	Label string
}

func uiReady(id string) bool {
	// Qt is an upstream preview AppImage that only some builds carry.
	return id != "qt" || oscmixQtInstalled()
}

// cardUIs lists the UIs a card can open right now, in profile order. A UI
// that is not installed is left out rather than greyed: the menu only cycles
// through choices that work.
func cardUIs(c profiles.Card) []cardUI {
	openers := c.Openers()
	if len(openers) == 0 {
		if c.Spec.Setup != profiles.SetupOscmix {
			return nil
		}
		openers = []profiles.Opener{{ID: "web"}, {ID: "gtk"}, {ID: "qt"}}
	}
	var out []cardUI
	seen := map[string]bool{}
	for _, o := range openers {
		if _, known := uiLaunchers[o.ID]; !known || seen[o.ID] || !uiReady(o.ID) {
			continue
		}
		label := o.Label
		if label == "" {
			label = defaultUILabels[o.ID]
		}
		seen[o.ID] = true
		out = append(out, cardUI{ID: o.ID, Label: label})
	}
	return out
}

// cardUIs returns the openers of the card on screen.
func (m model) cardUIs() []cardUI {
	c, _, err := profiles.Effective(m.deviceID)
	if err != nil {
		return nil
	}
	return cardUIs(c)
}

// chosenUI is the opener "Open UI & Use it" uses: the saved choice while the
// profile still offers it, otherwise the first one.
func chosenUI(uis []cardUI, saved string) string {
	for _, ui := range uis {
		if ui.ID == saved {
			return saved
		}
	}
	if len(uis) > 0 {
		return uis[0].ID
	}
	return ""
}

func uiLabel(uis []cardUI, id string) string {
	for _, ui := range uis {
		if ui.ID == id {
			return ui.Label
		}
	}
	return id
}

// cycleDefaultUI moves the saved default UI through the offered ones. Enter
// and the horizontal arrows both land here.
func (m *model) cycleDefaultUI(delta int) tea.Cmd {
	uis := m.cardUIs()
	if len(uis) < 2 {
		return nil
	}
	cur := 0
	saved := m.ui.DefaultUI[m.deviceID]
	for i, ui := range uis {
		if ui.ID == saved {
			cur = i
		}
	}
	next := (cur + delta + len(uis)) % len(uis)
	if m.ui.DefaultUI == nil {
		m.ui.DefaultUI = map[string]string{}
	}
	m.ui.DefaultUI[m.deviceID] = uis[next].ID
	if err := saveUIPrefs(m.ui); err != nil {
		m.toast, _ = m.toast.SetErr("Could not save the default UI: " + err.Error())
		return nil
	}
	m.syncPicker()
	return nil
}
