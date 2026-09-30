package tuikit

import (
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"
)

// TestFolderIconNeedsNoNerdFont is the guard behind dropping U+F07B: the folder
// glyph used to be nf-fa-folder, so on any terminal without a Nerd Font it
// rendered as a tofu box and the one row type the glyph exists to disambiguate
// became unreadable. Geometric Shapes is the same block the fold arrows, the
// cursor and the ○/● marks already come from, so it can never be the odd one
// out.
func TestFolderIconNeedsNoNerdFont(t *testing.T) {
	for _, g := range []string{FolderClosed, FolderOpen} {
		if g == "" {
			t.Fatal("folder glyph must not be empty")
		}
		for _, r := range g {
			if r > 0x2FFF {
				t.Fatalf("folder glyph %q is outside BMP Unicode (U+%04X): that is a Private Use Area codepoint, i.e. a Nerd Font icon",
					string(r), r)
			}
		}
	}
	if FolderClosed == FolderOpen {
		t.Fatal("open and closed folders must be different glyphs")
	}
}

// TestFolderIconTracksFold checks the glyph follows the row's fold state, so a
// collapsed folder reads differently from an expanded one even though both sit
// in the same leading slot.
func TestFolderIconTracksFold(t *testing.T) {
	mk := func(fold string) PickerItem {
		return PickerItem{Display: "Apps", Value: "cat:apps", Folder: true, Fold: fold}
	}
	d := newPickerDelegate(2, 2, 0, true)
	closed := d.leadCell(mk(FoldCollapsed), false)
	open := d.leadCell(mk(FoldExpanded), false)
	if !strings.Contains(closed, FolderClosed) {
		t.Errorf("collapsed folder should draw %q, got %q", FolderClosed, closed)
	}
	if !strings.Contains(open, FolderOpen) {
		t.Errorf("expanded folder should draw %q, got %q", FolderOpen, open)
	}
	// A leaf keeps its checkbox: the folder glyph must not leak onto items.
	leaf := d.leadCell(PickerItem{Display: "reaper", Value: "item:r", Badge: "○"}, false)
	if strings.Contains(leaf, FolderClosed) || strings.Contains(leaf, FolderOpen) {
		t.Errorf("a non-folder row must keep its badge, got %q", leaf)
	}
}

// TestFolderIconDistinguishesSelection pins the idle/selected contrast. Both
// states are grey-ish neutrals on purpose: on achraff-67 the accent is a lime
// and an unselected folder glowing green read as a status rather than a shape.
func TestFolderIconDistinguishesSelection(t *testing.T) {
	// The palette is normally filled by ApplyTheme() at startup, and the
	// renderer only emits the exact foreground under a truecolor profile. A
	// test run without a TTY falls back to short ANSI, where the two theme
	// neutrals both degrade to grey and would compare equal for the wrong
	// reason — so pin the profile and the palette.
	applyPalette(loadOmarchyPalette())
	old := lipgloss.ColorProfile()
	lipgloss.SetColorProfile(2) // TrueColor
	t.Cleanup(func() { lipgloss.SetColorProfile(old) })

	d := newPickerDelegate(2, 2, 0, true)
	pi := PickerItem{Display: "Apps", Value: "cat:apps", Folder: true, Fold: FoldExpanded}
	idle := d.leadCell(pi, false)
	sel := d.leadCell(pi, true)
	if idle == sel {
		t.Fatal("a folder must look different when the cursor is on it")
	}
	if !strings.Contains(idle, FolderOpen) || !strings.Contains(sel, FolderOpen) {
		t.Fatalf("selection must not change the glyph, only its colour: idle=%q selected=%q", idle, sel)
	}
}
