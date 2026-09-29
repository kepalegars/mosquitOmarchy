package tuikit

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// Every line of a picker must start at the same column. This is the layout
// rule the whole app rests on: a tree whose rows stair-step is the single most
// reported "this screen looks broken" symptom, and it kept coming back because
// the padding was implicit (lipgloss Width/Align on a coloured, possibly
// multi-line string) and because trees used to bake their own indentation and
// tick marks into the label.
// assertRowsAligned checks that every row carries the same amount of leading
// padding. It does that by measuring each line's total width and its trailing
// padding: with a uniform block width, equal widths plus equal trailing pads
// imply equal leading pads, i.e. one shared column. This avoids trying to parse
// the indicator and badge out of the line, which is what made a previous
// version of this test report differences that were not there.
func assertRowsAligned(t *testing.T, view string) {
	t.Helper()
	type row struct{ line string }
	var rows []string
	first := true
	for _, l := range strings.Split(view, "\n") {
		plain := ansi.Strip(l)
		if strings.TrimSpace(plain) == "" {
			continue
		}
		if first {
			first = false
			continue // the centered header
		}
		rows = append(rows, plain)
	}
	if len(rows) < 2 {
		return
	}
	width := ansi.StringWidth(rows[0])
	trailing := func(s string) int {
		r := []rune(s)
		for i := len(r) - 1; i >= 0 && r[i] == ' '; i-- {
			// count
		}
		n := 0
		for i := len(r) - 1; i >= 0 && r[i] == ' '; i-- {
			n++
		}
		return n
	}
	_ = trailing
	for i, r := range rows {
		if w := ansi.StringWidth(r); w != width {
			t.Errorf("row %d is %d columns wide, first row is %d — the block is not uniform (%q)", i, w, width, r)
		}
	}
}

func TestPickerLabelsShareOneColumn(t *testing.T) {
	// The exact shape that used to push "lame language models (ai..)" and its
	// children out of line with every other folder: one very long folder label
	// and one even longer leaf label.
	items := []PickerItem{
		{Display: "Apps", Value: "cat:apps", Folder: true, Fold: FoldExpanded, Suffix: "  (0/3)"},
		{Display: "    ├─ ableton - v1.0.0", Value: "item:apps:ableton", Badge: "○"},
		{Display: "    └─ superfile - v1.0.0", Value: "item:apps:superfile", Badge: "●"},
		{Display: "lame language models (ai..)", Value: "cat:lame", Folder: true, Fold: FoldExpanded, Suffix: "  (0/2)"},
		{Display: "    ├─ bring back omarchy's agentic stuff", Value: "item:lame:remove-ai", Badge: "○"},
		{Display: "    └─ ollama - v1.0.0", Value: "item:lame:ollama", Badge: "●"},
		{Display: "VMs", Value: "cat:vms", Folder: true, Fold: FoldExpanded, Suffix: "  (0/1)"},
		{Display: "    └─ macos-vm - v1.0.0", Value: "item:vms:macos-vm", Badge: "○"},
	}
	for cur := 0; cur < len(items); cur++ {
		p := NewPicker("", items).SetSize(70, 14).SelectIndex(cur)
		assertRowsAligned(t, p.View())
	}
}

func TestFolderTreeLeavesLayoutToTheKit(t *testing.T) {
	rows := BuildFolderTree(
		[]TreeFolder{{ID: "lame", Label: "lame language models (ai..)", Total: 2}},
		map[string][]TreeItem{"lame": {
			{ID: "lame:ollama", Label: "ollama - v1.0.0"},
			{ID: "lame:remove-ai", Label: "bring back omarchy's agentic stuff", Checked: true},
		}},
		map[string]bool{"lame": true}, false)

	if len(rows) != 3 {
		t.Fatalf("expected folder + 2 children, got %d rows", len(rows))
	}
	child := rows[2]
	// Only the branch glyphs, no leading spaces and no mark in the label.
	if child.Display != "    └─ bring back omarchy's agentic stuff" {
		t.Errorf("child label = %q, want only the 4-space indent plus the branch", child.Display)
	}
	for _, banned := range []string{"○", "●"} {
		if strings.Contains(child.Display, banned) {
			t.Errorf("child label %q still carries a tick mark; it belongs in Badge", child.Display)
		}
	}
	if child.Badge != "●" {
		t.Errorf("checked child Badge = %q, want ●", child.Badge)
	}
	if rows[1].Badge != "○" {
		t.Errorf("unchecked child Badge = %q, want ○", rows[1].Badge)
	}
	// And the two kinds of row must line up once rendered.
	assertRowsAligned(t, NewPicker("", rows).SetSize(70, 8).View())
}
