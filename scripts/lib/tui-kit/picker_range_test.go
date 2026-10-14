package tuikit

import (
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

func rangePicker() Picker {
	return NewPicker("h", []PickerItem{
		{Display: "a", Value: "a"},
		{Display: "b", Value: "b"},
		{Display: "c", Value: "c"},
		{Display: "d", Value: "d"},
	}).SetSize(60, 20)
}

func rangeMsgs(p Picker, keys ...string) (Picker, []tea.Msg) {
	var out []tea.Msg
	for _, k := range keys {
		var cmd tea.Cmd
		p, cmd = p.Update(kmsg(k))
		if cmd != nil {
			if m := cmd(); m != nil {
				out = append(out, m)
			}
		}
	}
	return p, out
}

func rangeValues(msgs []tea.Msg) []string {
	var vals []string
	for _, m := range msgs {
		if r, ok := m.(PickerRangeMsg); ok {
			vals = append(vals, r.Values...)
		}
	}
	return vals
}

// Tab then Down checks every row on the way, anchor included.
func TestTabHeldDownChecksThePath(t *testing.T) {
	p := rangePicker()
	p, msgs := rangeMsgs(p, "tab", "down")
	foundToggle := false
	for _, m := range msgs {
		if tm, ok := m.(PickerToggleMsg); ok && tm.Value == "a" {
			foundToggle = true
		}
	}
	if !foundToggle {
		t.Fatal("Tab did not toggle the anchor row")
	}
	vals := rangeValues(msgs)
	if len(vals) != 2 || vals[0] != "a" || vals[1] != "b" {
		t.Fatalf("range = %v, want [a b]", vals)
	}
}

// Extending further down grows the range from the same anchor.
func TestTabHeldDownTwiceGrowsFromAnchor(t *testing.T) {
	p := rangePicker()
	_, msgs := rangeMsgs(p, "tab", "down", "down")
	vals := rangeValues(msgs)
	// First down: [a b]; second down: [a b c].
	if len(vals) != 5 {
		t.Fatalf("range values = %v, want 5 across two steps", vals)
	}
	if vals[4] != "c" {
		t.Fatalf("extended range does not reach c: %v", vals)
	}
}

// Up works symmetrically.
func TestTabHeldUpChecksUpwards(t *testing.T) {
	p := rangePicker()
	p, _ = rangeMsgs(p, "down", "down")
	_, msgs := rangeMsgs(p, "tab", "up")
	vals := rangeValues(msgs)
	if len(vals) != 2 || vals[0] != "b" || vals[1] != "c" {
		t.Fatalf("range = %v, want [b c]", vals)
	}
}

// A repeated Tab on the same row (physically held key) must not flip-flop.
func TestHeldTabRepeatDoesNotToggle(t *testing.T) {
	p := rangePicker()
	_, msgs := rangeMsgs(p, "tab", "tab")
	toggles := 0
	for _, m := range msgs {
		if _, ok := m.(PickerToggleMsg); ok {
			toggles++
		}
	}
	if toggles != 1 {
		t.Fatalf("same-row Tab twice gave %d toggles, want 1", toggles)
	}
}

// Any other key ends the hold: x, then arrows, selects nothing.
func TestOtherKeyEndsTheHold(t *testing.T) {
	p := rangePicker()
	_, msgs := rangeMsgs(p, "tab", "x", "down")
	if vals := rangeValues(msgs); len(vals) != 0 {
		t.Fatalf("range after x = %v, want none", vals)
	}
}

// Enter ends the hold and acts normally.
func TestEnterEndsTheHold(t *testing.T) {
	p := rangePicker()
	p, msgs := rangeMsgs(p, "tab", "enter")
	if vals := rangeValues(msgs); len(vals) != 0 {
		t.Fatalf("range on enter = %v, want none", vals)
	}
	foundResult := false
	for _, m := range msgs {
		if _, ok := m.(PickerResultMsg); ok {
			foundResult = true
		}
	}
	if !foundResult {
		t.Fatal("enter did not choose")
	}
}

// A held range keeps emitting across a long list: every step from the
// anchor re-reports the whole crossed span, so no row on the way is missed
// even over dozens of rows.
func TestTabHeldRangeSpansLongLists(t *testing.T) {
	items := make([]PickerItem, 0, 40)
	for i := 0; i < 40; i++ {
		items = append(items, PickerItem{Display: "row", Value: "v" + itoa(i)})
	}
	p := NewPicker("h", items).SetSize(60, 8)
	p, msgs := rangeMsgs(p, "tab")
	for i := 0; i < 39; i++ {
		var cmd tea.Cmd
		p, cmd = p.Update(kmsg("down"))
		if cmd != nil {
			if m := cmd(); m != nil {
				msgs = append(msgs, m)
			}
		}
	}
	vals := rangeValues(msgs)
	seen := map[string]bool{}
	for _, v := range vals {
		seen[v] = true
	}
	for _, want := range []string{"v0", "v20", "v39"} {
		if !seen[want] {
			t.Fatalf("row %q never crossed (vals=%d)", want, len(vals))
		}
	}
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	out := ""
	for n > 0 {
		out = string(rune('0'+n%10)) + out
		n /= 10
	}
	return out
}

// Inert rows (headings, disabled) are skipped by the range.
func TestRangeSkipsInertRows(t *testing.T) {
	p := NewPicker("h", []PickerItem{
		{Display: "a", Value: "a"},
		{Display: "head", Heading: true},
		{Display: "b", Value: "b"},
	}).SetSize(60, 20)
	_, msgs := rangeMsgs(p, "tab", "down", "down")
	vals := rangeValues(msgs)
	// One range [a b]: the cursor skips the heading, the second down
	// goes nowhere. The heading itself is never included.
	if len(vals) != 2 || vals[0] != "a" || vals[1] != "b" {
		t.Fatalf("range = %v, want [a b]", vals)
	}
}
