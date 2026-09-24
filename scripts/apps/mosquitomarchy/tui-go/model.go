package main

import (
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	tuikit "mosquitomarchy.local/tui-kit"
)

type screen int

const (
	scrMain screen = iota
	scrStatus
	scrSetup
	scrSetupCat
	scrUpdate
	scrHealth
	scrKB
	scrKBList
	scrKBCat
	scrKBItems
	scrKBKeys
	scrKBInput
	scrBackup
	scrBackupRestore
	scrConfirm
	scrWorking
	scrPassphrase
	scrInfo
	scrBackupOptions
	scrBackupApps
)

// BackupOpts are the Backup screen's content choices.
type BackupOpts struct {
	VST     string // "list" | "full" | "none"
	Keepass bool   // include KeePassXC passwords (only when installed)
	Encrypt bool   // AES-256 with a passphrase
	HasKeep bool   // the machine has keepassxc + its config/db
}

// model is the single Bubble Tea model for the whole session: every screen
// is a state in m.nav, never a subprocess.
type model struct {
	w, h int

	nav []screen

	mainPicker  navPicker
	setupPicker navPicker
	// setupCatPicker is the folder tree of the Setup category currently open
	// (the first Setup screen lists the categories as plain options).
	setupCatPicker navPicker
	setupCat       string
	updatePicker   navPicker
	// healthPicker lists the pieces the Health check found missing; the rows
	// are toggled with tab (same multi-select convention as Setup/Update) and
	// only the checked ones are re-applied.
	healthPicker navPicker
	backupPicker navPicker
	// backupOptPicker drives the Backup options screen; backupAppsPicker is
	// the apps/tuis/webapps content tree.
	backupOptPicker  navPicker
	backupAppsPicker navPicker

	confirm   tuikit.Confirm
	runner    tuikit.Runner
	toast     tuikit.Toast
	info      tuikit.Info
	passInput tuikit.TextInput

	statusRecs []StatusRec
	backupRecs []BackupRec
	updateRec  UpdateRec

	// Setup tree: folders in display order, their items (flat, folder-tagged),
	// and a value -> item index for the "i" info popup.
	setupFolders []FolderRec
	setupItems   []SetupItemRec
	setupByValue map[string]SetupItemRec
	folderOpen   map[string]bool
	selected     map[string]bool
	// updateSelected is the Update screen's own selection (kept apart from
	// the Setup tree's, so visiting one never clears the other).
	updateSelected map[string]bool
	// healthChecked is the Health check list's checkbox map (default: every
	// missing piece checked, since they're all there to be re-applied).
	healthChecked map[string]bool
	// healthItems keeps the FULL health records (id + label + detail) so the
	// "i" popup can describe the highlighted row.
	healthItems []HealthRec
	blinkOn     bool

	// Keybindings manager (the old setup-keybindings.sh, now a TUI screen).
	// kbMode is "setup" (Setup ▸ keybindings) or "uninstall" (Uninstall ▸
	// keybindings, list first + Reset). kbSel PERSISTS across navigation in
	// uninstall mode so a global uninstall run removes the ticked combos.
	kbMode       string
	kbPicker     navPicker // the Keybindings MENU
	kbListPicker navPicker // the "Managed keybindings" list (distinct picker: popping back to the menu must not keep showing the list)
	kbItems      []KbRec
	kbSel        map[string]bool
	// Setup/Uninstall tree typing filter: printable keys build a live
	// substring filter that flattens the tree (leaf rows only, no category
	// folders); tab still ticks rows and Enter acts on them.
	filterText string
	// filterOpen: the 'f' toggle that shows the rectangular filter zone
	// above the shortcut bar (Setup/Uninstall + their subcategories). The
	// zone echoes every pressed key in real time while filtering.
	filterOpen bool
	// kpxGnomeRm tracks the per-install-plan answer to "remove the
	// gnome-keyring package?": 0 = not asked yet, 1 = yes, 2 = no.
	kpxGnomeRm    int
	kbCatPicker   navPicker
	kbItemPicker  navPicker
	kbCatItems    []KbCatItem
	kbKeyPicker   navPicker
	kbFree        []string
	kbPending     KbCatItem
	kbInput       tuikit.TextInput
	kbInputStep   int    // 0 = label, 1 = command
	kbCustomLabel string // custom-command label while the command is typed

	// Backup content selection (apps/tuis/webapps), reusing the setup tree
	// display; plus the "what to include" options.
	backupFolders []FolderRec
	backupItems   []SetupItemRec
	backupChecked map[string]bool
	backupOpen    map[string]bool
	backupOpts    BackupOpts
	backupSelFile string

	// pending* hold a confirm's/action's decision.
	pendingAction string // "apply" | "update" | "update-repo" | "backup" | "restore" | "menu-entry"
	pendingArgs   []string
	pendingFile   string
	// pendingPass holds the first encrypted-backup passphrase while the
	// confirmation entry is shown.
	pendingPass string
	pendingMsg  string
	pendingNo   string
	pendingYes  string

	// passphraseSet tracks whether OMARCHY_BACKUP_PASSPHRASE is currently
	// exported for the running child, so RunnerDone can unset it.
	passphraseSet bool

	// lastOutput keeps the last action's streamed output so the "finished
	// with errors" prompt can show the full log.
	lastOutput string

	// workingLabel is the label of the running action, used to name its crash
	// log when the run fails.
	workingLabel string

	// pendingPatchKeys holds the app keys whose patch script should be proposed
	// after a successful apply.
	pendingPatchKeys []string

	// treeMode is which tree the Setup screens are showing: "install" (the
	// normal Setup, with selection + Install selection) or "uninstall" (only
	// the installed entries, Enter uninstalls).
	treeMode string

	fatal error
	quit  bool
}

