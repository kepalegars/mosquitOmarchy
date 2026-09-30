package main

import (
	"strings"
	"testing"

	tuikit "mosquitomarchy.local/tui-kit"
)

// The plugin list used to emit ONE ROW PER FILE, so a plugin installed as
// vst2 + vst3 + clap appeared three times under the same name. The user had to
// pick the same plugin three times to act on it, and a vendor's count read as
// a file count. These pin the merged shape: one row per plugin, carrying the
// formats it is installed in.
func TestPluginRowMergesFormatsIntoOneLine(t *testing.T) {
	items := []Item{
		{Kind: "folder", Value: "vendor:FabFilter", Display: "FabFilter"},
		{Kind: "plugin", Value: "vst:vst2:/x/One.dll", Display: "FabFilter One",
			Parent: "vendor:FabFilter", Formats: "vst2,vst3,clap"},
	}
	m := &model{
		nav: []screen{scrUninstallPick}, w: 100, h: 40,
		uninstallCache: items, uninstallChecked: map[string]bool{},
		folderExpanded: map[string]bool{"vendor:FabFilter": true},
	}
	m.rebuildUninstallPicker()
	rows := m.picker.Items()

	// Folder + exactly ONE child.
	if len(rows) != 2 {
		t.Fatalf("got %d rows, want 2 (folder + one merged plugin)", len(rows))
	}
	if rows[0].Suffix != "  0/1" {
		t.Errorf("the vendor count should count PLUGINS, got %q", rows[0].Suffix)
	}
	// The formats are shown, in the Suffix so the label column stays straight.
	if !strings.Contains(rows[1].Display, "FabFilter One") {
		t.Errorf("child label = %q", rows[1].Display)
	}
	if got := rows[1].Suffix; got != "  [v2 v3 clap]" {
		t.Errorf("format suffix = %q, want %q", got, "  [v2 v3 clap]")
	}
}

// Acting on a plugin row has to act on EVERY file of that plugin. The old
// row-per-file shape made a "plugin" a single file by accident, so hiding
// FabFilter Pro-Q hid its vst2 copy and left the vst3 and clap ones in the DAW.
func TestPluginRowActsOnEveryInstalledFormat(t *testing.T) {
	p := PluginItem{
		Value:    "vst:vst2:/x/Pro-Q.dll",
		Variants: "vst:vst2:/x/Pro-Q.dll;vst:vst3:/x/Pro-Q.vst3;vst:clap:/x/Pro-Q.clap",
	}
	got := p.AllValues()
	if len(got) != 3 {
		t.Fatalf("AllValues = %v, want the 3 installed formats", got)
	}
	// The row's own value comes first and is not duplicated by the variants list.
	if got[0] != "vst:vst2:/x/Pro-Q.dll" {
		t.Errorf("AllValues[0] = %q, want the row's own value", got[0])
	}
	seen := map[string]bool{}
	for _, v := range got {
		if seen[v] {
			t.Errorf("duplicate in AllValues: %q", v)
		}
		seen[v] = true
	}
	// A plugin with a single format still acts, once.
	if n := len((PluginItem{Value: "vst:vst2:/x/A.dll"}).AllValues()); n != 1 {
		t.Errorf("single-format plugin produced %d actions, want 1", n)
	}
}

// A vendor folder row has to resolve to a vendor name: it is what Enter acts
// on, and what the backend needs to apply fixes to the whole suite.
func TestVendorFolderResolvesToItsVendor(t *testing.T) {
	items := []PluginItem{
		{Kind: "folder", Value: "vendor:FabFilter", Display: "FabFilter"},
		{Kind: "plugin", Value: "vst:vst2:/x/One.dll", Vendor: "FabFilter", Parent: "vendor:FabFilter"},
	}
	if got := vendorOfFolder(items, "vendor:FabFilter"); got != "FabFilter" {
		t.Errorf("vendorOfFolder = %q, want FabFilter", got)
	}
	// A plugin row is not a folder and must not resolve to a vendor.
	if got := vendorOfFolder(items, "vst:vst2:/x/One.dll"); got != "" {
		t.Errorf("a plugin row resolved to vendor %q, want none", got)
	}
}

