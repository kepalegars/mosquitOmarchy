package tuikit

import (
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

// resetTabGuard clears the package-level Tab repeat guard. It is shared by
// every Picker in the process (by design: a host rebuilds the Picker on each
// toggle, so a per-struct guard would be reset by the toggle itself), so
// tests must clear it before driving Tab.
func resetTabGuard() { ResetTabRepeatGuard() }

func rangePicker() Picker {
	resetTabGuard()
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
	if len(vals) != 1 || vals[0] != "b" {
		t.Fatalf("range = %v, want [b] (anchor excluded)", vals)
	}
}

// Extending further down grows the range from the same anchor.
func TestTabHeldDownTwiceGrowsFromAnchor(t *testing.T) {
	p := rangePicker()
	_, msgs := rangeMsgs(p, "tab", "down", "down")
	vals := rangeValues(msgs)
	// First down emits [b], second emits [c]: one crossed row per step.
	if len(vals) != 2 || vals[0] != "b" || vals[1] != "c" {
		t.Fatalf("range values = %v, want [b c]", vals)
	}
}

// Up works symmetrically.
func TestTabHeldUpChecksUpwards(t *testing.T) {
	p := rangePicker()
	p, _ = rangeMsgs(p, "down", "down")
	_, msgs := rangeMsgs(p, "tab", "up")
	vals := rangeValues(msgs)
	if len(vals) != 1 || vals[0] != "b" {
		t.Fatalf("range = %v, want [b]", vals)
	}
}

// A fast double-tap toggles twice (untick works instantly — the guard does
// not eat the second press).
func TestFastDoubleTapTogglesTwice(t *testing.T) {
	p := rangePicker()
	_, msgs := rangeMsgs(p, "tab", "tab")
	toggles := 0
	for _, m := range msgs {
		if _, ok := m.(PickerToggleMsg); ok {
			toggles++
		}
	}
	if toggles != 2 {
		t.Fatalf("same-row Tab twice gave %d toggles, want 2", toggles)
	}
}

// A held Tab (the repeat stream) is: two toggles then the lock. The row
// cannot flip-flop forever — the bug the user saw as "Tab acting like the
// key was stuck down".
func TestHeldTabLocksAfterTwoToggles(t *testing.T) {
	p := rangePicker()
	_, msgs := rangeMsgs(p, "tab", "tab", "tab", "tab", "tab")
	toggles := 0
	for _, m := range msgs {
		if _, ok := m.(PickerToggleMsg); ok {
			toggles++
		}
	}
	if toggles != 2 {
		t.Fatalf("held Tab gave %d toggles, want exactly 2 then silence", toggles)
	}
}

// The lock must outlive the host's repaint: the host rebuilds the Picker (and
// calls ArmRange) between every repeat. Drive that exact cycle and the row
// still toggles twice then goes quiet, instead of restarting the count on
// each rebuild (the real-world flip-flop).
func TestHeldTabSurvivesRepaintRebuild(t *testing.T) {
	p := rangePicker()
	toggles := 0
	var cmd tea.Cmd
	p, cmd = p.Update(kmsg("tab"))
	for i := 0; i < 5; i++ {
		if cmd != nil {
			if m := cmd(); m != nil {
				if _, ok := m.(PickerToggleMsg); ok {
					toggles++
				}
			}
		}
		// The host's PickerToggleMsg handler: rebuild and re-arm at the row.
		p = p.ArmRange("a")
		p, cmd = p.Update(kmsg("tab"))
	}
	if toggles != 2 {
		t.Fatalf("held Tab across repaints gave %d toggles, want exactly 2", toggles)
	}
}

// Letting Tab go ends the range: once the guard clock lapses the next Down
// is a plain move, not another brush stroke. Key-up is unobservable to the
// program, so the lapse is faked by shrinking the window.
func TestReleasedTabEndsTheRange(t *testing.T) {
	p := rangePicker()
	old := tabRangeWindow
	tabRangeWindow = time.Nanosecond
	defer func() { tabRangeWindow = old }()
	var cmd tea.Cmd
	p, cmd = p.Update(kmsg("tab"))
	if cmd != nil {
		cmd()
	}
	time.Sleep(time.Millisecond)
	_, msgs := rangeMsgs(p, "down")
	if vals := rangeValues(msgs); len(vals) != 0 {
		t.Fatalf("range after release = %v, want none", vals)
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
	resetTabGuard()
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
	for _, want := range []string{"v1", "v20", "v39"} {
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
	resetTabGuard()
	p := NewPicker("h", []PickerItem{
		{Display: "a", Value: "a"},
		{Display: "head", Heading: true},
		{Display: "b", Value: "b"},
	}).SetSize(60, 20)
	_, msgs := rangeMsgs(p, "tab", "down", "down")
	vals := rangeValues(msgs)
	// One range [b]: the cursor skips the heading, the second down
	// goes nowhere. The heading itself is never included.
	if len(vals) != 1 || vals[0] != "b" {
		t.Fatalf("range = %v, want [b]", vals)
	}
}

// Turning back re-emits the rows crossed again (anchor still excluded), so
// the host toggles them back — down over two then up over one unchecks it.
func TestTabHeldTurnBackReemits(t *testing.T) {
	p := rangePicker()
	_, msgs := rangeMsgs(p, "tab", "down", "down", "up")
	vals := rangeValues(msgs)
	// [b], [c], [b]: down checks, down checks, back up unchecks.
	if len(vals) != 3 || vals[0] != "b" || vals[1] != "c" || vals[2] != "b" {
		t.Fatalf("turn-back ranges = %v, want [b c b]", vals)
	}
}
