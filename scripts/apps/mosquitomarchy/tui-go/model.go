package main

import (
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
	backupPicker   navPicker
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
	blinkOn        bool

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

	fatal error
	quit  bool
}

func initialModel() model {
	m := model{
		nav:            []screen{scrMain},
		selected:       map[string]bool{},
		updateSelected: map[string]bool{},
		folderOpen:     map[string]bool{},
		setupByValue:   map[string]SetupItemRec{},
		backupChecked:  map[string]bool{},
		backupOpen:     map[string]bool{},
		backupOpts:     BackupOpts{VST: "list", Keepass: true},
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
	return tuikit.ThemeWatchCmd()
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

func (m model) updateSelectedCount() int { return len(m.updateSelected) }

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
