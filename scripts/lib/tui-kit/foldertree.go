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
			branch := "├─ "
			if i == last {
				branch = "└─ "
			}
			// The tree lines are the ONLY thing this composes into Display.
			// The mark goes in Badge and the cursor in the fixed indicator
			// slot, both of which the kit lays out in a column of their own.
			// Baking the mark into the label as well is what made children
			// start a different column from their folder: the label carried
			// four extra spaces plus a box-drawing mark plus the badge, while
			// the folder row had none of that.
			// Checked lives in Badge so the kit owns the marker column. An
			// explicit Badge on the TreeItem still wins: a host that puts a
			// state glyph there knows better than the generic ○/●.
			badge := it.Badge
			if badge == "" {
				badge = "○"
				if it.Checked {
					badge = "●"
				}
			}
			row := PickerItem{
				Display: "    " + branch + it.Label,
				Value:   TreeValue(TreeItemPrefix, it.ID),
				Badge:   badge,
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
