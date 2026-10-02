package main

import (
	"regexp"
	"strings"
	"testing"
)

var markRe = regexp.MustCompile(`[○●]`)

// The checkbox inside a suite line must sit under the line's own text, not at
// the vendor level's offset.
//
// The nested level reused the parent's pad, so every plugin under "Neutron 5"
// drew its mark two columns short of the line that contains it — the one thing
// the indentation is for.
func TestSuiteLinePluginsAlignUnderTheLine(t *testing.T) {
	tree := uninstallTree(suiteItems())
	rows := treeItemsToPicker(tree, map[string]bool{}, map[string]bool{
		"vendor:iZotope":            true,
		"vendor:iZotope\x00Neutron 5": true,
	})

	lineCol, pluginCol := -1, -1
	_ = lineCol
	for _, r := range rows {
		loc := markRe.FindStringIndex(r.Display)
		switch {
		case loc == nil && strings.HasSuffix(strings.TrimSpace(r.Display), "Neutron 5"):
			lineCol = leading(r.Display)
			t.Logf("line row: %q lead@%d", r.Display, lineCol)
		case strings.Contains(r.Display, "Neutron 5 Gate"):
			if loc != nil {
				pluginCol = loc[0]
			}
			t.Logf("plugin row: %q mark@%d", r.Display, loc[0])
		}
	}
	if lineCol < 0 || pluginCol < 0 {
		t.Fatalf("could not find both rows (line=%d plugin=%d)", lineCol, pluginCol)
	}
	if pluginCol <= lineCol {
		t.Errorf("the plugin's mark is at column %d, the line's at %d: it is not indented past it",
			pluginCol, lineCol)
	}
}

// Enter on a folder row must resolve to the plugins inside it.
//
// uninstall-batch only understands vst:/win:/native: tokens, so a folder's
// "vendor:<name>" came back "unrecognized target: vendor:iZotope" and the step
// failed — for the vendor row and for a suite line alike.
func TestEnterOnAFolderResolvesToItsPlugins(t *testing.T) {
	items := suiteItems()

	vendor := expandFolderTarget(items, "vendor:iZotope")
	if len(vendor) != 4 {
		t.Errorf("iZotope resolved to %d plugins (%v), want 4", len(vendor), vendor)
	}
	for _, v := range vendor {
		if strings.HasPrefix(v, "vendor:") {
			t.Errorf("a folder token leaked into the targets: %q", v)
		}
	}

	line := expandFolderTarget(items, "vendor:iZotope\x00RX 11")
	if len(line) != 2 {
		t.Fatalf("RX 11 resolved to %d plugins (%v), want 2", len(line), line)
	}
	for _, v := range line {
		if !strings.Contains(v, "RX 11") {
			t.Errorf("RX 11 pulled in %q", v)
		}
	}
}

// leading is the column the row's text starts at.
func leading(s string) int {
	n := 0
	for _, r := range s {
		if r != ' ' {
			break
		}
		n++
	}
	return n
}

// A suite's product lines come FIRST, then the plugins that belong to no line.
//
// The lines rendered below the loose plugins, so the parts of the suite appeared
// after things that are not part of it — bottom-up.
func TestSuiteLinesComeBeforeUngroupedPlugins(t *testing.T) {
	items := []Item{
		{Display: "Loose Tool", Value: "vst:vst3:/x/Loose Tool", Kind: "plugin",
			Parent: "vendor:iZotope", Formats: "vst3"},
		{Display: "Neutron 5 Gate", Value: "vst:vst3:/x/Neutron 5 Gate", Kind: "plugin",
			Parent: "vendor:iZotope", Group: "Neutron 5", Formats: "vst3"},
		{Display: "RX 11 Connect", Value: "vst:vst3:/x/RX 11 Connect", Kind: "plugin",
			Parent: "vendor:iZotope", Group: "RX 11", Formats: "vst3"},
		{Display: "iZotope", Value: "vendor:iZotope", Kind: "folder"},
	}
	tree := uninstallTree(items)
	rows := treeItemsToPicker(tree, map[string]bool{}, map[string]bool{
		"vendor:iZotope":            true,
		"vendor:iZotope\x00Neutron 5": true,
		"vendor:iZotope\x00RX 11":     true,
	})
	loose, firstLine := -1, -1
	for i, r := range rows {
		if strings.Contains(r.Display, "Loose Tool") {
			loose = i
		}
		if firstLine < 0 && (strings.HasSuffix(strings.TrimSpace(r.Display), "Neutron 5") ||
			strings.HasSuffix(strings.TrimSpace(r.Display), "RX 11")) {
			firstLine = i
		}
	}
	if loose < 0 || firstLine < 0 {
		t.Fatalf("missing rows (loose=%d firstLine=%d)\n%v", loose, firstLine, rows)
	}
	if firstLine > loose {
		t.Errorf("a product line is at row %d and the ungrouped plugin at %d: the lines must come first", firstLine, loose)
	}
}
