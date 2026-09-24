package main

import (
	"fmt"
	"sort"
	"strings"

	"github.com/charmbracelet/bubbles/key"
	tea "github.com/charmbracelet/bubbletea"
	tuikit "mosquitomarchy.local/tui-kit"
)

// readmeSentinel is the picker Value for the "Readme" entry always
// appended to Plugin list — matches the bash native interface's own
// "Readme is always last" convention. Won't collide with a real
// "kind:target" value (those never contain ':' this way).
const readmeSentinel = "__readme__"

func itemsToPicker(items []Item) []tuikit.PickerItem {
	out := make([]tuikit.PickerItem, len(items))
	for i, it := range items {
		out[i] = tuikit.PickerItem{Display: it.Display, Value: it.Value}
	}
	return out
}

func (m *model) enterCmd() tea.Cmd {
	switch m.top() {
	case scrMain:
		m.loading = true
		return fetchStatus()
	case scrSettings:
		m.picker = tuikit.NewPicker("Settings", m.settingsItemsWithPending()).SetSize(m.contentSize())
		return nil
	case scrVstMenu:
		m.picker = tuikit.NewPicker("Windows VST Plugins (Wine)", m.vstMenuItemsWithPending()).SetSize(m.contentSize())
		return nil
	case scrPluginList:
		m.loading = true
		m.pluginCache = nil
		m.pluginChecked = nil
		m.pluginOrig = nil
		return fetchAllPlugins()
	case scrUninstallPick:
		m.loading = true
		m.uninstallCache = nil
		m.uninstallChecked = map[string]bool{}
		return fetchItems("uninstall", "list-uninstallable")
	case scrInstallPrefixChoice:
		m.confirm = tuikit.NewConfirm("Install into the default wine prefix?", "No, new prefix", "Yes")
		return nil
	case scrSuperfileInstallConfirm:
		m.confirm = tuikit.NewConfirm(
			"Superfile isn't installed. Install it now (pacman, official repo — opens a terminal for the sudo password) and switch to it?",
			"No", "Yes, install")
		return nil
	case scrInstallPrefixPick:
		m.loading = true
		return fetchPrefixes()
	case scrInstallPrefixName:
		m.input = tuikit.NewTextInput("Name of the new wine prefix (e.g. 'early' → ~/.wine-early):", "")
		return m.input.Init()
	case scrPrefixMovePluginPick:
		m.loading = true
		return fetchPrefixedPlugins()
	case scrPrefixMoveTargetPick:
		m.loading = true
		return fetchPrefixes()
	case scrPrefixMoveTargetName:
		m.input = tuikit.NewTextInput("Name of the new prefix (e.g. 'early' → ~/.wine-early):", "")
		return m.input.Init()
	case scrPrefixMoveConfirm:
		m.confirm = tuikit.NewConfirm(
			"Move '"+m.moveKey+"' from "+baseName(m.moveFrom)+" to "+baseName(m.moveTo)+"?", "No", "Yes")
		return nil
	case scrStandalonePick:
		m.loading = true
		return fetchItems("standalone", "list-standalones")
	case scrExecsToggle:
		m.loading = true
		return fetchExecToggle()
	case scrQuitConfirm:
		m.confirm = tuikit.NewConfirm("Close the mosquito Audio Plugin Manager?", "No", "Yes")
		return nil
	case scrFixPluginPick:
		// The chooser renders the SAME unified plugin list (folders + sort)
		// as Installed plugins, so it loads through the same path. The
		// applied-fix set rides along in one cheap extra call so the picker
		// can badge plugins that already carry a fix.
		m.loading = true
		m.fixPluginCache = nil
		m.fixAppliedPlugins = nil
		return tea.Batch(fetchAllPlugins(), fetchAppliedFixPlugins())
	case scrFixChoose:
		m.loading = true
		m.fixCache = nil
		m.fixChecked = nil
		m.fixOrig = nil
		// Drop any remembered collapse state: every category re-seeds
		// expanded on entry (see rebuildFixPicker), so the folders are
		// always visible when the screen opens.
		m.fixFolderExpanded = nil
		return fetchPluginFixes(m.fixPlugin)
	}
	return nil
}

// startWizardFinish pushes the wizard's reporting screen and launches the
// backend's single wizard-finish runner, which persists the chosen plugins
// folder (default or picked), marks the wizard done, and streams a
// per-DAW line for the user to read.
func (m *model) startWizardFinish() tea.Cmd {
	m.push(scrWizardDaw)
	m.runner = tuikit.NewRunner().SetSize(m.contentSize())
	root := m.wizardRoot
	if root == "" {
		root = m.status.PluginsRoot
	}
	var cmd tea.Cmd
	m.runner, cmd = m.runner.Start("First launch — pointing your DAWs at the plugins folder",
		actionsBin(), "wizard-finish", root)
	return cmd
}

func baseName(p string) string {
	for i := len(p) - 1; i >= 0; i-- {
		if p[i] == '/' {
			return p[i+1:]
		}
	}
	return p
}

func splitPair(s string) (string, string) {
	for i := 0; i < len(s); i++ {
		if s[i] == '\x1f' {
			return s[:i], s[i+1:]
		}
	}
	return s, ""
}

func execItemsToPicker(items []ExecToggleItem) []tuikit.PickerItem {
	out := make([]tuikit.PickerItem, len(items))
	for i, it := range items {
		mark := "○"
		if it.Shown {
			mark = "●"
		}
		out[i] = tuikit.PickerItem{Display: mark + "  " + it.Display, Value: it.Value}
	}
	return out
}

// uninstallTreeItem is the intermediate shape used by uninstallTree to
// describe one rendered row: either a folder header (Folder = true,
// Value is the folder's uninstall target, Plugins = the child plugins
// in installation order) or a standalone plugin (Folder = false).
type uninstallTreeItem struct {
	Folder  bool
	Value   string
	Display string
	Plugins []Item
}

// uninstallTree reorganises list-uninstallable's flat output into the
// tree the Uninstall screen renders: every wine-program folder first
// (the user picks the folder to uninstall the whole installer in one
// shot), then its sub-plugins indented directly below it, then the next
// folder, and finally any standalone plugins (no parent folder) at the
// end. Plugins are kept in the order list-uninstallable returned them —
// the bash side emits per-plugin rows before folder rows so the natural
// insertion order is the bundle's own discovery order, not alphabetical.
func uninstallTree(items []Item) []uninstallTreeItem {
	// Pass 1: index plugins by parent (parent == "" for standalone).
	pluginsByParent := map[string][]Item{}
	var standalone []Item
	for _, it := range items {
		if it.Kind == "folder" {
			continue // folder rows are not real plugins
		}
		if it.Parent == "" {
			standalone = append(standalone, it)
		} else {
			pluginsByParent[it.Parent] = append(pluginsByParent[it.Parent], it)
		}
	}
	// Pass 2: walk the folder rows in order, emit each as a tree node,
	// then its sub-plugins. (Folder rows are at the tail of the flat
	// list because list-uninstallable emits plugins first, then folders
	// — we walk the original list again to preserve that folder order.)
	out := []uninstallTreeItem{}
	emittedStandalone := map[string]bool{}
	for _, it := range items {
		if it.Kind != "folder" {
			continue
		}
		out = append(out, uninstallTreeItem{
			Folder:  true,
			Value:   it.Value,
			Display: it.Display,
			Plugins: pluginsByParent[it.Value],
		})
	}
	// Standalone plugins last.
	for _, it := range standalone {
		_ = emittedStandalone // placeholder; kept for symmetry
		out = append(out, uninstallTreeItem{
			Folder:  false,
			Value:   it.Value,
			Display: it.Display,
			Plugins: nil,
		})
	}
	return out
}

// isFolderRow reports whether the given picker Value belongs to a folder
// row in the uninstall list (vs. an individual plugin row). Folder rows
// have Value like "win:/path/to/wine/folder" (the wine uninstaller target),
// and list-uninstallable marks them with Kind="folder". Everything else
// (Value=vst:..., native:...) is a single plugin row.
func isFolderRow(items []Item, value string) bool {
	for _, it := range items {
		if it.Value == value {
			return it.Kind == "folder"
		}
	}
	return false
}

// toggleFolderPlugins flips the checked state of every sub-plugin that
// belongs under the given folder row's Value. The semantics match what
// the user sees in the folder row's checkbox (○ all-off, ● all-on,
// ▣ partial — Tab on the folder row always flips to the opposite extreme,
// never to "partial", so a single keystroke means "I want the whole
// installer" or "I want none of it").
func toggleFolderPlugins(items []Item, folderValue string, checked map[string]bool) {
	// Decide the new state: if at least one child is unchecked → mark
	// all checked (the user is "selecting everything in this folder").
	// If every child is already checked → uncheck all (the user is
	// "deselecting everything in this folder"). This avoids getting
	// stuck in partial state via Tab — partial can still be reached
	// row-by-row by tabbing individual children.
	anyUnchecked := false
	for _, it := range items {
		if it.Parent == folderValue && !checked[it.Value] {
			anyUnchecked = true
			break
		}
	}
	target := anyUnchecked
	for _, it := range items {
		if it.Parent == folderValue {
			checked[it.Value] = target
		}
	}
}

