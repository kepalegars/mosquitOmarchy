package main

import (
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

// A query keeps the plugin rows that match AND the vendor row above them, so
// the filtered tree still says where the plugin lives. A vendor-name match
// keeps the whole suite.
func TestFilterItemsForSearch(t *testing.T) {
	items := []Item{
		{Display: "Arturia", Value: "vendor:Arturia", Kind: "folder"},
		{Display: "Analog Lab V", Value: "vst:analog", Kind: "plugin", Parent: "vendor:Arturia", Formats: "vst3"},
		{Display: "Mini V", Value: "vst:mini", Kind: "plugin", Parent: "vendor:Arturia", Formats: "vst3"},
		{Display: "Serum 2", Value: "vst:serum", Kind: "plugin", Formats: "vst2"},
	}

	got := filterItemsForSearch(items, "analog")
	if len(got) != 2 || got[0].Value != "vendor:Arturia" || got[1].Value != "vst:analog" {
		t.Fatalf("analog filter = %+v, want vendor + Analog Lab V", got)
	}

	got = filterItemsForSearch(items, "arturia")
	if len(got) != 3 {
		t.Fatalf("vendor match kept %d rows, want the folder and both children", len(got))
	}

	got = filterItemsForSearch(items, "vst2")
	if len(got) != 1 || got[0].Value != "vst:serum" {
		t.Fatalf("format match = %+v, want Serum only", got)
	}

	if got := filterItemsForSearch(items, "zzz"); len(got) != 0 {
		t.Fatalf("no-match filter = %+v, want empty", got)
	}
}

// shift+F opens the query, typing filters live, enter hands the list back to
// the cursor, and esc clears the filter before it leaves the screen.
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
		t.Fatal("shift+F did not open search")
	}
	for _, r := range "analog" {
		m = updateModel(t, m, tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{r}})
	}
	if m.filterText != "analog" {
		t.Fatalf("filterText = %q, want analog", m.filterText)
	}
	if rows := m.picker.Items(); len(rows) != 2 {
		t.Fatalf("filtered list has %d rows, want folder + one plugin: %+v", len(rows), rows)
	}

	m = updateModel(t, m, tea.KeyMsg{Type: tea.KeyEnter})
	if m.filterOpen || m.filterText != "analog" {
		t.Fatalf("enter should close the query and keep it: open=%v text=%q", m.filterOpen, m.filterText)
	}

	m = updateModel(t, m, tea.KeyMsg{Type: tea.KeyEsc})
	if m.filterText != "" {
		t.Fatalf("esc left filterText = %q, want empty", m.filterText)
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
