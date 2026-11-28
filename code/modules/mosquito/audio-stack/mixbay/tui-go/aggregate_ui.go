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

	// The card picker is a 2-column grid like the EVO controls: column 0 is
	// outputs, column 1 inputs. row is shared and clamped when switching
	// columns, and picked is shared too — one selection map for both sides.
	column int
	row    int
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

// panelLabel mirrors the audio panel's Model.js nodeLabel(): nickname first,
// then description, then the raw node name, with the same cosmetic cleanup.
func panelLabel(n patchbay.Node) string {
	raw := n.Nick
	if raw == "" {
		raw = n.ProfileDescription
	}
	if raw == "" {
		raw = n.Description
	}
	if raw == "" {
		raw = n.Name
	}
	s := strings.TrimSpace(raw)
	lower := strings.ToLower(s)
	for _, p := range []string{"sof-soundwire ", "sof-soundwire\t", "built-in audio ", "builtinaudio ", "built in audio "} {
		if strings.HasPrefix(lower, p) {
			s = strings.TrimSpace(s[len(p):])
			break
		}
	}
	lower = strings.ToLower(s)
	if strings.HasSuffix(lower, " output") {
		s = strings.TrimSpace(s[:len(s)-len(" output")])
	} else if strings.HasSuffix(lower, " input") {
		s = strings.TrimSpace(s[:len(s)-len(" input")])
	}
	return strings.ReplaceAll(s, "Microphones", "Microphone")
}

// isSuperwhisper keeps the dictation app's virtual endpoints out of every
// aggregate picker, regardless of how PipeWire named them.
func isSuperwhisper(n patchbay.Node) bool {
	for _, s := range []string{n.Name, n.Description, n.Nick, n.ProfileDescription} {
		if strings.Contains(strings.ToLower(s), "superwhisper") {
			return true
		}
	}
	return false
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
		// New aggregates and raw link presets are created/saved by shortcuts
		// only; the picker stays a list of things you can act on.
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
	// Raw link presets remain applyable, but their create/refresh rows are
	// shortcut-only (s / r) and the old unselectable heading is gone.
	for _, it := range m.patchbayItems() {
		switch it.Value {
		case "save", "refresh":
			continue
		}
		if strings.HasPrefix(it.Value, "apply:") {
			it.Display = "link: " + it.Display
		}
		items = append(items, it)
	}
	return items
}

// aggregatePickLists splits the live graph into the two columns of the card
// picker. Both columns share the same selection map and the same row index.
func (m model) aggregatePickLists() ([]string, []string, map[string]patchbay.Node) {
	var outputs, inputs []string
	nodes := map[string]patchbay.Node{}
	for _, n := range m.aggregate.graph.Nodes {
		if strings.HasPrefix(n.Name, "agg_") || strings.Contains(n.Name, ":monitor") || isSuperwhisper(n) {
			continue
		}
		if n.Class != "Audio/Sink" && n.Class != "Audio/Source" {
			continue
		}
		nodes[n.Name] = n
		if n.Class == "Audio/Source" {
			inputs = append(inputs, n.Name)
		} else {
			outputs = append(outputs, n.Name)
		}
	}
	byLabel := func(names []string) {
		sort.Slice(names, func(i, j int) bool {
			li, lj := panelLabel(nodes[names[i]]), panelLabel(nodes[names[j]])
			if li != lj {
				return li < lj
			}
			return names[i] < names[j]
		})
	}
	byLabel(outputs)
	byLabel(inputs)
	return outputs, inputs, nodes
}

func aggregateRowValue(row int) string { return fmt.Sprintf("row:%d", row) }

// clampAggregateRow mirrors evoClampCursor: switching to a shorter column
// keeps the row index where possible instead of jumping to a different card.
func (m *model) clampAggregateRow() {
	outputs, inputs, _ := m.aggregatePickLists()
	rows := max(len(outputs), len(inputs))
	if rows == 0 {
		m.aggregate.row = 0
		return
	}
	list := outputs
	if m.aggregate.column == 1 {
		list = inputs
	}
	if m.aggregate.row >= len(list) {
		if len(list) == 0 {
			m.aggregate.row = 0
		} else {
			m.aggregate.row = len(list) - 1
		}
	}
}