// treeItemsToPicker flattens the uninstall tree into picker rows. The same
// function backs BOTH the uninstall screen and the "Installed plugins" setup
// list, so folder grouping cannot drift between them.
// Folder rules (matching the fixes picker's folder convention exactly):
//   - a folder row is "<chevron> <mark>  <name>": the chevron is "▾" when
//     the folder is expanded and "▸" when collapsed, and the mark is ● only
//     when every plugin in the folder is selected;
//   - sub-plugins render ONLY while the folder is expanded, indented with a
//     file-tree angle ("    ├─ " / "    └─ "), the last child using the
//     corner glyph.
//
// Every row uses the app-wide ○ (off) / ● (on) circle convention.
func treeItemsToPicker(items []uninstallTreeItem, checked map[string]bool, expanded map[string]bool) []tuikit.PickerItem {
	out := []tuikit.PickerItem{}
	for _, n := range items {
		if n.Folder {
			marked := 0
			for _, p := range n.Plugins {
				if checked[p.Value] {
					marked++
				}
			}
			mark := "○"
			if len(n.Plugins) > 0 && marked == len(n.Plugins) {
				mark = "●"
			}
			chevron := "▸" // collapsed
			if expanded[n.Value] {
				chevron = "▾"
			}
			out = append(out, tuikit.PickerItem{
				Display: chevron + " " + mark + "  " + n.Display,
				Value:   n.Value,
			})
			// Sub-plugins render ONLY inside the expanded folder, and
			// always indented under it — never as siblings anywhere.
			if expanded[n.Value] {
				last := len(n.Plugins) - 1
				for i, p := range n.Plugins {
					pmark := "○"
					if checked[p.Value] {
						pmark = "●"
					}
					branch := "├─ "
					if i == last {
						branch = "└─ "
					}
					out = append(out, tuikit.PickerItem{
						Display: "    " + branch + pmark + "  " + p.Display,
						Value:   p.Value,
					})
				}
			}
		} else {
			mark := "○"
			if checked[n.Value] {
				mark = "●"
			}
			out = append(out, tuikit.PickerItem{Display: mark + "  " + n.Display, Value: n.Value})
		}
	}
	return out
}

// checkboxItemsToPicker renders the Uninstall screen's Tab multi-select
// state -- same ●/○ convention as execItemsToPicker, for the generic Item
// shape list-uninstallable returns. (Kept for any code path that still
// feeds a flat list — the uninstall flow now goes through uninstallTree
// + treeItemsToPicker instead, so the user gets the folder/sub-plugin
// grouping the user asked for.)
func checkboxItemsToPicker(items []Item, checked map[string]bool) []tuikit.PickerItem {
	out := make([]tuikit.PickerItem, len(items))
	for i, it := range items {
		mark := "○"
		if checked[it.Value] {
			mark = "●"
		}
		out[i] = tuikit.PickerItem{Display: mark + "  " + it.Display, Value: it.Value}
	}
	return out
}

// rebuildUninstallPicker re-renders the Uninstall picker from uninstallCache
// + uninstallChecked, same shape as rebuildPluginPicker. The cursor is
// preserved across the rebuild (Tab on a row used to jump back to the
// top of the list after every selection — universally unwanted).
func (m *model) rebuildUninstallPicker() {
	if m.folderExpanded == nil {
		m.folderExpanded = map[string]bool{}
	}
	sidx := m.picker.Index()
	m.picker = tuikit.NewPicker("Uninstall which plugin(s)?",
		treeItemsToPicker(uninstallTree(m.uninstallCache), m.uninstallChecked, m.folderExpanded)).SetSize(m.contentSize()).
		SetHelpKeys(
			key.NewBinding(key.WithKeys("tab"), key.WithHelp("tab", "select")),
			key.NewBinding(key.WithKeys("s"), key.WithHelp("s", "sort")),
			key.NewBinding(key.WithKeys("x"), key.WithHelp("x", "open folder")),
			key.NewBinding(key.WithKeys("right"), key.WithHelp("→", "expand")),
			key.NewBinding(key.WithKeys("left"), key.WithHelp("←", "collapse")),
			key.NewBinding(key.WithKeys("enter"), key.WithHelp("enter", "uninstall")),
		)
	m.picker = m.picker.SelectIndex(sidx)
}

// selectedFolderValueIn reports whether value names a folder row in the
// given flat item set, returning it when so and "" otherwise. Both the
// uninstall screen and the Installed-plugins setup list key their
// Left/Right folder gesture off the row under the cursor.
func selectedFolderValueIn(items []Item, value string) string {
	for _, it := range items {
		if it.Kind == "folder" && it.Value == value {
			return it.Value
		}
	}
	return ""
}

// selectedFolderValue returns the Value of a folder row under the
// uninstall picker's cursor, or "" when the cursor is on a standalone
// plugin row (or the screen is empty).
func (m *model) selectedFolderValue() string {
	return selectedFolderValueIn(m.uninstallCache, m.picker.SelectedValue())
}

// pluginItemsAsItems converts the unified Plugin list rows into the generic
// Item shape the uninstall tree is built from, so the setup list can call
// the exact same uninstallTree/treeItemsToPicker grouping the uninstall
// screen uses (Kind="folder" header rows included).
func pluginItemsAsItems(items []PluginItem) []Item {
	out := make([]Item, len(items))
	for i, it := range items {
		out[i] = Item{Display: it.Display, Value: it.Value, Kind: it.Kind, Parent: it.Parent}
	}
	return out
}

// fixCategoryValuePrefix marks the fixes picker's category-header rows. A
// category row's Value is "__fixcat__:<category>"; a real fix id can never
// look like that (ids are [a-z_]+), so toggling the header can be told apart
// from toggling a fix.
const fixCategoryValuePrefix = "__fixcat__:"

// fixCategoryOf is the display bucket for a fix: its category, or "Other"
// when the catalog left it empty.
func fixCategoryOf(it FixItem) string {
	if it.Category == "" {
		return "Other"
	}
	return it.Category
}

// fixItemsToPicker renders the "Plugin fixes" catalog as a single
// multi-select list where each category is a folder: a
// "▾/▸ ○/●  <Category>" parent row followed by its fixes indented under it
// with a file-tree angle. Toggling the parent flips every fix in that
// category; individual fixes toggle on their own. Uses the app-wide ○/●
// circle convention and global fixes are tagged so it is obvious they are
// not plugin-scoped; plugin-specific fixes stay visible/selectable for every
// plugin (they are never filtered) and need no tag — their category already
// names the product.
// The folder row's chevron/child-visibility follows expanded exactly as
// treeItemsToPicker does for the other two screens.
func fixItemsToPicker(items []FixItem, checked map[string]bool, expanded map[string]bool) []tuikit.PickerItem {
	hasCategory := false
	for _, it := range items {
		if it.Category != "" {
			hasCategory = true
			break
		}
	}
	out := []tuikit.PickerItem{}
	if !hasCategory {
		// No categories in the catalog: a clean flat list, same as before.
		for _, it := range items {
			mark := "○"
			if checked[it.ID] {
				mark = "●"
			}
			out = append(out, tuikit.PickerItem{Display: mark + "  " + it.Title + fixRowTags(it), Value: it.ID})
		}
		return out
	}
	seen := map[string]bool{}
	lastOf := map[string]int{}
	for i, it := range items {
		lastOf[fixCategoryOf(it)] = i
	}
	for i, it := range items {
		cat := fixCategoryOf(it)
		if !seen[cat] {
			seen[cat] = true
			// Header mark: ● only when every fix in the category is on.
			all := true
			any := false
			for _, other := range items {
				if fixCategoryOf(other) != cat {
					continue
				}
				any = true
				if !checked[other.ID] {
					all = false
				}
			}
			hmark := "○"
			if all && any {
				hmark = "●"
			}
			chevron := "▸" // collapsed
			if expanded[cat] {
				chevron = "▾"
			}
			out = append(out, tuikit.PickerItem{
				Display: chevron + " " + hmark + "  " + cat,
				Value:   fixCategoryValuePrefix + cat,
			})
		}
		// Children render only while the category is expanded.
		if !expanded[cat] {
			continue
		}
		mark := "○"
		if checked[it.ID] {
			mark = "●"
		}
		// File-tree angle so the fix is visibly a child of its category.
		branch := "├─ "
		if lastOf[cat] == i {
			branch = "└─ "
		}
		out = append(out, tuikit.PickerItem{Display: "    " + branch + mark + "  " + it.Title + fixRowTags(it), Value: it.ID})
	}
	return out
}

// fixRowTags is the trailing tag block on a fix row: "  [global]" for a
// desktop-wide fix. Plugin-specific fixes carry no tag anymore — the fix's
// category folder already conveys which product it belongs to, so the old
// "[plugin: X]" suffix was redundant noise.
func fixRowTags(it FixItem) string {
	if it.Scope == "global" {
		return "  [global]"
	}
	return ""
}

