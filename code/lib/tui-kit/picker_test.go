package tuikit

import (
	"errors"
	"strings"
	"testing"

	"github.com/charmbracelet/bubbles/key"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

// newTestPicker builds a ready single-row picker, which is what a host screen
// holds: NewPicker alone has not run bubbles' init, so it would answer nothing.
func newTestPicker(t *testing.T, it PickerItem) Picker {
	t.Helper()
	return NewPicker("", []PickerItem{it}).SetSize(60, 20)
}

// A row block measured over the FULL tree can be wider than the pane it is
// drawn in — "lame language models" and its children measure 118 columns in a
// 92-column list. Centering that block is impossible, so the block has to be
// clamped: a block as wide as the list is already in place, which lays every
// row flush left on one column.
func TestBlockForClampsToTheList(t *testing.T) {
	cases := []struct{ maxRowW, listW, want int }{
		{maxRowW: 0, listW: 92, want: 92},   // nothing measured: fill the list
		{maxRowW: 57, listW: 92, want: 57},  // fits: centering still applies
		{maxRowW: 92, listW: 92, want: 92},  // exactly the list
		{maxRowW: 118, listW: 92, want: 92}, // overflows: flush left
	}
	for _, c := range cases {
		if got := blockFor(c.maxRowW, c.listW); got != c.want {
			t.Errorf("blockFor(%d, %d) = %d, attendu %d", c.maxRowW, c.listW, got, c.want)
		}
	}
}

// lipgloss WRAPS a string longer than Width, so an over-long row used to grow
// a second line out of nowhere. Inside a list that phantom line is invisible in
// the code and obvious on screen: it is the blank line that appeared between
// modules, and it desynchronised the list's pagination.
func TestFitBlockTruncatesInsteadOfWrapping(t *testing.T) {
	out := fitBlock(strings.Repeat("x", 200), 30, 40)
	if strings.Contains(out, "\n") {
		t.Errorf("fitBlock a replie la ligne: %q", out)
	}
	if w := lipgloss.Width(out); w != 40 {
		t.Errorf("largeur %d, attendu 40", w)
	}
}

// The delegate is REBUILT whenever the block width is pinned, and a rebuild
// that forgets the compact layout silently restores bubbles' defaults:
// ShowDescription on, height 2, spacing 1. A pinned picker then spent two
// terminal lines per option — a blank line between every module, and only half
// the list on screen.
func TestPinnedPickerKeepsOneLinePerOption(t *testing.T) {
	items := []PickerItem{
		{Display: "alpha", Value: "a"},
		{Display: "beta", Value: "b"},
		{Display: "gamma", Value: "c"},
	}
	for _, pinned := range []int{0, 200} {
		p := NewPicker("", items).SetSize(60, 20)
		if pinned > 0 {
			p = p.SetContentWidth(pinned)
		}
		view := p.View()
		seen := 0
		for _, l := range strings.Split(view, "\n") {
			if strings.Contains(l, "alpha") || strings.Contains(l, "beta") || strings.Contains(l, "gamma") {
				seen++
			}
		}
		if seen != len(items) {
			t.Errorf("pinned=%d: %d/%d options rendues", pinned, seen, len(items))
		}
		// The three options must land on three consecutive lines.
		var idx []int
		for i, l := range strings.Split(view, "\n") {
			for _, it := range items {
				if strings.Contains(ansi.Strip(l), it.Display) {
					idx = append(idx, i)
				}
			}
		}
		for k := 1; k < len(idx); k++ {
			if idx[k] != idx[k-1]+1 {
				t.Errorf("pinned=%d: ligne vide entre les options %d et %d", pinned, idx[k-1], idx[k])
			}
		}
	}
}

// THE SETTINGS RULE. A toggle row must ask for the OTHER state on Enter, and
// the kit must say which state it is moving to — the host repaints with that
// and applies afterwards, so the row never waits on a write. Getting this
// wrong is what made every settings row in this TUI feel dead: the write ran
// first, synchronously, and the label only changed once the subprocess was
// done.
func TestToggleRowAsksForTheOtherState(t *testing.T) {
	p := newTestPicker(t, PickerItem{
		Value:   "opt",
		Display: "off label",
		Toggle:  &ToggleSpec{On: "on label", Off: "off label", Value: false},
	})
	p, cmd := p.Update(tea.KeyMsg{Type: tea.KeyEnter})
	if cmd == nil {
		t.Fatal("Enter on a toggle row produced no command")
	}
	got, ok := cmd().(PickerToggleOptionMsg)
	if !ok {
		t.Fatalf("Enter on a toggle row emitted %T, want PickerToggleOptionMsg", cmd())
	}
	if got.Value != "opt" || !got.Next || got.Previous {
		t.Fatalf("got %+v, want Value=opt Next=true Previous=false", got)
	}

	// A toggle that is already on asks for off, and says what it was.
	p = newTestPicker(t, PickerItem{
		Value:   "opt",
		Display: "on label",
		Toggle:  &ToggleSpec{On: "on label", Off: "off label", Value: true},
	})
	_, cmd = p.Update(tea.KeyMsg{Type: tea.KeyEnter})
	got = cmd().(PickerToggleOptionMsg)
	if got.Next || !got.Previous {
		t.Fatalf("got %+v, want Next=false Previous=true", got)
	}
}

// A plain row is still an action: Enter must keep emitting PickerResultMsg, or
// giving one row a Toggle would silently change every other screen.
func TestPlainRowStillEmitsAResult(t *testing.T) {
	p := newTestPicker(t, PickerItem{Value: "opt", Display: "do the thing"})
	_, cmd := p.Update(tea.KeyMsg{Type: tea.KeyEnter})
	if _, ok := cmd().(PickerResultMsg); !ok {
		t.Fatalf("Enter on a plain row emitted %T, want PickerResultMsg", cmd())
	}
}

// A failed write has to report the state the setting really has, so the host
// can put the row back. A toggle that only ever moved forward would leave the
// menu claiming a change that did not happen.
func TestToggleOptionCmdReportsFailureWithTheRealState(t *testing.T) {
	boom := errors.New("refused")
	cmd := ToggleOptionCmd("opt", true, func(on bool) (bool, error) { return !on, boom })
	res := cmd().(ToggleOptionResultMsg)
	if !res.Failed || res.Err != boom {
		t.Fatalf("failure not reported: %+v", res)
	}
	if res.On {
		t.Fatal("On must be the state the setting REALLY has, not the one we asked for")
	}

	// A successful write reports what it actually set, not what we hoped.
	cmd = ToggleOptionCmd("opt", true, func(on bool) (bool, error) { return on, nil })
	res = cmd().(ToggleOptionResultMsg)
	if res.Failed || !res.On {
		t.Fatalf("success not reported: %+v", res)
	}
}

// ToggleSpec.Display is the only thing that builds a toggle label, so a host
// cannot pair the wrong string with the wrong state.
func TestToggleSpecDisplay(t *testing.T) {
	s := ToggleSpec{On: "ON", Off: "OFF"}
	if s.Display(true) != "ON" || s.Display(false) != "OFF" {
		t.Fatalf("Display returned %q / %q", s.Display(true), s.Display(false))
	}
}

// TestShortcutsHintFitsAndKeepsThePrimaryAction is the regression for a
// shortcut bar that did not fit.
//
// Measured on the Setup tree at 100 columns: a 123-column hint. The overflow was
// invisible — the bar is the bottom-most block, so the excess simply ran off the
// bottom edge — which is how "enter install selection", the one hint telling
// the user what Enter does on that screen, ended up off-screen. Wrapping it
// instead is not a fix: BottomBar is contractually BarRows tall and every budget
// subtracts exactly that, so a wrapped hint turned a two-row bar into a five-row
// one and the terminal scrolled the title away.
func TestShortcutsHintFitsAndKeepsThePrimaryAction(t *testing.T) {
	kb := func(k, d string) key.Binding {
		return key.NewBinding(key.WithKeys(k), key.WithHelp(k, d))
	}
	p := NewPicker("", []PickerItem{
		{Display: "one", Value: "1"},
		{Display: "two", Value: "2"},
	}).SetSize(92, 20).SetHelpKeys(
		kb("tab/x", "select"),
		kb("i", "info"),
		kb("shift+f", "search"),
		kb("right", "open"),
		kb("left", "close"),
		kb("enter", "install selection"),
	)

	hint := p.ShortcutsHint()
	plain := ansi.Strip(hint)
	if w := lipgloss.Width(plain); w > 92 {
		t.Errorf("hint is %d columns in a 92-column panel:\n%s", w, plain)
	}
	for _, want := range []string{"i info", "enter install selection"} {
		if !strings.Contains(plain, want) {
			t.Errorf("hint dropped %q — it must survive the fit:\n%s", want, plain)
		}
	}
	// And at a width where even the primary action cannot fit, it degrades to
	// something rather than wrapping.
	tiny := p.SetSize(24, 20).ShortcutsHint()
	if lipgloss.Height(tiny) != 1 {
		t.Errorf("hint wrapped at 24 columns:\n%s", ansi.Strip(tiny))
	}
}
