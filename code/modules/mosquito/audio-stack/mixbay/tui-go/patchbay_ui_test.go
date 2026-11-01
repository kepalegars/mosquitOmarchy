package main

import (
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"mosquitomarchy.local/mosquitomixbay-tui/patchbay"
	tuikit "mosquitomarchy.local/tui-kit"
)

func TestPatchbayItemsMarkMismatch(t *testing.T) {
	m := initialModel()
	m.w, m.h = 100, 30
	m.patchbay.states = []patchbay.State{
		{Preset: patchbay.Preset{Name: "studio"}, Applies: true},
		{Preset: patchbay.Preset{Name: "old"}, Reason: "interfaces differ"},
	}
	items := m.patchbayItems()
	if len(items) != 5 {
		t.Fatalf("items = %d, want 5", len(items))
	}
	if items[0].Value != "save" {
		t.Fatalf("first row = %+v, want save", items[0])
	}
	if items[1].Suffix != "  ✓" || items[1].Disabled {
		t.Fatalf("applicable row = %+v", items[1])
	}
	if !items[2].Disabled || items[2].Suffix != "  (interfaces differ)" {
		t.Fatalf("mismatched row = %+v", items[2])
	}
}

func TestPatchbayEnterOpensConfirm(t *testing.T) {
	m := initialModel()
	m.w, m.h = 100, 30
	m.nav = append(m.nav, scrPatchbay)
	m.patchbay.states = []patchbay.State{{Preset: patchbay.Preset{Name: "studio"}, Applies: true}}
	m.syncPicker()
	m.picker = m.picker.SelectValue("apply:studio")

	nm, cmd := m.updateKey(tea.KeyMsg{Type: tea.KeyEnter})
	mm := nm.(model)
	if cmd != nil {
		t.Fatal("confirm must wait for the user")
	}
	if mm.top() != scrConfirm || mm.confirmAct == nil {
		t.Fatalf("top=%v act=%v", mm.top(), mm.confirmAct != nil)
	}
}

func TestPatchbayLoadedFillsPicker(t *testing.T) {
	m := initialModel()
	m.w, m.h = 100, 30
	m.nav = append(m.nav, scrPatchbay)
	m.patchbay.loading = true
	nm, _ := m.Update(patchbayLoadedMsg{states: []patchbay.State{{Preset: patchbay.Preset{Name: "studio"}, Applies: true}}})
	mm := nm.(model)
	if mm.patchbay.loading || len(mm.patchbay.states) != 1 {
		t.Fatalf("state = %+v", mm.patchbay)
	}
	vals := map[string]bool{}
	for _, it := range mm.patchbayItems() {
		vals[it.Value] = true
	}
	if !vals["apply:studio"] || !vals["save"] {
		t.Fatalf("items = %v", vals)
	}
}

func TestPatchbaySaveOpensNamePrompt(t *testing.T) {
	m := initialModel()
	m.w, m.h = 100, 30
	m.nav = append(m.nav, scrPatchbay)
	m.syncPicker()
	nm, _ := m.updateKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("s")})
	mm := nm.(model)
	if mm.top() != scrInput || mm.textAct == nil {
		t.Fatalf("top=%v act=%v", mm.top(), mm.textAct != nil)
	}
}

func TestPatchbaySaveSubmitClosesPrompt(t *testing.T) {
	m := initialModel()
	m.w, m.h = 100, 30
	m.nav = append(m.nav, scrPatchbay)
	m.syncPicker()
	nm, _ := m.updateKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("s")})
	m = nm.(model)
	nm, cmd := m.Update(tuikit.InputResultMsg{Value: "studio"})
	if cmd == nil {
		t.Fatal("submitting a name must run the save command")
	}
	if got := nm.(model).top(); got != scrPatchbay {
		t.Fatalf("top = %v, want patchbay", got)
	}
}
