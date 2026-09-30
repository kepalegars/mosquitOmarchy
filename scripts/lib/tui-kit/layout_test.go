package tuikit

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// TestPickerRowWidthsAreUniform is the invariant a picker rests on: every
// rendered row occupies the same number of columns. With a uniform block width
// every line gets the same left pad, so a list cannot stair-step and one long
// row cannot drag its neighbours out of line with it.
//
// The tree builder deliberately keeps its own indent and tick inside the label
// — that is the house style across the APKs. What has to be uniform is the
// WIDTH, not the label's contents.
func TestPickerRowWidthsAreUniform(t *testing.T) {
	// The shape that used to break it: one very long folder label, one even
	// longer leaf label, and a collapsed folder in the middle.
	items := []PickerItem{
		{Display: "Apps", Value: "cat:apps", Folder: true, Fold: FoldExpanded, Suffix: "  (0/2)"},
		{Display: "    └─ ableton - v1.0.0", Value: "a", Badge: "○"},
		{Display: "lame language models (ai..)", Value: "cat:lame", Folder: true, Fold: FoldExpanded, Suffix: "  (0/2)"},
		{Display: "    └─ bring back omarchy's agentic stuff", Value: "b", Badge: "●"},
		{Display: "VMs", Value: "cat:vms", Folder: true, Fold: FoldCollapsed, Suffix: "  (0/1)"},
		{Display: "Back", Value: "back"},
	}
	for cur := range items {
		p := NewPicker("", items).SetSize(70, 14).SelectIndex(cur)
		var widths []int
		first := true
		for _, l := range strings.Split(p.View(), "\n") {
			plain := ansi.Strip(l)
			if strings.TrimSpace(plain) == "" {
				continue
			}
			if first {
				first = false
				continue // the picker's centered header, not a row
			}
			widths = append(widths, ansi.StringWidth(plain))
		}
		for i, w := range widths {
			if w != widths[0] {
				t.Errorf("cursor %d: row %d is %d columns, first is %d — not one block", cur, i, w, widths[0])
			}
		}
	}
}

// A greyed row must still show its Suffix. That is where the preinstalls screen
// keeps "(already removed)" and "(your own app — kept)", so dropping it left
// every disabled row as a bare name with no reason attached.
func TestDisabledRowKeepsItsSuffix(t *testing.T) {
	items := []PickerItem{
		{Display: "Firefox", Value: "firefox", Badge: "○"},
		{Display: "GIMP", Value: "gimp", Badge: "○", Suffix: "  (your own app — kept)", Disabled: true},
		{Display: "Zoom", Value: "zoom", Badge: "○", Suffix: "  (already removed)", Disabled: true},
		{Display: "Back", Value: "back"},
	}
	view := ansi.Strip(NewPicker("", items).SetSize(70, 12).View())
	for _, want := range []string{"your own app", "already removed"} {
		if !strings.Contains(view, want) {
			t.Errorf("a disabled row lost its suffix %q — the row does not say why it is greyed:\n%s", want, view)
		}
	}
}

// ← has to close the category the cursor is IN, not only when it sits on the
// category's title. That is the whole point of TreeParentOf: the nearest
// folder row above the cursor is its owner, leaf or not.
func TestTreeParentOf(t *testing.T) {
	items := []PickerItem{
		{Value: TreeValue(TreeFolderPrefix, "apps")},
		{Value: TreeValue(TreeItemPrefix, "apps:reaper")},
		{Value: TreeValue(TreeItemPrefix, "apps:extracto")},
		{Value: TreeValue(TreeFolderPrefix, "lame")},
		{Value: TreeValue(TreeItemPrefix, "lame:ollama")},
		{Value: "back"},
	}
	cases := []struct {
		value  string
		folder string
		ok     bool
	}{
		{value: TreeValue(TreeFolderPrefix, "apps"), folder: "apps", ok: true},
		{value: TreeValue(TreeItemPrefix, "apps:reaper"), folder: "apps", ok: true},
		{value: TreeValue(TreeItemPrefix, "apps:extracto"), folder: "apps", ok: true},
		{value: TreeValue(TreeFolderPrefix, "lame"), folder: "lame", ok: true},
		{value: TreeValue(TreeItemPrefix, "lame:ollama"), folder: "lame", ok: true},
		{value: "", ok: false},
	}
	for _, c := range cases {
		folder, ok := TreeParentOf(items, c.value)
		if ok != c.ok || folder != c.folder {
			t.Errorf("TreeParentOf(%q) = %q,%v want %q,%v", c.value, folder, ok, c.folder, c.ok)
		}
	}
}

// The same question for a host whose rows use their own prefixes.
func TestParentFolderOfCustomPrefix(t *testing.T) {
	items := []PickerItem{
		{Value: "status-cat:apps"},
		{Value: "status:reaper"},
		{Value: "status-cat:mosquito"},
		{Value: "status:live-mode"},
		{Value: "back"},
	}
	if got, ok := ParentFolderOf(items, "status-cat:", "status:live-mode"); !ok || got != "mosquito" {
		t.Errorf("ParentFolderOf(status:live-mode) = %q,%v want mosquito,true", got, ok)
	}
	if got, ok := ParentFolderOf(items, "status-cat:", "status-cat:apps"); !ok || got != "apps" {
		t.Errorf("ParentFolderOf(status-cat:apps) = %q,%v want apps,true", got, ok)
	}
	// "back" is a trailing row that happens to sit after a folder, so the walk
	// finds that folder. The kit cannot know "back" is special: hosts filter
	// with their own row kinds (tuikit.IsTerminalValue) when it matters.
	if _, ok := ParentFolderOf(items, "status-cat:", ""); ok {
		t.Error("an empty value has no parent folder")
	}
}
