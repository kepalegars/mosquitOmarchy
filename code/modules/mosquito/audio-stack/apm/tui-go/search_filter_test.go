package main

import (
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

// The filtered view is the mosquitOmarchy one: matching LEAF rows only,
// flattened, with the vendor prefixed. A vendor-name match keeps every child.
func TestFilteredLeafRows(t *testing.T) {
	items := []Item{
		{Display: "Arturia", Value: "vendor:Arturia", Kind: "folder"},
		{Display: "Analog Lab V", Value: "vst:analog", Kind: "plugin", Parent: "vendor:Arturia", Formats: "vst3"},
		{Display: "Mini V", Value: "vst:mini", Kind: "plugin", Parent: "vendor:Arturia", Formats: "vst3"},
		{Display: "Serum 2", Value: "vst:serum", Kind: "plugin", Formats: "vst2"},
	}
	got := filteredLeafRows(items, "analog", map[string]bool{"vst:analog": true})
	if len(got) != 1 || got[0].Value != "vst:analog" {
		t.Fatalf("analog filter = %+v, want only Analog Lab V", got)
	}
	if !strings.Contains(got[0].Display, "Arturia › Analog Lab V") {
		t.Fatalf("filtered row lost its vendor: %q", got[0].Display)
	}
	if got[0].Badge != "●" {
		t.Fatalf("filtered row badge = %q, want ●", got[0].Badge)
	}

	got = filteredLeafRows(items, "arturia", nil)
	if len(got) != 2 {
		t.Fatalf("vendor match kept %d rows, want both children only", len(got))
	}
	got = filteredLeafRows(items, "vst2", nil)
	if len(got) != 1 || got[0].Value != "vst:serum" {
		t.Fatalf("format match = %+v, want Serum only", got)
	}
	if got := filteredLeafRows(items, "zzz", nil); len(got) != 0 {
		t.Fatalf("no-match filter = %+v, want empty", got)
	}
}

// F opens the bottom filter zone, typing filters live, and F/Esc close
// it and restore the full list (the mosquitOmarchy convention).
func TestSearchKeyFlow(t *testing.T) {
	m := initialModel()
	m.w, m.h = 120, 40
	m.nav = []screen{scrMain, scrPluginList}
	m.pluginCache = []PluginItem{
		{Display: "Arturia", Value: "vendor:Arturia", Kind: "folder"},
		{Display: "Analog Lab V", Value: "vst:analog", Kind: "plugin", Parent: "vendor:Arturia", Formats: "vst3", Enabled: true},
		{Display: "Serum 2", Value: "vst:serum", Kind: "plugin", Formats: "vst2", Enabled: true},
	}
	m.pluginChecked = map[string]bool{"vst:analog": true, "vst:serum": true}
	m.pluginOrig = map[string]bool{"vst:analog": true, "vst:serum": true}
	m.rebuildPluginPicker()

	m = updateModel(t, m, tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'F'}})
	if !m.filterOpen {
		t.Fatal("F did not open the filter zone")
	}
	for _, r := range "analog" {
		m = updateModel(t, m, tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{r}})
	}
	if m.filterText != "analog" {
		t.Fatalf("filterText = %q, want analog", m.filterText)
	}
	if rows := m.picker.Items(); len(rows) != 1 {
		t.Fatalf("filtered list has %d rows, want one leaf: %+v", len(rows), rows)
	}

	m = updateModel(t, m, tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'F'}})
	if m.filterOpen || m.filterText != "" {
		t.Fatalf("F should close and clear the filter: open=%v text=%q", m.filterOpen, m.filterText)
	}
	if rows := m.picker.Items(); len(rows) < 2 {
		t.Fatalf("closing the filter left %d rows, want the full list", len(rows))
	}

	m = updateModel(t, m, tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'F'}})
	m = updateModel(t, m, tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'x'}})
	m = updateModel(t, m, tea.KeyMsg{Type: tea.KeyEsc})
	if m.filterOpen || m.filterText != "" {
		t.Fatalf("Esc should close and clear the filter: open=%v text=%q", m.filterOpen, m.filterText)
	}
}

// Opening the filter zone must not push the list upward: the reserved blank
// rows are replaced by the box, and the first plugin stays on the same line.
func TestFilterZoneDoesNotMoveTheList(t *testing.T) {
	m := initialModel()
	m.w, m.h = 120, 40
	m.nav = []screen{scrMain, scrPluginList}
	m.pluginCache = []PluginItem{
		{Display: "Arturia", Value: "vendor:Arturia", Kind: "folder"},
		{Display: "Analog Lab V", Value: "vst:analog", Kind: "plugin", Parent: "vendor:Arturia", Formats: "vst3", Enabled: true},
	}
	m.pluginChecked = map[string]bool{"vst:analog": true}
	m.pluginOrig = map[string]bool{"vst:analog": true}
	m.folderExpanded = map[string]bool{"vendor:Arturia": true}
	m.rebuildPluginPicker()
	lineOf := func(text string) int {
		for i, line := range strings.Split(m.View(), "\n") {
			if strings.Contains(line, text) {
				return i
			}
		}
		return -1
	}
	closed := lineOf("Analog Lab V")
	m.filterOpen = true
	open := lineOf("Analog Lab V")
	if closed < 0 || open != closed {
		t.Fatalf("filter shifted the list: closed line %d, open line %d", closed, open)
	}
}

func updateModel(t *testing.T, m model, msg tea.Msg) model {
	t.Helper()
	next, _ := m.Update(msg)
	out, ok := next.(model)
	if !ok {
		t.Fatalf("Update returned %T, want model", next)
	}
	return out
}