// sortedFixItems returns the fixes catalog in the screen's current order:
// by category then title (ascending, or descending when desc), with the id
// as a stable tie-break so the rows never shuffle between rebuilds. A copy
// is returned so m.fixCache's server order is preserved.
func sortedFixItems(items []FixItem, desc bool) []FixItem {
	out := make([]FixItem, len(items))
	copy(out, items)
	sort.SliceStable(out, func(i, j int) bool {
		ci, cj := fixCategoryOf(out[i]), fixCategoryOf(out[j])
		if ci != cj {
			if desc {
				return ci > cj
			}
			return ci < cj
		}
		if out[i].Title != out[j].Title {
			if desc {
				return out[i].Title > out[j].Title
			}
			return out[i].Title < out[j].Title
		}
		return out[i].ID < out[j].ID
	})
	return out
}

// fixSortLabel is the human-readable description of the fixes list's current
// order, shown in the screen title so `s` always has visible feedback.
func fixSortLabel(desc bool) string {
	if desc {
		return "category, title (Z→A)"
	}
	return "category, title (A→Z)"
}

// toggleFixValue flips one entry of the fixes list: a category header flips
// every fix in that category to the opposite extreme (like the uninstall
// folder rows), a fix id flips only itself.
func (m *model) toggleFixValue(value string) {
	if strings.HasPrefix(value, fixCategoryValuePrefix) {
		cat := strings.TrimPrefix(value, fixCategoryValuePrefix)
		anyUnchecked := false
		for _, it := range m.fixCache {
			if fixCategoryOf(it) == cat && !m.fixChecked[it.ID] {
				anyUnchecked = true
				break
			}
		}
		for _, it := range m.fixCache {
			if fixCategoryOf(it) == cat {
				m.fixChecked[it.ID] = anyUnchecked
			}
		}
		return
	}
	m.fixChecked[value] = !m.fixChecked[value]
}

// rebuildFixPicker re-renders the fixes picker from fixCache + fixChecked,
// preserving the cursor, exactly like rebuildPluginPicker. The header asks
// the question the screen actually answers; Tab and x both toggle, s cycles
// the category-then-title order, Left/Right collapse/expand a category row,
// and Enter applies the delta. Every category defaults to expanded the first
// time it is seen, so the initial list still shows every fix.
func (m *model) rebuildFixPicker() {
	if m.fixFolderExpanded == nil {
		m.fixFolderExpanded = map[string]bool{}
	}
	for _, it := range m.fixCache {
		cat := fixCategoryOf(it)
		if _, ok := m.fixFolderExpanded[cat]; !ok {
			m.fixFolderExpanded[cat] = true
		}
	}
	header := "Choose the fixes to apply or remove for " + m.fixPlugin
	sidx := m.picker.Index()
	m.picker = tuikit.NewPicker(header,
		fixItemsToPicker(sortedFixItems(m.fixCache, m.fixSortDesc), m.fixChecked, m.fixFolderExpanded)).
		SetSize(m.contentSize()).
		SetHelpKeys(
			key.NewBinding(key.WithKeys("tab", "x"), key.WithHelp("tab/x", "toggle")),
			key.NewBinding(key.WithKeys("s"), key.WithHelp("s", "sort")),
			key.NewBinding(key.WithKeys("right"), key.WithHelp("→", "expand")),
			key.NewBinding(key.WithKeys("left"), key.WithHelp("←", "collapse")),
			key.NewBinding(key.WithKeys("enter"), key.WithHelp("enter", "apply")),
		)
	m.picker = m.picker.SelectIndex(sidx)
}

// fixAppliedBadge marks a plugin — or a folder holding one — that already has
// at least one applied fix. A filled square (not the ○/● checkbox glyph, and
// not a star) reads cleanly next to the selection marks and matches the
// legend shown at the top of the chooser ("□ = no fixes applied · ■ = fixes
// applied"). Rendered in the theme accent as a TrailingBadge, i.e. at the END
// of the row's own label ("name  ■"), never on the leading badge slot.
const fixAppliedBadge = "■"

// rebuildFixPluginPicker renders the "Plugin fixes — which plugin?"
// chooser with the exact same tree the Installed-plugins list uses:
// uninstallTree(pluginItemsAsItems(...)) folded through the shared
// folderExpanded map into treeItemsToPicker. It is a single-select screen
// (no Tab marks), so the help keys only advertise choose/sort/folders.
//
// The applied-fix marker used to be set only on the child plugin row, which
// the shared tree starts with COLLAPSED — so the one badged row was hidden
// and the chooser showed no marker at all. Now every folder that contains a
// matching plugin is expanded on sight (so the plugin's own row and square
// are visible) and the folder row itself also carries the square (so the
// marker survives a manual collapse). pluginStemOf reduces the full
// "vst:<type>:<path>" picker value to the canonical stem the applied set
// stores, exactly like fix_plugin_canonical().
func (m *model) rebuildFixPluginPicker() {
	if m.folderExpanded == nil {
		m.folderExpanded = map[string]bool{}
	}
	tree := uninstallTree(pluginItemsAsItems(m.fixPluginCache))
	appliedFolders := map[string]bool{}
	if len(m.fixAppliedPlugins) > 0 {
		for _, n := range tree {
			if !n.Folder {
				continue
			}
			for _, p := range n.Plugins {
				if m.fixAppliedPlugins[pluginStemOf(p.Value)] {
					appliedFolders[n.Value] = true
					m.folderExpanded[n.Value] = true
					break
				}
			}
		}
	}
	items := treeItemsToPicker(tree, m.pluginChecked, m.folderExpanded)
	// Accent ■ marker on every plugin row that already has at least one
	// applied fix, plus its parent folder header. It is a TrailingBadge, so
	// it renders at the END of the row label ("name  ■") — the leading
	// badge slot is deliberately left untouched (the user found the leading
	// square ugly). The kit reserves one trailing width for the whole
	// picker, so aligned rows stay aligned whether or not they carry the
	// square. The matching □/■ legend is rendered in the screen subtitle
	// (view.go, scrFixPluginPick).
	if len(m.fixAppliedPlugins) > 0 {
		folders := map[string]bool{}
		for _, n := range tree {
			if n.Folder {
				folders[n.Value] = true
			}
		}
		for i := range items {
			if folders[items[i].Value] {
				if appliedFolders[items[i].Value] {
					items[i].TrailingBadge = fixAppliedBadge
				}
				continue
			}
			if m.fixAppliedPlugins[pluginStemOf(items[i].Value)] {
				items[i].TrailingBadge = fixAppliedBadge
			}
		}
	}
	sidx := m.picker.Index()
	m.picker = tuikit.NewPicker("Plugin fixes — which plugin?", items).
		SetSize(m.contentSize()).
		SetHelpKeys(
			key.NewBinding(key.WithKeys("s"), key.WithHelp("s", "sort")),
			key.NewBinding(key.WithKeys("right"), key.WithHelp("→", "expand")),
			key.NewBinding(key.WithKeys("left"), key.WithHelp("←", "collapse")),
			key.NewBinding(key.WithKeys("enter"), key.WithHelp("enter", "choose")),
		)
	m.picker = m.picker.SelectIndex(sidx)
}

// pluginListHelpKeys are the extra shortcut hints shown in the picker's own
// help bar (alongside the built-in up/down/quit/?) -- never in the header,
// same convention as every other shortcut in this TUI.
func pluginListHelpKeys() []key.Binding {
	return []key.Binding{
		key.NewBinding(key.WithKeys("tab"), key.WithHelp("tab", "hide/show")),
		key.NewBinding(key.WithKeys("s"), key.WithHelp("s", "sort")),
		key.NewBinding(key.WithKeys("right"), key.WithHelp("→", "expand")),
		key.NewBinding(key.WithKeys("left"), key.WithHelp("←", "collapse")),
		key.NewBinding(key.WithKeys("x"), key.WithHelp("x", "window handler")),
		key.NewBinding(key.WithKeys("enter"), key.WithHelp("enter", "info")),
	}
}

// rebuildPluginPicker re-renders the Plugin list picker from pluginCache +
// pluginChecked -- called after every Tab toggle, every Left/Right
// folder open/collapse, and every fresh/re-sorted fetch, so the checkbox
// marks, the folder chevrons and the header's current sort label always
// match the model's in-progress state. The Readme entry is always appended,
// even when the list itself is empty, so it's never unreachable.
func (m *model) rebuildPluginPicker() {
	header := "Installed plugins — sort: " + sortModeLabel(m.status.SortMode)
	if len(m.pluginCache) == 0 {
		header = "No plugin found — see the Readme below for where DAWs must point"
	}
	if m.folderExpanded == nil {
		m.folderExpanded = map[string]bool{}
	}
	items := treeItemsToPicker(uninstallTree(pluginItemsAsItems(m.pluginCache)), m.pluginChecked, m.folderExpanded)
	items = append(items, tuikit.PickerItem{Display: "📖  Readme", Value: readmeSentinel})
	sidx := m.picker.Index()
	m.picker = tuikit.NewPicker(header, items).SetSize(m.contentSize()).SetHelpKeys(pluginListHelpKeys()...)
	m.picker = m.picker.SelectIndex(sidx)
}