// Every page that shows folders now ARRIVES COLLAPSED. The fixes list used to
// force-open any folder holding an already-applied fix, so the page came in
// already unfolded and the reason was invisible.
func TestPluginListArrivesWithEveryFolderCollapsed(t *testing.T) {
	m := &model{
		nav: []screen{scrPluginList}, w: 100, h: 40,
		pluginCache: []PluginItem{
			{Kind: "folder", Value: "vendor:FabFilter", Display: "FabFilter"},
			{Kind: "plugin", Value: "vst:vst2:/x/One.dll", Display: "FabFilter One",
				Vendor: "FabFilter", Parent: "vendor:FabFilter"},
		},
		pluginChecked: map[string]bool{},
	}
	m.rebuildPluginPicker()
	if len(m.folderExpanded) != 0 {
		t.Errorf("a folder was opened on arrival: %v", m.folderExpanded)
	}
	for _, it := range m.picker.Items() {
		if it.Value == "vst:vst2:/x/One.dll" {
			t.Fatal("a plugin is visible while its folder is collapsed")
		}
	}
	// → opens it.
	mm, _ := m.Update(tuikit.PickerSortMsg{Dir: 1})
	got, _ := mm.(model)
	if !got.folderExpanded["vendor:FabFilter"] {
		t.Error("→ did not open the folder")
	}
}

// The applied-fix marker has to survive the folder being closed: that is the
// only thing that used to require unfolding it.
func TestCollapsedVendorFolderStillShowsItHoldsAFix(t *testing.T) {
	m := &model{
		nav: []screen{scrFixPluginPick}, w: 100, h: 40,
		fixPluginCache: []PluginItem{
			{Kind: "folder", Value: "vendor:FabFilter", Display: "FabFilter"},
			{Kind: "plugin", Value: "vst:vst2:/x/One.dll", Display: "FabFilter One",
				Vendor: "FabFilter", Parent: "vendor:FabFilter"},
		},
		fixAppliedPlugins:  map[string]bool{"One": true},
		pluginChecked:      map[string]bool{},
		folderExpanded:     map[string]bool{},
		folderFoldedByUser: map[string]bool{},
	}
	m.rebuildFixPluginPicker()
	marked := false
	for _, it := range m.picker.Items() {
		if it.Value == "vendor:FabFilter" && it.TrailingBadge == fixAppliedBadge {
			marked = true
		}
	}
	if !marked {
		t.Error("the closed folder lost its applied-fix marker")
	}
}

// Choosing a plugin BY HAND is a per-plugin request. The post-install flow
// sets a vendor; without clearing it, the next hand-picked plugin would
// silently keep fixing the whole suite installed a moment earlier.
func TestHandPickedPluginClearsTheVendor(t *testing.T) {
	m := &model{
		nav: []screen{scrFixPluginPick}, w: 100, h: 40,
		fixPluginCache: []PluginItem{
			{Kind: "plugin", Value: "vst:vst2:/x/One.dll", Display: "FabFilter One"},
		},
		pluginChecked: map[string]bool{}, folderExpanded: map[string]bool{},
		fixVendor: "FabFilter",
	}
	m.rebuildFixPluginPicker()
	mm, cmd := m.update(tuikit.PickerResultMsg{Value: "vst:vst2:/x/One.dll"})
	got, _ := mm.(model)
	if got.fixVendor != "" {
		t.Errorf("hand-picking a plugin left the vendor %q in place", got.fixVendor)
	}
	if got.top() != scrFixChoose {
		t.Errorf("hand-picking a plugin went to screen %d", got.top())
	}
	_ = cmd
}