func initialModel() model {
	m := model{
		nav:            []screen{scrMain},
		selected:       map[string]bool{},
		updateSelected: map[string]bool{},
		healthChecked:  map[string]bool{},
		kbSel:          map[string]bool{},
		folderOpen:     map[string]bool{},
		setupByValue:   map[string]SetupItemRec{},
		backupChecked:  map[string]bool{},
		backupOpen:     map[string]bool{},
		backupOpts:     BackupOpts{VST: "list", Keepass: true},
		treeMode:       "install",
	}
	m.mainPicker = newNavPicker("", mainMenuItems())
	m.setupPicker = newNavPicker("", nil)
	m.setupCatPicker = newNavPicker("", nil)
	m.updatePicker = newNavPicker("", nil)
	m.backupPicker = newNavPicker("", nil)
	m.backupOptPicker = newNavPicker("", nil)
	m.backupAppsPicker = newNavPicker("", nil)
	m.runner = tuikit.NewRunner()
	return m
}

func (m model) Init() tea.Cmd {
	return tea.Batch(tuikit.ThemeWatchCmd(), firstRunCmd())
}

func (m model) top() screen { return m.nav[len(m.nav)-1] }

func (m *model) push(s screen) { m.nav = append(m.nav, s) }

func (m *model) pop() {
	if len(m.nav) > 1 {
		m.nav = m.nav[:len(m.nav)-1]
		m.toast = m.toast.ClearNonCritical()
	}
}

func (m *model) replace(s screen) { m.nav[len(m.nav)-1] = s }

func mainMenuItems() []tuikit.PickerItem {
	return []tuikit.PickerItem{
		{Display: "Status", Value: "status"},
		{Display: "Update", Value: "update"},
		{Display: "Setup", Value: "setup"},
		{Display: "Uninstall", Value: "uninstall"},
		{Display: "Health check", Value: "health"},
		{Display: "Backup / Restore", Value: "backup"},
		{Display: "Close", Value: "close"},
	}
}

