package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	tuikit "mosquitomarchy.local/tui-kit"
)

// settingsDwell is how long a Left/Right-adjusted settings value is shown as
// "pending" before it is applied automatically. Every fresh Left/Right
// restarts the clock (see settingsDwellMsg/cycleLoadedSetting).
const settingsDwell = 800 * time.Millisecond

// settingsDwellMsg fires when a pending settings value has been left alone
// for settingsDwell. row identifies the row and seq guards against stale
// timers: every Left/Right bumps settingsDwellSeq, so an older tick whose
// seq no longer matches is ignored.
type settingsDwellMsg struct {
	row string
	seq int
}

// isWineInstaller reports whether a picked file is a Windows installer
// (exe/msi, routed through the existing wine-prefix wizard) as opposed to
// a native plugin file or archive (lv2/clap/vst3/zip/tar/tar.gz/tgz) --
// everything not exe/msi is treated as native and handed to the bash side,
// which does the real format validation.
func isWineInstaller(path string) bool {
	lower := strings.ToLower(path)
	return strings.HasSuffix(lower, ".exe") || strings.HasSuffix(lower, ".msi")
}

// missingPrompt is the shared "in the log but NOT on this computer" message —
// it names exactly the two decisions the screen offers (add to log / remove
// everywhere), so the buttons always correlate with what's displayed.
func missingPrompt(labels []string) string {
	var b strings.Builder
	b.WriteString("Listed in the log but NOT on this computer:\n")
	for _, l := range labels {
		b.WriteString("  • " + l + "\n")
	}
	b.WriteString("\nAdd them back to the shared log (keep them listed), or remove them everywhere?")
	return b.String()
}

type screen int

const (
	scrMain screen = iota
	scrSettings
	scrVstMenu
	scrPluginList // unified: VST + native together
	scrPluginListSaveConfirm
	scrInfo
	scrUninstallPick // unified, Tab multi-select
	scrUninstallConfirm
	scrUninstalling
	scrInstallPrefixChoice
	scrInstallPrefixPick
	scrInstallPrefixName
	scrInstalling
	scrPrefixMovePluginPick
	scrPrefixMoveTargetPick
	scrPrefixMoveTargetName
	scrPrefixMoveConfirm
	scrMoving
	scrStandalonePick
	scrExecsToggle
	scrSuperfileInstallConfirm
	scrSuperfileInstalling
	scrQuitConfirm
	scrReconcileMissingInfo
	scrReconcileMissingRemove
	scrReconcileOrphansTick
	scrCleanupConfirm
	scrPluginsRootConfirm   // "move every plugin to X?" before migrating
	scrPluginsRootMigrating // runner: migrate_plugins_root in progress
	scrRunnerSuccessConfirm // "See log / OK" result prompt after install/uninstall/move/migrate (success OR failure wording)
	scrFixPluginPick        // "Plugin fixes": pick the plugin first
	scrFixChoose            // then Tab-select the fixes to apply/remove
	scrInstallFixesConfirm  // after a successful install: "Apply fixes for <plugin> now?"
	scrPluginHandlerConfirm // confirm a plugin-window-handler change (global Hyprland rules)

	scrWizardRoot // first-launch wizard: choose/confirm the plugins folder
	scrWizardDaw  // then stream the "point every installed DAW at it" report
)

