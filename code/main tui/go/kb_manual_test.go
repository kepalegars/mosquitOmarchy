package main

import (
	"strings"
	"testing"

	tuikit "mosquitomarchy.local/tui-kit"
)

// The key picker only lists SUPER + X; anything else (SUPER + ALT + M, …)
// needs a manual entry row to be reachable at all.
func TestKeyPickerOffersManualEntry(t *testing.T) {
	m := initialModel()
	m.kbFree = []string{"SUPER + A", "SUPER + B"}
	m.kbPending = KbCatItem{Label: "REAPER", Cmd: "reaper", Type: "launch"}
	p := m.rebuildKBKeys()
	found := false
	for _, it := range p.items {
		if it.Value == "manual" {
			found = true
		}
	}
	if !found {
		t.Fatalf("manual key row missing: %v", p.items)
	}
}

// A combo picked from the "free" list is checked too: that list only knows
// bindings.lua, so another hypr config can still own the key.
func TestPickedKeyAlsoChecksOwner(t *testing.T) {
	m := initialModel()
	m.w, m.h = 100, 34
	m.nav = []screen{scrMain, scrKBKeys}
	mm, cmd := m.screenPicked(tuikit.PickerResultMsg{Value: "SUPER + J"})
	if cmd == nil || mm.top() != scrKBKeys || mm.pendingAction != "" {
		t.Fatalf("picking a key did not defer to the owner check: top=%v action=%q cmd=%v", mm.top(), mm.pendingAction, cmd)
	}
}

func TestManualKeyWarnsBeforeOverriding(t *testing.T) {
	m := initialModel()
	m.w, m.h = 100, 34
	m.nav = []screen{scrMain, scrKBKeys}
	m.kbPending = KbCatItem{Label: "REAPER", Cmd: "reaper", Type: "launch"}

	mm, _ := m.screenPicked(tuikit.PickerResultMsg{Value: "manual"})
	if mm.top() != scrKBInput || mm.kbInputStep != 2 {
		t.Fatalf("manual row did not open the key input: top=%v step=%d", mm.top(), mm.kbInputStep)
	}

	mm, _ = mm.update(tuikit.InputResultMsg{Value: "SUPER + ALT + M"})
	if mm.top() != scrKBKeys || mm.kbInputStep != 0 {
		t.Fatalf("submitting the key did not return to the picker: top=%v step=%d", mm.top(), mm.kbInputStep)
	}

	// Backend says the combo is already owned: the confirm must say so and
	// carry "force" so kb-add knows the user accepted the override.
	mm, _ = mm.update(kbCheckMsg{combo: "SUPER + ALT + M", taken: true, where: "Omarchy default (Launch terminal)", overridable: true})
	if mm.top() != scrConfirm {
		t.Fatalf("taken key did not ask for confirmation: top=%v", mm.top())
	}
	if mm.pendingAction != "kb-add" || len(mm.pendingArgs) != 5 || mm.pendingArgs[4] != "force" {
		t.Fatalf("override not queued: action=%q args=%v", mm.pendingAction, mm.pendingArgs)
	}
	if !strings.Contains(mm.pendingMsg, "already bound") || !strings.Contains(mm.pendingMsg, "Omarchy default") {
		t.Fatalf("warning missing the existing owner: %q", mm.pendingMsg)
	}

	// A free combo goes through the same confirm, without the override.
	mm, _ = mm.update(kbCheckMsg{combo: "SUPER + SHIFT + F12"})
	if mm.top() != scrConfirm || len(mm.pendingArgs) != 4 {
		t.Fatalf("free key confirm wrong: top=%v args=%v", mm.top(), mm.pendingArgs)
	}
	if !strings.Contains(mm.pendingMsg, "Bind SUPER + SHIFT + F12") {
		t.Fatalf("free key confirm message wrong: %q", mm.pendingMsg)
	}
}

// A conflict declared after our block cannot be overridden: no "Bind anyway"
// prompt, and the manual entry comes back with its text for editing.
func TestUnsolvableConflictReturnsToEntry(t *testing.T) {
	m := initialModel()
	m.w, m.h = 100, 34
	m.nav = []screen{scrMain, scrKBKeys}
	m.kbPending = KbCatItem{Label: "REAPER"}
	mm, _ := m.screenPicked(tuikit.PickerResultMsg{Value: "manual"})
	mm, _ = mm.update(tuikit.InputResultMsg{Value: "SUPER + ALT + V"})

	mm, _ = mm.update(kbCheckMsg{combo: "SUPER + ALT + V", taken: true, where: "hyprland.lua (VM focus)"})
	if mm.top() != scrKBInput {
		t.Fatalf("unsolvable conflict did not return to the key input: top=%v", mm.top())
	}
	if mm.kbInputStep != 2 {
		t.Fatalf("key input step = %d, want 2", mm.kbInputStep)
	}
}

// Cancelling a bind prompt (plain or "Bind anyway") resumes the manual entry
// instead of dropping its text.
func TestCancelBindPromptResumesEntry(t *testing.T) {
	m := initialModel()
	m.w, m.h = 100, 34
	m.nav = []screen{scrMain, scrKBKeys, scrConfirm}
	m.kbPending = KbCatItem{Label: "REAPER"}
	m.pendingAction = "kb-add"
	m.kbManual = true
	m.kbInput = tuikit.NewTextInput("Key combo:", "SUPER + ALT + M")

	mm, _ := m.update(tuikit.ConfirmResultMsg{Canceled: true})
	if mm.top() != scrKBInput || mm.kbInputStep != 2 {
		t.Fatalf("cancel did not resume the key input: top=%v step=%d", mm.top(), mm.kbInputStep)
	}
}
