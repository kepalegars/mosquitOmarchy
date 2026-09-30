package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"sort"
	"strings"

	"github.com/charmbracelet/lipgloss"

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
		m.picker = tuikit.NewPicker("Settings", m.settingsItemsWithPending()).
			SetSize(m.contentSize()).
			SetHelpNote(settingsHelpNote())
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
		return fetchPluginFolders("uninstall")
	case scrInstallPrefixChoice:
		// The standard ask: default prefix first. When the installer matches a
		// plugin the tests know, ALWAYS name the recommended prefix — even when
		// it IS the default (that's the point: the user must see that this
		// installer is a known one and where it is expected to live), and say
		// whether it matches the default so the choice is explicit.
		rec := m.installRecommendedPrefix
		// The two buttons carry the whole answer, and NO "Enter = ... / y = ..."
		// legend line: it was noise, and the two implementations (this dialog
		// and the bash prompt) drifted apart until it lied about what Enter did.
		// tuikit.NewConfirm keeps [No, Yes] in that order and focuses index 0,
		// so Enter would answer "No, new prefix" — the opposite of what the
		// question asks. SetFocus(1) moves the focus to "Yes" so Enter agrees
		// with the question instead of contradicting it.
		const (
			noPrefixLabel = "No, new prefix"
			yesUseLabel   = "Yes, use it"
		)
		switch {
		case knownPluginInstaller(m.installFile) && rec != "":
			def := m.installDefaultPrefix
			extra := "\n\nKnown plugin — RECOMMENDED prefix: " + rec
			if rec == def {
				extra += "\n(this is the default prefix)"
			} else {
				extra += "\n(not the default: " + def + ")"
			}
			m.confirm = tuikit.NewConfirm(
				"Install into the DEFAULT wine prefix?"+extra,
				noPrefixLabel, yesUseLabel).SetFocus(1)
		case knownPluginInstaller(m.installFile):
			m.confirm = tuikit.NewConfirm(
				"Install into the DEFAULT wine prefix?"+
					"\n\nKnown plugin, but no recorded recommendation for this file.",
				noPrefixLabel, yesUseLabel).SetFocus(1)
		default:
			m.confirm = tuikit.NewConfirm(
				"Install into the default wine prefix?",
				noPrefixLabel, "Yes").SetFocus(1)
		}
		return nil
	case scrSuperfileInstallConfirm:
		m.confirm = tuikit.NewConfirm(
			"Superfile isn't installed. Install it now (pacman, official repo — opens a terminal for the sudo password) and switch to it?",
			"No", "Yes, install")
		return nil
	case scrInstallPrefixPick:
		m.loading = true
		return prefixListCmd(m.installFile)
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
		// Cleared with the rest: a stale scope would title the page with the
		// previous plugin's name before the catalog even lands, and a stale
		// target list would let the confirmation name plugins that are no
		// longer in the selection.
		m.fixScope = ""
		m.fixVendorPlugins = nil
		m.fixAppliedBy = nil
		m.fixCandidate = nil
		m.fixPendingApply = nil
		m.fixPendingRemove = nil
		m.fixTouched = nil
		// Drop any remembered collapse state: every category re-seeds
		// expanded on entry (see rebuildFixPicker), so the folders are
		// always visible when the screen opens.
		m.fixFolderExpanded = nil
		// A vendor run asks for the union over that folder's plugins; a
		// single-plugin run asks about that plugin. The same handler takes
		// both, so which one is in play is decided here rather than at every
		// call site.
		if m.fixVendor != "" {
			return fetchFixesForVendorCmd(m.fixVendor)
		}
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
	// Formats is the format list of a STANDALONE row (a plugin with no folder
	// above it). Folder children carry their own on the Item.
	Formats string
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
			Formats: it.Formats,
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
//   - a folder row is "<mark>  <name>" plus PickerItem.Fold, which the kit
//     draws IN the cursor slot (▸ collapsed / ▾ expanded) so the fold state
//     and the selection cursor are one marker, never "▶ ▸ <name>". The mark is
//     ● only
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
			fold := tuikit.FoldCollapsed
			if expanded[n.Value] {
				fold = tuikit.FoldExpanded
			}
			// Folder: the kit draws a folder glyph in the leading slot and
			// bolds the label; the all-or-none checkbox mark becomes a
			// "done/total" count in the trailing slot, so the leading column
			// only ever says what KIND of row this is.
			folder := tuikit.PickerItem{
				Display: n.Display,
				Value:   n.Value,
				Fold:    fold,
				Folder:  true,
			}
			if total := len(n.Plugins); total > 0 {
				folder.Suffix = fmt.Sprintf("  %d/%d", marked, total)
			}
			out = append(out, folder)
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
					row := tuikit.PickerItem{
						Display: "    " + branch + pmark + "  " + p.Display,
						Value:   p.Value,
					}
					// The formats live in the Suffix, not in Display: the
					// label column is shared with the folder rows above, and
					// baking the formats into the text would make the labels
					// ragged. The kit reserves one trailing width for the whole
					// picker, so the rows stay aligned whether or not a plugin
					// is in several formats.
					row.Suffix = p.FormatSuffix()
					out = append(out, row)
				}
			}
		} else {
			mark := "○"
			if checked[n.Value] {
				mark = "●"
			}
			row := tuikit.PickerItem{Display: mark + "  " + n.Display, Value: n.Value}
			row.Suffix = formatSuffix(n.Formats)
			out = append(out, row)
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
	// WithTree: same fold gesture as the Installed-plugins list, and the shared
	// m.folderExpanded, so a folder folded on one screen is folded on the other.
	m.picker = tuikit.NewPicker("Uninstall which plugin(s)?",
		treeItemsToPicker(uninstallTree(m.uninstallCache), m.uninstallChecked, m.folderExpanded)).SetSize(m.contentSize()).
		SetHelpKeys(
			key.NewBinding(key.WithKeys("tab"), key.WithHelp("tab", "select")),
			key.NewBinding(key.WithKeys("s"), key.WithHelp("s", "sort")),
			key.NewBinding(key.WithKeys("x"), key.WithHelp("x", "open folder")),
			key.NewBinding(key.WithKeys("right"), key.WithHelp("→", "expand")),
			key.NewBinding(key.WithKeys("left"), key.WithHelp("←", "collapse")),
			key.NewBinding(key.WithKeys("enter"), key.WithHelp("enter", "uninstall")),
		).WithTree(m.folderExpanded)
	m.picker = m.picker.SelectIndex(sidx)
}

