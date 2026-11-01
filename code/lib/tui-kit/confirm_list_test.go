package tuikit

import (
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

func names(n int) []string {
	out := make([]string, n)
	for i := range out {
		out[i] = "Plugin " + string(rune('A'+i))
	}
	return out
}

// A confirmation that says "this will touch 21 plugins" without naming them is
// one nobody can answer. The list is the evidence, and it has to be in the
// dialog rather than behind a key.
func TestConfirmCanCarryAList(t *testing.T) {
	c := NewConfirm("Apply 1 fix to the FabFilter suite?", "no", "apply").
		SetList("these plugins (21)", names(21), 6)
	v := c.View()
	if !strings.Contains(v, "these plugins") {
		t.Error("the list title is missing")
	}
	if !strings.Contains(v, "Plugin A") {
		t.Error("the list does not show the first row")
	}
	// 21 rows in a 6-row window cannot fit, and the dialog has to admit it.
	if strings.Contains(v, "Plugin G") {
		t.Error("the window shows more rows than it was given")
	}
	if !strings.Contains(v, "1–6 of 21") {
		t.Errorf("the dialog does not say the list is cut short:\n%s", v)
	}
}

// ↑/↓ scroll the list. It has to be the vertical arrows specifically: left and
// right already move between the buttons, and hijacking them would break every
// dialog in these apps.
func TestConfirmListScrolls(t *testing.T) {
	c := NewConfirm("apply?", "no", "apply").SetList("", names(21), 6)
	for i := 0; i < 3; i++ {
		c, _ = c.Update(tea.KeyMsg{Type: tea.KeyDown})
	}
	if !strings.Contains(c.View(), "4–9 of 21") {
		t.Errorf("three ↓ presses should show rows 4–9:\n%s", c.View())
	}
	// Back to the top, and stop there rather than wrapping or going blank.
	for i := 0; i < 30; i++ {
		c, _ = c.Update(tea.KeyMsg{Type: tea.KeyUp})
	}
	if !strings.Contains(c.View(), "1–6 of 21") {
		t.Errorf("scrolling up past the top should stay at the top:\n%s", c.View())
	}
	c, _ = c.Update(tea.KeyMsg{Type: tea.KeyEnd})
	if !strings.Contains(c.View(), "16–21 of 21") {
		t.Errorf("end should show the last window:\n%s", c.View())
	}
	// And down past the end.
	for i := 0; i < 30; i++ {
		c, _ = c.Update(tea.KeyMsg{Type: tea.KeyDown})
	}
	if !strings.Contains(c.View(), "16–21 of 21") {
		t.Errorf("scrolling down past the end should stay at the end:\n%s", c.View())
	}
}

// A list shorter than the window is shown whole, with no scroll hint — there is
// nothing to scroll.
func TestShortListShowsWholeWithNoHint(t *testing.T) {
	c := NewConfirm("apply?", "no", "apply").SetList("these", names(3), 8)
	v := c.View()
	if !strings.Contains(v, "Plugin C") {
		t.Error("the third row is missing")
	}
	if strings.Contains(v, "to scroll") {
		t.Errorf("a list that fits should not claim to scroll:\n%s", v)
	}
}

// Scrolling must not answer the question. A dialog where ↓ dismisses or where
// y/n stops working is worse than one without a list.
func TestScrollingDoesNotSubmitOrCancel(t *testing.T) {
	c := NewConfirm("apply?", "no", "apply").SetList("", names(21), 6)
	for _, k := range []tea.KeyType{tea.KeyDown, tea.KeyUp, tea.KeyEnd, tea.KeyHome} {
		var cmd tea.Cmd
		c, cmd = c.Update(tea.KeyMsg{Type: k})
		if cmd != nil {
			t.Errorf("scrolling (key %v) produced a result message", k)
		}
	}
	// The buttons still answer.
	c = c.SetFocus(1)
	_, cmd := c.Update(tea.KeyMsg{Type: tea.KeyEnter})
	if cmd == nil {
		t.Fatal("enter no longer submits")
	}
	if _, ok := cmd().(ConfirmResultMsg); !ok {
		t.Error("enter produced the wrong message")
	}
	// And left/right still move between buttons, not the list.
	before := c.focus
	c, _ = c.Update(tea.KeyMsg{Type: tea.KeyRight})
	if c.focus == before {
		t.Error("right no longer moves the button focus")
	}
}

// Every existing dialog must render EXACTLY as it did: the kit is shared by six
// apps and a stray blank line in a shared modal is a visible regression
// everywhere.
func TestConfirmWithoutAListIsUnchanged(t *testing.T) {
	plain := NewConfirm("Really?", "no", "yes")
	withEmpty := NewConfirm("Really?", "no", "yes").SetList("ignored", nil, 5)
	if plain.View() != withEmpty.View() {
		t.Errorf("an empty list changed the dialog:\n%q\n%q", plain.View(), withEmpty.View())
	}
}
