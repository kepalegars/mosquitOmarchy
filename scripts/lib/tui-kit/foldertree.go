package tuikit

import (
	"fmt"
	"strings"
)

// FolderTree is the shared builder for every "list of folders, each holding
// rows" screen in these apps: mosquitomarchy's Setup, Uninstall, Status and
// Backup content screens, the audio plugin manager's plugin and fix choosers,
// the move manager and the live mode manager.
//
// Every one of them used to grow its own copy of the same loop — take a folder
// list, count the ticked children, emit a folder row with a fold glyph and a
// "3/5" count, then emit each child indented under it. Six near-identical
// copies drifted apart (some kept the ○/● mark in the leading slot, some moved
// it to a suffix, some drew tree angles and some did not), so a fix to one
// screen never reached the others.
//
// The data is deliberately generic — a []TreeFolder of []TreeItem, not any app's
// record type — so a host maps its own rows in and gets identical rendering.
type (
	// TreeFolder is one container. Marked is how many of its children are
	// ticked, Total how many it has (the "3/5" suffix). Accent makes the label
	// blink for a folder the host wants to draw the eye to.
	TreeFolder struct {
		ID     string
		Label  string
		Total  int
		Marked int
		Accent bool
	}

	// TreeItem is one leaf row inside a folder. Checked is the host's own
	// selection flag; Info is the text the host shows for `i`.
	TreeItem struct {
		ID      string
		Label   string
		Checked bool
		Info    string
		// Disabled greys the row and takes it out of navigation (a greyed row
		// the user cannot reach still lists what exists, with a reason).
		Disabled bool
		// Badge is an optional trailing marker, e.g. the ■ that says "a fix is
		// already applied here".
		Badge string
	}
)

// TreeValues are the prefixes FolderTree writes into PickerItem.Value, so a
// host can tell a folder row from a leaf row and recover the id on any event
// (toggle, fold, info) without keeping a parallel index.
const (
	TreeFolderPrefix = "cat:"
	TreeItemPrefix   = "item:"
)

// TreeValue builds the PickerItem.Value for a folder or an item.
func TreeValue(prefix, id string) string { return prefix + id }

// TreeSplit returns the prefix and the id behind a tree row's value.
func TreeSplit(v string) (prefix, id string, ok bool) {
	switch {
	case strings.HasPrefix(v, TreeFolderPrefix):
		return TreeFolderPrefix, strings.TrimPrefix(v, TreeFolderPrefix), true
	case strings.HasPrefix(v, TreeItemPrefix):
		return TreeItemPrefix, strings.TrimPrefix(v, TreeItemPrefix), true
	}
	return "", "", false
}

// TreeParentOf walks a rendered tree and reports the folder a row belongs to:
// its own id for a folder row, and the id of the folder whose children it sits
// under for a leaf row. ok is false for a row that is not part of a tree (a
// "Back" row, a header) — those have no parent to fold.
//
// This is what makes ← work from inside a folder, not only on its title. The
// arrows act on "the folder the cursor is in", so holding ↓ to walk into a
// category and then pressing ← closes it instead of doing nothing. A host that
// only ever looked at the selected row's own value got "no folder here" and
// had to send the cursor back up to the title first.
func TreeParentOf(items []PickerItem, value string) (folder string, ok bool) {
	prefix, id, isTree := TreeSplit(value)
	if !isTree {
		return "", false
	}
	if prefix == TreeFolderPrefix {
		return id, true
	}
	// A leaf: the nearest folder row ABOVE it is its owner. Walk FORWARD and
	// keep the last folder seen, stopping at the row itself — walking backward
	// finds the LAST folder in the list instead, which is why every leaf used
	// to resolve to the final category.
	target := -1
	for i, it := range items {
		if it.Value == value {
			target = i
			break
		}
	}
	if target < 0 {
		return "", false
	}
	owner := ""
	for _, it := range items[:target] {
		if p, pid, ok2 := TreeSplit(it.Value); ok2 && p == TreeFolderPrefix {
			owner = pid
		}
	}
	if owner == "" {
		return "", false
	}
	return owner, true
}

// ParentFolderOf is the same question as TreeParentOf for hosts whose rows do
// NOT use the cat:/item: prefixes — the Status tree uses its own
// ("status-cat:" / "status:"). Pass those and it walks the list the same way:
// the nearest folder row above the cursor is the folder the cursor is in.
//
// The point is the same in both: ← must close the category the cursor is
// sitting inside, not only when it happens to be on the category's title.
func ParentFolderOf(items []PickerItem, folderPrefix, value string) (folder string, ok bool) {
	byValue := func(v string) (string, bool) {
		if strings.HasPrefix(v, folderPrefix) {
			return strings.TrimPrefix(v, folderPrefix), true
		}
		return "", false
	}
	if id, isFolder := byValue(value); isFolder {
		return id, true
	}
	target := -1
	for i, it := range items {
		if it.Value == value {
			target = i
			break
		}
	}
	if target < 0 {
		return "", false
	}
	owner := ""
	for _, it := range items[:target] {
		if id, isFolder := byValue(it.Value); isFolder {
			owner = id
		}
	}
	if owner == "" {
		return "", false
	}
	return owner, true
}

