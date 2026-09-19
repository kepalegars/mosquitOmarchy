package main

// kb.go — the Keybindings manager screen. The old setup-keybindings.sh is
// GONE: this screen IS the manager now, in both flavors —
//   setup mode     (Setup ▸ keybindings): status of the managed SUPER combos,
//                  category options to add one, tab-check + Enter to remove,
//                  every add/remove asks to reload Hyprland afterwards.
//   uninstall mode (Uninstall ▸ keybindings): the managed list directly,
//                  tab-check + Enter to remove, plus a Reset row that wipes
//                  EVERYTHING managed by mosquitOmarchy (precise confirm).
// The tab selection in uninstall mode PERSISTS while the user walks other
// uninstall pages, and a global uninstall run removes the ticked combos too.

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/charmbracelet/bubbles/key"
	tea "github.com/charmbracelet/bubbletea"
	tuikit "mosquitomarchy.local/tui-kit"
)

// KbRec is one managed keybinding (one o.bind line in the marker block).
type KbRec struct {
	Key      string `json:"key"`
	Label    string `json:"label"`
	Cmd      string `json:"cmd"`
	Type     string `json:"type"` // "cmd" | "launch"
	Replaces string `json:"replaces"`
}

type kbMsg struct {
	items []KbRec
	err   error
}

type kbFreeMsg struct {
	keys []string
	err  error
}

// KbCatItem is one bindable thing from a category catalog.
type KbCatItem struct {
	Label string // human name
	Cmd   string // command / launch target ("" in the custom category)
	Type  string // "cmd" | "launch"
}

// kbCatalog is the add-a-keybinding catalog: category id → rows. "custom"
// has no rows; it prompts for label + command instead.
var kbCatalog = []struct {
	ID    string
	Title string
	Items []KbCatItem
}{
	{"apps", "package app", []KbCatItem{
		{"Ableton Live", "ableton-live", "launch"},
		{"Guitar Pro 8", "guitarpro", "launch"},
		{"Bitwig Studio", "bitwig-studio", "launch"},
		{"DaVinci Resolve", "davinci-resolve", "launch"},
		{"HandBrake", "ghb", "launch"},
		{"REAPER", "reaper", "launch"},
	}},
	{"funcs", "quick function", []KbCatItem{
		{"Brightness +5%", "$HOME/.local/bin/backlight +5%", "cmd"},
		{"Brightness -5%", "$HOME/.local/bin/backlight 5%-", "cmd"},
		{"Brightness maximum", "$HOME/.local/bin/backlight 100%", "cmd"},
		{"Brightness minimum", "$HOME/.local/bin/backlight 0%", "cmd"},
		{"Ultra-save toggle", "sudo -n $HOME/.local/bin/ultra-save toggle", "cmd"},
		{"Mega-caffeine on", "mega-caffeine on", "cmd"},
		{"Mega-caffeine off", "mega-caffeine off", "cmd"},
		{"Mega-caffeine toggle", "mega-caffeine toggle", "cmd"},
		{"mosquitOmarchy setup", "foot -e $HOME/mosquitOmarchy/setup-customarchy.sh", "cmd"},
		{"SuperFile", "foot -e spf", "cmd"},
	}},
	{"move", "Ableton Move", []KbCatItem{
		{"Move: main menu", "$HOME/.local/bin/mosquito-move-manager", "cmd"},
		{"Move: Move Manager webapp", "$HOME/.local/bin/move-manager-webapp", "launch"},
		{"Move: convert a set → MIDI", "$HOME/.local/bin/mosquito-move-manager --midi", "cmd"},
	}},
	{"custom", "custom command", nil},
}

func fetchKbCmd() tea.Cmd {
	return func() tea.Msg {
		outB, err := runQuick("kb-list")
		if err != nil {
			return kbMsg{err: err}
		}
		var items []KbRec
		for _, line := range strings.Split(string(outB), "\n") {
			line = strings.TrimSpace(line)
			if line == "" {
				continue
			}
			var r KbRec
			if err := json.Unmarshal([]byte(line), &r); err == nil && r.Key != "" {
				items = append(items, r)
			}
		}
		return kbMsg{items: items}
	}
}

func fetchKbFreeCmd() tea.Cmd {
	return func() tea.Msg {
		outB, err := runQuick("kb-free")
		if err != nil {
			return kbFreeMsg{err: err}
		}
		var keys []string
		for _, line := range strings.Split(string(outB), "\n") {
			if line = strings.TrimSpace(line); line != "" {
				keys = append(keys, line)
			}
		}
		return kbFreeMsg{keys: keys}
	}
}

// kbCheckedKeys lists the ticked combos (in list order).
func (m model) kbCheckedKeys() []string {
	var out []string
	for _, it := range m.kbItems {
		if m.kbSel[it.Key] {
			out = append(out, it.Key)
		}
	}
	return out
}

