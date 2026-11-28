package main

import (
	"fmt"
	"sort"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"mosquitomarchy.local/mosquitomixbay-tui/aggregate"
	"mosquitomarchy.local/mosquitomixbay-tui/patchbay"
	tuikit "mosquitomarchy.local/tui-kit"
)

type aggregateView struct {
	loading bool
	err     string
	info    aggregate.Info
	presets []aggregate.Preset
	graph   patchbay.Graph
	picked  map[string]bool
}

type aggregateLoadedMsg struct {
	info    aggregate.Info
	presets []aggregate.Preset
	graph   patchbay.Graph
	err     error
}

type aggregateActionMsg struct {
	what  string
	err   error
	added int
}

func loadAggregateCmd() tea.Cmd {
	return func() tea.Msg {
		info, err := aggregate.Status()
		if err != nil {
			return aggregateLoadedMsg{info: info, err: err}
		}
		presets, perr := aggregate.List()
		if perr != nil && perr != aggregate.ErrNoPresets {
			return aggregateLoadedMsg{info: info, err: perr}
		}
		var g patchbay.Graph
		if g2, gerr := patchbay.Snapshot(); gerr == nil {
			g = g2
		}
		return aggregateLoadedMsg{info: info, presets: presets, graph: g}
	}
}

func aggregateSaveCmd(name, display string, outputs, inputs []string) tea.Cmd {
	return func() tea.Msg {
		if err := aggregate.EnsureWritable(); err != nil {
			return aggregateActionMsg{what: "save", err: err}
		}
		g, err := patchbay.Snapshot()
		if err != nil {
			return aggregateActionMsg{what: "save", err: err}
		}
		p, err := aggregate.MakePreset(name, display, g, outputs, inputs)
		if err != nil {
			return aggregateActionMsg{what: "save", err: err}
		}
		if err := aggregate.Save(p, false); err != nil {
			return aggregateActionMsg{what: "save", err: err}
		}
		return aggregateActionMsg{what: "save"}
	}
}

func aggregateActivateCmd(name string) tea.Cmd {
	return func() tea.Msg {
		p, err := aggregate.Load(name)
		if err != nil {
			return aggregateActionMsg{what: "activate", err: err}
		}
		if err := aggregate.Activate(p, false); err != nil {
			return aggregateActionMsg{what: "activate", err: err}
		}
		return aggregateActionMsg{what: "activate"}
	}
}

func aggregateSimpleCmd(what string, act func() error) tea.Cmd {
	return func() tea.Msg {
		return aggregateActionMsg{what: what, err: act()}
	}
}

func (m model) aggregateItems() []tuikit.PickerItem {
	var items []tuikit.PickerItem
	locked := m.aggregate.info.Locked && !m.aggregate.info.Unlocked
	switch {
	case m.aggregate.loading:
		items = append(items, tuikit.PickerItem{Display: "Loading PipeWire graph…", Disabled: true})
	case m.aggregate.err != "":
		items = append(items, tuikit.PickerItem{Display: "Error: " + m.aggregate.err, Disabled: true})
	default:
		newRow := tuikit.PickerItem{Display: "New aggregate…  (n)", Value: "new"}
		if locked {
			newRow.Disabled = true
			newRow.Suffix = "  (locked by Live Mode)"
		} else if !m.aggregate.info.Available {
			newRow.Disabled = true
			newRow.Suffix = "  (needs pw-cli and pw-dump)"
		}
		items = append(items, newRow)
		if m.aggregate.info.Active != "" {
			resampled := 0
			for _, member := range m.aggregate.info.Members {
				if member.Drift {
					resampled++
				}
			}
			state := m.aggregate.info.State
			if !m.aggregate.info.LinksOK {
				state += " (link missing)"
			}
			items = append(items, tuikit.PickerItem{
				Display:  fmt.Sprintf("  %s: %s · %d Hz · resampling %d/%d", m.aggregate.info.Active, state, m.aggregate.info.Rate, resampled, len(m.aggregate.info.Members)),
				Disabled: true,
			})
		}
		if len(m.aggregate.presets) == 0 {
			items = append(items, tuikit.PickerItem{Display: "No aggregates yet", Disabled: true})
		}
		for _, p := range m.aggregate.presets {
			mark := "  "
			if m.aggregate.info.Active == p.Name {
				mark = "● "
			}
			row := tuikit.PickerItem{
				Display: fmt.Sprintf("%s%s  (%d out / %d in)", mark, p.Name, len(p.Outputs), len(p.Inputs)),
				Value:   "aggregate:" + p.Name,
			}
			if locked {
				row.Disabled = true
				row.Suffix = "  (locked by Live Mode)"
			}
			items = append(items, row)
		}
	}
	items = append(items, tuikit.PickerItem{Display: "PipeWire links", Heading: true})
	items = append(items, m.patchbayItems()...)
	return items
}