// TreeFoldMsg asks a host to rebuild a tree picker after the ←/→ gesture
// changed a folder's open state.
//
// The kit can flip the shared open-state map but cannot rebuild the rows — only
// the host knows what its rows mean — so it names the change and the row the
// cursor should end up on, and the host repaints:
//
//	case tuikit.TreeFoldMsg:
//	    m.rebuildPicker()
//	    m.picker = m.picker.SelectValue(msg.Cursor)
//
// The kit emits this INSTEAD of PickerSortMsg for a picker declared with
// WithTree, so a host no longer writes the fold logic (resolve the folder, flip
// the map, remember where the cursor was, rebuild, reselect) once per screen.
type TreeFoldMsg struct {
	// Folder is the row value of the container that was opened or closed.
	Folder string
	// Open is its new state.
	Open bool
	// Cursor is the row the cursor should land on after the rebuild. It is the
	// folder itself when closing, because the row the cursor was on was one of
	// the children that just disappeared — without this the cursor would fall
	// off the end of a shorter list.
	Cursor string
}

// MarkBadge is the filled square a container row carries when something inside
// it is selected. Same glyph, same accent colour and same trailing slot as the
// plugin manager's "a fix is already applied here" marker, so "there is
// something in here" reads identically on every screen.
const MarkBadge = "■"

// WithCategoryMark stamps MarkBadge on every folder row that has at least one
// selected child, and leaves every other row — and every folder with nothing
// selected — exactly as it was.
//
// It is a function rather than a rule baked into BuildFolderTree on purpose:
// the marker is a per-host decision, and a host that always wants it can call
// this once on the rows it just built. marked is asked for the folder row's own
// Value, so a host keyed on ids can strip them with TreeSplit, and a host whose
// folder values ARE the id can use them directly.
//
// The square goes in TrailingBadge, never the leading Badge: the leading slot
// already says what KIND of row this is (folder glyph, checkbox), and the mark
// is about content, so it belongs at the end where the plugin manager puts it.
func WithCategoryMark(items []PickerItem, marked func(folderValue string) int) []PickerItem {
	if marked == nil {
		return items
	}
	for i := range items {
		if !items[i].Folder {
			continue
		}
		if marked(items[i].Value) > 0 {
			items[i].TrailingBadge = MarkBadge
		}
	}
	return items
}

// ParentFolderFlag answers the same question as ParentFolderOf for a host that
// marks its folder rows with Folder:true instead of giving them a recognisable
// value prefix. The plugin manager builds its own trees that way (a folder's
// Value is an opaque id), so there is no prefix to key on — the flag is the
// only thing that says "this row is a container".
func ParentFolderFlag(items []PickerItem, value string) (folder string, ok bool) {
	target := -1
	for i, it := range items {
		if it.Value == value {
			target = i
			break
		}
	}
	if target < 0 {
		return "", false
	}
	if items[target].Folder {
		// Already on the folder itself: that folder is the one to fold.
		return items[target].Value, true
	}
	owner := ""
	for _, it := range items[:target] {
		if it.Folder {
			owner = it.Value
		}
	}
	if owner == "" {
		return "", false
	}
	return owner, true
}

// BuildFolderTree renders the folders and their items as PickerItems.
//
// open is the host's fold state: a folder whose id is absent or false is
// collapsed and its children are omitted entirely, which is what makes the
// list navigable with a single cursor. blinkOn drives the Accent flag.
//
// The tree lines (├─ / └─) are drawn here rather than by each host: they are
// what makes a child read as belonging to the folder above it, and leaving that
// to six separate call sites is how they ended up inconsistent.
func BuildFolderTree(folders []TreeFolder, items map[string][]TreeItem, open map[string]bool, blinkOn bool) []PickerItem {
	out := make([]PickerItem, 0, len(folders)+len(items)+1)
	for _, f := range folders {
		children := items[f.ID]
		fold := FoldCollapsed
		expanded := open[f.ID]
		if expanded {
			fold = FoldExpanded
		}
		folder := PickerItem{
			Display: f.Label,
			Value:   TreeValue(TreeFolderPrefix, f.ID),
			Accent:  f.Accent && blinkOn,
			Fold:    fold,
			Folder:  true,
		}
		if f.Total > 0 {
			folder.Suffix = fmt.Sprintf("  (%d/%d)", f.Marked, f.Total)
		}
		out = append(out, folder)
		if !expanded {
			continue
		}
		last := len(children) - 1
		for i, it := range children {
			mark := "○"
			if it.Checked {
				mark = "●"
			}
			branch := "├─ "
			if i == last {
				branch = "└─ "
			}
			row := PickerItem{
				Display: "    " + branch + mark + "  " + it.Label,
				Value:   TreeValue(TreeItemPrefix, it.ID),
				Badge:   it.Badge,
			}
			if it.Disabled {
				row.Disabled = true
				row.Sub = it.Info
			}
			out = append(out, row)
		}
	}
	return out
}
