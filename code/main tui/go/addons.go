package main

import (
	"fmt"
	"sort"
	"strings"

	tea "github.com/charmbracelet/bubbletea"

	key "github.com/charmbracelet/bubbles/key"
	tuikit "mosquitomarchy.local/tui-kit"
)

// addonRec is one addon folder under code/main tui/addons/.
type addonRec struct {
	Name        string `json:"name"`
	Category    string `json:"category"`
	Description string `json:"description"`
	Installed   bool   `json:"installed"`
}

type addonsMsg struct {
	rows []addonRec
	err  error
}

func fetchAddonsCmd() tea.Cmd {
	return func() tea.Msg {
		out, err := runQuick("addons-list")
		if err != nil {
			return addonsMsg{err: err}
		}
		rows, err := decodeJSONLines[addonRec](out)
		return addonsMsg{rows: rows, err: err}
	}
}

// addonCategories groups the rows in the same logical order the TUI uses for
// Setup, then alphabetically for custom families. Empty families never enter
// the map, so no empty folder is rendered.
func (m model) addonCategories() ([]string, map[string][]addonRec) {
	byCat := map[string][]addonRec{}
	for _, a := range m.addons {
		cat := a.Category
		if cat == "" {
			cat = "Other"
		}
		byCat[cat] = append(byCat[cat], a)
	}
	cats := make([]string, 0, len(byCat))
	for cat := range byCat {
		cats = append(cats, cat)
	}
	priority := map[string]int{"Themes": 0, "Apps": 1, "System": 2, "Integration": 3}
	sort.Slice(cats, func(i, j int) bool {
		pi, iok := priority[cats[i]]
		pj, jok := priority[cats[j]]
		if iok != jok {
			return iok
		}
		if iok && pi != pj {
			return pi < pj
		}
		return strings.ToLower(cats[i]) < strings.ToLower(cats[j])
	})
	for cat := range byCat {
		sort.Slice(byCat[cat], func(i, j int) bool {
			return strings.ToLower(byCat[cat][i].Name) < strings.ToLower(byCat[cat][j].Name)
		})
	}
	return cats, byCat
}

// rebuildAddons is the same folder tree as Setup/Uninstall: category folders
// with counts, fold glyphs, ├─/└─ child lines and ○/● marks. There is no
// "Apply" row: Enter applies the whole ticked set, exactly like Setup.
func (m model) rebuildAddons() navPicker {
	if !m.addonsLoaded {
		return newNavPicker("Addons:", []tuikit.PickerItem{{Display: "loading…", Value: "", Disabled: true}}).
			SetSize(m.contentSize())
	}
	if m.filterText != "" {
		return m.rebuildFilteredAddons()
	}
	cats, byCat := m.addonCategories()
	folders := make([]tuikit.TreeFolder, 0, len(cats))
	items := make(map[string][]tuikit.TreeItem, len(cats))
	for _, cat := range cats {
		rows := byCat[cat]
		children := make([]tuikit.TreeItem, 0, len(rows))
		marked := 0
		for _, a := range rows {
			on := m.addonsSel[a.Name]
			if on {
				marked++
			}
			children = append(children, tuikit.TreeItem{
				ID:      a.Name,
				Label:   a.Name,
				Checked: on,
				Info:    a.Description,
			})
		}
		folders = append(folders, tuikit.TreeFolder{
			ID: cat, Label: cat, Total: len(rows), Marked: marked,
		})
		items[cat] = children
	}
	out := tuikit.BuildFolderTree(folders, items, m.addonsOpen, false)
	if len(out) == 0 {
		out = append(out, tuikit.PickerItem{Display: "No addons in code/main tui/addons/", Value: "", Disabled: true})
	}
	out = append(out, tuikit.PickerItem{Display: "Back", Value: "back"})
	return newNavPicker("", out).SetSize(m.contentSize()).
		SetHelpKeys(
			key.NewBinding(key.WithKeys("tab"), key.WithHelp("tab", "select")),
			key.NewBinding(key.WithKeys("F", "/"), key.WithHelp("F", "search")),
			key.NewBinding(key.WithKeys("left", "right"), key.WithHelp("←/→", "fold")),
			key.NewBinding(key.WithKeys("enter"), key.WithHelp("enter", "apply")),
		).KeepCursor(m.addonsPicker.SelectedValue())
}

// rebuildFilteredAddons is the typing-filter view: matching leaf rows only,
// carrying their category so the answer reads without the folder tree.
func (m model) rebuildFilteredAddons() navPicker {
	ft := strings.ToLower(m.filterText)
	items := make([]tuikit.PickerItem, 0, len(m.addons)+1)
	for _, a := range m.addons {
		cat := a.Category
		if cat == "" {
			cat = "Other"
		}
		if !searchMatch(cat, ft) &&
			!searchMatch(a.Name, ft) &&
			!searchMatch(a.Description, ft) {
			continue
		}
		mark := "○"
		if m.addonsSel[a.Name] {
			mark = "●"
		}
		items = append(items, tuikit.PickerItem{
			Display: cat + " › " + a.Name,
			Value:   tuikit.TreeValue(tuikit.TreeItemPrefix, a.Name),
			Badge:   mark,
		})
	}
	header := "  filter: ┃ " + m.filterText + " ▏  (type to refine · esc clear · tab select · enter apply)"
	p := newNavPicker(header, items).SetSize(m.contentSize()).
		SetHelpKeys(
			key.NewBinding(key.WithKeys("tab"), key.WithHelp("tab", "select")),
			key.NewBinding(key.WithKeys("F", "/"), key.WithHelp("F", "search")),
			key.NewBinding(key.WithKeys("enter"), key.WithHelp("enter", "apply")),
		)
	return p.KeepCursor(m.addonsPicker.SelectedValue())
}

func (m model) addonSelectedNames() []string {
	names := make([]string, 0, len(m.addonsSel))
	for _, a := range m.addons {
		if m.addonsSel[a.Name] {
			names = append(names, a.Name)
		}
	}
	sort.Strings(names)
	return names
}

func (m model) addonChanges() (added, removed []string) {
	for _, a := range m.addons {
		want := m.addonsSel[a.Name]
		switch {
		case want && !a.Installed:
			added = append(added, a.Name)
		case !want && a.Installed:
			removed = append(removed, a.Name)
		}
	}
	sort.Strings(added)
	sort.Strings(removed)
	return added, removed
}

func addonChangesText(added, removed []string) string {
	var b strings.Builder
	b.WriteString("Apply these addon changes?\n\n")
	if len(added) == 0 && len(removed) == 0 {
		b.WriteString("No change.")
		return b.String()
	}
	if len(added) > 0 {
		b.WriteString("Added:\n")
		for _, n := range added {
			fmt.Fprintf(&b, "  + %s\n", n)
		}
	}
	if len(removed) > 0 {
		if len(added) > 0 {
			b.WriteString("\n")
		}
		b.WriteString("Removed:\n")
		for _, n := range removed {
			fmt.Fprintf(&b, "  - %s\n", n)
		}
	}
	return b.String()
}
