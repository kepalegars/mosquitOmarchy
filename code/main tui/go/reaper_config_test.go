package main

import (
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"

	tuikit "mosquitomarchy.local/tui-kit"
)

// TestCOnReaperOpensConfigPrompt: C is the per-row REAPER config action, like D
// on DaVinci. It must warn about replacing the config, name the backup, and
// default to System fonts.
func TestCOnReaperOpensConfigPrompt(t *testing.T) {
	m := flatSetup()
	m.setupPicker = m.setupPicker.SelectValue(setupValue("apps", "reaper"))

	if view := ansi.Strip(m.View()); !strings.Contains(view, "C custom config") {
		t.Fatalf("Setup legend does not advertise the C key on the reaper row:\n%s", view)
	}

	m, _ = m.update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("C")})
	if m.top() != scrConfirm || m.pendingAction != "reaper-custom-config" {
		t.Fatalf("C on reaper did not open the config confirm: top=%v action=%q", m.top(), m.pendingAction)
	}
	for _, want := range []string{"REPLACES THE CURRENT CONFIG", "-install/"} {
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
	m, _ = m.update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("C")})
	if m.top() != scrSetup || m.pendingAction == "reaper-custom-config" {
		t.Fatalf("C on another row must be inert: top=%v action=%q", m.top(), m.pendingAction)
	}
}

// TestCOnReaperInUninstallRestores: the same per-row key must undo the install
// on the Uninstall page instead of offering to install again.
func TestCOnReaperInUninstallRestores(t *testing.T) {
	m := flatSetup()
	m.treeMode = "uninstall"
	m.setupPicker = m.setupPicker.SelectValue(setupValue("apps", "reaper"))

	view := ansi.Strip(m.View())
	if !strings.Contains(view, "C restore config") || strings.Contains(view, "C custom config") {
		t.Fatalf("Uninstall legend does not advertise the restore key:\n%s", view)
	}

	m, _ = m.update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("C")})
	if m.top() != scrConfirm || m.pendingAction != "reaper-custom-config-revert" {
		t.Fatalf("C on reaper in Uninstall did not open the restore confirm: top=%v action=%q", m.top(), m.pendingAction)
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
	m, _ = m.update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("C")})
	_, cmd := m.update(tea.KeyMsg{Type: tea.KeyEnter})
	if cmd == nil {
		t.Fatal("Enter on the restore confirm returned no answer")
	}
	if res := cmd().(tuikit.ConfirmResultMsg); res.Canceled || !res.Yes {
		t.Fatalf("default restore answer = %+v, want Yes", res)
	}
}
