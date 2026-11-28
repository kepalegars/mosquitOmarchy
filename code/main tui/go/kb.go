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
	"bytes"
	"encoding/json"
	"fmt"
	"sort"
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

// kbCheckMsg answers a manually typed combo: is it already owned by a binding
// outside our marker block, and by whom.
type kbCheckMsg struct {
	combo       string
	taken       bool
	where       string
	overridable bool
	err         error
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
		{"Ableton Live (Wine)", "ableton-live", "launch"},
		{"Ableton Live (Native)", "$HOME/.local/share/ableton-live-12/push3_opt/push3/AbletonLive12", "launch"},
		{"Guitar Pro 8", "guitarpro", "launch"},
		{"Bitwig Studio", "bitwig-studio", "launch"},
		{"DaVinci Resolve", "davinci-resolve", "launch"},
		{"HandBrake", "ghb", "launch"},
		{"REAPER", "reaper", "launch"},
		{"Betterbird", "betterbird", "launch"},
		{"KeePassXC", "keepassxc", "launch"},
	}},
	{"funcs", "quick function", []KbCatItem{
		{"Brightness maximum", "$HOME/.local/bin/brightness-0 100%", "cmd"},
		{"Brightness minimum", "$HOME/.local/bin/brightness-0 0%", "cmd"},
		{"Mega-caffeine toggle", "mega-caffeine toggle", "cmd"},
		{"SuperFile", "foot -e spf", "cmd"},
	}},
	{"move", "Ableton Move", []KbCatItem{
		{"main menu", "$HOME/.local/bin/mosquito-move-manager", "cmd"},
		{"Move Manager webapp", "$HOME/.local/bin/move-manager-webapp", "launch"},
		{"convert a set → MIDI", "$HOME/.local/bin/mosquito-move-manager --midi", "cmd"},
	}},
	// Its own category, right above "Custom command" — mosquitomarchy is the
	// one thing this TUI exists for, so burying its launcher under a list of
	// brightness presets made it undiscoverable. One row per opener, through
	// the same entry points as the Omarchy menu (the dispatcher opens a
	// terminal itself when there is none, which a bare TUI binary cannot).
	{"mosquito", "mosquito", []KbCatItem{
		{"mosquitOmarchy", "$HOME/.local/bin/mosquitomarchy", "cmd"},
		// The old jamjamjam-tui was retired: its binary is no longer
		// installed, so the launcher silently did nothing. The panel is the
		// live JamJamJam interface (same IPC the bar widget uses).
		{"JamJamJam", "omarchy-shell mosquito.jamjamjam.panel toggle", "cmd"},
		{"PipeWire settings", "omarchy-shell shell summon mosquito.pipewire '{}'", "cmd"},
	}},
	{"custom", "custom command", nil},
}