type model struct {
	w, h int
	nav  []screen

	status  Status
	loading bool

	picker  tuikit.Picker
	confirm tuikit.Confirm
	input   tuikit.TextInput
	info    tuikit.Info
	// infoConfirm is the framed confirm used for the plugin-window-handler
	// change: same Readme/Info frame as m.info, but with Yes/No semantics.
	infoConfirm tuikit.InfoConfirm
	runner      tuikit.Runner
	toast       tuikit.Toast

	// flow state, threaded across the install / uninstall / prefix-move
	// wizards
	installFile   string
	installPrefix string
	installNew    bool
	moveKey       string
	moveFrom      string
	moveTo        string
	moveNew       bool

	// unified Plugin list (scrPluginList): pluginCache is the last fetched
	// row set, pluginChecked is the in-progress hide/show mark per row
	// value (Tab), pluginOrig is the server-reported baseline it's diffed
	// against on save — nil means "not loaded for this visit yet", reset
	// on every fresh entry into the screen so a stale dirty-mark from a
	// previous visit never leaks in.
	pluginCache   []PluginItem
	pluginChecked map[string]bool
	pluginOrig    map[string]bool

	// Uninstall picker (scrUninstallPick): same Tab multi-select shape,
	// but always starts fully unchecked (no "server baseline" to diff —
	// every visit is a fresh empty batch) and uninstallTargets is the
	// resolved batch (checked rows, or the single highlighted row when
	// nothing was checked) once Enter commits it.
	uninstallCache   []Item
	uninstallChecked map[string]bool
	uninstallTargets []string
	// folderExpanded tracks which folder rows are opened (Right arrow) vs
	// collapsed (Left) on BOTH the Uninstall screen and the Installed
	// plugins setup list — they share this one map so the tree grouping
	// can never drift between them. Sub-plugins only ever render inside an
	// expanded folder; collapsed folders show the single folder line,
	// which is the whole point of the grouping.
	folderExpanded map[string]bool

	pendingPluginsRoot string // picked in scrSettings, confirmed in scrPluginsRootConfirm

	// "Plugin fixes" flow: fixPlugin is the plugin chosen on
	// scrFixPluginPick, fixCache the catalog fetched for it, and
	// fixChecked/fixOrig the in-progress marks vs the server baseline —
	// same Tab-diff pattern as the Plugin list, so Enter only sends the
	// apply/remove delta.
	fixPlugin string
	// fixPluginCache is the unified plugin list rendered (folders + sort)
	// by the fixes plugin chooser, exactly like the Installed plugins
	// screen; it is only ever read to build that picker.
	fixPluginCache []PluginItem
	// fixAppliedPlugins is the set of plugin stems (fix_plugin_canonical
	// form) that already carry at least one applied fix — loaded once per
	// visit to the fixes plugin chooser and rendered as an accent ● badge.
	fixAppliedPlugins map[string]bool
	fixCache          []FixItem
	fixChecked        map[string]bool
	fixOrig           map[string]bool

	// settingsPending holds a Left/Right-adjusted but not-yet-applied value
	// per settings row (the value is the target: "on"/"off", "default"/
	// "superfile", "classic"/"hyprland"). The displayed label is overridden
	// from it immediately; the change is applied on the dwell timer, when
	// the cursor leaves the row, or when the screen is left. settingsDwellSeq
	// invalidates older dwell timers.
	settingsPending  map[string]string
	settingsDwellSeq int
	// pendingHandlerMode is the classic/hyprland mode a handler change will
	// switch to once the user confirms the global-rules warning; it is set
	// when the confirm screen is pushed and consumed on Yes.
	pendingHandlerMode string
	// installFixPlugin is the value (vst:<type>:<path>) of the plugin just
	// installed, parked while the post-install "Apply fixes now?" confirm is
	// on screen; accepting it becomes the fixPlugin of the normal apply
	// flow.
	installFixPlugin string

	// fixFolderExpanded tracks which fix-category header rows are open
	// (Right arrow) vs collapsed (Left) on scrFixChoose. A category with no
	// entry defaults to expanded the first time it is seen (see
	// rebuildFixPicker), so the initial look keeps every fix visible —
	// collapsing is an explicit act.
	fixFolderExpanded map[string]bool
	// fixSortDesc toggles the fixes list's category-then-title ordering
	// between ascending and descending (the `s` key on scrFixChoose).
	fixSortDesc bool

	reconcileChecked bool
	missingKeys      []string // keys of "in the log but NOT on this computer" plugins
	quit             bool

	// first-launch wizard state: wizardStarted guards against re-offering
	// the wizard on later status fetches within this session (the backend
	// flips status.WizardDone=true once the wizard actually finishes);
	// wizardRoot is the folder the user settled on (default or chosen).
	wizardStarted bool
	wizardRoot    string
}

func initialModel() model {
	m := model{nav: []screen{scrMain}}
	m.picker = tuikit.NewPicker("", nil)
	m.runner = tuikit.NewRunner()
	return m
}

func (m model) Init() tea.Cmd { return tea.Batch(fetchStatus(), tuikit.ThemeWatchCmd()) }

func (m model) top() screen       { return m.nav[len(m.nav)-1] }
func (m *model) push(s screen)    { m.nav = append(m.nav, s) }
func (m *model) replace(s screen) { m.nav[len(m.nav)-1] = s }
func (m *model) pop() {
	if len(m.nav) > 1 {
		m.nav = m.nav[:len(m.nav)-1]
	}
	m.toast = m.toast.ClearNonCritical()
}