// selectedFolderValueIn and selectedFolderValue used to answer "is the cursor on
// a folder row?" and the uninstall screen keyed its Left/Right gesture off that.
// It was the wrong question: on a sub-plugin row it said no, so ← did nothing
// and closing a folder meant walking the cursor back up to its title first. The
// kit now resolves "the folder the cursor is IN" (tuikit's foldKey), so the
// lookup is gone rather than left behind as a trap for the next caller.

// fixApplyConfirm builds the confirmation shown before a fix is written.
//
// The wording is about FILES, not about checkboxes, because that is what the
// action is: "apply to the FabFilter suite" rewrites a third-party binary once
// per plugin, and the rows it came from are marked in the same ●/○ language as
// a to-do list.
//
// The list is the part that was missing. "to every FabFilter plugin" leaves the
// size of the change unstated, and a vendor suite is nineteen or twenty-one
// products; the dialog names each one and scrolls when they do not all fit.
func (m model) fixApplyConfirm(toApply, toRemove []string) tuikit.Confirm {
	var msg string
	applyLabel, removeLabel := "apply", "remove"
	if len(toApply) == 1 {
		applyLabel = "apply 1 fix"
	} else if len(toApply) > 1 {
		applyLabel = fmt.Sprintf("apply %d fixes", len(toApply))
	}
	if len(toRemove) > 0 {
		if len(toRemove) == 1 {
			removeLabel = "remove 1 fix"
		} else {
			removeLabel = fmt.Sprintf("remove %d fixes", len(toRemove))
		}
	}

	targets := m.fixApplyTargets(toApply)
	switch {
	case m.fixVendor != "" && len(toRemove) > 0:
		msg = fmt.Sprintf("This will %s to the %s suite (%s) and %s from the plugin you picked.",
			applyLabel, m.fixScope, m.countWord(len(targets)), removeLabel)
	case m.fixVendor != "":
		msg = fmt.Sprintf("This will %s to %s of the %s suite. The files are rewritten in place.",
			applyLabel, m.countWord(len(targets)), m.fixScope)
	default:
		what := "1 plugin file"
		if n := fixTargetCount(m, toApply); n > 1 {
			what = fmt.Sprintf("%d plugin files", n)
		}
		msg = fmt.Sprintf("This will %s to %s. The file is rewritten in place.", applyLabel, what)
	}

	yes := applyLabel
	if len(toRemove) > 0 && len(toApply) == 0 {
		yes = removeLabel
	}

	rows := m.fixApplyTargetRows(toApply)
	// Leave room for the question, the buttons, the frame and the scroll hint.
	// The modal is unsized, so the budget comes from the same content box the
	// lists use rather than from the raw terminal height.
	_, ch := m.contentSize()
	maxRows := ch - 14
	if maxRows < 3 {
		maxRows = 3
	}
	title := fmt.Sprintf("plugins concerned (%d)", len(rows))
	return tuikit.NewConfirm(msg, "back", yes).SetList(title, rows, maxRows)
}

// fixApplyTargets is the set of plugin names the pending fixes will reach, in
// vendor order.
//
// It is the union over the checked fixes, and NOT simply the whole selection: a
// product-specific fix (CrispyTuner's tooltip) reaches that product, and listing
// the other twenty would overstate the change. A generic fix reaches the whole
// selection, which is the case worth showing in full.
func (m model) fixApplyTargets(toApply []string) []string {
	seen := map[string]bool{}
	var out []string
	add := func(n string) {
		if n == "" || seen[n] {
			return
		}
		seen[n] = true
		out = append(out, n)
	}
	for _, id := range toApply {
		it, ok := m.fixItemByID(id)
		if !ok {
			continue
		}
		if m.fixIsProductSpecific(it) {
			add(it.Plugin)
			continue
		}
		if m.fixVendor != "" {
			for _, n := range m.fixVendorPlugins {
				add(n)
			}
			continue
		}
		add(pluginStemOf(m.fixPlugin))
	}
	return out
}

// fixApplyTargetRows renders the confirmation list: one row per plugin the
// change reaches, marking the ones a partial fix has not reached yet.
//
// A plain list of names would say the same thing for "these twenty-one already
// carry the fix" and "one of them does, and the other twenty are about to", so
// the ones being reached for the first time are called out. That difference is
// the whole reason a partial fix has its own mark on the row above.
func (m model) fixApplyTargetRows(toApply []string) []string {
	targets := m.fixApplyTargets(toApply)
	if len(targets) == 0 {
		return nil
	}
	already := map[string]bool{}
	for _, id := range toApply {
		for _, n := range m.fixAppliedBy[id] {
			already[n] = true
		}
	}
	rows := make([]string, 0, len(targets))
	for _, n := range targets {
		if already[n] {
			rows = append(rows, fmt.Sprintf("• %s  (already applied)", n))
			continue
		}
		rows = append(rows, "• "+n)
	}
	return rows
}

// fixTargetCount is the number of FILES a single-plugin visit will rewrite: one
// per fix, since each fix is a separate rewrite of the same plugin.
func fixTargetCount(m model, toApply []string) int { return len(toApply) }

func (m model) fixItemByID(id string) (FixItem, bool) {
	for _, it := range m.fixCache {
		if it.ID == id {
			return it, true
		}
	}
	return FixItem{}, false
}

func (m model) fixIsProductSpecific(it FixItem) bool { return it.Plugin != "" }

// fixIsPartial reports whether a fix is on some of the plugins in view and not
// the others, from the counts the vendor merge recorded.
func (m model) fixIsPartial(id string) bool {
	n, ok := m.fixCandidate[id]
	return ok && n > 1 && len(m.fixAppliedBy[id]) > 0 && len(m.fixAppliedBy[id]) < n
}

