package main

import (
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

// updateOnEmpty builds the Update screen with nothing pending.
func updateOnEmpty() model {
	m := initialModel()
	m.nav = []screen{scrMain, scrUpdate}
	m.w, m.h = 100, 34
	m.updateRec = UpdateRec{}
	m.updateSelected = map[string]bool{}
	m.updatePicker = m.rebuildUpdate()
	return m
}

// TestReinstallRowOffered: with no update pending, the Update screen offers
// "Reinstall last update…" instead of a dead page.
func TestReinstallRowOffered(t *testing.T) {
	m := updateOnEmpty()
	found := false
	for _, it := range m.updatePicker.items {
		if it.Value == "reinstall" {
			found = true
		}
	}
	if !found {
		t.Fatalf("no reinstall row on the empty Update screen")
	}
}

// TestReinstallListsInstalled: choosing the row fetches the status, and the
// status answer turns the installed modules into ticked rows on the same
// screen; a catalog-looking id never becomes a module key.
func TestReinstallListsInstalled(t *testing.T) {
	m := updateOnEmpty()
	m.updatePicker = m.updatePicker.SelectValue("reinstall")
	var cmd tea.Cmd
	m.updatePicker, cmd = m.updatePicker.Update(tea.KeyMsg{Type: tea.KeyEnter})
	if cmd == nil {
		t.Fatalf("Enter on the reinstall row produced no message")
	}
	m, _ = m.update(cmd())
	if !m.reinstallPending {
		t.Fatalf("reinstall row did not start a status fetch")
	}
	m, _ = m.update(queryMsg{kind: "status", status: []StatusRec{
		{Id: "reaper", Label: "REAPER + integration", State: "ok"},
		{Id: "ollama", Label: "Local AI", State: "missing"},
		{Id: "weird entry", Label: "not a module", State: "ok"},
		{Id: "apps", Label: "umbrella", State: "ok"},
	}})
	if !m.reinstallMode {
		t.Fatalf("status answer did not enter reinstall mode")
	}
	if !m.updateSelected["reaper"] {
		t.Fatalf("installed module not preselected")
	}
	if m.updateSelected["ollama"] || m.updateSelected["weird entry"] || m.updateSelected["apps"] {
		t.Fatalf("non-installed/non-module rows leaked into the selection")
	}
	if keys := m.updateKeys(); len(keys) != 1 || keys[0] != "reaper" {
		t.Fatalf("updateKeys = %v, want [reaper]", keys)
	}
}