// pluginDirty reports whether any Tab-marked checked-state differs from the
// server baseline captured on load.
func (m model) pluginDirty() bool {
	for k, v := range m.pluginChecked {
		if m.pluginOrig[k] != v {
			return true
		}
	}
	return false
}

// pluginDirtyCounts splits the dirty set into "about to be hidden" vs.
// "about to be shown again", for the save-confirm message.
func (m model) pluginDirtyCounts() (toHide, toShow int) {
	for k, v := range m.pluginChecked {
		if m.pluginOrig[k] == v {
			continue
		}
		if v {
			toShow++
		} else {
			toHide++
		}
	}
	return
}

func (m model) updateScreen(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch m.top() {

	case scrMain:
		if res, ok := msg.(tuikit.PickerResultMsg); ok {
			if res.Canceled {
				// Esc on the home screen asks the same quit-confirmation
				// as the explicit "Close" menu item — the user's standing
				// rule: esc at home must CONFIRM before closing, never
				// silently exit (and never skip the dialog either way).
				m.push(scrQuitConfirm)
				return m, m.enterCmd()
			}
			return m.handleMainChoice(res.Value)
		}
		var cmd tea.Cmd
		m.picker, cmd = m.picker.Update(msg)
		return m, cmd

	case scrSettings:
		if dm, ok := msg.(settingsDwellMsg); ok {
			// Dwell elapsed: apply the pending value for the row the user
			// stopped on (stale timers are dropped).
			if m.top() != scrSettings || dm.seq != m.settingsDwellSeq {
				return m, nil
			}
			return m, m.applySettingPending(dm.row)
		}
		if res, ok := msg.(tuikit.PickerResultMsg); ok {
			if res.Canceled || res.Value == "back" {
				// Leaving the screen commits every pending value first.
				cmd := m.applyAllPending()
				if m.top() == scrSettings {
					m.pop()
				}
				return m, tea.Batch(cmd, m.enterCmd())
			}
			// Enter acts on this row directly (its handler is the apply):
			// commit the other pending rows, drop this one's mark.
			applyCmd := m.applyAllPendingExcept(res.Value)
			mm, cmd := m.handleAudioSettingsChoice(res.Value)
			return mm, tea.Batch(applyCmd, cmd)
		}
		if _, ok := msg.(tuikit.PickerSortMsg); ok {
			// Left/Right updates the pending label only; the value is
			// applied on the dwell timer / blur / leave.
			return m.cycleLoadedSetting()
		}
		before := m.picker.SelectedValue()
		var cmd tea.Cmd
		m.picker, cmd = m.picker.Update(msg)
		after := m.picker.SelectedValue()
		var applyCmd tea.Cmd
		if before != "" && before != after {
			// Cursor moved to a different row: apply what was left behind.
			applyCmd = m.applySettingPending(before)
		}
		return m, tea.Batch(cmd, applyCmd)

	case scrWizardRoot:
		if res, ok := msg.(tuikit.ConfirmResultMsg); ok {
			if res.Canceled {
				// Skip the wizard entirely: load_prefs already picked a
				// sensible default root, nothing needs changing. The next
				// launch will offer the wizard again (wizard_done is still
				// false) — it is only finished by actually completing it.
				m.pop()
				return m, m.enterCmd()
			}
			if !res.Yes {
				// "No, choose a folder": open the default file manager
				// (superfile if installed, running inside this terminal) to
				// browse, then the native folder dialog for the real
				// choice — same picker the Settings screens use.
				m.loading = true
				if m.status.SuperfileInstalled {
					return m, wizardBrowseThenPick()
				}
				return m, pickFolderCmd("wizard-root", "Choose your plugins folder", m.status.PluginsRoot)
			}
			// "Yes, use the default".
			return m, m.startWizardFinish()
		}
		if pm, ok := msg.(pathMsg); ok && pm.kind == "wizard-browse-done" {
			// superfile just exited (browse-only — it can't pick a bare
			// folder): now the native dialog captures the actual choice.
			m.loading = true
			return m, pickFolderCmd("wizard-root", "Choose your plugins folder", m.status.PluginsRoot)
		}
		var cmd tea.Cmd
		m.confirm, cmd = m.confirm.Update(msg)
		return m, cmd

	case scrPluginsRootConfirm:
		if res, ok := msg.(tuikit.ConfirmResultMsg); ok {
			m.pop()
			if res.Canceled || !res.Yes {
				return m, m.enterCmd()
			}
			m.push(scrPluginsRootMigrating)
			m.runner = tuikit.NewRunner().SetSize(m.contentSize())
			var cmd tea.Cmd
			m.runner, cmd = m.runner.Start("Moving plugins", actionsBin(), "set-plugins-root", m.pendingPluginsRoot)
			return m, cmd
		}
		var cmd tea.Cmd
		m.confirm, cmd = m.confirm.Update(msg)
		return m, cmd

	case scrRunnerSuccessConfirm:
		if res, ok := msg.(tuikit.ConfirmResultMsg); ok {
			if res.Canceled || !res.Yes {
				// "See log" -- open the FULL run log in the universal Info
				// screen (same bounded, wrapping, scrollable, framed log
				// view mosquitomarchy uses), so the details read like any
				// other full-screen log in the mosquito TUIs.
				m.info = tuikit.NewInfo(m.runner.Output()).
					SetSize(m.contentSize())
				m.pop()
				m.push(scrInfo)
				return m, nil
			}
			// "OK" -- return to the main menu.
			m.pop()
			m.nav = []screen{scrMain}
			return m, m.enterCmd()
		}
		var cmd tea.Cmd
		m.confirm, cmd = m.confirm.Update(msg)
		return m, cmd

	case scrVstMenu:
		if dm, ok := msg.(settingsDwellMsg); ok {
			if m.top() != scrVstMenu || dm.seq != m.settingsDwellSeq {
				return m, nil
			}
			return m, m.applySettingPending(dm.row)
		}
		if res, ok := msg.(tuikit.PickerResultMsg); ok {
			if res.Canceled || res.Value == "back" {
				cmd := m.applyAllPending()
				if m.top() == scrVstMenu {
					m.pop()
				}
				return m, tea.Batch(cmd, m.enterCmd())
			}
			applyCmd := m.applyAllPendingExcept(res.Value)
			mm, cmd := m.handleVstMenuChoice(res.Value)
			return mm, tea.Batch(applyCmd, cmd)
		}
		if _, ok := msg.(tuikit.PickerSortMsg); ok {
			// The two Hide filters defer like the Settings rows.
			return m.cycleLoadedSetting()
		}
		before := m.picker.SelectedValue()
		var cmd tea.Cmd
		m.picker, cmd = m.picker.Update(msg)
		after := m.picker.SelectedValue()
		var applyCmd tea.Cmd
		if before != "" && before != after {
			applyCmd = m.applySettingPending(before)
		}
		return m, tea.Batch(cmd, applyCmd)

	case scrPluginList:
		if km, ok := msg.(tea.KeyMsg); ok && km.String() == "s" {
			// `s` cycles the sort now that Left/Right fold folder rows
			// (the old arrow-key sort binding). Intercepted here, before
			// the picker ever sees the key.
			return m, cycleSortCmd(stepSortMode(m.status.SortMode, 1))
		}
		if pl, ok := msg.(pluginListMsg); ok {
			m.loading = false
			if pl.err != nil {
				m.toast, _ = m.toast.SetErr(pl.err.Error())
				m.pop()
				return m, m.enterCmd()
			}
			if pl.mode != "" {
				m.status.SortMode = pl.mode
			}
			m.pluginCache = pl.items
			if m.pluginChecked == nil {
				// First load for this visit -- seed both maps from the
				// server's own enabled/disabled state.
				m.pluginChecked = map[string]bool{}
				m.pluginOrig = map[string]bool{}
			}
			for _, it := range pl.items {
				if it.Kind == "folder" {
					continue // folder rows derive their mark from their children
				}
				if _, ok := m.pluginChecked[it.Value]; !ok {
					m.pluginChecked[it.Value] = it.Enabled
					m.pluginOrig[it.Value] = it.Enabled
				}
			}
			m.rebuildPluginPicker()
			return m, nil
		}
		if tg, ok := msg.(tuikit.PickerToggleMsg); ok {
			if tg.Value == readmeSentinel {
				return m, nil
			}
			rows := pluginItemsAsItems(m.pluginCache)
			if isFolderRow(rows, tg.Value) {
				// Folder row: hide/show every plugin it contains.
				toggleFolderPlugins(rows, tg.Value, m.pluginChecked)
			} else {
				m.pluginChecked[tg.Value] = !m.pluginChecked[tg.Value]
			}
			m.rebuildPluginPicker()
			return m, nil
		}
		if am, ok := msg.(tuikit.PickerActionMsg); ok && am.Key == "x" {
			// x: request the plugin window handler flip (classic ⇄
			// hyprland) from the plugin list itself — the registered
			// shortcut for the "which window layout do plugin GUIs use"
			// toggle, and the same handler the Settings row exposes. The
			// change is global, so it goes through the confirmation screen.
			// (x is deliberately kept for this; Tab is the hide/show key.)
			return m, m.requestPluginHandlerChange(togglePluginHandlerTarget(m.status.PluginWinHandler))
		}
		if sm, ok := msg.(tuikit.PickerSortMsg); ok {
			// LEFT/RIGHT now open/close the folder row under the cursor,
			// exactly like the uninstall screen (Right = reveal
			// sub-plugins, Left = hide them again); the sort cycle moved
			// to `s`. Both screens share m.folderExpanded and the same
			// treeItemsToPicker, so the gesture and the rendering stay in
			// lockstep.
			if fv := selectedFolderValueIn(pluginItemsAsItems(m.pluginCache), m.picker.SelectedValue()); fv != "" {
				if m.folderExpanded == nil {
					m.folderExpanded = map[string]bool{}
				}
				if sm.Dir > 0 {
					m.folderExpanded[fv] = true
				} else {
					delete(m.folderExpanded, fv)
				}
				m.rebuildPluginPicker()
			}
			return m, nil
		}
		if sd, ok := msg.(pluginSaveDoneMsg); ok {
			m.loading = false
			if sd.err != nil {
				m.toast, _ = m.toast.SetErr(sd.err.Error())
				return m, nil
			}
			m.toast, _ = m.toast.SetOK(sd.what)
			m.pop()
			return m, m.enterCmd()
		}
		if res, ok := msg.(tuikit.PickerResultMsg); ok {
			if res.Canceled {
				if m.pluginDirty() {
					toHide, toShow := m.pluginDirtyCounts()
					m.confirm = tuikit.NewConfirm(
						fmt.Sprintf("Save visibility changes? %d to hide, %d to show", toHide, toShow),
						"Discard", "Save")
					m.push(scrPluginListSaveConfirm)
					return m, nil
				}
				m.pop()
				return m, m.enterCmd()
			}
			if res.Value == readmeSentinel {
				m.loading = true
				return m, fetchText("plugin-list-readme", "readme-text")
			}
			m.loading = true
			return m, fetchText("plugin-detail-info", "plugin-detail", res.Value)
		}
		if tm, ok := msg.(textMsg); ok && (tm.kind == "plugin-list-readme" || tm.kind == "plugin-detail-info") {
			m.loading = false
			if tm.err != nil {
				m.toast, _ = m.toast.SetErr(tm.err.Error())
				return m, nil
			}
			m.info = tuikit.NewInfo(tm.text).SetSize(m.contentSize())
			m.push(scrInfo)
			return m, nil
		}
		var cmd tea.Cmd
		m.picker, cmd = m.picker.Update(msg)
		return m, cmd

	case scrFixPluginPick:
		if km, ok := msg.(tea.KeyMsg); ok && km.String() == "s" {
			// `s` cycles the same vendor→name→format→date sort the
			// Installed-plugins list uses; set-sort-and-list persists it
			// and returns the freshly ordered rows.
			return m, cycleSortCmd(stepSortMode(m.status.SortMode, 1))
		}
		if pl, ok := msg.(pluginListMsg); ok {
			m.loading = false
			if pl.err != nil {
				m.toast, _ = m.toast.SetErr(pl.err.Error())
				m.pop()
				return m, m.enterCmd()
			}
			if pl.mode != "" {
				m.status.SortMode = pl.mode
			}
			m.fixPluginCache = pl.items
			// Seed the row marks from the server's enabled state exactly like
			// Installed plugins, so the shared tree renderer looks the same.
			if m.pluginChecked == nil {
				m.pluginChecked = map[string]bool{}
				m.pluginOrig = map[string]bool{}
			}
			for _, it := range pl.items {
				if it.Kind == "folder" {
					continue
				}
				if _, ok := m.pluginChecked[it.Value]; !ok {
					m.pluginChecked[it.Value] = it.Enabled
					m.pluginOrig[it.Value] = it.Enabled
				}
			}
			m.rebuildFixPluginPicker()
			return m, nil
		}
		if af, ok := msg.(appliedFixPluginsMsg); ok {
			// The applied-fix set can land before or after the plugin list
			// (two round trips race); store it and rebuild either way — on an
			// empty cache the rebuild is harmless and the list fetch rebuilds
			// again with the badges once it arrives.
			if af.err != nil {
				// Never swallow this silently: a failed fetch would leave
				// every row unbadged with no explanation, which reads exactly
				// like "the applied-fix indicator doesn't show".
				m.toast, _ = m.toast.SetWarn("could not read applied fixes")
				return m, nil
			}
			m.fixAppliedPlugins = af.plugins
			m.rebuildFixPluginPicker()
			return m, nil
		}
		if sm, ok := msg.(tuikit.PickerSortMsg); ok {
			// Left/Right fold the folder row under the cursor, sharing the
			// same folderExpanded map and tree renderer as Installed plugins.
			if fv := selectedFolderValueIn(pluginItemsAsItems(m.fixPluginCache), m.picker.SelectedValue()); fv != "" {
				if m.folderExpanded == nil {
					m.folderExpanded = map[string]bool{}
				}
				if sm.Dir > 0 {
					m.folderExpanded[fv] = true
				} else {
					delete(m.folderExpanded, fv)
				}
				m.rebuildFixPluginPicker()
			}
			return m, nil
		}
		if res, ok := msg.(tuikit.PickerResultMsg); ok {
			if res.Canceled {
				m.pop()
				return m, m.enterCmd()
			}
			// Single-select: a folder row folds/unfolds instead of being
			// chosen; only a plugin row moves on to the fixes list.
			if isFolderRow(pluginItemsAsItems(m.fixPluginCache), res.Value) {
				if m.folderExpanded == nil {
					m.folderExpanded = map[string]bool{}
				}
				if m.folderExpanded[res.Value] {
					delete(m.folderExpanded, res.Value)
				} else {
					m.folderExpanded[res.Value] = true
				}
				m.rebuildFixPluginPicker()
				return m, nil
			}
			m.fixPlugin = res.Value
			m.push(scrFixChoose)
			return m, m.enterCmd()
		}
		var cmd tea.Cmd
		m.picker, cmd = m.picker.Update(msg)
		return m, cmd

	case scrFixChoose:
		if km, ok := msg.(tea.KeyMsg); ok && km.String() == "s" {
			// `s` flips the fixes order between category-then-title A→Z
			// and Z→A. Intercepted before the picker sees the key.
			m.fixSortDesc = !m.fixSortDesc
			m.rebuildFixPicker()
			return m, nil
		}
		if fm, ok := msg.(fixesMsg); ok {
			m.loading = false
			if fm.err != nil {
				m.toast, _ = m.toast.SetErr(fm.err.Error())
				m.pop()
				return m, m.enterCmd()
			}
			m.fixCache = fm.items
			if m.fixChecked == nil {
				// First load for this visit -- seed the marks from the
				// server's applied state, same diff contract as the list.
				m.fixChecked = map[string]bool{}
				m.fixOrig = map[string]bool{}
			}
			for _, it := range fm.items {
				if _, ok := m.fixChecked[it.ID]; !ok {
					m.fixChecked[it.ID] = it.Applied
					m.fixOrig[it.ID] = it.Applied
				}
			}
			m.rebuildFixPicker()
			return m, nil
		}
		if tg, ok := msg.(tuikit.PickerToggleMsg); ok {
			m.toggleFixValue(tg.Value)
			m.rebuildFixPicker()
			return m, nil
		}
		if am, ok := msg.(tuikit.PickerActionMsg); ok && am.Key == "x" {
			// x is a second toggle key on this screen (the fixes list has
			// no other x shortcut).
			m.toggleFixValue(m.picker.SelectedValue())
			m.rebuildFixPicker()
			return m, nil
		}
		if sm, ok := msg.(tuikit.PickerSortMsg); ok {
			// LEFT/RIGHT collapse/expand the category header under the
			// cursor (Right = expand, Left = collapse), same gesture and
			// chevron as the other two folder lists. Toggling the header
			// still checks/unchecks the whole category regardless of the
			// expanded state.
			if v := m.picker.SelectedValue(); strings.HasPrefix(v, fixCategoryValuePrefix) {
				cat := strings.TrimPrefix(v, fixCategoryValuePrefix)
				if m.fixFolderExpanded == nil {
					m.fixFolderExpanded = map[string]bool{}
				}
				if sm.Dir > 0 {
					m.fixFolderExpanded[cat] = true
				} else {
					m.fixFolderExpanded[cat] = false
				}
				m.rebuildFixPicker()
			}
			return m, nil
		}
		if df, ok := msg.(fixesDoneMsg); ok {
			m.loading = false
			m.toast, _ = m.toast.SetOK(df.what)
			m.pop()
			return m, m.enterCmd()
		}
		if res, ok := msg.(tuikit.PickerResultMsg); ok {
			if res.Canceled {
				m.pop()
				return m, m.enterCmd()
			}
			var toApply, toRemove []string
			for id, v := range m.fixChecked {
				if v && !m.fixOrig[id] {
					toApply = append(toApply, id)
				}
				if !v && m.fixOrig[id] {
					toRemove = append(toRemove, id)
				}
			}
			if len(toApply) == 0 && len(toRemove) == 0 {
				m.toast, _ = m.toast.SetWarn("no change")
				return m, nil
			}
			m.loading = true
			return m, syncFixesCmd(m.fixPlugin, toApply, toRemove)
		}
		var cmd tea.Cmd
		m.picker, cmd = m.picker.Update(msg)
		return m, cmd

	case scrPluginListSaveConfirm:
		if res, ok := msg.(tuikit.ConfirmResultMsg); ok {
			if res.Canceled {
				m.pop() // back to the still-open plugin list, nothing changed
				return m, nil
			}
			if !res.Yes {
				// Discard: revert the in-progress marks and leave.
				for k := range m.pluginChecked {
					m.pluginChecked[k] = m.pluginOrig[k]
				}
				m.pop() // leave the confirm
				m.pop() // leave the plugin list
				return m, m.enterCmd()
			}
			var toToggle []string
			for k, v := range m.pluginChecked {
				if m.pluginOrig[k] != v {
					toToggle = append(toToggle, k)
				}
			}
			m.pop() // leave the confirm -- plugin list is on top again
			m.loading = true
			return m, saveHiddenChangesCmd(toToggle)
		}
		var cmd tea.Cmd
		m.confirm, cmd = m.confirm.Update(msg)
		return m, cmd

	case scrInfo:
		if _, ok := msg.(tuikit.InfoDismissedMsg); ok {
			m.pop()
			return m, m.enterCmd()
		}
		var cmd tea.Cmd
		m.info, cmd = m.info.Update(msg)
		return m, cmd

	case scrReconcileMissingInfo:
		if res, ok := msg.(tuikit.ConfirmResultMsg); ok {
			if res.Canceled {
				m.pop()
				return m, m.enterCmd()
			}
			if !res.Yes {
				// "add to log": keep the shared-log entry, stop nagging here.
				what := fmt.Sprintf("kept in the log: %d plugin(s)", len(m.missingKeys))
				args := append([]string{"add-missing"}, m.missingKeys...)
				return m, runFireAndForget(what, args...)
			}
			// "remove everywhere": ask a second, explicit confirmation.
			m.confirm = tuikit.NewConfirm(
				fmt.Sprintf("Really remove %d plugin(s) from the log EVERYWHERE? Their files are already gone on this computer. This also clears their generated menu entries.", len(m.missingKeys)),
				"keep in log", "remove everywhere")
			m.push(scrReconcileMissingRemove)
			return m, nil
		}
		var cmd tea.Cmd
		m.confirm, cmd = m.confirm.Update(msg)
		return m, cmd

	case scrReconcileMissingRemove:
		if res, ok := msg.(tuikit.ConfirmResultMsg); ok {
			if !res.Canceled && res.Yes {
				what := fmt.Sprintf("removed everywhere: %d plugin(s)", len(m.missingKeys))
				args := append([]string{"remove-missing"}, m.missingKeys...)
				return m, runFireAndForget(what, args...)
			}
			m.pop() // back to the first prompt ("add to log" / esc)
			return m, m.enterCmd()
		}
		var cmd tea.Cmd
		m.confirm, cmd = m.confirm.Update(msg)
		return m, cmd

	case scrCleanupConfirm:
		if res, ok := msg.(tuikit.ConfirmResultMsg); ok {
			m.pop()
			if res.Canceled || !res.Yes {
				return m, m.enterCmd()
			}
			return m, cleanupCmd()
		}
		var cmd tea.Cmd
		m.confirm, cmd = m.confirm.Update(msg)
		return m, cmd

	case scrPluginHandlerConfirm:
		if res, ok := msg.(tuikit.ConfirmResultMsg); ok {
			m.pop()
			// Whatever the outcome, the pending Settings mark is spent:
			// drop it so the row settles on the real (applied or kept)
			// value instead of re-opening the confirm on the next dwell.
			delete(m.settingsPending, "toggle_plugin_handler")
			if res.Canceled || !res.Yes {
				// Cancel/No leaves the current value untouched.
				m.pendingHandlerMode = ""
				return m, m.enterCmd()
			}
			mode := m.pendingHandlerMode
			m.pendingHandlerMode = ""
			m.loading = true
			return m, setPluginHandlerCmd(mode)
		}
		var cmd tea.Cmd
		m.infoConfirm, cmd = m.infoConfirm.Update(msg)
		return m, cmd

	case scrUninstallPick:
		if km, ok := msg.(tea.KeyMsg); ok && km.String() == "s" {
			// `s` cycles the sort here too (Left/Right are the folder
			// open/collapse gesture on this screen). cycleSortCmd persists
			// the mode and re-lists; the resulting pluginListMsg is
			// converted back into the uninstall cache below.
			return m, cycleSortCmd(stepSortMode(m.status.SortMode, 1))
		}
		if it, ok := msg.(itemsMsg); ok && it.kind == "uninstall" {
			m.loading = false
			if it.err != nil {
				m.toast, _ = m.toast.SetErr(it.err.Error())
				m.pop()
				return m, m.enterCmd()
			}
			if len(it.items) == 0 {
				m.info = tuikit.NewInfo("No plugin to uninstall — nothing installed yet.").SetSize(m.contentSize())
				m.replace(scrInfo)
				return m, nil
			}
			m.uninstallCache = it.items
			m.rebuildUninstallPicker()
			return m, nil
		}
		if pl, ok := msg.(pluginListMsg); ok {
			// Re-sort result shared with the Installed-plugins list: the
			// same unified rows, fed through the same tree the uninstall
			// screen renders.
			m.loading = false
			if pl.err != nil {
				m.toast, _ = m.toast.SetErr(pl.err.Error())
				return m, nil
			}
			if pl.mode != "" {
				m.status.SortMode = pl.mode
			}
			m.uninstallCache = pluginItemsAsItems(pl.items)
			m.rebuildUninstallPicker()
			return m, nil
		}
		if tg, ok := msg.(tuikit.PickerToggleMsg); ok {
			// Tab on a folder row: toggle every sub-plugin under that
			// folder to the opposite state (all-checked → all-unchecked,
			// any-unselected → all-checked). The user gets the "pick the
			// whole installer" gesture with one keystroke, and the
			// folder's ○/● mark turns filled. Tab on a single plugin
			// row: toggle only that one, cursor stays where it is.
			if isFolderRow(m.uninstallCache, tg.Value) {
				toggleFolderPlugins(m.uninstallCache, tg.Value, m.uninstallChecked)
			} else {
				m.uninstallChecked[tg.Value] = !m.uninstallChecked[tg.Value]
			}
			m.rebuildUninstallPicker()
			return m, nil
		}
		if am, ok := msg.(tuikit.PickerActionMsg); ok && am.Key == "x" {
			// x opens the highlighted row's containing folder in the
			// system file manager (folder rows open the wine program
			// folder; plugin rows open the folder holding the plugin
			// file). This is the uninstall screen's only x binding, so
			// Tab stays the multi-select key here.
			return m, openFolderCmd(m.picker.SelectedValue())
		}
		if sm, ok := msg.(tuikit.PickerSortMsg); ok {
			// LEFT/RIGHT open/close the folder row under the cursor
			// (Right = reveal sub-plugins, Left = hide them again). The
			// sort cycle moved to `s`, so these keys are free for folder
			// navigation — same gesture as the Installed-plugins list.
			if fv := m.selectedFolderValue(); fv != "" {
				if m.folderExpanded == nil {
					m.folderExpanded = map[string]bool{}
				}
				if sm.Dir > 0 {
					m.folderExpanded[fv] = true
				} else {
					delete(m.folderExpanded, fv)
				}
				m.rebuildUninstallPicker()
			}
			return m, nil
		}
		if res, ok := msg.(tuikit.PickerResultMsg); ok {
			if res.Canceled {
				m.pop()
				return m, m.enterCmd()
			}
			var targets []string
			for _, it := range m.uninstallCache {
				if m.uninstallChecked[it.Value] {
					targets = append(targets, it.Value)
				}
			}
			if len(targets) == 0 {
				// Nothing Tab-checked -- fall back to the single highlighted
				// row, preserving the old one-shot-pick convenience.
				targets = []string{res.Value}
			}
			m.uninstallTargets = targets
			m.push(scrUninstallConfirm)
			if len(targets) == 1 {
				m.confirm = tuikit.NewConfirm("Remove '"+baseName(targets[0])+"'? (files are quarantined, nothing is destroyed)", "No", "Yes")
			} else {
				m.confirm = tuikit.NewConfirm(fmt.Sprintf("Remove %d plugins? (files are quarantined, nothing is destroyed)", len(targets)), "No", "Yes")
			}
			return m, nil
		}
		var cmd tea.Cmd
		m.picker, cmd = m.picker.Update(msg)
		return m, cmd

	case scrUninstallConfirm:
		if res, ok := msg.(tuikit.ConfirmResultMsg); ok {
			m.pop()
			if !res.Yes {
				return m, m.enterCmd()
			}
			m.replace(scrUninstalling)
			m.runner = tuikit.NewRunner().SetSize(m.contentSize())
			args := append([]string{"uninstall-batch"}, m.uninstallTargets...)
			var cmd tea.Cmd
			m.runner, cmd = m.runner.Start("Uninstalling", actionsBin(), args...)
			return m, cmd
		}
		var cmd tea.Cmd
		m.confirm, cmd = m.confirm.Update(msg)
		return m, cmd

	case scrInstallPrefixChoice:
		if res, ok := msg.(tuikit.ConfirmResultMsg); ok {
			if res.Canceled {
				// Esc here must abort the install, not be read as the "No,
				// new prefix" button — that's a real, deliberate choice
				// with its own next screen, not a synonym for cancel.
				m.pop()
				return m, m.enterCmd()
			}
			if res.Yes {
				m.installNew = false
				return m, tea.Batch(fetchPath("default-prefix", "default-prefix"))
			}
			m.installNew = true
			m.push(scrInstallPrefixName)
			return m, m.enterCmd()
		}
		var cmd tea.Cmd
		m.confirm, cmd = m.confirm.Update(msg)
		return m, cmd

	case scrInstallPrefixName:
		if res, ok := msg.(tuikit.InputResultMsg); ok {
			if res.Canceled || res.Value == "" {
				m.pop()
				m.pop()
				return m, m.enterCmd()
			}
			return m, fetchPath("create-prefix", "create-prefix", res.Value)
		}
		var cmd tea.Cmd
		m.input, cmd = m.input.Update(msg)
		return m, cmd

	case scrStandalonePick:
		if it, ok := msg.(itemsMsg); ok && it.kind == "standalone" {
			m.loading = false
			if len(it.items) == 0 {
				m.info = tuikit.NewInfo("No standalone executable registered yet — install a plugin via the manager first.").SetSize(m.contentSize())
				m.replace(scrInfo)
				return m, nil
			}
			m.picker = tuikit.NewPicker("Launch a standalone plugin (via wine)?", itemsToPicker(it.items)).SetSize(m.contentSize())
			return m, nil
		}
		if res, ok := msg.(tuikit.PickerResultMsg); ok {
			m.pop()
			if res.Canceled {
				return m, m.enterCmd()
			}
			return m, tea.Batch(m.enterCmd(), runFireAndForget("launched", "launch-standalone", res.Value))
		}
		var cmd tea.Cmd
		m.picker, cmd = m.picker.Update(msg)
		return m, cmd

	case scrExecsToggle:
		if et, ok := msg.(execToggleMsg); ok {
			m.loading = false
			if len(et.items) == 0 {
				m.info = tuikit.NewInfo("No standalone executable registered yet — install a plugin via the manager first.").SetSize(m.contentSize())
				m.replace(scrInfo)
				return m, nil
			}
			m.picker = tuikit.NewPicker("Toggle which executables appear in the menu — keep picking, esc to finish:", execItemsToPicker(et.items)).
				SetSize(m.contentSize()).
				SetHelpKeys(
					key.NewBinding(key.WithKeys("tab", "x"), key.WithHelp("tab/x", "toggle")),
					key.NewBinding(key.WithKeys("enter"), key.WithHelp("enter", "toggle")),
				)
			return m, nil
		}
		if tg, ok := msg.(tuikit.PickerToggleMsg); ok {
			return m, toggleExecAndRefetch(tg.Value)
		}
		if am, ok := msg.(tuikit.PickerActionMsg); ok && am.Key == "x" {
			return m, toggleExecAndRefetch(m.picker.SelectedValue())
		}
		if res, ok := msg.(tuikit.PickerResultMsg); ok {
			if res.Canceled {
				m.pop()
				return m, m.enterCmd()
			}
			return m, toggleExecAndRefetch(res.Value)
		}
		var cmd tea.Cmd
		m.picker, cmd = m.picker.Update(msg)
		return m, cmd

	case scrInstallFixesConfirm:
		if res, ok := msg.(tuikit.ConfirmResultMsg); ok {
			if res.Yes && !res.Canceled {
				// Drive the normal apply-fixes screen for the freshly
				// installed plugin (which pre-checks whatever is already
				// applied). Drop the finished runner screen so the fix
				// flow, when it finishes, returns straight to the menu.
				m.fixPlugin = m.installFixPlugin
				m.nav = []screen{scrMain, scrFixChoose}
				return m, m.enterCmd()
			}
			// Declined: show the ordinary install-success prompt in place
			// of the question.
			m.confirm = tuikit.NewConfirm("Success! The step completed without errors.", "See log", "OK")
			m.replace(scrRunnerSuccessConfirm)
			return m, nil
		}
		var cmd tea.Cmd
		m.confirm, cmd = m.confirm.Update(msg)
		return m, cmd

	case scrReconcileOrphansTick:
		if ro, ok := msg.(reconcileOrphansMsg); ok {
			if len(ro.items) == 0 {
				m.pop()
				return m, nil
			}
			m.picker = tuikit.NewPicker("Found on disk but not tracked — pick to add (esc to finish):", itemsToPicker(ro.items)).SetSize(m.contentSize())
			return m, nil
		}
		if res, ok := msg.(tuikit.PickerResultMsg); ok {
			if res.Canceled {
				m.pop()
				return m, nil
			}
			return m, addOrphanAndRefetch(res.Value)
		}

		if rr, ok := msg.(reconcileResultMsg); ok {
			if rr.err != nil {
				m.toast, _ = m.toast.SetErr(rr.err.Error())
				return m, nil
			}
			m.toast, _ = m.toast.SetOK(rr.ok)
			if len(rr.items) == 0 {
				// Every orphan registered — the screen's job is done.
				m.pop()
				return m, m.enterCmd()
			}
			sidx := m.picker.Index()
			m.picker = tuikit.NewPicker("Found on disk but not tracked — pick to add (esc to finish):",
				itemsToPicker(rr.items)).SetSize(m.contentSize())
			m.picker = m.picker.SelectIndex(sidx)
			return m, nil
		}
		var cmd tea.Cmd
		m.picker, cmd = m.picker.Update(msg)
		return m, cmd

	case scrPrefixMovePluginPick:
		if pp, ok := msg.(prefixedPluginsMsg); ok {
			m.loading = false
			if pp.err != nil || len(pp.items) == 0 {
				m.info = tuikit.NewInfo("No prefix to manage — nothing installed yet.").SetSize(m.contentSize())
				m.replace(scrInfo)
				return m, nil
			}
			items := make([]tuikit.PickerItem, len(pp.items))
			for i, it := range pp.items {
				items[i] = tuikit.PickerItem{Display: it.Display, Value: it.Key + "\x1f" + it.Prefix}
			}
			m.picker = tuikit.NewPicker("Manage prefixes — move a plugin to another prefix:", items).SetSize(m.contentSize())
			return m, nil
		}
		if res, ok := msg.(tuikit.PickerResultMsg); ok {
			if res.Canceled {
				m.pop()
				return m, m.enterCmd()
			}
			key, prefix := splitPair(res.Value)
			m.moveKey = key
			m.moveFrom = prefix
			m.push(scrPrefixMoveTargetPick)
			return m, m.enterCmd()
		}
		var cmd tea.Cmd
		m.picker, cmd = m.picker.Update(msg)
		return m, cmd

	case scrPrefixMoveTargetPick:
		if pf, ok := msg.(prefixesMsg); ok {
			m.loading = false
			var items []tuikit.PickerItem
			for _, p := range pf.items {
				if p.Path == m.moveFrom {
					continue
				}
				items = append(items, tuikit.PickerItem{Display: p.Label, Value: p.Path})
			}
			items = append(items, tuikit.PickerItem{Display: "New prefix", Value: "__new__"})
			m.picker = tuikit.NewPicker("Move to which prefix? (currently "+baseName(m.moveFrom)+")", items).SetSize(m.contentSize())
			return m, nil
		}
		if res, ok := msg.(tuikit.PickerResultMsg); ok {
			if res.Canceled {
				m.pop()
				return m, m.enterCmd()
			}
			if res.Value == "__new__" {
				m.moveNew = true
				m.push(scrPrefixMoveTargetName)
				return m, m.enterCmd()
			}
			m.moveTo = res.Value
			m.push(scrPrefixMoveConfirm)
			return m, m.enterCmd()
		}
		var cmd tea.Cmd
		m.picker, cmd = m.picker.Update(msg)
		return m, cmd

	case scrPrefixMoveTargetName:
		if res, ok := msg.(tuikit.InputResultMsg); ok {
			if res.Canceled || res.Value == "" {
				m.pop()
				return m, m.enterCmd()
			}
			return m, fetchPath("move-create-prefix", "create-prefix", res.Value)
		}
		var cmd tea.Cmd
		m.input, cmd = m.input.Update(msg)
		return m, cmd

	case scrPrefixMoveConfirm:
		if res, ok := msg.(tuikit.ConfirmResultMsg); ok {
			m.pop()
			m.pop()
			m.pop()
			if !res.Yes {
				return m, m.enterCmd()
			}
			m.push(scrMoving)
			m.runner = tuikit.NewRunner().SetSize(m.contentSize())
			var cmd tea.Cmd
			m.runner, cmd = m.runner.Start("Moving", actionsBin(), "move-plugin", m.moveKey, m.moveFrom, m.moveTo)
			return m, cmd
		}
		var cmd tea.Cmd
		m.confirm, cmd = m.confirm.Update(msg)
		return m, cmd

	case scrQuitConfirm:
		if res, ok := msg.(tuikit.ConfirmResultMsg); ok {
			if res.Yes {
				m.quit = true
				return m, tea.Quit
			}
			m.pop()
			return m, m.enterCmd()
		}
		var cmd tea.Cmd
		m.confirm, cmd = m.confirm.Update(msg)
		return m, cmd

	case scrSuperfileInstallConfirm:
		if res, ok := msg.(tuikit.ConfirmResultMsg); ok {
			m.pop()
			if res.Canceled || !res.Yes {
				return m, m.enterCmd()
			}
			m.push(scrSuperfileInstalling)
			m.runner = tuikit.NewRunner().SetSize(m.contentSize())
			var cmd tea.Cmd
			m.runner, cmd = m.runner.Start("Installing superfile", actionsBin(), "ensure-superfile")
			return m, cmd
		}
		var cmd tea.Cmd
		m.confirm, cmd = m.confirm.Update(msg)
		return m, cmd

	case scrSuperfileInstalling:
		if done, ok := msg.(tuikit.RunnerDoneMsg); ok {
			if done.Err == nil {
				m.nav = []screen{scrMain, scrSettings}
				m.toast, _ = m.toast.SetOK("superfile installed — file picker set to Superfile")
				return m, setFilePickerAndRefetch("superfile")
			}
			return m, nil
		}
		if km, ok := msg.(tea.KeyMsg); ok && km.String() == "esc" {
			// Esc: cancel the install AND pop back to settings immediately.
			if !m.runner.Done() {
				m.runner.Cancel()
			}
			m.pop()
			return m, m.enterCmd()
		}
		if km, ok := msg.(tea.KeyMsg); ok && km.String() == "enter" {
			// Enter only continues once done.
			if m.runner.Done() {
				m.pop()
				return m, m.enterCmd()
			}
			return m, nil
		}
		var cmd tea.Cmd
		m.runner, cmd = m.runner.Update(msg)
		return m, cmd

	case scrWizardDaw:
		if km, ok := msg.(tea.KeyMsg); ok && km.String() == "esc" {
			// Esc cancels the reporting run and heads to the main menu.
			// The plugins-folder decision was already persisted at the top
			// of wizard-finish, so cancelling here only skips the readout.
			if !m.runner.Done() {
				m.runner.Cancel()
			}
			m.nav = []screen{scrMain}
			return m, m.enterCmd()
		}
		if km, ok := msg.(tea.KeyMsg); ok && km.String() == "enter" {
			if m.runner.Done() {
				m.nav = []screen{scrMain}
				return m, m.enterCmd()
			}
			return m, nil
		}
		var cmd tea.Cmd
		m.runner, cmd = m.runner.Update(msg)
		return m, cmd

	case scrUninstalling, scrInstalling, scrMoving, scrPluginsRootMigrating:
		if done, ok := msg.(tuikit.RunnerDoneMsg); ok {
			_ = done
			return m, nil
		}
		if km, ok := msg.(tea.KeyMsg); ok && km.String() == "esc" {
			// Esc: cancel AND pop back to main immediately.
			if !m.runner.Done() {
				m.runner.Cancel()
			}
			m.nav = []screen{scrMain}
			return m, m.enterCmd()
		}
		if km, ok := msg.(tea.KeyMsg); ok && km.String() == "enter" {
			if m.runner.Done() {
				m.nav = []screen{scrMain}
				return m, m.enterCmd()
			}
			return m, nil
		}
		var cmd tea.Cmd
		m.runner, cmd = m.runner.Update(msg)
		return m, cmd
	}
	return m, nil
}

