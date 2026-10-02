package main

import (
	"strings"
	"testing"
)

func suiteItems() []Item {
	var items []Item
	add := func(v, g string) {
		items = append(items, Item{
			Display: v, Value: "vst:vst3:/x/" + v, Kind: "plugin",
			Parent: "vendor:iZotope", Group: g,
		})
	}
	for _, n := range []string{"Neutron 5 Sculptor", "Neutron 5 Gate"} {
		add(n, "Neutron 5")
	}
	for _, n := range []string{"RX 11 Connect", "RX 11 De-click"} {
		add(n, "RX 11")
	}
	items = append(items, Item{Display: "iZotope", Value: "vendor:iZotope", Kind: "folder"})
	items = append(items, Item{Display: "FabFilter", Value: "vendor:FabFilter", Kind: "folder"})
	return items
}

// A suite that keeps several products in ONE vendor folder must be one folder
// you can open, with the product lines inside it.
//
// It used to emit "iZotope/Neutron 5" as the folder value, so the tree showed
// two rows both labelled iZotope and there was no iZotope to open.
func TestSuiteIsOneFolderWithLinesInside(t *testing.T) {
	tree := uninstallTree(suiteItems())

	var vendors []string
	for _, n := range tree {
		if n.Folder {
			vendors = append(vendors, n.Display)
		}
	}
	if len(vendors) != 2 {
		t.Fatalf("the tree has %d folders (%v), want iZotope and FabFilter", len(vendors), vendors)
	}

	iso := tree[0]
	if iso.Display != "iZotope" {
		t.Fatalf("the first folder is %q, want iZotope", iso.Display)
	}
	if len(iso.Subgroups) != 2 {
		t.Fatalf("iZotope has %d subgroups (%d), want 2", len(iso.Subgroups), len(iso.Subgroups))
	}
	if iso.Subgroups[0].Display != "Neutron 5" || len(iso.Subgroups[0].Plugins) != 2 {
		t.Errorf("first subgroup is %q with %d plugins, want Neutron 5 with 2",
			iso.Subgroups[0].Display, len(iso.Subgroups[0].Plugins))
	}
	if iso.Subgroups[1].Display != "RX 11" || len(iso.Subgroups[1].Plugins) != 2 {
		t.Errorf("second subgroup is %q with %d plugins, want RX 11 with 2",
			iso.Subgroups[1].Display, len(iso.Subgroups[1].Plugins))
	}
}

// Opening iZotope has to REVEAL the lines; they are nested, not siblings.
func TestSuiteLinesOnlyShowWhenTheVendorIsOpen(t *testing.T) {
	tree := uninstallTree(suiteItems())
	checked := map[string]bool{}

	rows := treeItemsToPicker(tree, checked, map[string]bool{})
	for _, r := range rows {
		if strings.Contains(r.Display, "Neutron 5") {
			t.Fatalf("a product line was visible with the vendor closed: %q", r.Display)
		}
	}

	open := map[string]bool{"vendor:iZotope": true}
	rows = treeItemsToPicker(tree, checked, open)
	var sawNeutron, sawNeutronPlugin bool
	for _, r := range rows {
		if strings.TrimSpace(r.Display) == "Neutron 5" {
			sawNeutron = true
		}
		if strings.Contains(r.Display, "Neutron 5 Sculptor") {
			sawNeutronPlugin = true
		}
	}
	if !sawNeutron {
		t.Error("opening iZotope did not show its product lines")
	}
	// The line's own plugins stay hidden until the LINE is opened: one level
	// of nesting, not two at once.
	if sawNeutronPlugin {
		t.Error("the product line's plugins were visible without opening the line")
	}

	open["vendor:iZotope\x00Neutron 5"] = true
	rows = treeItemsToPicker(tree, checked, open)
	var sawPlugin bool
	for _, r := range rows {
		if strings.Contains(r.Display, "Neutron 5 Sculptor") {
			sawPlugin = true
		}
	}
	if !sawPlugin {
		t.Error("opening the product line did not show its plugins")
	}
}

// Tab on a product line must select that line's plugins.
//
// The line's folder value is "<vendor>\x00<line>", which no plugin's Parent
// equals, so the Parent-only match selected nothing — while the row's count
// said there was something to select.
func TestTabOnASuiteLineSelectsItsPlugins(t *testing.T) {
	items := suiteItems()
	checked := map[string]bool{}
	line := "vendor:iZotope\x00RX 11"

	toggleFolderPlugins(items, line, checked)

	for _, it := range items {
		want := it.Group == "RX 11"
		if got := checked[it.Value]; got != want {
			t.Errorf("%s: checked=%v, want %v", it.Display, got, want)
		}
	}
}

// The vendor row's count must cover the plugins inside its lines too, or
// iZotope would read "0/0" while holding thirty plugins.
func TestSuiteFolderCountIncludesItsLines(t *testing.T) {
	tree := uninstallTree(suiteItems())
	checked := map[string]bool{"vst:vst3:/x/Neutron 5 Gate": true}

	rows := treeItemsToPicker(tree, checked, map[string]bool{})
	for _, r := range rows {
		if r.Value == "vendor:iZotope" {
			if !strings.Contains(r.Suffix, "1/4") {
				t.Errorf("iZotope count is %q, want 1/4", r.Suffix)
			}
			return
		}
	}
	t.Fatal("the iZotope row is missing")
}