func (m model) contentSize() (int, int) {
	w := m.w - 8
	if w > 92 {
		w = 92
	}
	if w < 20 {
		w = m.w
	}
	h := m.h - 8
	if h > 26 {
		h = 26
	}
	if h < 8 {
		h = m.h - 4
	}
	if m.top() == scrMain {
		h = m.mainBudget(h)
	}
	return w, h
}

// mainContentSize is contentSize() as it would be on the home screen no
// matter which screen is on top; the main picker is always laid out with it
// so a background rebuild that lands while a sub-screen is up keeps the
// picker at the home budget (no one-frame overflow when popping back).
func (m model) mainContentSize() (int, int) {
	w := m.w - 8
	if w > 92 {
		w = 92
	}
	if w < 20 {
		w = m.w
	}
	h := m.h - 8
	if h > 26 {
		h = 26
	}
	if h < 8 {
		h = m.h - 4
	}
	h = m.mainBudget(h)
	return w, h
}

// mainBudget applies the home-screen reserve to a height extent.
func (m model) mainBudget(h int) int {
	th := m.homeBannerReserve()
	reserved := m.h - th - 2 /*bar: notify+hint*/ - 2 /*frame pad*/ - 2 /*spare*/
	if reserved > 26 {
		reserved = 26
	}
	if reserved >= 8 {
		return reserved
	}
	return h
}

func (m model) contentSizeW() int {
	w, _ := m.contentSize()
	return w
}

// setupValue is the stable picker/selection key for a Setup item.
func setupValue(folder, key string) string { return "item:" + folder + ":" + key }

// folderValue is the picker key for a Setup folder row.
func folderValue(folder string) string { return "cat:" + folder }

// setupItemsOf returns the children of one folder, in backend order.
func (m model) setupItemsOf(folder string) []SetupItemRec {
	out := make([]SetupItemRec, 0, 8)
	for _, it := range m.setupItems {
		if it.Folder == folder {
			out = append(out, it)
		}
	}
	return out
}

// toggle marks/unmarks a Setup item by picker value.
func (m *model) toggle(value string) {
	if m.selected[value] {
		delete(m.selected, value)
	} else {
		m.selected[value] = true
	}
}

// toggleFolder marks every child of a folder, or unmarks them all when they
// were all marked already (one keystroke always flips to an extreme, exactly
// like the audio-plugin-manager's folder select-all).
func (m *model) toggleFolder(folder string) {
	toggleTreeFolder(m.setupItems, m.selected, folder)
}

// toggleTreeFolder is the shared folder select-all/none used by the Setup and
// backup-content trees.
func toggleTreeFolder(items []SetupItemRec, checked map[string]bool, folder string) {
	n := 0
	anyUnchecked := false
	for _, it := range items {
		if it.Folder != folder {
			continue
		}
		n++
		if !checked[setupValue(folder, it.Key)] {
			anyUnchecked = true
			break
		}
	}
	if n == 0 {
		return
	}
	for _, it := range items {
		if it.Folder != folder {
			continue
		}
		if anyUnchecked {
			checked[setupValue(folder, it.Key)] = true
		} else {
			delete(checked, setupValue(folder, it.Key))
		}
	}
}

// selectedCount counts the checked Setup items.
func (m model) selectedCount() int {
	n := 0
	for _, v := range m.selected {
		if v {
			n++
		}
	}
	return n
}

// toggleUpdate marks/unmarks an Update module by key.
func (m *model) toggleUpdate(key string) {
	if m.updateSelected[key] {
		delete(m.updateSelected, key)
	} else {
		m.updateSelected[key] = true
	}
}

// toggleHealth marks/unmarks one piece of the Health check list.
func (m *model) toggleHealth(key string) {
	if m.healthChecked[key] {
		delete(m.healthChecked, key)
	} else {
		m.healthChecked[key] = true
	}
}