// mainItems is the first menu -- Plugin list/Install/Uninstall/Launch are
// common to both plugin universes (VST + native) and live here directly,
// per explicit request; "Windows VST Plugins (Wine)" is only the
// Wine-specific leftovers (see vstMenuItems).
func mainItems() []tuikit.PickerItem {
	return []tuikit.PickerItem{
		{Display: "Installed plugins", Value: "list"},
		{Display: "Install a plugin from file", Value: "install"},
		{Display: "Uninstall a plugin", Value: "uninstall"},
		{Display: "Plugin fixes", Value: "fixes"},
		{Display: "Launch a standalone plugin", Value: "standalone"},
		{Display: "Windows VST Plugins", Value: "vst"},
		{Display: "Settings", Value: "settings"},
		{Display: "Close", Value: "quit"},
	}
}

// settingsItems is the single unified Settings screen -- every setting that
// isn't VST-specific lives here (file picker, manual rescan trigger).
func settingsItems(s Status) []tuikit.PickerItem {
	fp := "Default"
	if s.FilePicker == "superfile" {
		fp = "Superfile"
	}
	handler := "Hyprland-managed"
	if s.PluginWinHandler == "classic" {
		handler = "Classic (float + decorations)"
	}
	return []tuikit.PickerItem{
		{Display: "File picker: " + fp, Value: "switch_file_picker"},
		{Display: "Plugins folder: " + s.PluginsRoot, Value: "pick_plugins_root"},
		{Display: "Default plugin installation file directory: " + s.DownloadsDir, Value: "pick_downloads_dir"},
		{Display: "Plugin window handler: " + handler, Value: "toggle_plugin_handler"},
		{Display: "Rescan for untracked plugins", Value: "rescan"},
		{Display: "Cleanup inconsistencies", Value: "cleanup"},
		{Display: "Back", Value: "back"},
	}
}

// vstMenuItems is "Windows VST Plugins (Wine)" -- the Wine/yabridge-specific
// leftovers only, per explicit request: prefix management, executable
// visibility, and the two Hide filters (Windows-plugin concepts that don't
// map onto LV2/CLAP/native-VST3), as flat toggle items directly in this
// list -- no further "VST settings" sub-page.
func vstMenuItems(s Status) []tuikit.PickerItem {
	hv, h32 := "Off", "Off"
	if s.HideVst2 {
		hv = "On"
	}
	if s.Hide32Bit {
		h32 = "On"
	}
	return []tuikit.PickerItem{
		{Display: "Manage prefixes", Value: "prefixes"},
		{Display: "Hide VST2: " + hv, Value: "toggle_hide_vst2"},
		{Display: "Hide 32-bit: " + h32, Value: "toggle_hide_32bit"},
		{Display: "Manage visible executables in Omarchy Menu", Value: "execs"},
		{Display: "Back", Value: "back"},
	}
}

func sortModeLabel(mode string) string {
	switch mode {
	case "name":
		return "Name"
	case "format":
		return "Format"
	case "date":
		return "Install date"
	default:
		return "Vendor"
	}
}

// stepSortMode cycles vendor -> name -> format -> date, either direction —
// the btop-style live sort-cycle (the `s` key) inside the unified Plugin
// list and the Uninstall screen (see cycleSortCmd in actions.go). Vendor
// still applies (native rows fall back to name-sort on the bash side, same
// as before).
func stepSortMode(current string, dir int) string {
	order := []string{"vendor", "name", "format", "date"}
	idx := 0
	for i, m := range order {
		if m == current {
			idx = i
			break
		}
	}
	idx = ((idx+dir)%len(order) + len(order)) % len(order)
	return order[idx]
}

// toggleTarget maps a boolean state to its pending-string target.
func toggleTarget(on bool) string {
	if on {
		return "on"
	}
	return "off"
}

// settingsItemsWithPending overlays the not-yet-applied Left/Right value on
// the Settings rows so the label moves the instant the user presses an
// arrow, before anything is written (see applySettingPending).
func (m model) settingsItemsWithPending() []tuikit.PickerItem {
	items := settingsItems(m.status)
	for i := range items {
		switch items[i].Value {
		case "switch_file_picker":
			if p, ok := m.settingsPending["switch_file_picker"]; ok {
				fp := "Default"
				if p == "superfile" {
					fp = "Superfile"
				}
				items[i].Display = "File picker: " + fp
			}
		case "toggle_plugin_handler":
			if p, ok := m.settingsPending["toggle_plugin_handler"]; ok {
				h := "Hyprland-managed"
				if p == "classic" {
					h = "Classic (float + decorations)"
				}
				items[i].Display = "Plugin window handler: " + h
			}
		}
	}
	return items
}