// requestPluginHandlerChange parks a target handler mode and shows the
// global-rules confirmation instead of switching immediately. Changing the
// handler rewrites the GLOBAL Hyprland window rules for every wine plugin
// editor, it only affects plugin windows created after the reload, and a
// per-plugin fix overrides it — broad enough that it must be confirmed.
// Only a Yes applies the mode; No/Esc keeps the current value.
func (m *model) requestPluginHandlerChange(target string) tea.Cmd {
	m.pendingHandlerMode = target
	next := "Hyprland-managed"
	if target == "classic" {
		next = "Classic (float + decorations)"
	}
	m.infoConfirm = tuikit.NewInfoConfirm(
		"Switch the plugin window handler to "+next+"?\n\n"+
			"This rewrites the GLOBAL Hyprland window rules for wine plugin editors. "+
			"It only affects plugin windows opened from now on, and per-plugin fixes override it.",
		"No", "Yes").SetSize(m.contentSize())
	m.push(scrPluginHandlerConfirm)
	return m.enterCmd()
}

// handleAudioSettingsChoice is the Enter path for the unified Settings
// screen: it runs the exact actions the pre-pending code did, unchanged.
func (m model) handleAudioSettingsChoice(v string) (tea.Model, tea.Cmd) {
	switch v {
	case "switch_file_picker":
		if m.status.FilePicker == "superfile" {
			// Turning it off is always safe -- no install to undo.
			return m, setFilePickerAndRefetch("default")
		}
		if m.status.SuperfileInstalled {
			return m, setFilePickerAndRefetch("superfile")
		}
		m.push(scrSuperfileInstallConfirm)
		return m, m.enterCmd()
	case "rescan":
		return m, rescanCmd()
	case "pick_plugins_root":
		m.loading = true
		return m, pickFolderCmd("pick-plugins-root", "Plugins folder", m.status.PluginsRoot)
	case "pick_downloads_dir":
		m.loading = true
		return m, pickFolderCmd("pick-downloads-dir", "Default plugin installation file directory", m.status.DownloadsDir)
	case "toggle_plugin_handler":
		// Flips classic ⇄ hyprland (the plugin editor window manager:
		// "classic" = floating decorated windows, the shape that actually
		// receives interaction on this compositor; "hyprland" = plain
		// toplevels). Broad/global — confirm before applying.
		return m, m.requestPluginHandlerChange(togglePluginHandlerTarget(m.status.PluginWinHandler))
	}
	return m, nil
}

