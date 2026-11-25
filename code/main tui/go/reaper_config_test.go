package main

import (
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"

	tuikit "mosquitomarchy.local/tui-kit"
)

// TestPOnReaperOpensConfigPrompt: P is the per-row REAPER config action, like P
// on DaVinci. It must warn about replacing the config, name the backup, and
// default to System fonts.
func TestPOnReaperOpensConfigPrompt(t *testing.T) {
	m := flatSetup()
	m.setupPicker = m.setupPicker.SelectValue(setupValue("apps", "reaper"))

	if view := ansi.Strip(m.View()); !strings.Contains(view, "P custom config") {
		t.Fatalf("Setup legend does not advertise the P key on the reaper row:\n%s", view)
	}

	m, _ = m.update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("P")})
	if m.top() != scrConfirm || m.pendingAction != "reaper-custom-config" {
		t.Fatalf("P on reaper did not open the config confirm: top=%v action=%q", m.top(), m.pendingAction)
	}
	for _, want := range []string{"REPLACES THE CURRENT CONFIG", "-install/", "THEME FILE", "Downloads", "bootstrap"} {
		if !strings.Contains(m.pendingMsg, want) {
			t.Fatalf("REAPER config prompt is missing %q: %q", want, m.pendingMsg)
		}
	}

	// The default button is Yes = System fonts, not the Extra (Reapertips) one.
	_, cmd := m.update(tea.KeyMsg{Type: tea.KeyEnter})
	if cmd == nil {
		t.Fatal("Enter on the REAPER config confirm returned no answer")
	}
	res, ok := cmd().(tuikit.ConfirmResultMsg)
	if !ok || res.Canceled || res.Extra || !res.Yes {
		t.Fatalf("default REAPER font answer = %+v, want Yes (System fonts)", res)
	}

	m = flatSetup()
	m.setupPicker = m.setupPicker.SelectValue(setupValue("apps", "extracto"))
	m, _ = m.update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("P")})
	if m.top() != scrSetup || m.pendingAction == "reaper-custom-config" {
		t.Fatalf("P on another row must be inert: top=%v action=%q", m.top(), m.pendingAction)
	}
}

// TestPOnReaperInUninstallRestores: the same per-row key must undo the install
// on the Uninstall page instead of offering to install again.
func TestPOnReaperInUninstallRestores(t *testing.T) {
	m := flatSetup()
	m.treeMode = "uninstall"
	m.setupPicker = m.setupPicker.SelectValue(setupValue("apps", "reaper"))

	view := ansi.Strip(m.View())
	if !strings.Contains(view, "P restore config") || strings.Contains(view, "P custom config") {
		t.Fatalf("Uninstall legend does not advertise the restore key:\n%s", view)
	}

	m, _ = m.update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("P")})
	if m.top() != scrConfirm || m.pendingAction != "reaper-custom-config-revert" {
		t.Fatalf("P on reaper in Uninstall did not open the restore confirm: top=%v action=%q", m.top(), m.pendingAction)
	}
	for _, want := range []string{"Restore the REAPER config backup", "-before-restore/", "SWS"} {
		if !strings.Contains(m.pendingMsg, want) {
			t.Fatalf("restore prompt is missing %q: %q", want, m.pendingMsg)
		}
	}

	// Enter = the focused Yes ("Restore").
	m = flatSetup()
	m.treeMode = "uninstall"
	m.setupPicker = m.setupPicker.SelectValue(setupValue("apps", "reaper"))
	m, _ = m.update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("P")})
	_, cmd := m.update(tea.KeyMsg{Type: tea.KeyEnter})
	if cmd == nil {
		t.Fatal("Enter on the restore confirm returned no answer")
	}
	if res := cmd().(tuikit.ConfirmResultMsg); res.Canceled || !res.Yes {
		t.Fatalf("default restore answer = %+v, want Yes", res)
	}
}

// TestReaperPromptScrollsAndWarns: the long P prompt lives in a height-capped
// scrollable list, and the red warning only appears when neither Downloads nor
// the network can provide ReaPack + SWS.
func TestReaperPromptScrollsAndWarns(t *testing.T) {
	m := flatSetup()
	m.setupPicker = m.setupPicker.SelectValue(setupValue("apps", "reaper"))
	m, _ = m.update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("P")})
	m, _ = m.update(reaperAddonsStatusMsg{missing: false})

	if len(m.confirm.List) < 2 {
		t.Fatal("REAPER prompt has no detail lines to scroll")
	}
	from, to := m.confirm.ListBoundsForTest()
	if to-from >= len(m.confirm.List) {
		t.Fatalf("prompt list is not capped: %d of %d rows visible", to-from, len(m.confirm.List))
	}
	if view := ansi.Strip(m.View()); !strings.Contains(view, "scroll list") {
		t.Fatalf("scrollable prompt does not advertise ↑/↓:\n%s", view)
	}
	if strings.Contains(ansi.Strip(m.View()), reaperAddonsMissingText) {
		t.Fatal("add-ons warning shown even though they are available")
	}

	m, _ = m.update(reaperAddonsStatusMsg{missing: true})
	view := ansi.Strip(m.View())
	if !strings.Contains(view, "sws & reapack are neither in downloads") ||
		!strings.Contains(view, "sws-2.14.0.7-Linux-x86_64.tar.xz") {
		t.Fatalf("missing add-ons warning is not at the top of the prompt:\n%s", view)
	}
}
