package main

import (
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	tuikit "mosquitomarchy.local/tui-kit"
)

// TestTabOnFolderTicksAll: Tab on a level-1 folder ticks every tickable row
// inside it (greyed rows stay out), and unticks them all on the second Tab.
func TestTabOnFolderTicksAll(t *testing.T) {
	m := flatSetup()
	m.nav = []screen{scrMain, scrSetup}
	m.w, m.h = 100, 34
	m.treeMode = "install"
	m.setupPicker = m.rebuildSetup()
	m.setupPicker = m.setupPicker.SelectValue("cat:apps")
	var cmd tea.Cmd
	m.setupPicker, cmd = m.setupPicker.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("\t")})
	_ = cmd
	// The picker emits ToggleMsg through its own Update; drive the host path.
	m, _ = m.update(tuikit.PickerToggleMsg{Value: "cat:apps"})
	if !m.selected[setupValue("apps", "reaper")] || !m.selected[setupValue("apps", "extracto")] {
		t.Fatalf("folder Tab did not tick the children: %v", m.selected)
	}
	m, _ = m.update(tuikit.PickerToggleMsg{Value: "cat:apps"})
	if m.selected[setupValue("apps", "reaper")] || m.selected[setupValue("apps", "extracto")] {
		t.Fatalf("second folder Tab did not untick: %v", m.selected)
	}
}

// TestFolderSquareNeedsFullTick: the folder square fills only when every
// tickable row is ticked; a partial tick leaves it empty.
func TestFolderSquareNeedsFullTick(t *testing.T) {
	m := flatSetup()
	m.w, m.h = 100, 34
	m.treeMode = "install"
	square := func() bool {
		for _, it := range m.rebuildSetup().items {
			if it.Value == "cat:apps" {
				return it.TrailingBadge == "■"
			}
		}
		return false
	}
	m.selected[setupValue("apps", "reaper")] = true
	if square() {
		t.Fatalf("partial tick filled the folder square")
	}
	m.selected[setupValue("apps", "extracto")] = true
	if !square() {
		t.Fatalf("full tick did not fill the folder square")
	}
}