// vstMenuItemsWithPending is settingsItemsWithPending's counterpart for the
// two Hide filters on the Windows VST Plugins menu (they persist and refresh
// through the very same status fetch as Settings).
func (m model) vstMenuItemsWithPending() []tuikit.PickerItem {
	items := vstMenuItems(m.status)
	for i := range items {
		label := func(p string) string {
			if p == "on" {
				return "On"
			}
			return "Off"
		}
		switch items[i].Value {
		case "toggle_hide_vst2":
			if p, ok := m.settingsPending["toggle_hide_vst2"]; ok {
				items[i].Display = "Hide VST2: " + label(p)
			}
		case "toggle_hide_32bit":
			if p, ok := m.settingsPending["toggle_hide_32bit"]; ok {
				items[i].Display = "Hide 32-bit: " + label(p)
			}
		}
	}
	return items
}

// settingTargetMatchesStatus reports whether a pending row's target is now
// the value the server reports — the signal to drop the pending override so
// the label settles on the applied value.
func (m model) settingTargetMatchesStatus(row, target string) bool {
	switch row {
	case "switch_file_picker":
		return target == m.status.FilePicker
	case "toggle_plugin_handler":
		return target == m.status.PluginWinHandler
	case "toggle_hide_vst2":
		return (target == "on") == m.status.HideVst2
	case "toggle_hide_32bit":
		return (target == "on") == m.status.Hide32Bit
	}
	return false
}

func (m *model) settleSettingsPending() {
	for row, target := range m.settingsPending {
		if m.settingTargetMatchesStatus(row, target) {
			delete(m.settingsPending, row)
		}
	}
}

// applySettingPending runs the same action Enter uses for one pending row,
// keeping the cursor in place (the status refresh rebuilds the picker with
// the applied value). It is a no-op when the target already matches the
// server, and it pushes the Superfile install confirm when switching to a
// not-yet-installed Superfile is what the pending value asks for.
func (m *model) applySettingPending(row string) tea.Cmd {
	target, ok := m.settingsPending[row]
	if !ok {
		return nil
	}
	switch row {
	case "switch_file_picker":
		if target == m.status.FilePicker {
			delete(m.settingsPending, row)
			return nil
		}
		if target == "superfile" && !m.status.SuperfileInstalled {
			delete(m.settingsPending, row)
			m.push(scrSuperfileInstallConfirm)
			return m.enterCmd()
		}
		return setFilePickerAndRefetch(target)
	case "toggle_plugin_handler":
		if target == m.status.PluginWinHandler {
			delete(m.settingsPending, row)
			return nil
		}
		// The global Hyprland-rules change is confirm-gated; keep the
		// pending target until the confirm resolves (see
		// requestPluginHandlerChange / scrPluginHandlerConfirm).
		return m.requestPluginHandlerChange(target)
	case "toggle_hide_vst2":
		if (target == "on") == m.status.HideVst2 {
			delete(m.settingsPending, row)
			return nil
		}
		return toggleHideVst2AndRefetch()
	case "toggle_hide_32bit":
		if (target == "on") == m.status.Hide32Bit {
			delete(m.settingsPending, row)
			return nil
		}
		return toggleHide32BitAndRefetch()
	}
	return nil
}

func (m *model) applyAllPending() tea.Cmd {
	var cmds []tea.Cmd
	for row := range m.settingsPending {
		if c := m.applySettingPending(row); c != nil {
			cmds = append(cmds, c)
		}
	}
	return tea.Batch(cmds...)
}

// applyAllPendingExcept applies every pending row except the one the user is
// acting on with Enter: that row's own Enter handler is the apply, so its
// pending mark is simply dropped to avoid a double toggle.
func (m *model) applyAllPendingExcept(except string) tea.Cmd {
	delete(m.settingsPending, except)
	var cmds []tea.Cmd
	for row := range m.settingsPending {
		if c := m.applySettingPending(row); c != nil {
			cmds = append(cmds, c)
		}
	}
	return tea.Batch(cmds...)
}

func (m *model) rebuildSettingsPicker() {
	sidx := m.picker.Index()
	m.picker = tuikit.NewPicker("Settings", m.settingsItemsWithPending()).
		SetSize(m.contentSize())
	m.picker = m.picker.SelectIndex(sidx)
}

func (m *model) rebuildVstPicker() {
	sidx := m.picker.Index()
	m.picker = tuikit.NewPicker("Windows VST Plugins (Wine)", m.vstMenuItemsWithPending()).
		SetSize(m.contentSize())
	m.picker = m.picker.SelectIndex(sidx)
}