// filteredCheckedKeys lists the ticked Setup/Uninstall leaf rows. While the
// typing filter is active only the visible (matching) rows count, so acting
// from the filtered view never touches unlisted ticked rows.
func (m model) filteredCheckedKeys() []string {
	if m.filterText == "" {
		return nil
	}
	ft := strings.ToLower(m.filterText)
	var out []string
	for _, f := range m.setupFolders {
		for _, it := range m.setupItemsOf(f.Folder) {
			if !strings.Contains(strings.ToLower(it.Label), ft) {
				continue
			}
			v := setupValue(f.Folder, it.Key)
			if m.selected[v] {
				out = append(out, strings.TrimPrefix(v, "item:"))
			}
		}
	}
	return out
}

// healthKeys returns the checked Health check pieces in list order.
func (m model) healthKeys() []string {
	out := make([]string, 0, len(m.healthChecked))
	for _, it := range m.healthItems {
		if m.healthChecked[it.ID] {
			out = append(out, it.ID)
		}
	}
	return out
}

func (m model) updateSelectedCount() int { return len(m.updateSelected) }

// preselectUpdate marks EVERY available changed module as selected so the
// Update screen's module list starts fully ticked (the user can un-tick
// anything they want to skip manually).
func (m *model) preselectUpdate() {
	for _, it := range m.updateRec.Modules {
		m.updateSelected[it.Key] = true
	}
}

// updateKeys returns the checked Update module keys as a stable slice (in
// the order the modules are listed).
func (m model) updateKeys() []string {
	out := make([]string, 0, len(m.updateSelected))
	for _, it := range m.updateRec.Modules {
		if m.updateSelected[it.Key] {
			out = append(out, it.Key)
		}
	}
	return out
}

// applyPlan groups the checked Setup items by folder, in folder order, as
// TAB-separated "<folder>\t<key>…" groups for the backend's `apply`.
func (m model) applyPlan() []string {
	var groups []string
	for _, f := range m.setupFolders {
		var keys []string
		for _, it := range m.setupItemsOf(f.Folder) {
			if m.selected[setupValue(f.Folder, it.Key)] {
				keys = append(keys, it.Key)
			}
		}
		if len(keys) > 0 {
			group := f.Folder
			for _, k := range keys {
				group += "\t" + k
			}
			groups = append(groups, group)
		}
	}
	return groups
}

// selectedKeysOfCat returns the checked item keys of one category only.
func (m model) selectedKeysOfCat(cat string) []string {
	var keys []string
	for _, it := range m.setupItemsOf(cat) {
		if m.selected[setupValue(cat, it.Key)] {
			keys = append(keys, it.Key)
		}
	}
	return keys
}

// allSelectedKeys returns every checked item key across all folders (used by
// the Uninstall tree's "Uninstall selection", the mirror of "Install
// selection").
func (m model) allSelectedKeys() []string {
	var keys []string
	for _, it := range m.setupItems {
		if m.selected[setupValue(it.Folder, it.Key)] {
			keys = append(keys, it.Key)
		}
	}
	return keys
}

// highlightedKey returns the item key under the cursor in the Setup folder
// tree (used by Uninstall: Enter on an unchecked row uninstalls just that row).
func (m model) highlightedKey() []string {
	v := m.setupCatPicker.SelectedValue()
	if !strings.HasPrefix(v, "item:") {
		return nil
	}
	rest := strings.TrimPrefix(v, "item:")
	if i := strings.Index(rest, ":"); i >= 0 {
		return []string{rest[i+1:]}
	}
	return nil
}

// applyPlanCat is the apply plan for ONE category only (the Setup submenu's
// Enter installs just what is checked there).
func (m model) applyPlanCat(cat string) []string {
	var keys []string
	for _, it := range m.setupItemsOf(cat) {
		if m.selected[setupValue(cat, it.Key)] {
			keys = append(keys, it.Key)
		}
	}
	if len(keys) == 0 {
		return nil
	}
	group := cat
	for _, k := range keys {
		group += "\t" + k
	}
	return []string{group}
}
