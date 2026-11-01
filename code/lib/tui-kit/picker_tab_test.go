package tuikit

import (
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

// resetTabGuard clears the package-level Tab repeat guard. It is shared by
// every Picker in the process (by design: a host rebuilds the Picker on each
// toggle, so a per-struct guard would be reset by the toggle itself), so
// tests must clear it before driving Tab.
func resetTabGuard() { ResetTabRepeatGuard() }

func tabPicker() Picker {
	resetTabGuard()
	return NewPicker("h", []PickerItem{
		{Display: "a", Value: "a"},
		{Display: "b", Value: "b"},
		{Display: "c", Value: "c"},
		{Display: "d", Value: "d"},
	}).SetSize(60, 20)
}

func tabMsgs(p Picker, keys ...string) (Picker, []tea.Msg) {
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

func tabToggles(msgs []tea.Msg) int {
	n := 0
	for _, m := range msgs {
		if _, ok := m.(PickerToggleMsg); ok {
			n++
		}
	}
	return n
}

// A fast double-tap toggles twice (untick works instantly — the guard does
// not eat the second press).
func TestFastDoubleTapTogglesTwice(t *testing.T) {
	p := tabPicker()
	_, msgs := tabMsgs(p, "tab", "tab")
	if got := tabToggles(msgs); got != 2 {
		t.Fatalf("same-row Tab twice gave %d toggles, want 2", got)
	}
}

// A held Tab (the repeat stream) is: two toggles then the lock. The row
// cannot flip-flop forever — the bug the user saw as "Tab acting like the
// key was stuck down".
func TestHeldTabLocksAfterTwoToggles(t *testing.T) {
	p := tabPicker()
	_, msgs := tabMsgs(p, "tab", "tab", "tab", "tab", "tab")
	if got := tabToggles(msgs); got != 2 {
		t.Fatalf("held Tab gave %d toggles, want exactly 2 then silence", got)
	}
}

// The lock must outlive the host's repaint: the host rebuilds the Picker
// between every repeat. Drive that exact cycle and the row still toggles
// twice then goes quiet, instead of restarting the count on each rebuild
// (the real-world flip-flop).
func TestHeldTabSurvivesRepaintRebuild(t *testing.T) {
	p := tabPicker()
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
		// The host's PickerToggleMsg handler: rebuild and keep the cursor.
		p = NewPicker("h", p.Items()).SetSize(60, 20).SelectValue("a")
		p, cmd = p.Update(kmsg("tab"))
	}
	if toggles != 2 {
		t.Fatalf("held Tab across repaints gave %d toggles, want exactly 2", toggles)
	}
}