// cycleLoadedSetting steps the row under the cursor and shows the new value
// as a pending label without applying it, then arms the dwell timer that
// applies it if the user leaves the value alone.
func (m *model) cycleLoadedSetting() (tea.Model, tea.Cmd) {
	row := m.picker.SelectedValue()
	if m.settingsPending == nil {
		m.settingsPending = map[string]string{}
	}
	switch row {
	case "switch_file_picker":
		cur := m.status.FilePicker
		if p, ok := m.settingsPending[row]; ok {
			cur = p
		}
		if cur == "superfile" {
			m.settingsPending[row] = "default"
		} else {
			m.settingsPending[row] = "superfile"
		}
	case "toggle_plugin_handler":
		cur := m.status.PluginWinHandler
		if p, ok := m.settingsPending[row]; ok {
			cur = p
		}
		target := "classic"
		if cur == "classic" {
			target = "hyprland"
		}
		// This row is a global Hyprland-rules change, so it is confirm-gated
		// and must ASK IMMEDIATELY on the key press — never ride the dwell/
		// blur deferral the other settings use. Drop any stale pending mark
		// (a leftover would re-open the confirm when the cursor leaves).
		delete(m.settingsPending, row)
		// requestPluginHandlerChange mutates m (parks the target, pushes the
		// confirm screen, sizes the InfoConfirm), so run it BEFORE the value
		// copy. Returning the *model receiver itself here was the crash:
		// model.Update asserts next.(model) on every message, so the moment
		// the user hit Left/Right on this row the TUI panicked with
		// "interface conversion: tea.Model is *main.model, not main.model".
		// Every other branch below returns the dereferenced *m.
		cmd := m.requestPluginHandlerChange(target)
		return *m, cmd
	case "toggle_hide_vst2":
		cur := m.status.HideVst2
		if p, ok := m.settingsPending[row]; ok {
			cur = p == "on"
		}
		m.settingsPending[row] = toggleTarget(!cur)
	case "toggle_hide_32bit":
		cur := m.status.Hide32Bit
		if p, ok := m.settingsPending[row]; ok {
			cur = p == "on"
		}
		m.settingsPending[row] = toggleTarget(!cur)
	default:
		// A non-value row (Back, Plugins folder, Rescan, …): Left/Right has
		// nothing to cycle. Dereference like every other exit — returning
		// the *model receiver here panicked model.Update's next.(model)
		// assertion.
		return *m, nil
	}
	if m.top() == scrVstMenu {
		m.rebuildVstPicker()
	} else {
		m.rebuildSettingsPicker()
	}
	m.settingsDwellSeq++
	seq := m.settingsDwellSeq
	rowID := row
	// Dereference: model.Update asserts next.(model) on every message, so a
	// pointer-receiver method MUST return the model value (*m), never the
	// *model receiver itself — returning m here panicked with
	// "interface conversion: tea.Model is *main.model, not main.model" the
	// moment any Left/Right preview was shown. Maps are shared by reference,
	// so the pending/target mutations above survive the value copy.
	return *m, tea.Tick(settingsDwell, func(time.Time) tea.Msg {
		return settingsDwellMsg{row: rowID, seq: seq}
	})
}

// Update wraps update so every toast gets a matching expiry timer. The
// Set*/ClearNonCritical call sites only assign m.toast, so the generation
// bump is detected here and ToastExpireCmd is batched onto whatever command
// update already returned. ToastExpireMsg carries the generation it was
// scheduled for, so an older toast's timer can never clear a newer toast.
func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	if em, ok := msg.(tuikit.ToastExpireMsg); ok {
		m.toast = m.toast.Expire(em.Gen)
		return m, nil
	}
	before := m.toast.Gen()
	next, cmd := m.update(msg)
	m = next.(model)
	if m.toast.Gen() != before {
		cmd = tea.Batch(cmd, m.toast.ExpireCmd())
	}
	return m, cmd
}

