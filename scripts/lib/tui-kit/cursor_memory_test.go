package tuikit

import (
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

func memPick() Picker {
	return NewPicker("h", []PickerItem{
		{Display: "one", Value: "a"},
		{Display: "two", Value: "b"},
		{Display: "three", Value: "c"},
	}).SetSize(60, 20)
}

// The bug this exists for: rebuild the list, and the cursor must stay where the
// user left it instead of jumping to row 0.
func TestCursorSurvivesARebuild(t *testing.T) {
	mem := NewCursorMemory()
	p := memPick().SelectIndex(2)
	mem.Remember("execs", p)

	fresh := NewPicker("h", []PickerItem{
		{Display: "one", Value: "a"},
		{Display: "two", Value: "b"},
		{Display: "three", Value: "c"},
	}).SetSize(60, 20)

	got := mem.Restore("execs", fresh)
	if got.Index() != 2 {
		t.Fatalf("after a rebuild the cursor is at %d, want 2", got.Index())
	}
	if got.SelectedValue() != "c" {
		t.Errorf("selected %q, want c", got.SelectedValue())
	}
}

// Match by VALUE, not index: when rows are inserted above the cursor, an
// index-based restore lands on a different plugin and the next action applies
// to the wrong thing.
func TestRestoreMatchesByValueNotIndex(t *testing.T) {
	mem := NewCursorMemory()
	mem.Remember("execs", memPick().SelectValue("b"))

	fresh := NewPicker("h", []PickerItem{
		{Display: "new", Value: "z"},
		{Display: "one", Value: "a"},
		{Display: "two", Value: "b"},
	}).SetSize(60, 20)

	got := mem.Restore("execs", fresh)
	if got.SelectedValue() != "b" {
		t.Errorf("selected %q, want b — a row was inserted above the cursor", got.SelectedValue())
	}
}

// A row that is GONE must not send the cursor past the end or to the top of an
// unrelated region: the nearest index survives.
func TestRestoreFallsBackWhenTheRowIsGone(t *testing.T) {
	mem := NewCursorMemory()
	mem.Remember("execs", memPick().SelectValue("c"))

	fresh := NewPicker("h", []PickerItem{
		{Display: "one", Value: "a"},
	}).SetSize(60, 20)

	got := mem.Restore("execs", fresh)
	if got.Index() >= len(got.Items()) {
		t.Fatalf("cursor is at %d with %d rows", got.Index(), len(got.Items()))
	}
}

// Two screens must not share a position, and an unvisited screen is untouched.
func TestScreensDoNotShare(t *testing.T) {
	mem := NewCursorMemory()
	mem.Remember("plugins", memPick().SelectIndex(2))

	other := mem.Restore("uninstall", memPick())
	if other.Index() != 0 {
		t.Errorf("an unvisited screen came back at row %d, want 0", other.Index())
	}
}

// Forgetting must actually forget, so a stale position cannot leak into a list
// that later reuses the name.
func TestForget(t *testing.T) {
	mem := NewCursorMemory()
	mem.Remember("x", memPick().SelectIndex(2))
	mem.Forget("x")
	if got := mem.Restore("x", memPick()); got.Index() != 0 {
		t.Errorf("after Forget the cursor is at %d, want 0", got.Index())
	}
}

// A nil memory must be inert: hosts that do not use it still compile and run.
func TestNilMemoryIsSafe(t *testing.T) {
	var mem *CursorMemory
	mem.Remember("x", memPick())
	if got := mem.Restore("x", memPick()); got.Index() != 0 {
		t.Errorf("a nil memory moved the cursor to %d", got.Index())
	}
}

// The real gesture: arrow down twice on a list, leave, come back.
func TestEnterAndLeaveKeepsTheRow(t *testing.T) {
	mem := NewCursorMemory()
	p := memPick().SetHelpKeys()

	// Two "down" presses.
	for i := 0; i < 2; i++ {
		np, _ := p.Update(tea.KeyMsg{Type: tea.KeyDown})
		p = np
	}
	if p.SelectedValue() != "c" {
		t.Fatalf("setup failed: at %q", p.SelectedValue())
	}
	mem.Remember("menu", p)

	back := mem.Restore("menu", memPick())
	if back.SelectedValue() != "c" {
		t.Errorf("coming back landed on %q, want c — the user has to walk again", back.SelectedValue())
	}
	_ = strings.TrimSpace(back.View())
}

// A rebuild on RE-ENTRY must not overwrite the position saved when the screen
// was left. Overwriting it with whatever picker is current loses it — the exact
// "leave and come back and I'm at the top again" symptom.
func TestRememberIfAbsentDoesNotClobber(t *testing.T) {
	mem := NewCursorMemory()
	mem.Remember("execs", memPick().SelectValue("b"))

	mem.RememberIfAbsent("execs", memPick().SelectValue("a"))
	if got := mem.Restore("execs", memPick()); got.SelectedValue() != "b" {
		t.Errorf("clobbered to %q, want b", got.SelectedValue())
	}

	// With nothing saved, it does save — that is the in-place rebuild case.
	mem2 := NewCursorMemory()
	mem2.RememberIfAbsent("execs", memPick().SelectValue("c"))
	if got := mem2.Restore("execs", memPick()); got.SelectedValue() != "c" {
		t.Errorf("first save did not take: %q", got.SelectedValue())
	}
}