func (m model) aggregatePickItems() []tuikit.PickerItem {
	var names []string
	for _, n := range m.aggregate.graph.Nodes {
		if strings.HasPrefix(n.Name, "agg_") || strings.Contains(n.Name, ":monitor") {
			continue
		}
		if n.Class != "Audio/Sink" && n.Class != "Audio/Source" {
			continue
		}
		names = append(names, n.Name)
	}
	sort.Strings(names)
	if len(names) == 0 {
		items := []tuikit.PickerItem{{Display: "No audio nodes in the PipeWire graph", Disabled: true}}
		return append(items, tuikit.PickerItem{Display: "Back", Value: "back"})
	}
	var items []tuikit.PickerItem
	for _, name := range names {
		mark := "[ ]"
		if m.aggregate.picked[name] {
			mark = "[x]"
		}
		items = append(items, tuikit.PickerItem{Display: mark + " " + name, Value: "toggle:" + name})
	}
	return append(items,
		tuikit.PickerItem{Display: "Name and save…  (n)", Value: "save"},
		tuikit.PickerItem{Display: "Back", Value: "back"},
	)
}

func (m *model) promptAggregateName() tea.Cmd {
	outputs, inputs := m.aggregateSelection()
	if len(outputs)+len(inputs) == 0 {
		m.toast, _ = m.toast.SetWarn("Pick at least one output or input")
		return nil
	}
	m.text = tuikit.NewTextInput("Aggregate device name:", "")
	m.textAct = func(name string) tea.Cmd {
		name = strings.TrimSpace(name)
		if name == "" {
			m.toast, _ = m.toast.SetErr("A name is required")
			return nil
		}
		return aggregateSaveCmd(name, name, outputs, inputs)
	}
	m.push(scrInput)
	return m.text.Init()
}

func (m model) aggregateSelection() ([]string, []string) {
	var outputs, inputs []string
	for _, n := range m.aggregate.graph.Nodes {
		if !m.aggregate.picked[n.Name] {
			continue
		}
		if n.Class == "Audio/Source" {
			inputs = append(inputs, n.Name)
		} else {
			outputs = append(outputs, n.Name)
		}
	}
	sort.Strings(outputs)
	sort.Strings(inputs)
	return outputs, inputs
}

func (m model) selectedAggregate() (string, bool) {
	v := m.picker.SelectedValue()
	if !strings.HasPrefix(v, "aggregate:") {
		return "", false
	}
	return strings.TrimPrefix(v, "aggregate:"), true
}

