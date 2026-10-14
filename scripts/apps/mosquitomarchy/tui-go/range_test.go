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

// TestTabHeldBrushChecksUnchecks: Tab on a leaf, Down, Down checks the two
// crossed leaves; stepping onto the folder row fills it as a unit (one
// more step onto live-mode itself would toggle it back off — the brush
// toggles everything it enters).
func TestTabHeldBrushChecksUnchecks(t *testing.T) {
	m := flatSetup()
	m.nav = []screen{scrMain, scrSetup}
	m.w, m.h = 100, 34
	m.treeMode = "install"
	m.setupPicker = m.rebuildSetup()
	// Start on the first leaf, not the folder.
	m.setupPicker = m.setupPicker.SelectIndex(1)
	m = driveKeys(m, tabKey(), downKey())
	if !m.selected[setupValue("apps", "reaper")] || !m.selected[setupValue("apps", "extracto")] {
		t.Fatalf("brush did not check crossed leaves: %v", m.selected)
	}
	m = driveKeys(m, downKey())
	if !m.selected[setupValue("mosquito", "live-mode")] {
		t.Fatalf("brush did not fill the crossed folder: %v", m.selected)
	}
}

// TestTabHeldTurnBackUntoggles: down over two rows checks them, back up
// over one unchecks it again — the range is a toggle brush, not check-only.
func TestTabHeldTurnBackUntoggles(t *testing.T) {
	m := flatSetup()
	m.nav = []screen{scrMain, scrSetup}
	m.w, m.h = 100, 34
	m.treeMode = "install"
	m.setupPicker = m.rebuildSetup()
	// Start on the first leaf, not the folder, so the range is rows only.
	m.setupPicker = m.setupPicker.SelectIndex(1)
	m = driveKeys(m, tabKey(), downKey())
	if !m.selected[setupValue("apps", "reaper")] || !m.selected[setupValue("apps", "extracto")] {
		t.Fatalf("down range did not check: %v", m.selected)
	}
	// Back up onto the anchor: it toggles off, the other row keeps its check.
	m = driveKeys(m, upKey())
	if m.selected[setupValue("apps", "reaper")] {
		t.Fatalf("turn-back did not untoggle the anchor: %v", m.selected)
	}
	if !m.selected[setupValue("apps", "extracto")] {
		t.Fatalf("turn-back cleared too much: %v", m.selected)
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
	m.setupPicker = m.setupPicker.SelectIndex(1)
	m = driveKeys(m, tabKey(), downKey())
	if !m.selected[setupValue("apps", "extracto")] {
		t.Fatal("first step did not check")
	}
	// Blink rebuild, as the 600ms tick does.
	m.setupPicker = m.rebuildSetup()
	m = driveKeys(m, downKey())
	if !m.selected[setupValue("mosquito", "live-mode")] {
		t.Fatalf("range died on the blink rebuild: %v", m.selected)
	}
}

// TestRangeTogglesFolder: a Tab-held pass over a folder value flips it
// through the same fill-or-empty path as its Tab.
func TestRangeTogglesFolder(t *testing.T) {
	m := flatSetup()
	m.nav = []screen{scrMain, scrSetup}
	m.w, m.h = 100, 34
	m.treeMode = "install"
	m.setupPicker = m.rebuildSetup()
	m, _ = m.update(tuikit.PickerRangeMsg{Values: []string{"cat:apps"}, Anchor: "cat:apps"})
	if !m.selected[setupValue("apps", "reaper")] || !m.selected[setupValue("apps", "extracto")] {
		t.Fatalf("folder range did not fill: %v", m.selected)
	}
	m, _ = m.update(tuikit.PickerRangeMsg{Values: []string{"cat:apps"}, Anchor: "cat:apps"})
	if len(m.selected) != 0 {
		t.Fatalf("second folder range did not empty: %v", m.selected)
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
