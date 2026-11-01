package tuikit

import "testing"

func TestConfirmFocusYes(t *testing.T) {
	c := NewConfirm("Clean up about 2 GB?", "No", "Yes").FocusYes()
	if c.focus != c.buttonCount()-1 {
		t.Fatalf("focus = %d, want the last (Yes) button", c.focus)
	}
}

// A cleanup prompt with a list keeps the list under the message and stays
// scrollable without changing the Yes focus.
func TestConfirmFocusYesWithList(t *testing.T) {
	c := NewConfirm("Clean up?", "No", "Yes").FocusYes().
		SetList("Selected cleanups", []string{"one", "two", "three"}, 2)
	if c.focus != c.buttonCount()-1 {
		t.Fatalf("focus changed after SetList: %d", c.focus)
	}
	if len(c.List) != 3 || c.ListMaxRows != 2 {
		t.Fatalf("list = %v/%d", c.List, c.ListMaxRows)
	}
}
