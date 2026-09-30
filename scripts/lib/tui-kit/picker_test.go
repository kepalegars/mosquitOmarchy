package tuikit

import (
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

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