func (m *model) syncAggregatePick() {
	m.clampAggregateRow()
	m.syncPicker()
	outputs, inputs, _ := m.aggregatePickLists()
	if max(len(outputs), len(inputs)) > 0 {
		m.picker = m.picker.SelectValue(aggregateRowValue(m.aggregate.row))
	}
}

func (m model) aggregatePickCell(list []string, nodes map[string]patchbay.Node, row, col int) string {
	if row >= len(list) {
		return ""
	}
	name := list[row]
	mark := "[ ]"
	if m.aggregate.picked[name] {
		mark = "[x]"
	}
	label := panelLabel(nodes[name])
	if m.aggregate.column == col && m.aggregate.row == row {
		return mark + " " + label + " ◀"
	}
	return mark + " " + label
}

func (m model) aggregatePickItems() []tuikit.PickerItem {
	outputs, inputs, nodes := m.aggregatePickLists()
	rows := max(len(outputs), len(inputs))
	if rows == 0 {
		return []tuikit.PickerItem{
			{Display: "No audio nodes in the PipeWire graph", Disabled: true},
			{Display: "Back", Value: "back"},
		}
	}
	colW := (m.w - 6) / 2
	if colW < 12 {
		colW = 12
	}
	if colW > 40 {
		colW = 40
	}
	items := []tuikit.PickerItem{{Display: fmt.Sprintf("%-*s  %s", colW, "Outputs", "Inputs"), Disabled: true}}
	for r := 0; r < rows; r++ {
		left := m.aggregatePickCell(outputs, nodes, r, 0)
		right := m.aggregatePickCell(inputs, nodes, r, 1)
		items = append(items, tuikit.PickerItem{
			Display: fmt.Sprintf("%-*s  %s", colW, left, right),
			Value:   aggregateRowValue(r),
		})
	}
	return append(items, tuikit.PickerItem{Display: "Back", Value: "back"})
}

// aggregateActiveNode is the card under the shared (row, column) cursor.
func (m model) aggregateActiveNode() (string, bool) {
	outputs, inputs, _ := m.aggregatePickLists()
	list := outputs
	if m.aggregate.column == 1 {
		list = inputs
	}
	if m.aggregate.row >= len(list) {
		return "", false
	}
	return list[m.aggregate.row], true
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
		m.aggregate.column, m.aggregate.row = 0, 0
		m.push(scrAggregatePick)
		m.syncAggregatePick()
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

func (m *model) toggleAggregateActive() {
	name, ok := m.aggregateActiveNode()
	if !ok {
		return
	}
	if m.aggregate.picked == nil {
		m.aggregate.picked = map[string]bool{}
	}
	m.aggregate.picked[name] = !m.aggregate.picked[name]
	m.syncAggregatePick()
}

// aggregatePickKey owns the 2-column grid. Picker's own h is "back" on every
// plain list, so it MUST be intercepted here: in this grid h/l switch columns.
func (m model) aggregatePickKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	k := msg.String()
	switch k {
	case "esc", "backspace":
		m.pop()
		return m, nil
	case "h", "l":
		// With two columns both keys toggle; j/k stay on the shared row.
		m.aggregate.column = 1 - m.aggregate.column
		m.syncAggregatePick()
		return m, nil
	case "j", "down":
		m.aggregate.row++
		m.syncAggregatePick()
		return m, nil
	case "k", "up":
		if m.aggregate.row > 0 {
			m.aggregate.row--
		}
		m.syncAggregatePick()
		return m, nil
	case "enter":
		if m.picker.SelectedValue() == "back" {
			m.pop()
			return m, nil
		}
		m.toggleAggregateActive()
		return m, nil
	case " ":
		m.toggleAggregateActive()
		return m, nil
	case "n":
		return m, m.promptAggregateName()
	}
	var cmd tea.Cmd
	m.picker, cmd = m.picker.Update(msg)
	return m, cmd
}