func (m model) countWord(n int) string {
	if n == 1 {
		return "1 plugin"
	}
	return fmt.Sprintf("%d plugins", n)
}

// pluginItemsAsItems converts the unified Plugin list rows into the generic
// Item shape the uninstall tree is built from, so the setup list can call
// the exact same uninstallTree/treeItemsToPicker grouping the uninstall
// screen uses (Kind="folder" header rows included).
func pluginItemsAsItems(items []PluginItem) []Item {
	out := make([]Item, len(items))
	for i, it := range items {
		// Formats has to travel: the fixes chooser renders the SAME rows as the
		// plugin list, and a plugin shown without its formats is exactly the
		// bare name the user asked to replace.
		out[i] = Item{Display: it.Display, Value: it.Value, Kind: it.Kind, Parent: it.Parent, Formats: it.Formats}
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

// fixIsPluginSpecific reports whether a fix belongs to ONE named product (its
// `plugin` field is set, e.g. "CrispyTuner", "Serum 2"). Those are the fixes
// that get their own "Plugin specific fixes" section, labelled by the plugin
// name alone. A fix with an empty plugin field is generic and stays in the
// shared categories above.
func fixIsPluginSpecific(it FixItem) bool { return it.Plugin != "" }

// The three marks a fix row can carry.
//
// ○ off · ● on · ◐ on for SOME of the plugins in view and not the others.
//
// ◐ is the one that was missing. On a vendor-wide visit a fix is reported per
// plugin and merged, and the merge used to keep only "was it on for any of
// them", so a fix recorded on CrispyTuner and on nothing else in a suite of 21
// drew a plain ●. The user read that as done for the whole suite, re-ran it,
// saw nothing change, and had no way to tell that three quarters of the suite
// was in fact untouched. The left half is filled because that is the literal
// meaning: some of the circle, not all of it.
//
// A row the user has just changed shows the plain mark, because the pending
// intent is what the ●/○ pair is about: ◐ describes the RECORDED state, and
// once you have ticked or unticked a row you have an opinion about it.
func fixMarkOf(it FixItem, checked, orig map[string]bool) string {
	if !checked[it.ID] {
		return "○"
	}
	if orig[it.ID] && it.IsPartial() {
		return "◐"
	}
	return "●"
}

// fixItemsToPicker renders the "Plugin fixes" catalog as a single
// multi-select list. Generic fixes (no specific plugin) come first, grouped by
// their category as a folder: a "<mark>  <Category>" parent row (whose fold
// glyph rides in the cursor slot) followed by
// its fixes indented under it with a file-tree angle. Toggling the parent
// flips every fix in that category; individual fixes toggle on their own.
// Uses the app-wide ○/● circle convention and global fixes are tagged so it is
// obvious they are not plugin-scoped.
//
// Plugin-specific fixes (scoped to one product) are collected at the BOTTOM,
// under a horizontal separator and a "Plugin specific fixes" title, each
// product forming its own group labelled with the plugin name alone. This
// keeps the shared fixes up top and the product-specific ones clearly set
// apart, instead of interleaving categories like "CrispyTuner specific" among
// the generic ones. A product-specific fix is NEVER hidden: it stays visible
// and selectable for every plugin, since the same Wine issues can show up
// elsewhere. The folder row's chevron/child-visibility follows expanded
// exactly as treeItemsToPicker does for the other two screens.
func fixItemsToPicker(items []FixItem, checked, orig map[string]bool, expanded map[string]bool) []tuikit.PickerItem {
	// Split once: generic = no specific plugin, specific = scoped to a product.
	var generic, specific []FixItem
	for _, it := range items {
		if fixIsPluginSpecific(it) {
			specific = append(specific, it)
		} else {
			generic = append(generic, it)
		}
	}

	out := []tuikit.PickerItem{}
	// The rule is sized to the widest row on the page (a fix title plus its
	// tags, at its indented child position) so it closes the section instead of
	// stopping in the middle of it. A fixed 28-column rule was narrower than
	// most fix titles, which read as a rule that had been cut short.
	sep := fixSeparator(items)
	if len(generic) > 0 {
		out = append(out, tuikit.PickerItem{Display: fixGenericTitle(), Value: fixGenericTitleValue, Accent: true, Heading: true})
	}
	out = append(out, fixCategoryGroup(generic, checked, orig, expanded, false)...)

	// The product-specific section, if any.
	if len(specific) > 0 {
		// Horizontal rule between the two sections, non-selectable.
		out = append(out, tuikit.PickerItem{Display: sep, Value: fixSeparatorValue, Disabled: true, Heading: true})
		// Section title in the theme's accent colour, and NOT selectable: the
		// cursor must step over it. It used to be a plain Accent row, so the
		// cursor parked on a heading and Enter did nothing there.
		out = append(out, tuikit.PickerItem{Display: fixSpecificTitle(), Value: fixSpecificTitleValue, Accent: true, Heading: true})
		// Grouped by PLUGIN NAME (not the catalog category), so the header
		// reads just "CrispyTuner" / "Serum 2" — the product it belongs to.
		out = append(out, fixCategoryGroup(specific, checked, orig, expanded, true)...)
	}
	return out
}

// Values for the non-selectable section rows. They can never collide with a
// fix id ([a-z_]+) nor with a category header ("__fixcat__:" prefix).
const (
	fixSeparatorValue     = "__fixsep__"
	fixSpecificTitleValue = "__fixspectitle__"
	fixGenericTitleValue  = "__fixgenerictitle__"
)

// childIndent is the prefix a fix row carries when it sits inside a category
// folder ("    └─ "). The separator is measured with it, so the rule lines up
// with the text it is meant to close.
const childIndent = "    └─ "

// fixSeparator is a horizontal rule spanning the widest fix row on the page.
// It uses the same glyph family as the file-tree angles so it reads as part of
// the list. Falls back to a short rule when the catalog is empty, so a
// degenerate screen still renders something.
func fixSeparator(items []FixItem) string {
	width := 0
	for _, it := range items {
		if w := lipgloss.Width(childIndent + it.Title + fixRowTags(it)); w > width {
			width = w
		}
	}
	if width < 8 {
		width = 28
	}
	return strings.Repeat("─", width)
}

// fixGenericTitle heads the fixes that are not scoped to one product.
//
// "Applies to any plugin" is the wording, and it is chosen over the obvious
// "Global fixes" on purpose: these fixes are still applied PER PLUGIN (you
// tick them for a plugin, and a fix that opens its editor window is written
// per plugin), so calling them global would be a different and wrong claim —
// only the cursor one is actually global, and it already says so with its
// [global] tag. The heading answers the question the two sections are split on:
// does this fix need a product, or does it work on any?
func fixGenericTitle() string { return "Applies to any plugin" }

// fixSpecificTitle is the heading for the product-specific section.
func fixSpecificTitle() string { return "Plugin specific fixes" }

// fixCategoryGroup renders a set of fix items as expandable categories
// (folder header + indented children), preserving the input order. When
// groupByPlugin is true the folder label is the fix's product (its `plugin`
// field) instead of its catalog category, so the product-specific section is
// headed by the plugin name alone. It is the shared body used for both the
// generic group and the product-specific group.
func fixCategoryGroup(items []FixItem, checked, orig map[string]bool, expanded map[string]bool, groupByPlugin bool) []tuikit.PickerItem {
	// keyFor is the group a fix belongs to: the plugin name in the specific
	// section, the catalog category otherwise.
	keyFor := func(it FixItem) string { return fixCategoryOf(it) }
	if groupByPlugin {
		keyFor = func(it FixItem) string { return it.Plugin }
	}
	hasCategory := false
	for _, it := range items {
		if fixCategoryOf(it) != "" || it.Category != "" {
			hasCategory = true
			break
		}
	}
	out := []tuikit.PickerItem{}
	if !hasCategory {
		// No categories in the catalog: a clean flat list, same as before.
		for _, it := range items {
			out = append(out, tuikit.PickerItem{Display: fixMarkOf(it, checked, orig) + "  " + it.Title + fixRowTags(it), Value: it.ID})
		}
		return out
	}
	seen := map[string]bool{}
	lastOf := map[string]int{}
	for i, it := range items {
		lastOf[keyFor(it)] = i
	}
	for i, it := range items {
		cat := keyFor(it)
		if !seen[cat] {
			seen[cat] = true
			fold := tuikit.FoldCollapsed
			if expanded[cat] {
				fold = tuikit.FoldExpanded
			}
			// Folder (not Badge): the row is a container, so the kit draws a
			// folder glyph instead of the ○/● checkbox and bolds the label.
			// The all-or-none mark moves to the TRAILING slot as "done/total",
			// so nothing is lost and the leading column now says only "what
			// kind of row is this".
			entry := tuikit.PickerItem{
				Display: cat,
				Value:   fixCategoryValuePrefix + cat,
				Fold:    fold,
				Folder:  true,
			}
			done, total := 0, 0
			for _, other := range items {
				if keyFor(other) != cat {
					continue
				}
				total++
				if checked[other.ID] {
					done++
				}
			}
			if total > 0 {
				entry.Suffix = fmt.Sprintf("  %d/%d", done, total)
			}
			out = append(out, entry)
		}
		// Children render only while the category is expanded.
		if !expanded[cat] {
			continue
		}
		mark := fixMarkOf(it, checked, orig)
		// File-tree angle so the fix is visibly a child of its category. The
		// mark goes in Badge, NOT in the label: the kit already owns a fixed
		// badge column, so baking it in gave every child a different width and
		// therefore a different starting column from its category.
		branch := "├─ "
		if lastOf[cat] == i {
			branch = "└─ "
		}
		out = append(out, tuikit.PickerItem{
			Display: "    " + branch + it.Title + fixRowTags(it),
			Badge:   mark,
			Value:   it.ID,
		})
	}
	return out
}

// fixRowTags is the trailing tag block on a fix row. "[global]" marks a
// desktop-wide fix; "[VST2]"/"[VST3]" mark a fix that applies to ONE plugin
// format only. An "any" fix gets NO tag on purpose: it covers the product's
// VST2 and VST3 at once, which is the normal case and needs no explaining —
// tagging every row "VST2+VST3" would be noise. A fix that narrows the format
// says so, because silently not touching the other format is exactly the kind
// of thing that looks like a bug.
func fixRowTags(it FixItem) string {
	var tags string
	if it.Scope == "global" {
		tags += "  [global]"
	}
	switch it.Vst {
	case "vst2":
		tags += "  [VST2 only]"
	case "vst3":
		tags += "  [VST3 only]"
	}
	return tags
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
	// Any deliberate change to a fix row marks it touched, so a partial fix the
	// user re-ticks counts as "complete this one" rather than staying invisible
	// to the delta.
	if m.fixTouched == nil {
		m.fixTouched = map[string]bool{}
	}
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
				m.fixTouched[it.ID] = true
			}
		}
		return
	}
	m.fixChecked[value] = !m.fixChecked[value]
	m.fixTouched[value] = true
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
		// BOTH keys must be pre-expanded, and they are different strings:
		// fixCategoryOf(it) is the catalog category the generic groups are
		// keyed by, while a plugin-specific fix is grouped by its `Plugin`
		// name ("CrispyTuner"). Registering only the category is what left
		// the "Plugin specific fixes" section stuck COLLAPSED — its headers
		// were keys nothing had ever expanded, so the section rendered as a
		// title followed by nothing.
		for _, k := range []string{fixCategoryOf(it), it.Plugin} {
			if k == "" {
				continue
			}
			if _, ok := m.fixFolderExpanded[k]; !ok {
				m.fixFolderExpanded[k] = true
			}
		}
	}
	// The header names what the fixes are ABOUT, not the picker value: a value
	// is "vst:<type>:<full/path>" and the title used to print all of it, which
	// both overflowed the panel and repeated what the list below already says.
	//
	// m.fixScope is that noun, resolved once when the catalog lands: the plugin
	// stem for a single-plugin visit, the suite for a whole-vendor one. It used
	// to be recomputed as pluginStemOf(m.fixPlugin) here, which is EMPTY on a
	// vendor visit, so the title ended on a dangling "for ".
	// The header is empty on purpose: the screen TITLE carries the question
	// (see the view), and it used to be repeated here with the wrong noun.
	header := ""
	sidx := m.picker.Index()
	m.picker = tuikit.NewPicker(header,
		fixItemsToPicker(sortedFixItems(m.fixCache, m.fixSortDesc), m.fixChecked, m.fixOrig, m.fixFolderExpanded)).
		SetSize(m.contentSize()).
		SetHelpKeys(
			key.NewBinding(key.WithKeys("tab", "x"), key.WithHelp("tab/x", "toggle")),
			key.NewBinding(key.WithKeys("i"), key.WithHelp("i", "info")),
			key.NewBinding(key.WithKeys("s"), key.WithHelp("s", "sort")),
			key.NewBinding(key.WithKeys("right"), key.WithHelp("→", "expand")),
			key.NewBinding(key.WithKeys("left"), key.WithHelp("←", "collapse")),
			key.NewBinding(key.WithKeys("enter"), key.WithHelp("enter", "apply")),
		).WithTree(m.fixFolderExpanded)
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
	// NOTHING is force-opened any more.
	//
	// A folder holding an already-applied fix used to open itself on sight, so
	// its marker would not be hidden behind a closed folder. The user asked for
	// every folder COLLAPSED when arriving at a page of folders, and an
	// auto-opened folder defeats that: the page came in already unfolded and the
	// reason was invisible. The marker is carried on the FOLDER ROW itself
	// instead (below), so a closed folder still says it holds a fixed plugin
	// and there is nothing to reveal.
	//
	// folderFoldedByUser is kept: a folder the user opened stays open across
	// rebuilds, and one they closed stays closed.
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
				// A CLOSED folder still has to say it holds a fixed plugin —
				// that is the whole reason the auto-open existed. Computing it
				// from the tree rather than from the old appliedFolders map
				// keeps the badge while the folder stays shut, so the page can
				// arrive fully collapsed without losing the information that
				// used to require unfolding it.
				if folderHoldsAppliedFix(tree, items[i].Value, m.fixAppliedPlugins) {
					items[i].TrailingBadge = fixAppliedBadge
				}
				continue
			}
			if m.fixAppliedPlugins[pluginStemOf(items[i].Value)] {
				items[i].TrailingBadge = fixAppliedBadge
			}
		}
	}
	// The screen says what the fixes are ABOUT. When a vendor is in play the
	// whole suite is being fixed, and a title naming a single plugin would
	// understate what Enter is about to do.
	title := "Plugin fixes — which plugin?"
	if m.fixVendor != "" {
		title = "Plugin fixes — every " + m.fixVendor + " plugin"
	}
	sidx := m.picker.Index()
	m.picker = tuikit.NewPicker(title, items).
		SetSize(m.contentSize()).
		SetHelpKeys(
			key.NewBinding(key.WithKeys("i"), key.WithHelp("i", "info")),
			key.NewBinding(key.WithKeys("s"), key.WithHelp("s", "sort")),
			key.NewBinding(key.WithKeys("right"), key.WithHelp("→", "expand")),
			key.NewBinding(key.WithKeys("left"), key.WithHelp("←", "collapse")),
			key.NewBinding(key.WithKeys("enter"), key.WithHelp("enter", "choose")),
		).WithTree(m.folderExpanded)
	m.picker = m.picker.SelectIndex(sidx)
}

