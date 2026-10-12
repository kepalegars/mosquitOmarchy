package tuikit

import (
	"strings"
	"testing"
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

// TestFolderIconIgnoresFoldAndCursor checks the glyph follows NEITHER the
// row's fold state NOR the cursor: collapsed, expanded, idle and cursor-on
// all draw the same empty square. Only Filled fills it in (see below).
func TestFolderIconIgnoresFoldAndCursor(t *testing.T) {
	mk := func(fold string) PickerItem {
		return PickerItem{Display: "Apps", Value: "cat:apps", Folder: true, Fold: fold}
	}
	d := newPickerDelegate(2, 2, 0, true)
	for _, fold := range []string{FoldCollapsed, FoldExpanded} {
		for _, selected := range []bool{false, true} {
			got := d.leadCell(mk(fold), selected)
			if !strings.Contains(got, FolderClosed) {
				t.Errorf("fold=%q selected=%v should draw %q, got %q", fold, selected, FolderClosed, got)
			}
			if strings.Contains(got, FolderOpen) {
				t.Errorf("fold=%q selected=%v must not draw the filled %q, got %q", fold, selected, FolderOpen, got)
			}
		}
	}
	// A leaf keeps its checkbox: the folder glyph must not leak onto items.
	leaf := d.leadCell(PickerItem{Display: "reaper", Value: "item:r", Badge: "○"}, false)
	if strings.Contains(leaf, FolderClosed) || strings.Contains(leaf, FolderOpen) {
		t.Errorf("a non-folder row must keep its badge, got %q", leaf)
	}
}

// TestFolderIconFillsWhenTicked pins the contract: a folder's square fills
// in if and only if the host marked it Filled (entirely ticked). Cursor,
// fold state, palette — none of those fill anything on their own.
func TestFolderIconFillsWhenTicked(t *testing.T) {
	d := newPickerDelegate(2, 2, 0, true)
	pi := PickerItem{Display: "Apps", Value: "cat:apps", Folder: true, Fold: FoldExpanded}
	if got := d.leadCell(pi, false); !strings.Contains(got, FolderClosed) {
		t.Fatalf("unticked folder should draw the plain square %q, got %q", FolderClosed, got)
	}
	pi.Filled = true
	if got := d.leadCell(pi, false); !strings.Contains(got, FolderOpen) {
		t.Fatalf("ticked folder should draw the filled square %q, got %q", FolderOpen, got)
	}
}
