package main

import (
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	tuikit "mosquitomarchy.local/tui-kit"
)

// driveKeys feeds raw keys to the Setup picker and routes every message the
// picker emits back into the host, exactly like the terminal loop does —
// ToggleMsg AND RangeMsg alike.
func driveKeys(m model, keys ...tea.KeyMsg) model {
	for _, k := range keys {
		var cmd tea.Cmd
		m.setupPicker, cmd = m.setupPicker.Update(k)
		if cmd == nil {
			continue
		}
		m, _ = m.update(cmd())
	}
	return m
}

func tabKey() tea.KeyMsg { return tea.KeyMsg{Type: tea.KeyTab} }
func downKey() tea.KeyMsg {
	return tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("down")}
}
func upKey() tea.KeyMsg {
	return tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("up")}
}

// TestTabHeldDownChecksThePath: Tab, Down, Down checks the three rows from
// the anchor down — the file-explorer Shift+arrows gesture.
func TestTabHeldDownChecksThePath(t *testing.T) {
	m := flatSetup()
	m.nav = []screen{scrMain, scrSetup}
	m.w, m.h = 100, 34
	m.treeMode = "install"
	m.setupPicker = m.rebuildSetup()
	m.setupPicker = m.setupPicker.SelectIndex(0)
	m = driveKeys(m, tabKey(), downKey(), downKey(), downKey(), downKey())
	for _, key := range []string{"reaper", "extracto", "live-mode"} {
		found := false
		for v := range m.selected {
			if v == setupValue("apps", key) || v == setupValue("mosquito", key) {
				found = true
			}
		}
		if !found {
			t.Fatalf("%s not checked after Tab-held range: %v", key, m.selected)
		}
	}
}

// TestTabHeldRangeNeverUntoggles: rows Tab already checked stay checked
// when a later range crosses them again.
func TestTabHeldRangeNeverUntoggles(t *testing.T) {
	m := flatSetup()
	m.nav = []screen{scrMain, scrSetup}
	m.w, m.h = 100, 34
	m.treeMode = "install"
	m.setupPicker = m.rebuildSetup()
	m.setupPicker = m.setupPicker.SelectIndex(0)
	m = driveKeys(m, tabKey(), downKey())
	// Everything crossed is checked now; walk back up over it: still checked.
	m = driveKeys(m, upKey())
	for _, key := range []string{"reaper", "extracto"} {
		if !m.selected[setupValue("apps", key)] {
			t.Fatalf("%s lost its check on the way back: %v", key, m.selected)
		}
	}
}

// TestTabHeldRangeAsksKeepassxcConsent: a range that newly checks the
// KeePassXC row raises the same consent prompt as a single Tab.
func TestTabHeldRangeAsksKeepassxcConsent(t *testing.T) {
	m := initialModel()
	m.nav = []screen{scrMain, scrSetupCat}
	m.w, m.h = 100, 34
	m.treeMode = "install"
	m, _ = m.update(tuikit.PickerRangeMsg{Values: []string{"item:plugins:keepassxc"}})
	if m.top() != scrConfirm || m.pendingAction != "keepassxc-consent" {
		t.Fatalf("no consent prompt after range-checked keepassxc (top=%v action=%q)", m.top(), m.pendingAction)
	}
}

// TestTabHeldSurvivesBlink: the blink tick rebuilds the Setup picker every
// 600ms; a hold must survive it, or every range past one second silently
// stops selecting (the reported "it selects the first ones then stops").
func TestTabHeldSurvivesBlink(t *testing.T) {
	m := flatSetup()
	m.nav = []screen{scrMain, scrSetup}
	m.w, m.h = 100, 34
	m.treeMode = "install"
	m.setupPicker = m.rebuildSetup()
	m.setupPicker = m.setupPicker.SelectIndex(0)
	m = driveKeys(m, tabKey(), downKey())
	if !m.selected[setupValue("apps", "reaper")] {
		t.Fatal("first step did not check")
	}
	// Blink rebuild, as the 600ms tick does.
	m.setupPicker = m.rebuildSetup()
	m = driveKeys(m, downKey())
	if !m.selected[setupValue("apps", "extracto")] {
		t.Fatalf("range died on the blink rebuild: %v", m.selected)
	}
}

// TestRangeSkipsChecked: a Tab-held pass over an already-full folder leaves
// it full instead of flipping it empty like a second Tab would.
func TestRangeSkipsChecked(t *testing.T) {
	m := flatSetup()
	m.nav = []screen{scrMain, scrSetup}
	m.w, m.h = 100, 34
	m.treeMode = "install"
	m.setupPicker = m.rebuildSetup()
	m, _ = m.update(tuikit.PickerToggleMsg{Value: "cat:apps"})
	if !m.selected[setupValue("apps", "reaper")] {
		t.Fatal("setup: folder Tab did not tick")
	}
	m, _ = m.update(tuikit.PickerRangeMsg{Values: []string{"cat:apps", setupValue("apps", "reaper")}})
	if !m.selected[setupValue("apps", "reaper")] || !m.selected[setupValue("apps", "extracto")] {
		t.Fatalf("full folder flipped by the range: %v", m.selected)
	}
}

// Untick a folder (fast double-tap: tick then untick) and move on: the
// folder stays unticked instead of reselecting itself on the next arrow.
func TestUntickFolderThenMoveStaysUnticked(t *testing.T) {
	m := flatSetup()
	m.nav = []screen{scrMain, scrSetup}
	m.w, m.h = 100, 34
	m.treeMode = "install"
	m.setupPicker = m.rebuildSetup()
	m.setupPicker = m.setupPicker.SelectIndex(0)
	m = driveKeys(m, tabKey())
	if !m.selected[setupValue("apps", "reaper")] {
		t.Fatal("setup: folder Tab did not tick")
	}
	m = driveKeys(m, tabKey())
	if len(m.selected) != 0 {
		t.Fatalf("fast double-tap did not untick: %v", m.selected)
	}
	m = driveKeys(m, downKey(), downKey())
	if len(m.selected) != 0 {
		t.Fatalf("moving reselected the unticked folder: %v", m.selected)
	}
}