// rebuildKB renders the Keybindings MENU — the screen Enter on the Setup/
// Uninstall "Keybindings" row opens. It is a plain menu (no checkboxes): the
// managed list and the add flow each live in their own properly-named
// submenu; uninstall mode keeps the same menu (its list screen carries the
// Reset row and its tick selection persists).
func (m model) rebuildKB() navPicker {
	idx := m.kbPicker.Index()
	items := []tuikit.PickerItem{
		{Display: "Managed keybindings", Value: "managed"},
	}
	if m.kbMode == "setup" {
		items = append(items, tuikit.PickerItem{Display: "Add a keybinding", Value: "add"})
	}
	items = append(items, tuikit.PickerItem{Display: "Back", Value: "back"})
	p := newNavPicker("Keybindings — SUPER combos managed by mosquitomarchy (bindings.lua block)", items).
		SetSize(m.contentSize()).
		SetHelpKeys(key.NewBinding(key.WithKeys("enter"), key.WithHelp("enter", "open")))
	return p.SelectIndex(idx)
}

// rebuildKBList renders the "Managed keybindings" submenu: one tab-toggle row
// per managed combo (status + removal in both flavors). In uninstall mode a
// Reset row sits at the bottom — it wipes EVERY binding managed by
// mosquitomarchy (precise confirmation), leaving your own bindings and the
// Omarchy defaults untouched.
func (m model) rebuildKBList() navPicker {
	idx := m.kbListPicker.Index()
	items := make([]tuikit.PickerItem, 0, len(m.kbItems)+2)
	for _, it := range m.kbItems {
		mark := "○"
		if m.kbSel[it.Key] {
			mark = "●"
		}
		display := it.Key + "  →  " + it.Label
		if it.Replaces != "" {
			display += "  (replaces \"" + it.Replaces + "\")"
		}
		items = append(items, tuikit.PickerItem{Display: display, Value: "kb:" + it.Key, Badge: mark})
	}
	if m.kbMode == "uninstall" {
		if len(m.kbItems) == 0 {
			items = append(items, tuikit.PickerItem{Display: "No keybindings managed by mosquitOmarchy", Value: "", Disabled: true})
		}
		items = append(items, tuikit.PickerItem{Display: "Reset — remove ALL keybindings managed by mosquitOmarchy", Value: "reset"})
	}
	header := "Managed keybindings"
	if m.kbMode == "uninstall" {
		header = "Managed keybindings — tick the ones to remove"
	}
	p := newNavPicker(header, items).SetSize(m.contentSize()).
		SetHelpKeys(
			key.NewBinding(key.WithKeys("tab"), key.WithHelp("tab", "select")),
			key.NewBinding(key.WithKeys("enter"), key.WithHelp("enter", "remove")),
			key.NewBinding(key.WithKeys("esc"), key.WithHelp("esc", "back")))
	return p.SelectIndex(idx)
}

// rebuildKBCat renders the "Add a keybinding" submenu: the category options
// (no prefix — the submenu's header already says what screen this is).
func (m model) rebuildKBCat() navPicker {
	idx := m.kbCatPicker.Index()
	items := make([]tuikit.PickerItem, 0, len(kbCatalog)+1)
	for _, c := range kbCatalog {
		items = append(items, tuikit.PickerItem{Display: kbCatLabel(c.Title), Value: "cat:" + c.ID})
	}
	items = append(items, tuikit.PickerItem{Display: "Back", Value: "back"})
	return newNavPicker("Add a keybinding — choose what it does", items).SetSize(m.contentSize()).
		SetHelpKeys(key.NewBinding(key.WithKeys("enter"), key.WithHelp("enter", "pick a key")),
			key.NewBinding(key.WithKeys("esc"), key.WithHelp("esc", "back"))).
		SelectIndex(idx)
}

// kbCatLabel maps the catalog's internal title to the row label (the rows no
// longer repeat "Add a keybinding" — the submenu's header carries it).
func kbCatLabel(title string) string {
	switch title {
	case "package app":
		return "Package app"
	case "quick function":
		return "Quick function"
	case "Ableton Move":
		return "Ableton Move"
	case "custom command":
		return "Custom command"
	}
	return title
}

// rebuildKBItems renders the chosen category's rows (what the new binding
// can do), inside the "Add a keybinding" flow.
func (m model) rebuildKBItems() navPicker {
	idx := m.kbItemPicker.Index()
	items := make([]tuikit.PickerItem, 0, len(m.kbCatItems)+1)
	for i, it := range m.kbCatItems {
		items = append(items, tuikit.PickerItem{Display: it.Label, Value: fmt.Sprintf("item:%d", i)})
	}
	items = append(items, tuikit.PickerItem{Display: "Back", Value: "back"})
	return newNavPicker("Add a keybinding — choose what it does", items).SetSize(m.contentSize()).
		SetHelpKeys(key.NewBinding(key.WithKeys("enter"), key.WithHelp("enter", "pick a key")),
			key.NewBinding(key.WithKeys("esc"), key.WithHelp("esc", "back"))).
		SelectIndex(idx)
}

// rebuildKBKeys renders the still-free SUPER combos for the pending binding.
func (m model) rebuildKBKeys() navPicker {
	idx := m.kbKeyPicker.Index()
	items := make([]tuikit.PickerItem, 0, len(m.kbFree)+1)
	for _, k := range m.kbFree {
		items = append(items, tuikit.PickerItem{Display: k, Value: k})
	}
	items = append(items, tuikit.PickerItem{Display: "Back", Value: "back"})
	return newNavPicker("Pick a free key for: "+m.kbPending.Label, items).SetSize(m.contentSize()).
		SetHelpKeys(key.NewBinding(key.WithKeys("enter"), key.WithHelp("enter", "bind"))).
		SelectIndex(idx)
}