// Rows read alphabetically inside every category (case-insensitive on the
// label), sorted once here so no future addition can break the order.
func init() {
	for i := range kbCatalog {
		items := kbCatalog[i].Items
		sort.SliceStable(items, func(a, b int) bool {
			return strings.ToLower(items[a].Label) < strings.ToLower(items[b].Label)
		})
	}
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

func fetchKbCheckCmd(combo string) tea.Cmd {
	return func() tea.Msg {
		outB, err := runQuick("kb-check", combo)
		if err != nil {
			return kbCheckMsg{err: err}
		}
		var res struct {
			Combo       string `json:"combo"`
			Taken       bool   `json:"taken"`
			Where       string `json:"where"`
			Overridable bool   `json:"overridable"`
		}
		if err := json.Unmarshal(bytes.TrimSpace(outB), &res); err != nil {
			return kbCheckMsg{err: err}
		}
		return kbCheckMsg{combo: res.Combo, taken: res.Taken, where: res.Where, overridable: res.Overridable}
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

// rebuildKB renders the Keybindings MENU — the screen the main menu's
// "Keybindings" row opens. It is a plain menu (no checkboxes): the managed
// list and the add flow each live in their own properly-named submenu. The
// list carries the removal tick selection and the Reset row, so adding and
// removing live in one place instead of being split across two tree flavors.
func (m model) rebuildKB() navPicker {
	idx := m.kbPicker.Index()
	// One screen for both trees: adding and removing were split across the
	// Setup and Uninstall flavors, which is why the same manager had two
	// partial menus.
	items := []tuikit.PickerItem{
		{Display: "Managed keybindings", Value: "managed"},
		{Display: "Add a keybinding", Value: "add"},
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
	// The Reset row used to be gated on uninstall mode, because Setup had no
	// way to reach this screen's removal side. There is one Keybindings screen
	// now, so the row and the empty-list line are always there.
	if len(m.kbItems) == 0 {
		items = append(items, tuikit.PickerItem{Display: "No keybindings managed by mosquitomarchy", Value: "", Disabled: true})
	}
	items = append(items, tuikit.PickerItem{Display: "Reset — remove ALL keybindings managed by mosquitomarchy", Value: "reset"})
	header := "Managed keybindings — tick the ones to remove"
	p := newNavPicker(header, items).SetSize(m.contentSize()).
		SetHelpKeys(
			key.NewBinding(key.WithKeys("tab"), key.WithHelp("tab", "toggle")),
			key.NewBinding(key.WithKeys("enter"), key.WithHelp("enter", "remove")),
			key.NewBinding(key.WithKeys("esc", "h"), key.WithHelp("esc/h", "back")))
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
			key.NewBinding(key.WithKeys("esc", "h"), key.WithHelp("esc/h", "back"))).
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
	case "mosquito":
		return "mosquito"
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
			key.NewBinding(key.WithKeys("esc", "h"), key.WithHelp("esc/h", "back"))).
		SelectIndex(idx)
}

// rebuildKBKeys renders the still-free SUPER combos for the pending binding.
// The manual row is first: "free" only covers SUPER + X, so any other combo
// (SUPER + ALT + M, a function key, …) needs a way in.
func (m model) rebuildKBKeys() navPicker {
	idx := m.kbKeyPicker.Index()
	items := make([]tuikit.PickerItem, 0, len(m.kbFree)+2)
	items = append(items, tuikit.PickerItem{Display: "Enter a key manually", Value: "manual"})
	for _, k := range m.kbFree {
		items = append(items, tuikit.PickerItem{Display: k, Value: k})
	}
	items = append(items, tuikit.PickerItem{Display: "Back", Value: "back"})
	return newNavPicker("Pick a free key for: "+m.kbPending.Label, items).SetSize(m.contentSize()).
		SetHelpKeys(key.NewBinding(key.WithKeys("enter"), key.WithHelp("enter", "bind")),
			key.NewBinding(key.WithKeys("esc", "h"), key.WithHelp("esc/h", "back"))).
		SelectIndex(idx)
}

// resumeKeyEntry puts the manual key input back with its text intact, so
// cancelling a bind prompt lets the user edit the combo instead of retyping it.
func (m model) resumeKeyEntry() (model, tea.Cmd) {
	if !m.kbManual {
		return m, nil
	}
	m.kbManual = false
	m.kbInputStep = 2
	m.push(scrKBInput)
	return m, m.kbInput.Init()
}

// askBind is the single confirm step for both a picked free key and a manually
// typed one. Accepting an already-bound combo appends "force" so kb-add knows
// the user accepted the override.
func (m model) askBind(combo string, taken bool, where string) (model, tea.Cmd) {
	m.pendingAction = "kb-add"
	m.pendingArgs = []string{combo, m.kbPending.Label, m.kbPending.Cmd, m.kbPending.Type}
	m.pendingNo = "Cancel"
	if taken {
		m.pendingArgs = append(m.pendingArgs, "force")
		m.pendingYes = "Bind anyway"
		m.pendingMsg = fmt.Sprintf("%s is already bound (%s).\n\nBind it to %s anyway?\n\nThe mosquitOmarchy block in bindings.lua will override the earlier binding. Hyprland needs a reload for it to take effect — you'll be asked right after.", combo, where, m.kbPending.Label)
	} else {
		m.pendingYes = "Bind"
		m.pendingMsg = fmt.Sprintf("Bind %s → %s?\n\nThe binding is written to the mosquitOmarchy block in bindings.lua. Hyprland needs a reload for it to take effect — you'll be asked right after.", combo, m.kbPending.Label)
	}
	m.push(scrConfirm)
	m.confirm = tuikit.NewConfirm(m.pendingMsg, m.pendingNo, m.pendingYes)
	return m, nil
}