func (m model) aggregateKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	k := msg.String()
	switch k {
	case "esc", "backspace", "h":
		m.pop()
		return m, nil
	case "r":
		m.aggregate.loading = true
		m.patchbay.loading = true
		m.syncPicker()
		return m, tea.Batch(loadAggregateCmd(), loadPatchbayCmd())
	case "n":
		if !m.aggregate.info.Available {
			m.toast, _ = m.toast.SetWarn("Aggregate devices need pw-cli and pw-dump")
			return m, nil
		}
		if m.aggregate.info.Locked && !m.aggregate.info.Unlocked {
			m.toast, _ = m.toast.SetWarn("Aggregate devices are locked by Live Mode")
			return m, nil
		}
		m.aggregate.picked = map[string]bool{}
		m.push(scrAggregatePick)
		m.syncPicker()
		return m, loadAggregateCmd()
	case "s":
		return m, m.promptPatchbaySave()
	case "p":
		if m.aggregate.info.Locked && !m.aggregate.info.Unlocked {
			m.toast, _ = m.toast.SetWarn("Aggregate devices are locked by Live Mode")
			return m, nil
		}
		m.confirm = tuikit.NewConfirm("Restore links removed from the active aggregate?", "Cancel", "Repair")
		m.confirmAct = func() tea.Cmd {
			return aggregateSimpleCmd("repair", func() error {
				_, err := aggregate.Repair()
				return err
			})
		}
		m.push(scrConfirm)
		return m, nil
	case "A":
		if !m.aggregate.info.Locked {
			m.toast, _ = m.toast.SetOK("Aggregate devices are not locked")
			return m, nil
		}
		title := "Unlock aggregate devices for this session?"
		if m.aggregate.info.Unlocked {
			title = "Re-lock aggregate devices for this session?"
		}
		m.confirm = tuikit.NewConfirm(title, "Cancel", "Confirm")
		m.confirmAct = func() tea.Cmd {
			return aggregateSimpleCmd("unlock", func() error { return aggregate.SetUnlocked(!m.aggregate.info.Unlocked) })
		}
		m.push(scrConfirm)
		return m, nil
	case "a", "enter", "l":
		if m.picker.SelectedValue() == "back" {
			m.pop()
			return m, nil
		}
		if m.picker.SelectedValue() == "refresh" {
			m.aggregate.loading = true
			m.syncPicker()
			return m, loadAggregateCmd()
		}
		if name, ok := m.selectedAggregate(); ok {
			if m.aggregate.info.Locked && !m.aggregate.info.Unlocked {
				m.toast, _ = m.toast.SetWarn("Aggregate devices are locked by Live Mode")
				return m, nil
			}
			if m.aggregate.info.Active == name {
				m.confirm = tuikit.NewConfirm(fmt.Sprintf("Deactivate aggregate “%s”? The virtual output disappears.", name), "Cancel", "Deactivate")
				m.confirmAct = func() tea.Cmd {
					return aggregateSimpleCmd("deactivate", func() error { return aggregate.Deactivate(false) })
				}
			} else {
				m.confirm = tuikit.NewConfirm(fmt.Sprintf("Activate aggregate “%s”? A new output appears in the audio panel.", name), "Cancel", "Activate")
				m.confirmAct = func() tea.Cmd { return aggregateActivateCmd(name) }
			}
			m.push(scrConfirm)
			return m, nil
		}
	}
	if k == "d" {
		if name, ok := m.selectedAggregate(); ok {
			if m.aggregate.info.Locked && !m.aggregate.info.Unlocked {
				m.toast, _ = m.toast.SetWarn("Aggregate devices are locked by Live Mode")
				return m, nil
			}
			m.confirm = tuikit.NewConfirm(fmt.Sprintf("Delete aggregate “%s”?", name), "Cancel", "Delete")
			m.confirmAct = func() tea.Cmd { return aggregateSimpleCmd("delete", func() error { return aggregate.Delete(name) }) }
			m.push(scrConfirm)
			return m, nil
		}
	}
	// Raw link presets keep their original Enter-to-apply behaviour.
	if strings.HasPrefix(m.picker.SelectedValue(), "apply:") {
		return m.patchbayKey(msg)
	}
	var cmd tea.Cmd
	m.picker, cmd = m.picker.Update(msg)
	return m, cmd
}

func (m model) aggregatePickKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	k := msg.String()
	switch k {
	case "esc", "backspace", "h":
		m.pop()
		return m, nil
	case "n", "enter", "l":
		if (k == "enter" || k == "l") && !strings.HasPrefix(m.picker.SelectedValue(), "save") {
			break
		}
		return m, m.promptAggregateName()
	}
	v := m.picker.SelectedValue()
	if strings.HasPrefix(v, "toggle:") {
		name := strings.TrimPrefix(v, "toggle:")
		if m.aggregate.picked == nil {
			m.aggregate.picked = map[string]bool{}
		}
		m.aggregate.picked[name] = !m.aggregate.picked[name]
	}
	var cmd tea.Cmd
	m.picker, cmd = m.picker.Update(msg)
	return m, cmd
}