// vendorOfFolder maps a folder row's value ("vendor:<name>") back to the vendor
// name, or "" when the row is not a vendor folder.
func vendorOfFolder(items []PluginItem, folderValue string) string {
	if v, ok := strings.CutPrefix(folderValue, "vendor:"); ok {
		return v
	}
	// A wine install folder ("win:/path") has no vendor name; look its children
	// up so a folder row still resolves to something the backend can act on.
	for _, it := range items {
		if it.Kind == "plugin" && it.Parent == folderValue && it.Vendor != "" {
			return it.Vendor
		}
	}
	return ""
}

// folderHoldsAppliedFix reports whether any plugin under this folder row
// already carries an applied fix.
//
// Computed from the items the picker is actually showing, because that is what
// the folder's children are: a folder is expanded or collapsed in this very
// list, and a badge that had to consult a separately-built map was one more
// thing that could disagree with what is on screen.
func folderHoldsAppliedFix(tree []uninstallTreeItem, folderValue string, applied map[string]bool) bool {
	if len(applied) == 0 {
		return false
	}
	// Read from the TREE, not from the rendered items. The point of this badge
	// is to say something about a folder whose children are NOT on screen — a
	// collapsed folder is exactly the case it exists for, and looking in the
	// rendered list can only ever find the children of an OPEN folder.
	for _, n := range tree {
		if !n.Folder || n.Value != folderValue {
			continue
		}
		for _, p := range n.Plugins {
			if applied[pluginStemOf(p.Value)] {
				return true
			}
		}
	}
	return false
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
	// WithTree: ←/→ are the fold gesture here (they are not sort keys on this
	// screen any more — the sort cycle moved to `s`), resolved by the kit from
	// the folder the CURSOR IS IN.
	m.picker = tuikit.NewPicker(header, items).SetSize(m.contentSize()).SetHelpKeys(pluginListHelpKeys()...).WithTree(m.folderExpanded)
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
				// "See log" — open the FULL run log in the universal Info
				// screen (same bounded, wrapping, scrollable, framed log view
				// mosquitomarchy uses). The runner is dropped from the stack
				// too, so a single ESC returns DIRECTLY to the main menu
				// (no "old log" frame lingering on top).
				m.info = tuikit.NewInfo(m.runner.Output()).
					SetSize(m.contentSize())
				m.pop() // dismiss the confirm
				m.pop() // drop the runner screen
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
		if fm, ok := msg.(tuikit.TreeFoldMsg); ok {
			// The kit owns the gesture now: it resolved "the folder the cursor
			// is in", flipped the shared map and named the row to land on. All
			// this screen owes it is a repaint.
			m.rebuildPluginPicker()
			m.picker = m.picker.SelectValue(fm.Cursor)
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
		if km, ok := msg.(tea.KeyMsg); ok && km.String() == "i" {
			// 'i' = what this screen is for (mosquitomarchy-style info).
			m.info = tuikit.NewInfo(
				"Plugin fixes — pick which plugin the fixes target.\n\n" +
					"The next screen lists the available fixes (window/input handling, " +
					"cursor warping…) with a plain-language description; press i there " +
					"to read what a given fix does before applying it.\n\n" +
					"Fixes are per-plugin and reversible: re-open this screen and untick " +
					"them, or use 'Cleanup inconsistencies' in Settings.").SetSize(m.contentSize())
			m.push(scrInfo)
			return m, nil
		}
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
		if fm, ok := msg.(tuikit.TreeFoldMsg); ok {
			// Same gesture as every other folder list, from the kit.
			//
			// The one thing that stays here is folderFoldedByUser: a folder the
			// user has folded by hand must not be auto-reopened by the "reveal
			// the applied fixes" rule on the next rebuild.
			if m.folderFoldedByUser == nil {
				m.folderFoldedByUser = map[string]bool{}
			}
			m.folderFoldedByUser[fm.Folder] = true
			m.rebuildFixPluginPicker()
			m.picker = m.picker.SelectValue(fm.Cursor)
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
				// ENTER ON A VENDOR = FIX THE WHOLE VENDOR.
				//
				// The folder row used to only fold/unfold, which made it
				// impossible to reach a fix without picking a single plugin
				// first. The user installs suites: FabFilter is nineteen
				// plugins, and the useful action is "fix them all", not "fix
				// whichever one I happen to have expanded".
				//
				// The catalog shown next is the union over the vendor, so what
				// is offered is what will actually be applied.
				if vendor := vendorOfFolder(m.fixPluginCache, res.Value); vendor != "" {
					m.fixVendor = vendor
					m.fixPlugin = ""
					m.fixChecked = map[string]bool{}
					m.fixOrig = map[string]bool{}
					// push, not a whole new stack: replacing nav put
					// scrFixPluginPick at the bottom, and pop() is a no-op at
					// depth 1, so Esc on this screen could never leave the
					// plugin-fixes page. It looked stuck. The single-plugin path
					// has always pushed, which is why only the vendor route
					// trapped you.
					m.push(scrFixChoose)
					m.loading = true
					return m, fetchFixesForVendorCmd(vendor)
				}
				if m.folderExpanded == nil {
					m.folderExpanded = map[string]bool{}
				}
				if m.folderFoldedByUser == nil {
					m.folderFoldedByUser = map[string]bool{}
				}
				m.folderFoldedByUser[res.Value] = true
				if m.folderExpanded[res.Value] {
					m.folderExpanded[res.Value] = false
				} else {
					m.folderExpanded[res.Value] = true
				}
				m.rebuildFixPluginPicker()
				return m, nil
			}
			m.fixPlugin = res.Value
			// Choosing a plugin by hand is a per-plugin request. Clearing the
			// vendor matters: the post-install flow sets it, and without this
			// the NEXT hand-picked plugin would silently keep fixing the whole
			// suite that was installed a moment earlier.
			m.fixVendor = ""
			m.push(scrFixChoose)
			return m, m.enterCmd()
		}
		var cmd tea.Cmd
		m.picker, cmd = m.picker.Update(msg)
		return m, cmd

	case scrFixChoose:
		if km, ok := msg.(tea.KeyMsg); ok && km.String() == "i" {
			// 'i' = info for the fix under the cursor, exactly like the
			// mosquitomarchy 'i': title + full description + scope.
			if v := m.picker.SelectedValue(); v != "" && !strings.HasPrefix(v, fixCategoryValuePrefix) {
				for _, it := range m.fixCache {
					if it.ID != v {
						continue
					}
					txt := it.Title
					if it.Description != "" {
						txt += "\n\n" + it.Description
					}
					txt += "\n\nscope: " + it.Scope
					if it.Category != "" {
						txt += "   ·   category: " + it.Category
					}
					// Say which formats the fix covers: "any" reaches the
					// product's VST2 and VST3 together, so the user does not
					// have to apply it twice wondering why the other format
					// is missing.
					switch it.Vst {
					case "vst2":
						txt += "\n\napplies to: VST2 only"
					case "vst3":
						txt += "\n\napplies to: VST3 only"
					default:
						txt += "\n\napplies to: this product's VST2 and VST3 (one fix covers both)"
					}
					if it.Applied {
						txt += "\n\nalready APPLIED for this plugin"
					}
					m.info = tuikit.NewInfo(txt).SetSize(m.contentSize())
					m.push(scrInfo)
					return m, nil
				}
			}
			return m, nil
		}
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
			m.fixVendorPlugins = fm.vendorPlugins
			// The scope is the noun the page is about, and it is what the title
			// names: a single-plugin visit says the plugin, a whole-suite one
			// says the suite. It used to always print pluginStemOf(fixPlugin),
			// which for a vendor visit is the empty string, so the title ended
			// with a dangling "for ".
			if fm.vendor != "" {
				m.fixScope = fm.vendor
			} else {
				m.fixScope = pluginStemOf(m.fixPlugin)
			}
			m.fixAppliedBy = map[string][]string{}
			m.fixCandidate = map[string]int{}
			for _, it := range fm.items {
				m.fixAppliedBy[it.ID] = it.AppliedTo
				m.fixCandidate[it.ID] = it.Candidates
			}
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
		if fm, ok := msg.(tuikit.TreeFoldMsg); ok {
			// LEFT/RIGHT collapse/expand the category (Right = expand,
			// Left = collapse), same gesture and chevron as the other folder
			// lists, and now resolved by the kit from the row the cursor is in
			// rather than from a value prefix. Toggling the header still
			// checks/unchecks the whole category whatever its expanded state.
			m.rebuildFixPicker()
			m.picker = m.picker.SelectValue(fm.Cursor)
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
				// A PARTIAL fix counts as pending even though its mark already
				// read as "on".
				//
				// This is the row the half circle exists for: it is on some of
				// the plugins in view and not the others, so leaving it ticked
				// and confirming is a decision to COMPLETE it. The delta used
				// to be `v && !orig`, which saw no change here — the fix was on,
				// the mark was on, Enter answered "no change" and wrote nothing.
				// So the one row whose whole reason for existing is that it is
				// unfinished was the one row that could never be acted on, and
				// no confirmation ever appeared for it.
				//
				// Untouched rows stay out of it, or every Enter would re-offer to
				// complete every partial fix on the page. m.fixTouched records
				// that the user actually made a decision about the row.
				pending := v && (!m.fixOrig[id] || (m.fixTouched[id] && m.fixIsPartial(id)))
				if pending {
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
			// Confirm BEFORE anything is written.
			//
			// This is the last moment the user can see the blast radius. On a
			// vendor visit "apply" rewrites a third-party binary once per plugin
			// in the suite, and the fixes are marked in the same ●/○ language
			// as a checkbox, which makes the action look like ticking a box
			// rather than like editing twenty-one files. The dialog names the
			// plugins, and it scrolls when there are more of them than fit.
			m.fixPendingApply = toApply
			m.fixPendingRemove = toRemove
			m.confirm = m.fixApplyConfirm(toApply, toRemove)
			m.push(scrFixApplyConfirm)
			return m, nil
		}
		var cmd tea.Cmd
		m.picker, cmd = m.picker.Update(msg)
		return m, cmd

	case scrFixApplyConfirm:
		if res, ok := msg.(tuikit.ConfirmResultMsg); ok {
			m.pop()
			if res.Canceled || !res.Yes {
				// Nothing was written. The marks stay as the user left them, so
				// they can adjust and come straight back.
				return m, nil
			}
			m.loading = true
			toApply, toRemove := m.fixPendingApply, m.fixPendingRemove
			// A vendor-wide run: the fixes go to every plugin of the folder,
			// which is the whole point of asking about the suite. Removal stays
			// per-plugin — there is no safe way to un-apply a fix from a vendor
			// the user did not ask to touch.
			if m.fixVendor != "" && len(toApply) > 0 {
				return m, syncVendorFixesCmd(m.fixVendor, toApply)
			}
			return m, syncFixesCmd(m.fixPlugin, toApply, toRemove)
		}
		var cmd tea.Cmd
		m.confirm, cmd = m.confirm.Update(msg)
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
			// One row is one PLUGIN, and the action is about the plugin: the
			// rows are per-plugin with their formats listed, so ticking
			// "FabFilter Pro-Q" has to act on its vst2, vst3 and clap copies.
			// Expanding here is what stops the list from quietly hiding one
			// format and leaving the other two in the DAW — the old behaviour
			// was a row per file, so a "plugin" was a single file by accident.
			byValue := map[string]PluginItem{}
			for _, it := range m.pluginCache {
				byValue[it.Value] = it
			}
			var toToggle []string
			for k, v := range m.pluginChecked {
				if m.pluginOrig[k] == v {
					continue
				}
				if it, ok := byValue[k]; ok {
					toToggle = append(toToggle, it.AllValues()...)
					continue
				}
				toToggle = append(toToggle, k)
			}
			m.pop() // leave the confirm -- plugin list is on top again
			m.loading = true
			return m, saveHiddenChangesCmd(toToggle)
		}
		var cmd tea.Cmd
		m.confirm, cmd = m.confirm.Update(msg)
		return m, cmd

	case scrInfo:
		if _, ok := msg.(tuikit.InfoCopiedMsg); ok {
			// `c` on an Info (a log, a fix description): the copy itself is
			// silent, so say whether it worked.
			c := msg.(tuikit.InfoCopiedMsg)
			if c.Err != nil {
				m.toast, _ = m.toast.SetErr("copy failed: " + c.Err.Error())
			} else {
				m.toast, _ = m.toast.SetOK(fmt.Sprintf("copied to the clipboard (%d bytes)", c.Bytes))
			}
			return m, nil
		}
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
				// "remove everywhere": both reconcile prompts are popped
				// NOW (they no longer describe reality), the keys are
				// cleared, and the remove-missing result is reported as a
				// toast — the generic actionOKMsg would pop only one screen
				// and leave the "add to log / remove everywhere" prompt on
				// screen forever even after a successful removal.
				what := fmt.Sprintf("removed everywhere: %d plugin(s)", len(m.missingKeys))
				keys := m.missingKeys
				m.missingKeys = nil
				m.pop() // leave this second confirm
				m.pop() // leave the first "add to log" prompt
				return m, removeMissingCmd(what, keys)
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

	case scrQuarantineClearConfirm:
		if res, ok := msg.(tuikit.ConfirmResultMsg); ok {
			m.pop()
			if res.Canceled || !res.Yes {
				return m, m.enterCmd()
			}
			return m, quarantineClearCmd()
		}
		var cmd tea.Cmd
		m.confirm, cmd = m.confirm.Update(msg)
		return m, cmd

	case scrQuarantineClearDone:
		// The install-style end-of-empty prompt: "See log" opens the full
		// run + per-folder report in the universal Info screen; "OK" heads
		// back to the main menu.
		if res, ok := msg.(tuikit.ConfirmResultMsg); ok {
			if res.Canceled || !res.Yes {
				m.info = tuikit.NewInfo(m.quarantineDetail).
					SetSize(m.contentSize())
				m.pop() // leave the result prompt
				m.push(scrInfo)
				return m, nil
			}
			m.pop()
			m.nav = []screen{scrMain}
			return m, m.enterCmd()
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
		if fm, ok := msg.(tuikit.TreeFoldMsg); ok {
			// LEFT/RIGHT open/close the folder the cursor is in (Right = reveal
			// sub-plugins, Left = hide them again), the same gesture as the
			// Installed-plugins list.
			//
			// This screen used to look the folder up with selectedFolderValue(),
			// which matched ONLY a row that was itself a folder row. ← on a
			// sub-plugin therefore found nothing and did nothing at all, so
			// closing a folder meant putting the cursor back on its title first.
			m.rebuildUninstallPicker()
			m.picker = m.picker.SelectValue(fm.Cursor)
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
				m.fixVendor = m.installFixVendor
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
	case "toggle_auto_fix":
		// Each switch is written on its own and the PAIR is read back, so the
		// row shows what the file now says rather than what we asked for — the
		// two are independent settings and must not drift together.
		return m, setFixPrefCmd("AUTO_FIX", !m.status.AutoFixOn)
	case "toggle_fix_prompt":
		return m, setFixPrefCmd("FIX_PROMPT", !m.status.FixPromptOn)
	case "adopt_plugins":
		// "Track the plugins already installed" — the one-shot answer to a
		// machine that already had plugins before the manager did. It does the
		// WHOLE set in a single pass, which is the only shape a person can act
		// on: the orphan screen asked for a tick per FILE, so a suite installed
		// outside the manager came back on EVERY launch, 50 rows for 23
		// plugins. After this the log knows the machine and the sweep at
		// startup has nothing left to reconcile.
		m.loading = true
		return m, adoptPluginsCmd()
	case "rescan":
		return m, rescanCmd()
	case "pick_plugins_root":
		m.loading = true
		return m, pickFolderCmd("pick-plugins-root", "Plugins folder", m.status.PluginsRoot)
	case "pick_downloads_dir":
		m.loading = true
		return m, pickFolderCmd("pick-downloads-dir", "Default plugin installation file directory", m.status.DownloadsDir)
	case "toggle_wine_runtime":
		rt := ""
		if o, err := runQuick("get-wine-runtime"); err == nil {
			var v struct {
				Runtime string `json:"runtime"`
			}
			_ = json.Unmarshal(bytes.TrimSpace(o), &v)
			rt = v.Runtime
		}
		next := "ableton"
		if rt == "ableton" {
			next = "system"
		}
		_, _ = runQuick("set-wine-runtime", next)
		return m, m.enterCmd()
	case "toggle_plugin_handler":
		// Flips classic ⇄ hyprland (the plugin editor window manager:
		// "classic" = floating decorated windows, the shape that actually
		// receives interaction on this compositor; "hyprland" = plain
		// toplevels). Broad/global — confirm before applying.
		return m, m.requestPluginHandlerChange(togglePluginHandlerTarget(m.status.PluginWinHandler))
	case "cleanup":
		// The row lives here too (settings screen); mirror the main-menu
		// confirm-then-run flow.
		m.confirm = tuikit.NewConfirm(
			"Clean up all plugin log/file inconsistencies?\n\nNon-destructive: missing plugins are kept in the log, untracked files on disk are registered into the log, and dangling menu entries are removed. Nothing is deleted — no real file or log entry is ever removed here.",
			"No", "Yes")
		m.push(scrCleanupConfirm)
		return m, nil
	case "empty_quarantine":
		// Permanently delete everything parked by past uninstalls — the
		// one case where the manager really deletes files, so an explicit
		// double confirmation spells out that this cannot be undone.
		// The row is normally greyed out and unreachable when the quarantine
		// is empty; this guard covers the remaining paths into it (a stale
		// status, an action chosen from a search) and answers with the
		// "nothing to delete" message instead of a confirmation that would
		// delete nothing.
		if m.status.QuarantineEntries == 0 {
			m.toast, _ = m.toast.SetOK("Quarantine is already empty — nothing to delete")
			return m, nil
		}
		m.confirm = tuikit.NewConfirm(
			fmt.Sprintf("Permanently DELETE everything the quarantine holds?\n\n%d parked entr(y/ies) (~/.cache/vst-quarantine and ~/.cache/audio-plugin-manager-quarantine/) are gone for good — this cannot be undone. Open a file manager on either path to browse them manually first if you want to keep anything.", m.status.QuarantineEntries),
			"No, keep them", "Yes, delete all")
		m.push(scrQuarantineClearConfirm)
		return m, nil
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

// wineRuntimeLabel resolves the current APM wine runtime choice and builds
// the Settings row: the ABLETON runtime is RECOMMENDED (its wine-d2d1-nspa
// build implements Windows DirectComposition, which stock wine-staging
// lacks — serum-style VST3 editors crash there).
func wineRuntimeLabel() string {
	out, err := runQuick("get-wine-runtime")
	if err != nil || len(bytes.TrimSpace(out)) == 0 {
		return "ableton (recommended)"
	}
	var v struct {
		Runtime string `json:"runtime"`
	}
	if err := json.Unmarshal(bytes.TrimSpace(out), &v); err != nil {
		return "ableton (recommended)"
	}
	if v.Runtime == "system" {
		return "system wine-staging"
	}
	return "ableton (recommended)"
}

// knownPluginInstaller reports whether the picked installer matches a plugin
// whose tests are RECORDED (the registry in PLUGIN-TESTS.md — serum 2, the
// sonible/smart chain ranges, crispy tuner…); recommended_prefix comes from
// the same table.
func knownPluginInstaller(path string) bool {
	out, err := runQuick("is-known-plugin", path)
	return err == nil && len(bytes.TrimSpace(out)) > 0
}

func recommendedPrefixCmd(path string) tea.Cmd {
	return func() tea.Msg {
		out, err := runQuick("recommended-prefix", path)
		if err != nil {
			return recommendedPrefixMsg{err: err}
		}
		var v struct {
			Prefix string `json:"prefix"`
		}
		if e := json.Unmarshal(bytes.TrimSpace(out), &v); e != nil {
			return recommendedPrefixMsg{err: e}
		}
		return recommendedPrefixMsg{prefix: v.Prefix}
	}
}

type recommendedPrefixMsg struct {
	prefix string
	err    error
}
