package main

import (
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"mosquitomarchy.local/mosquitomixbay-tui/aggregate"
	"mosquitomarchy.local/mosquitomixbay-tui/patchbay"
	tuikit "mosquitomarchy.local/tui-kit"
)

func deviceRow(t *testing.T, value string) tuikit.PickerItem {
	t.Helper()
	m := initialModel()
	for _, it := range m.deviceItems() {
		if it.Value == value {
			return it
		}
	}
	t.Fatalf("devices page has no %q row", value)
	return tuikit.PickerItem{}
}

func TestAggregateRowIsProminent(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	row := deviceRow(t, "aggregate")
	if row.Display != "Aggregate devices" {
		t.Fatalf("row reads %q", row.Display)
	}
	if strings.Contains(row.Display, "patchbay") {
		t.Fatalf("old label leaked into %q", row.Display)
	}
}

func TestAggregateItemsGreyWhenLocked(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	t.Setenv("XDG_RUNTIME_DIR", t.TempDir())
	if err := aggregate.SetLock(true); err != nil {
		t.Fatal(err)
	}
	m := initialModel()
	m.aggregate.info.Locked = true
	m.aggregate.info.Available = true
	m.aggregate.presets = []aggregate.Preset{{Name: "Studio pair"}}
	var presetRow tuikit.PickerItem
	for _, it := range m.aggregateItems() {
		if it.Value == "aggregate:Studio pair" {
			presetRow = it
		}
	}
	if !presetRow.Disabled || !strings.Contains(presetRow.Suffix, "locked by Live Mode") {
		t.Fatalf("preset row must be greyed while locked: %+v", presetRow)
	}
	if err := aggregate.SetLock(false); err != nil {
		t.Fatal(err)
	}
	if aggregate.Locked() {
		t.Fatal("release must clear the fence")
	}
}

func TestAggregatePickerUsesPanelLabelsAndHidesSuperwhisper(t *testing.T) {
	m := initialModel()
	m.aggregate.graph = patchbay.Graph{Nodes: []patchbay.Node{
		{Name: "alsa_output.pci-0000_00_1f.3.analog-stereo", Class: "Audio/Sink", Description: "alc257 analog"},
		{Name: "alsa_input.usb-Superwhisper-00.microphone", Class: "Audio/Source", Description: "Superwhisper microphone"},
		{Name: "agg_studio_pair", Class: "Audio/Sink", Description: "Studio pair"},
	}}
	items := m.aggregatePickItems()
	var labels string
	for _, it := range items {
		labels += it.Display + " " + it.Suffix + "\n"
		if strings.Contains(strings.ToLower(it.Display+it.Value), "superwhisper") {
			t.Fatalf("Superwhisper leaked into the picker: %+v", it)
		}
	}
	if !strings.Contains(labels, "alc257 analog") {
		t.Fatalf("picker must use the audio panel label, got:\n%s", labels)
	}
	if strings.Contains(labels, "alsa_output.pci-0000_00_1f.3.analog-stereo") {
		t.Fatalf("raw node name leaked into the picker:\n%s", labels)
	}
	if strings.Contains(labels, "agg_studio_pair") {
		t.Fatalf("an aggregate leaked into its own picker:\n%s", labels)
	}
}

func TestAggregatePickGridNavigationAndBack(t *testing.T) {
	m := initialModel()
	m.w, m.h = 100, 30
	m.nav = append(m.nav, scrAggregatePick)
	m.aggregate.graph = patchbay.Graph{Nodes: []patchbay.Node{
		{Name: "out_a", Class: "Audio/Sink", Description: "A analog"},
		{Name: "out_b", Class: "Audio/Sink", Description: "B analog"},
		{Name: "in_a", Class: "Audio/Source", Description: "A microphone"},
	}}
	m.syncAggregatePick()

	key := func(s string) {
		t.Helper()
		nm, _ := m.updateKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(s)})
		m = nm.(model)
	}
	active := func() string {
		t.Helper()
		name, ok := m.aggregateActiveNode()
		if !ok {
			t.Fatal("no active card")
		}
		return name
	}
	if got := active(); got != "out_a" {
		t.Fatalf("initial active = %q", got)
	}
	key("h")
	if m.aggregate.column != 1 || active() != "in_a" {
		t.Fatalf("h must switch columns, got column=%d active=%s", m.aggregate.column, active())
	}
	key("h")
	if m.aggregate.column != 0 || active() != "out_a" {
		t.Fatalf("h must toggle back, got column=%d active=%s", m.aggregate.column, active())
	}
	key("j")
	if m.aggregate.row != 1 || active() != "out_b" {
		t.Fatalf("j must move down a row, got row=%d active=%s", m.aggregate.row, active())
	}
	key("h")
	if m.aggregate.row != 0 || active() != "in_a" {
		t.Fatalf("switching to the shorter column must clamp the row, got row=%d active=%s", m.aggregate.row, active())
	}
	key(" ")
	if !m.aggregate.picked["in_a"] {
		t.Fatal("space must toggle the active card")
	}

	m.picker = m.picker.SelectValue("back")
	key("enter")
	if got := m.top(); got != scrDevices {
		t.Fatalf("enter on Back must leave the picker, got top=%v", got)
	}
}

func TestAggregateItemsHideShortcutOnlyRows(t *testing.T) {
	m := initialModel()
	m.aggregate.info.Available = true
	m.aggregate.presets = []aggregate.Preset{{Name: "Studio pair"}}
	m.patchbay.states = []patchbay.State{{Preset: patchbay.Preset{Name: "studio-links"}, Applies: true}}
	items := m.aggregateItems()
	for _, it := range items {
		switch it.Value {
		case "new", "save", "refresh":
			t.Fatalf("shortcut-only row %q must not be listed: %+v", it.Value, it)
		}
		if strings.Contains(it.Display, "PipeWire links") {
			t.Fatalf("unselectable heading must be gone: %+v", it)
		}
		if it.Value == "apply:studio-links" && !strings.HasPrefix(it.Display, "link: ") {
			t.Fatalf("link presets must be distinguishable: %+v", it)
		}
	}
}