func (m model) update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.w, m.h = msg.Width, msg.Height
		m.picker = m.picker.SetSize(m.contentSize())
		m.runner = m.runner.SetSize(m.contentSize())
		return m, nil

	case tea.KeyMsg:
		if msg.String() == "ctrl+c" {
			if len(m.nav) == 1 {
				m.quit = true
				return m, tea.Quit
			}
			if m.top() == scrSettings || m.top() == scrVstMenu {
				// Leaving a settings screen commits any pending Left/Right
				// value before the screen is popped (a value that needs a
				// confirm pushes that confirm instead).
				cmd := m.applyAllPending()
				if m.top() == scrSettings || m.top() == scrVstMenu {
					m.pop()
				}
				return m, tea.Batch(cmd, m.enterCmd())
			}
			m.pop()
			return m, m.enterCmd()
		}

	case tuikit.ThemeTickMsg:
		// Live theme following (see the move manager's identical case —
		// re-stamp every package-level color/style var, then re-issue).
		tuikit.ApplyTheme()
		return m, tuikit.ThemeWatchCmd()

	case statusMsg:
		if msg.skip {
			// Retry once, immediately — an empty result on the very
			// first load (before any menu has ever been built) must
			// not leave the picker permanently blank.
			return m, fetchStatus()
		}
		m.loading = false
		if msg.err != nil {
			m.toast, _ = m.toast.SetErr(msg.err.Error())
			return m, nil
		}
		m.status = msg.status
		// A pending settings value whose target the server now reports is
		// settled: drop the override so the row shows the applied value.
		m.settleSettingsPending()
		// Preserve the cursor across every rebuild on this path: the
		// refresh Status fetch re-creates the on-screen picker with fresh
		// labels, and without re-selecting, refreshing the connection
		// status sent the cursor flying back to the top of the list
		// (the user's explicit no-reset rule whenever "Refresh
		// connection status" runs).
		idx := m.picker.Index()
		switch m.top() {
		case scrMain:
			// The ASCII banner on the home screen is the title; the picker
			// header is left empty so it doesn't render a duplicate white
			// title under it (see view.go's main screen banner).
			m.picker = tuikit.NewPicker("", mainItems()).SetSize(m.contentSize())
		case scrSettings:
			m.picker = tuikit.NewPicker("Settings", m.settingsItemsWithPending()).SetSize(m.contentSize())
		case scrVstMenu:
			m.picker = tuikit.NewPicker("Windows VST Plugins", m.vstMenuItemsWithPending()).SetSize(m.contentSize())
		}
		m.picker = m.picker.SelectIndex(idx)
		if !m.status.WizardDone && !m.wizardStarted && m.top() == scrMain {
			// First launch: offer the wizard on top of the home menu. The
			// backend only reports wizard_done=false on a machine whose
			// prefs did NOT exist before load_prefs ran (upgrades never see
			// it), so this is a genuinely fresh setup.
			m.wizardStarted = true
			m.wizardRoot = m.status.PluginsRoot
			if m.wizardRoot == "" {
				home, _ := os.UserHomeDir()
				m.wizardRoot = filepath.Join(home, "Music", "Audio Plugins")
			}
			m.confirm = tuikit.NewConfirm(
				"First launch — use '"+m.wizardRoot+"' as the plugins folder?",
				"No, choose a folder", "Yes, use the default")
			m.push(scrWizardRoot)
			return m, nil
		}
		if !m.reconcileChecked {
			m.reconcileChecked = true
			return m, tea.Batch(reconcileMissingCmd(), reconcileOrphansCmd())
		}
		return m, nil

	case actionOKMsg:
		m.loading = false
		m.toast, _ = m.toast.SetOK(msg.what)
		m.pop()
		return m, tea.Batch(m.enterCmd(), fetchStatus())

	case actionErrMsg:
		m.loading = false
		m.toast, _ = m.toast.SetErr(msg.err.Error())
		return m, nil

	case installFixesCheckMsg:
		// A successful install just finished; the fixes catalog was fetched
		// for the new plugin. Offer the remaining plugin-scope fixes in a
		// clear confirm, or fall straight back to the normal success prompt
		// when there is nothing to propose.
		var toApply []string
		for _, it := range msg.items {
			if it.Scope == "plugin" && !it.Applied {
				toApply = append(toApply, it.ID)
			}
		}
		if msg.err == nil && len(toApply) > 0 {
			m.installFixPlugin = msg.plugin
			m.confirm = tuikit.NewConfirm(
				"Plugin installed. Apply fixes for "+baseName(pluginPathOf(msg.plugin))+" now?",
				"No", "Yes")
			m.push(scrInstallFixesConfirm)
			return m, nil
		}
		m.confirm = tuikit.NewConfirm("Success! The step completed without errors.", "See log", "OK")
		m.push(scrRunnerSuccessConfirm)
		return m, nil

	case folderOpenedMsg:
		// Opening a folder must never navigate away from the list it was
		// invoked from — just report what happened on the toast row.
		if msg.err != nil {
			m.toast, _ = m.toast.SetErr(msg.err.Error())
		} else {
			m.toast, _ = m.toast.SetOK(msg.what)
		}
		return m, nil

	case handlerErrMsg:
		// The handler flip's bash side failed (set-plugin-handler rejected
		// the value or hyprctl reload died) — tell the user, stop the
		// loading spinner.
		m.loading = false
		m.toast, _ = m.toast.SetErr(msg.err.Error())
		return m, nil

	case pluginHandlerOKMsg:
		// Confirmation toast (the plugin-list "x" shortcut has no other
		// visible effect), then refetch so the Settings row shows the mode.
		m.toast, _ = m.toast.SetOK("plugin window handler: " + msg.handler)
		return m, fetchStatus()

	case reconcileMissingMsg:
		if len(msg.labels) > 0 {
			m.missingKeys = msg.keys
			m.confirm = tuikit.NewConfirm(missingPrompt(msg.labels), "add to log", "remove everywhere")
			m.push(scrReconcileMissingInfo)
		}
		return m, nil

	case reconcileOrphansMsg:
		if len(msg.items) > 0 {
			items := make([]tuikit.PickerItem, len(msg.items))
			for i, it := range msg.items {
				items[i] = tuikit.PickerItem{Display: it.Display, Value: it.Value}
			}
			m.picker = tuikit.NewPicker("Found on disk but not tracked — pick to add (esc to finish):", items).SetSize(m.contentSize())
			m.push(scrReconcileOrphansTick)
		}
		return m, nil

	case cleanupMsg:
		// "cleanup!" ran: report what was fixed. Nothing is meaningful →
		// a toast and straight back to the menu; otherwise an info screen
		// summarizing the non-destructive fixes.
		if msg.err != nil {
			m.toast, _ = m.toast.SetErr(msg.err.Error())
			m.pop()
			return m, m.enterCmd()
		}
		r := msg.report
		if len(r.Kept) == 0 && len(r.Registered) == 0 && len(r.Desktops) == 0 && len(r.Deduped) == 0 {
			m.toast, _ = m.toast.SetOK("Cleanup: everything already consistent")
			m.pop()
			return m, m.enterCmd()
		}
		var b strings.Builder
		b.WriteString("Cleanup done — nothing was deleted:\n")
		if len(r.Kept) > 0 {
			b.WriteString(fmt.Sprintf("\nKept in the log (files missing, not deleted): %d\n", len(r.Kept)))
			for _, l := range r.Kept {
				b.WriteString("  • " + l + "\n")
			}
		}
		if len(r.Registered) > 0 {
			b.WriteString(fmt.Sprintf("\nUntracked files registered into the log: %d\n", len(r.Registered)))
			for _, l := range r.Registered {
				b.WriteString("  • " + l + "\n")
			}
		}
		if len(r.Deduped) > 0 {
			b.WriteString(fmt.Sprintf("\nDeduplicated cross-key file reference(s) in the log: %d\n", len(r.Deduped)))
		}
		if len(r.Desktops) > 0 {
			b.WriteString(fmt.Sprintf("\nDangling menu entries removed (standalone exe gone): %d\n", len(r.Desktops)))
			for _, l := range r.Desktops {
				b.WriteString("  • " + l + "\n")
			}
		}
		m.info = tuikit.NewInfo(b.String()).SetSize(m.contentSize())
		m.replace(scrInfo)
		return m, nil

	case rescanMsg:
		if len(msg.labels) == 0 && len(msg.items) == 0 {
			m.toast, _ = m.toast.SetOK("No untracked plugins found")
			return m, nil
		}
		if len(msg.labels) > 0 {
			m.missingKeys = msg.keys
			m.confirm = tuikit.NewConfirm(missingPrompt(msg.labels), "add to log", "remove everywhere")
			m.push(scrReconcileMissingInfo)
		}
		if len(msg.items) > 0 {
			items := make([]tuikit.PickerItem, len(msg.items))
			for i, it := range msg.items {
				items[i] = tuikit.PickerItem{Display: it.Display, Value: it.Value}
			}
			m.picker = tuikit.NewPicker("Found on disk but not tracked — pick to add (esc to finish):", items).SetSize(m.contentSize())
			m.push(scrReconcileOrphansTick)
		}
		return m, nil

	case pathMsg:
		m.loading = false
		if msg.err != nil {
			m.toast, _ = m.toast.SetErr(msg.err.Error())
			return m, nil
		}
		switch msg.kind {
		case "pick-file":
			if msg.path == "" {
				m.toast, _ = m.toast.SetWarn("no file selected")
				return m, nil
			}
			// Auto-detect: a Windows installer (exe/msi) goes through the
			// existing wine-prefix wizard; everything else (lv2/clap/vst3,
			// or an archive containing one) is a native install, handled
			// in one shot by the bash side.
			if isWineInstaller(msg.path) {
				m.installFile = msg.path
				m.push(scrInstallPrefixChoice)
				return m, m.enterCmd()
			}
			m.loading = true
			return m, nativeInstallCmd(msg.path)
		case "default-prefix":
			m.installPrefix = msg.path
			m.replace(scrInstalling)
			m.runner = tuikit.NewRunner().SetSize(m.contentSize())
			var cmd tea.Cmd
			m.runner, cmd = m.runner.Start("Installing", actionsBin(), "install", m.installFile, m.installPrefix)
			return m, cmd
		case "create-prefix":
			m.installPrefix = msg.path
			m.pop() // leave scrInstallPrefixName
			m.replace(scrInstalling)
			m.runner = tuikit.NewRunner().SetSize(m.contentSize())
			var cmd tea.Cmd
			m.runner, cmd = m.runner.Start("Installing", actionsBin(), "install", m.installFile, m.installPrefix, "new")
			return m, cmd
		case "move-create-prefix":
			m.moveTo = msg.path
			m.pop() // leave scrPrefixMoveTargetName
			m.push(scrPrefixMoveConfirm)
			return m, m.enterCmd()
		case "pick-plugins-root":
			if msg.path == "" {
				m.toast, _ = m.toast.SetWarn("no folder selected")
				return m, nil
			}
			m.pendingPluginsRoot = msg.path
			m.push(scrPluginsRootConfirm)
			m.confirm = tuikit.NewConfirm(
				"Move every plugin to '"+msg.path+"'? This moves real files and re-links wine/yabridge.",
				"No", "Yes")
			return m, nil
		case "pick-downloads-dir":
			if msg.path == "" {
				m.toast, _ = m.toast.SetWarn("no folder selected")
				return m, nil
			}
			return m, setDownloadsDirAndRefetch(msg.path)
		case "wizard-root":
			if msg.path == "" {
				// No folder chosen after browsing — the current default
				// root stays, wizard goes back to the main menu.
				m.toast, _ = m.toast.SetWarn("no folder chosen — keeping the current plugins folder")
				m.pop()
				return m, m.enterCmd()
			}
			m.wizardRoot = msg.path
			return m, m.startWizardFinish()
		}
		// Any kind this switch doesn't know belongs to a screen handler
		// (e.g. the wizard's wizard-browse-done superfile-exited marker) —
		// let the active screen decide.
		return m.updateScreen(msg)

	case tuikit.RunnerLineMsg, tuikit.RunnerDoneMsg:
		var cmd tea.Cmd
		m.runner, cmd = m.runner.Update(msg)
		if done, ok := msg.(tuikit.RunnerDoneMsg); ok {
			switch m.top() {
			case scrInstalling:
				// A successful wine install prints the freshly installed
				// plugin's list value; look for it and, when found, fetch
				// its fixes to offer the apply-those-fixes prompt instead
				// of the plain success dialog.
				if done.Err == nil {
					if v := installedPluginValue(m.runner.Output()); v != "" {
						m.installFixPlugin = v
						return m, checkInstallFixesCmd(v)
					}
					m.confirm = tuikit.NewConfirm("Success! The step completed without errors.", "See log", "OK")
				} else {
					m.confirm = tuikit.NewConfirm(
						"The step failed or was aborted — nothing was installed or changed.\nSee the log for details.",
						"See log", "OK")
				}
				m.push(scrRunnerSuccessConfirm)
			case scrUninstalling, scrMoving, scrPluginsRootMigrating:
				if done.Err == nil {
					m.confirm = tuikit.NewConfirm("Success! The step completed without errors.", "See log", "OK")
				} else {
					// Non-zero exit: the bash side reports a REAL failure or
					// an aborted install — notably install_via_wine returns 1
					// when the installer produced no new file (user canceled
					// it, or it silently failed). Never let that read as
					// "Success!" (the user's rule: an aborted install must be
					// reported as failed/aborted, not successful).
					m.confirm = tuikit.NewConfirm(
						"The step failed or was aborted — nothing was installed or changed.\nSee the log for details.",
						"See log", "OK")
				}
				m.push(scrRunnerSuccessConfirm)
			case scrWizardDaw:
				// Wizard's reporting run finished — back to the home menu;
				// the backend already persisted the root + wizard_done=true,
				// so the next status fetch will NOT re-offer the wizard.
				m.nav = []screen{scrMain}
				m.toast, _ = m.toast.SetOK("wizard complete — plugins folder: '" + m.wizardRoot + "'")
				return m, m.enterCmd()
			}
		}
		return m, cmd
	}

	return m.updateScreen(msg)
}
