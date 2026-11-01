package main

import (
	"fmt"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"mosquitomarchy.local/mosquitomixbay-tui/patchbay"
	tuikit "mosquitomarchy.local/tui-kit"
)

type patchbayView struct {
	loading bool
	err     string
	states  []patchbay.State
}

type patchbayLoadedMsg struct {
	states []patchbay.State
	err    error
}

type patchbayAppliedMsg struct {
	name string
	res  patchbay.ApplyResult
	err  error
}

type patchbaySavedMsg struct {
	name string
	err  error
}

func loadPatchbayCmd() tea.Cmd {
	return func() tea.Msg {
		g, err := patchbay.Snapshot()
		if err != nil {
			return patchbayLoadedMsg{err: err}
		}
		states, err := patchbay.States(g)
		return patchbayLoadedMsg{states: states, err: err}
	}
}

func savePatchbayCmd(name string) tea.Cmd {
	return func() tea.Msg {
		g, err := patchbay.Snapshot()
		if err != nil {
			return patchbaySavedMsg{name: name, err: err}
		}
		return patchbaySavedMsg{name: name, err: patchbay.CreatePreset(name, g)}
	}
}

func applyPatchbayCmd(name string, replace bool) tea.Cmd {
	return func() tea.Msg {
		g, err := patchbay.Snapshot()
		if err != nil {
			return patchbayAppliedMsg{name: name, err: err}
		}
		p, err := patchbay.LoadPreset(name)
		if err != nil {
			return patchbayAppliedMsg{name: name, err: err}
		}
		res, err := patchbay.Apply(p, g, replace)
		return patchbayAppliedMsg{name: name, res: res, err: err}
	}
}

func (m model) patchbayItems() []tuikit.PickerItem {
	var items []tuikit.PickerItem
	switch {
	case m.patchbay.loading:
		items = append(items, tuikit.PickerItem{Display: "Loading PipeWire graph…", Disabled: true})
	case m.patchbay.err != "":
		items = append(items, tuikit.PickerItem{Display: "Error: " + m.patchbay.err, Disabled: true})
	default:
		items = append(items, tuikit.PickerItem{Display: "Save current wiring…  (s)", Value: "save"})
		if len(m.patchbay.states) == 0 {
			items = append(items, tuikit.PickerItem{Display: "No presets yet", Disabled: true})
		}
		for _, st := range m.patchbay.states {
			it := tuikit.PickerItem{Display: st.Name, Value: "apply:" + st.Name}
			if st.Applies {
				it.Suffix = "  ✓"
			} else {
				it.Suffix = "  (interfaces differ)"
				it.Disabled = true
			}
			items = append(items, it)
		}
	}
	items = append(items,
		tuikit.PickerItem{Display: "Refresh", Value: "refresh"},
		tuikit.PickerItem{Display: "Back", Value: "back"},
	)
	return items
}

func (m *model) promptPatchbaySave() tea.Cmd {
	m.text = tuikit.NewTextInput("Save current PipeWire wiring as:", "")
	m.textAct = func(name string) tea.Cmd {
		return savePatchbayCmd(strings.TrimSpace(name))
	}
	m.push(scrInput)
	return m.text.Init()
}

func (m model) patchbayKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "esc", "backspace":
		m.pop()
		return m, nil
	case "r":
		m.patchbay.loading, m.patchbay.err = true, ""
		m.syncPicker()
		return m, loadPatchbayCmd()
	case "s":
		return m, m.promptPatchbaySave()
	case "enter":
		v := m.picker.SelectedValue()
		switch {
		case v == "back":
			m.pop()
			return m, nil
		case v == "refresh":
			m.patchbay.loading, m.patchbay.err = true, ""
			m.syncPicker()
			return m, loadPatchbayCmd()
		case v == "save":
			return m, m.promptPatchbaySave()
		}
		name := strings.TrimPrefix(v, "apply:")
		if name == v || name == "" {
			return m, nil
		}
		m.confirm = tuikit.NewConfirm(
			fmt.Sprintf("Apply PipeWire preset “%s”? Existing unrelated links are kept.", name),
			"Cancel", "Apply")
		m.confirmAct = func() tea.Cmd { return applyPatchbayCmd(name, false) }
		m.push(scrConfirm)
		return m, nil
	}
	var cmd tea.Cmd
	m.picker, cmd = m.picker.Update(msg)
	return m, cmd
}
