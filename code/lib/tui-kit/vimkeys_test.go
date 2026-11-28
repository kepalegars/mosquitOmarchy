package tuikit

import (
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

// The vim-style key policy is shared by every interactive widget: h is back,
// l is confirm, j/k move. These tests drive each widget with the real keys, so
// a host cannot drift away from the policy by wiring its own meaning.

func TestPickerVimBackAndConfirm(t *testing.T) {
	p := newTestPicker(t, PickerItem{Display: "a", Value: "a"})

	_, cmd := p.Update(kmsg("h"))
	if cmd == nil {
		t.Fatal("h produced no command")
	}
	if msg, ok := cmd().(PickerResultMsg); !ok || !msg.Canceled {
		t.Fatalf("h = %#v, want a canceled PickerResultMsg", msg)
	}

	_, cmd = p.Update(kmsg("l"))
	if cmd == nil {
		t.Fatal("l produced no command")
	}
	if msg, ok := cmd().(PickerResultMsg); !ok || msg.Canceled || msg.Value != "a" {
		t.Fatalf("l = %#v, want PickerResultMsg{Value: a}", msg)
	}
}

func TestPickerVimJKMoveTheCursor(t *testing.T) {
	p := NewPicker("", []PickerItem{
		{Display: "a", Value: "a"},
		{Display: "b", Value: "b"},
	}).SetSize(60, 20)

	p, _ = p.Update(kmsg("j"))
	if got := p.SelectedValue(); got != "b" {
		t.Fatalf("j left the cursor on %q, want b", got)
	}
	p, _ = p.Update(kmsg("k"))
	if got := p.SelectedValue(); got != "a" {
		t.Fatalf("k left the cursor on %q, want a", got)
	}
}

// On a tree, l folds instead of confirming: the same key must never install a
// whole selection by accident.
func TestPickerTreeLIsFoldNotConfirm(t *testing.T) {
	items := []PickerItem{
		{Display: "Folder", Value: "cat:f", Folder: true, Fold: FoldExpanded},
		{Display: "child", Value: "item:c"},
	}

	// WithFoldState: the host folds through PickerSortMsg.
	p := NewPicker("", items).SetSize(60, 20).WithFoldState().SelectValue("cat:f")
	_, cmd := p.Update(kmsg("l"))
	if cmd == nil {
		t.Fatal("l on a tree produced no command")
	}
	fold, ok := cmd().(PickerSortMsg)
	if !ok || fold.Dir != -1 {
		t.Fatalf("l on an expanded folder = %#v, want PickerSortMsg{Dir: -1}", cmd())
	}

	// A collapsed folder toggles the other way.
	items[0].Fold = FoldCollapsed
	p = NewPicker("", items).SetSize(60, 20).WithFoldState().SelectValue("cat:f")
	_, cmd = p.Update(kmsg("l"))
	if fold, ok := cmd().(PickerSortMsg); !ok || fold.Dir != 1 {
		t.Fatalf("l on a collapsed folder = %#v, want PickerSortMsg{Dir: 1}", cmd())
	}

	// WithTree: the kit owns the flip and reports it as TreeFoldMsg.
	open := map[string]bool{"cat:f": true}
	p = NewPicker("", items).SetSize(60, 20).WithTree(open).SelectValue("cat:f")
	p, cmd = p.Update(kmsg("l"))
	if cmd == nil {
		t.Fatal("l on a WithTree picker produced no command")
	}
	msg, ok := cmd().(TreeFoldMsg)
	if !ok || msg.Folder != "cat:f" || msg.Open || msg.Cursor != "cat:f" {
		t.Fatalf("l = %#v, want TreeFoldMsg{Folder: cat:f, Open: false, Cursor: cat:f}", cmd())
	}
	if open["cat:f"] {
		t.Fatal("the shared open map was not flipped")
	}

	// Enter still validates on a tree.
	p = p.SelectValue("cat:f")
	_, cmd = p.Update(kmsg("enter"))
	if msg, ok := cmd().(PickerResultMsg); !ok || msg.Value != "cat:f" {
		t.Fatalf("enter on a tree = %#v, want PickerResultMsg{Value: cat:f}", cmd())
	}
}

func TestConfirmVimKeys(t *testing.T) {
	_, cmd := NewConfirm("Continue?", "No", "Yes").Update(kmsg("h"))
	if msg, ok := cmd().(ConfirmResultMsg); !ok || !msg.Canceled {
		t.Fatalf("h = %#v, want canceled", cmd())
	}

	// l submits the focused answer, exactly like Enter.
	c := NewConfirm("Continue?", "No", "Yes")
	c, _ = c.Update(kmsg("right"))
	_, cmd = c.Update(kmsg("l"))
	if msg, ok := cmd().(ConfirmResultMsg); !ok || !msg.Yes || msg.Canceled {
		t.Fatalf("right then l = %#v, want Yes", cmd())
	}
}

// j/k scroll the evidence list and never move the focused answer.
func TestConfirmJKScrollTheListNotTheButtons(t *testing.T) {
	c := NewConfirm("Continue?", "No", "Yes").SetList("Rows", []string{"1", "2", "3", "4"}, 2)
	from, _ := c.ListBoundsForTest()
	c, _ = c.Update(kmsg("j"))
	after, _ := c.ListBoundsForTest()
	if after != from+1 {
		t.Fatalf("j moved the list window from %d to %d, want %d", from, after, from+1)
	}
	// Focus is still No (the first button): Enter answers No.
	_, cmd := c.Update(kmsg("enter"))
	if msg, ok := cmd().(ConfirmResultMsg); !ok || msg.Yes {
		t.Fatalf("enter after j = %#v, want No", cmd())
	}
}

func TestInfoConfirmVimKeys(t *testing.T) {
	_, cmd := NewInfoConfirm("Continue?", "No", "Yes").Update(kmsg("h"))
	if msg, ok := cmd().(ConfirmResultMsg); !ok || !msg.Canceled {
		t.Fatalf("h = %#v, want canceled", cmd())
	}

	c := NewInfoConfirm("Continue?", "No", "Yes")
	c, _ = c.Update(kmsg("right"))
	_, cmd = c.Update(kmsg("l"))
	if msg, ok := cmd().(ConfirmResultMsg); !ok || !msg.Yes {
		t.Fatalf("right then l = %#v, want Yes", cmd())
	}
}

func TestInfoVimKeysDismiss(t *testing.T) {
	for _, key := range []string{"h", "l"} {
		_, cmd := NewInfo("details").Update(kmsg(key))
		if cmd == nil {
			t.Fatalf("%s produced no command", key)
		}
		if _, ok := cmd().(InfoDismissedMsg); !ok {
			t.Fatalf("%s did not dismiss the Info", key)
		}
	}
}

// A text input types h/j/k/l literally; only Enter submits and Esc cancels.
func TestTextInputKeepsVimKeysLiteral(t *testing.T) {
	ti := NewTextInput("name", "")
	for _, k := range []string{"h", "j", "k", "l"} {
		ti, _ = ti.Update(kmsg(k))
	}
	_, cmd := ti.Update(kmsg("enter"))
	msg, ok := cmd().(InputResultMsg)
	if !ok || msg.Canceled || msg.Value != "hjkl" {
		t.Fatalf("typed value = %#v, want hjkl", msg)
	}

	_, cmd = ti.Update(tea.KeyMsg{Type: tea.KeyEsc})
	if msg, ok := cmd().(InputResultMsg); !ok || !msg.Canceled {
		t.Fatalf("esc = %#v, want canceled", cmd())
	}
}