// handleMainChoice -- Plugin list/Install/Uninstall/Launch are common to
// both plugin universes and live directly on the first menu; "install"
// auto-detects the picked file's kind (isWineInstaller in model.go) and
// routes to whichever install flow applies.
func (m model) handleMainChoice(v string) (tea.Model, tea.Cmd) {
	switch v {
	case "list":
		m.push(scrPluginList)
		return m, m.enterCmd()
	case "install":
		if m.status.FilePicker == "superfile" && m.status.SuperfileInstalled {
			return m, pickFileViaSuperfileEmbedded(m.status.DownloadsDir)
		}
		m.loading = true
		return m, fetchPath("pick-file", "pick-any-plugin-file")
	case "uninstall":
		m.push(scrUninstallPick)
		return m, m.enterCmd()
	case "fixes":
		m.push(scrFixPluginPick)
		return m, m.enterCmd()
	case "standalone":
		m.push(scrStandalonePick)
		return m, m.enterCmd()
	case "vst":
		m.push(scrVstMenu)
		return m, m.enterCmd()
	case "cleanup":
		m.confirm = tuikit.NewConfirm(
			"Clean up all plugin log/file inconsistencies?\n\nNon-destructive: missing plugins are kept in the log, untracked files on disk are registered into the log, and dangling menu entries are removed. Nothing is deleted — no real file or log entry is ever removed here.",
			"No", "Yes")
		m.push(scrCleanupConfirm)
		return m, nil
	case "settings":
		m.push(scrSettings)
		return m, m.enterCmd()
	case "quit":
		m.push(scrQuitConfirm)
		return m, m.enterCmd()
	}
	return m, nil
}

// handleVstMenuChoice -- "Windows VST Plugins (Wine)" is Wine/yabridge-specific
// leftovers only: prefix management, executable visibility, and the two
// Hide filters (flat toggle items, no further settings sub-page).
func (m model) handleVstMenuChoice(v string) (tea.Model, tea.Cmd) {
	switch v {
	case "prefixes":
		m.push(scrPrefixMovePluginPick)
		return m, m.enterCmd()
	case "execs":
		m.push(scrExecsToggle)
		return m, m.enterCmd()
	case "toggle_hide_vst2":
		return m, toggleHideVst2AndRefetch()
	case "toggle_hide_32bit":
		return m, toggleHide32BitAndRefetch()
	}
	return m, nil
}
