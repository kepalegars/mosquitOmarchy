package main

import (
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/key"
	tea "github.com/charmbracelet/bubbletea"
	tuikit "mosquitomarchy.local/tui-kit"
)

// blinkMsg drives the "mosquito" row's blink while the Setup tree is open.
// A dedicated, fast tick (rather than the 2 s theme poll) so the highlight is
// actually visible.
type blinkMsg struct{}

const blinkInterval = 600 * time.Millisecond

func blinkCmd() tea.Cmd {
	return tea.Tick(blinkInterval, func(time.Time) tea.Msg { return blinkMsg{} })
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	if em, ok := msg.(tuikit.ToastExpireMsg); ok {
		m.toast = m.toast.Expire(em.Gen)
		return m, nil
	}
	before := m.toast.Gen()
	var cmd tea.Cmd
	m, cmd = m.update(msg)
	if m.toast.Gen() != before {
		cmd = tea.Batch(cmd, m.toast.ExpireCmd())
	}
	return m, cmd
}

func (m model) update(msg tea.Msg) (model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.w, m.h = msg.Width, msg.Height
		m.mainPicker = m.mainPicker.SetSize(m.mainContentSize())
		m.setupPicker = m.setupPicker.SetSize(m.contentSize())
		m.setupCatPicker = m.setupCatPicker.SetSize(m.contentSize())
		m.updatePicker = m.updatePicker.SetSize(m.contentSize())
		m.backupPicker = m.backupPicker.SetSize(m.contentSize())
		m.backupOptPicker = m.backupOptPicker.SetSize(m.contentSize())
		m.backupAppsPicker = m.backupAppsPicker.SetSize(m.contentSize())
		m.info = m.info.SetSize(m.contentSize())
		m.runner = m.runner.SetSize(m.contentSize())
		return m, nil

	case tea.KeyMsg:
		if msg.String() == "ctrl+c" {
			if len(m.nav) == 1 {
				m.quit = true
				return m, tea.Quit
			}
			m.pop()
			return m, nil
		}

	case tuikit.ThemeTickMsg:
		tuikit.ApplyTheme()
		return m, tuikit.ThemeWatchCmd()

	case blinkMsg:
		// Blink the "mosquito" row while a Setup screen is open; stop as soon
		// as Setup is left (no re-arm).
		switch m.top() {
		case scrSetup:
			m.blinkOn = !m.blinkOn
			m.setupPicker = m.rebuildSetup()
			return m, blinkCmd()
		case scrSetupCat:
			m.blinkOn = !m.blinkOn
			m.setupCatPicker = m.rebuildSetupCat()
			return m, blinkCmd()
		}
		return m, nil

	case tuikit.RunnerLineMsg, tuikit.RunnerDoneMsg:
		var cmd tea.Cmd
		m.runner, cmd = m.runner.Update(msg)
		if _, ok := msg.(tuikit.RunnerLineMsg); ok {
			return m, cmd
		}
		if m.passphraseSet {
			os.Unsetenv("OMARCHY_BACKUP_PASSPHRASE")
			m.passphraseSet = false
		}
		if m.backupSelFile != "" {
			os.Remove(m.backupSelFile)
			m.backupSelFile = ""
		}
		// Runner finished: report, pop off the working screen and refresh
		// whatever screen we land back on.
		if m.top() == scrWorking {
			hadErr := m.runner.Err() != nil
			txt := "done"
			if hadErr {
				txt = m.runner.Err().Error()
			}
			m.pop()
			if hadErr {
				m.toast, _ = m.toast.SetErr(txt)
			} else {
				m.toast, _ = m.toast.SetOK(txt)
			}
			switch m.top() {
			case scrMain:
				return m, fetchStatusCmd()
			case scrUpdate:
				return m, fetchUpdateCheckCmd()
			}
		}
		return m, cmd

	case setupMsg:
		if msg.err != nil {
			m.toast, _ = m.toast.SetErr(msg.err.Error())
			return m, nil
		}
		m.setupFolders = msg.folders
		m.setupItems = msg.items
		m.setupByValue = make(map[string]SetupItemRec, len(msg.items))
		for _, it := range msg.items {
			m.setupByValue[setupValue(it.Folder, it.Key)] = it
		}
		if m.top() == scrSetup {
			m.setupPicker = m.rebuildSetup()
		}
		if m.top() == scrSetupCat {
			m.setupCatPicker = m.rebuildSetupCat()
		}
		return m, nil

	case backupOptionsMsg:
		if msg.err != nil {
			m.toast, _ = m.toast.SetErr(msg.err.Error())
			m.pop()
			return m, nil
		}
		m.backupFolders = msg.folders
		m.backupItems = msg.items
		m.backupOpen = map[string]bool{}
		m.backupChecked = map[string]bool{}
		for _, f := range msg.folders {
			m.backupOpen[f.Folder] = true
		}
		for _, it := range msg.items {
			if it.Checked {
				m.backupChecked[setupValue(it.Folder, it.Key)] = true
			}
		}
		m.backupOpts.HasKeep = msg.keepass
		if m.top() == scrBackupOptions {
			m.backupOptPicker = m.rebuildBackupOptions()
		}
		return m, nil

	case queryMsg:
		switch msg.kind {
		case "status":
			if msg.err != nil {
				m.toast, _ = m.toast.SetErr(msg.err.Error())
				m.pop()
				return m, nil
			}
			m.statusRecs = msg.status
			if m.top() == scrStatus {
				m.info = tuikit.NewInfo(m.statusView()).SetSize(m.contentSize())
			}
		case "backups":
			if msg.err != nil {
				m.toast, _ = m.toast.SetErr(msg.err.Error())
				m.pop()
				return m, nil
			}
			m.backupRecs = msg.backups
			if m.top() == scrBackupRestore {
				m.backupPicker = newNavPicker("", m.backupsList()).SetSize(m.contentSize())
			}
		case "update":
			if msg.err != nil {
				m.toast, _ = m.toast.SetErr(msg.err.Error())
				m.pop()
				return m, nil
			}
			m.updateRec = msg.update
			if m.top() == scrUpdate {
				m.updatePicker = m.rebuildUpdate()
			}
			if m.top() == scrSetup {
				m.setupPicker = m.rebuildSetup()
			}
		}
		return m, nil

	case tuikit.PickerResultMsg:
		return m.screenPicked(msg)

	case tuikit.PickerToggleMsg:
		switch m.top() {
		case scrSetupCat:
			v := msg.Value
			if strings.HasPrefix(v, "cat:") {
				m.toggleFolder(strings.TrimPrefix(v, "cat:"))
			} else if strings.HasPrefix(v, "item:") {
				m.toggle(v)
			}
			m.setupCatPicker = m.rebuildSetupCat()
		case scrBackupApps:
			v := msg.Value
			if strings.HasPrefix(v, "cat:") {
				toggleTreeFolder(m.backupItems, m.backupChecked, strings.TrimPrefix(v, "cat:"))
			} else if strings.HasPrefix(v, "item:") {
				if m.backupChecked[v] {
					delete(m.backupChecked, v)
				} else {
					m.backupChecked[v] = true
				}
			}
			m.backupAppsPicker = m.rebuildBackupApps()
		case scrUpdate:
			if msg.Value == "" || msg.Value == "repo" || msg.Value == "back" || msg.Value == "apply" {
				return m, nil
			}
			m.toggleUpdate(msg.Value)
			m.updatePicker = m.rebuildUpdate()
		}
		return m, nil

	case tuikit.PickerSortMsg:
		// Left/Right collapse/expand the folder under the cursor (the
		// audio-plugin-manager's folder convention), not a sort.
		switch m.top() {
		case scrSetupCat:
			folder := folderOfValue(m.setupCatPicker.SelectedValue())
			if folder == "" {
				return m, nil
			}
			if msg.Dir > 0 {
				m.folderOpen[folder] = true
			} else {
				delete(m.folderOpen, folder)
			}
			m.setupCatPicker = m.rebuildSetupCat()
		case scrBackupOptions:
			// Left/Right cycles/toggles the focused option (the "on/off /
			// short list" convention): ← previous · → next.
			switch m.backupOptPicker.SelectedValue() {
			case "vst":
				order := []string{"list", "full", "none"}
				idx := 0
				for i, v := range order {
					if v == m.backupOpts.VST {
						idx = i
					}
				}
				if msg.Dir > 0 {
					idx = (idx + 1) % len(order)
				} else {
					idx = (idx - 1 + len(order)) % len(order)
				}
				m.backupOpts.VST = order[idx]
			case "keepass":
				m.backupOpts.Keepass = !m.backupOpts.Keepass
			case "encrypt":
				m.backupOpts.Encrypt = !m.backupOpts.Encrypt
			}
			m.backupOptPicker = m.rebuildBackupOptions()
			return m, nil
		case scrBackupApps:
			folder := folderOfValue(m.backupAppsPicker.SelectedValue())
			if folder == "" {
				return m, nil
			}
			if msg.Dir > 0 {
				m.backupOpen[folder] = true
			} else {
				delete(m.backupOpen, folder)
			}
			m.backupAppsPicker = m.rebuildBackupApps()
		}
		return m, nil

	case tuikit.ConfirmResultMsg:
		if m.top() != scrConfirm {
			return m, nil
		}
		m.pop()
		if msg.Canceled || !msg.Yes {
			return m, nil
		}
		switch m.pendingAction {
		case "apply":
			return m.startWorking("Applying the selection", workingArgs("apply", m.pendingArgs)...)
		case "update":
			return m.startWorking("Re-applying modules", workingArgs("update", m.pendingArgs)...)
		case "update-modules":
			return m.startWorking("Updating modules", workingArgs("update-modules", nil)...)
		case "update-repo":
			return m.startWorking("Updating the repo", workingArgs("update-repo", nil)...)
		case "backup":
			return m.startWorking("Backing up", workingArgs("backup", m.pendingArgs)...)
		case "backup-encrypted":
			return m.startWorking("Backing up (encrypted)", workingArgs("backup", m.pendingArgs)...)
		case "restore":
			return m.startWorking("Restoring", workingArgs("restore", []string{m.pendingFile})...)
		case "menu-entry":
			return m.startWorking("Adding the menu entry", workingArgs("menu-entry", nil)...)
		case "close":
			m.quit = true
			return m, tea.Quit
		}
		return m, nil

	case tuikit.InputResultMsg:
		if m.top() != scrPassphrase {
			return m, nil
		}
		pass := msg.Value
		if msg.Canceled {
			m.pop()
			m.pendingPass = ""
			return m, nil
		}
		switch m.pendingAction {
		case "backup-encrypted":
			if pass == "" {
				m.pop()
				m.toast, _ = m.toast.SetWarn("empty passphrase — canceled")
				return m, nil
			}
			// Ask a second time and only encrypt when both entries match.
			m.pendingPass = pass
			m.pendingAction = "backup-encrypted-confirm"
			m.passInput = tuikit.NewPasswordInput("Confirm the passphrase:", "")
			return m, m.passInput.Init()
		case "backup-encrypted-confirm":
			m.pop()
			if pass != m.pendingPass {
				m.pendingPass = ""
				m.toast, _ = m.toast.SetWarn("passphrases don't match — backup canceled")
				return m, nil
			}
			// The backend's non-interactive passphrase source is the
			// OMARCHY_BACKUP_PASSPHRASE env var (never argv), so it stays out
			// of the process list. Unset again when the run finishes.
			os.Setenv("OMARCHY_BACKUP_PASSPHRASE", m.pendingPass)
			m.passphraseSet = true
			m.pendingPass = ""
			return m.startWorking("Backing up (encrypted)", workingArgs("backup", m.pendingArgs)...)
		case "restore-encrypted":
			m.pop()
			if pass == "" {
				m.toast, _ = m.toast.SetWarn("empty passphrase — canceled")
				return m, nil
			}
			os.Setenv("OMARCHY_BACKUP_PASSPHRASE", pass)
			m.passphraseSet = true
			return m.startWorking("Restoring", workingArgs("restore", []string{m.pendingFile})...)
		}
		m.pop()
		return m, nil

	case tuikit.InfoDismissedMsg:
		if m.top() == scrInfo || m.top() == scrStatus {
			m.pop()
		}
		return m, nil
	}

	// Fall through to the active screen's picker/input updates.
	var cmd tea.Cmd
	switch m.top() {
	case scrMain:
		m.mainPicker, cmd = m.mainPicker.Update(msg)
	case scrStatus:
		m.info, cmd = m.info.Update(msg)
	case scrSetup:
		if km, ok := msg.(tea.KeyMsg); ok && km.String() == "i" {
			if m.setupPicker.SelectedValue() == "menu-entry" {
				m.info = tuikit.NewInfo(menuEntryInfo).SetSize(m.contentSize())
				m.push(scrInfo)
				return m, nil
			}
		}
		m.setupPicker, cmd = m.setupPicker.Update(msg)
	case scrSetupCat:
		if km, ok := msg.(tea.KeyMsg); ok && km.String() == "i" {
			if v := m.setupCatPicker.SelectedValue(); v != "" {
				if it, ok := m.setupByValue[v]; ok {
					txt := it.Label
					if it.Info != "" {
						txt += "\n\n" + it.Info
					}
					m.info = tuikit.NewInfo(txt).SetSize(m.contentSize())
					m.push(scrInfo)
					return m, nil
				}
			}
		}
		m.setupCatPicker, cmd = m.setupCatPicker.Update(msg)
	case scrUpdate:
		m.updatePicker, cmd = m.updatePicker.Update(msg)
	case scrBackup:
		m.backupPicker, cmd = m.backupPicker.Update(msg)
	case scrBackupRestore:
		m.backupPicker, cmd = m.backupPicker.Update(msg)
	case scrBackupOptions:
		m.backupOptPicker, cmd = m.backupOptPicker.Update(msg)
	case scrBackupApps:
		m.backupAppsPicker, cmd = m.backupAppsPicker.Update(msg)
	case scrConfirm:
		m.confirm, cmd = m.confirm.Update(msg)
	case scrPassphrase:
		m.passInput, cmd = m.passInput.Update(msg)
	case scrInfo:
		m.info, cmd = m.info.Update(msg)
	case scrWorking:
		if km, ok := msg.(tea.KeyMsg); ok && (km.String() == "esc" || km.String() == "enter") {
			if m.runner.Done() {
				m.pop()
				return m, nil
			}
			if km.String() == "esc" {
				m.runner.Cancel()
			}
		}
		m.runner, cmd = m.runner.Update(msg)
	}
	return m, cmd
}

// folderOfValue returns the folder id encoded in a tree row's value (a
// folder row "cat:<id>" or one of its children "item:<id>:<key>"), or "".
func folderOfValue(v string) string {
	if strings.HasPrefix(v, "cat:") {
		return strings.TrimPrefix(v, "cat:")
	}
	if strings.HasPrefix(v, "item:") {
		rest := strings.TrimPrefix(v, "item:")
		if i := strings.Index(rest, ":"); i >= 0 {
			return rest[:i]
		}
	}
	return ""
}

// screenPicked routes a picker's Enter result.
func (m model) screenPicked(res tuikit.PickerResultMsg) (model, tea.Cmd) {
	if res.Canceled {
		// Esc at the main menu asks for the same exit confirmation as Close;
		// anywhere else it backs out one level.
		if m.top() == scrMain {
			return m.closeConfirm()
		}
		m.pop()
		if m.top() == scrSetup {
			m.setupPicker = m.rebuildSetup()
		}
		return m, nil
	}
	switch m.top() {
	case scrMain:
		switch res.Value {
		case "status":
			m.push(scrStatus)
			m.info = tuikit.NewInfo("loading…").SetSize(m.contentSize())
			return m, fetchStatusCmd()
		case "update":
			m.push(scrUpdate)
			m.updateSelected = map[string]bool{}
			m.updatePicker = newNavPicker("", []tuikit.PickerItem{{Display: "checking…", Value: "", Disabled: true}}).SetSize(m.contentSize())
			return m, fetchUpdateCheckCmd()
		case "setup":
			m.push(scrSetup)
			m.setupPicker = newNavPicker("", []tuikit.PickerItem{{Display: "loading…", Value: "", Disabled: true}}).SetSize(m.contentSize())
			// Auto-check for updates (mosquitOmarchy scripts/repo + changed
			// apps/tuis/modules) when Setup opens, so its first screen can
			// advertise them.
			return m, tea.Batch(fetchSetupCmd(), blinkCmd(), fetchUpdateCheckCmd())
		case "backup":
			m.push(scrBackup)
			m.backupPicker = newNavPicker("", backupActions()).SetSize(m.contentSize())
			return m, nil
		case "close":
			return m.closeConfirm()
		}

	case scrSetup:
		// Level 1: the category options. Entering one opens its folder tree;
		// the "Menu entry" option runs the menu registration directly.
		if res.Value == "back" {
			m.pop()
			return m, nil
		}
		if res.Value == "menu-entry" {
			m.pendingAction = "menu-entry"
			m.pendingMsg = "Add mosquitOmarchy to the Omarchy menu?\n\nRegisters (or refreshes) the entry in the Omarchy Install menu so the TUI can be opened from the launcher at any time."
			m.pendingNo = "Cancel"
			m.pendingYes = "Yes"
			m.push(scrConfirm)
			m.confirm = tuikit.NewConfirm(m.pendingMsg, m.pendingNo, m.pendingYes)
			return m, nil
		}
		if res.Value == "updates" {
			// Jump to the Update screen (repo update + changed modules).
			m.push(scrUpdate)
			m.updatePicker = m.rebuildUpdate()
			return m, fetchUpdateCheckCmd()
		}
		if res.Value == "install-selection" {
			plan := m.applyPlan()
			if len(plan) == 0 {
				m.toast, _ = m.toast.SetWarn("nothing selected")
				return m, nil
			}
			m.pendingAction = "apply"
			m.pendingArgs = plan
			m.pendingMsg = fmt.Sprintf("Install %d selected item(s)?\n\n%s", m.selectedCount(), m.selectionSummary())
			m.pendingNo = "Cancel"
			m.pendingYes = "Install"
			m.push(scrConfirm)
			m.confirm = tuikit.NewConfirm(m.pendingMsg, m.pendingNo, m.pendingYes)
			return m, nil
		}
		m.setupCat = folderOfValue(res.Value)
		m.folderOpen[m.setupCat] = true
		m.push(scrSetupCat)
		m.setupCatPicker = m.rebuildSetupCat()
		return m, nil

	case scrSetupCat:
		// Level 2: the folder tree. Enter installs ONLY the items checked in
		// this category.
		if res.Value == "back" {
			m.pop()
			m.setupPicker = m.rebuildSetup()
			return m, nil
		}
		plan := m.applyPlanCat(m.setupCat)
		if len(plan) == 0 {
			m.toast, _ = m.toast.SetWarn("nothing selected here — press tab to select items")
			return m, nil
		}
		m.pendingAction = "apply"
		m.pendingArgs = plan
		m.pendingMsg = fmt.Sprintf("Install %d selected item(s) in %s?\n\n%s",
			m.categorySelectedCount(m.setupCat), m.setupCatLabel(), m.categorySummary(m.setupCat))
		m.pendingNo = "Cancel"
		m.pendingYes = "Install"
		m.push(scrConfirm)
		m.confirm = tuikit.NewConfirm(m.pendingMsg, m.pendingNo, m.pendingYes)
		return m, nil

	case scrUpdate:
		switch res.Value {
		case "update-modules":
			m.pendingAction = "update-modules"
			ver := m.updateRec.RepoVersion
			if ver == "" {
				ver = "0.1.0"
			}
			m.pendingMsg = fmt.Sprintf("Update modules?\n\nLocal scripts repo: v%s.\n\nIf a GitHub update is available, the local repo is fast-forwarded FIRST so both versions stay in sync (joining the GitHub version), then the changed installed modules are re-applied. With no repo update (or no connection), the installed modules are re-applied from the local scripts.", ver)
			m.pendingNo = "Cancel"
			m.pendingYes = "Update"
			m.push(scrConfirm)
			m.confirm = tuikit.NewConfirm(m.pendingMsg, m.pendingNo, m.pendingYes)
			return m, nil
		case "back":
			m.pop()
			return m, nil
		}
		return m, nil

	case scrBackup:
		switch res.Value {
		case "backup":
			m.push(scrBackupOptions)
			m.backupOptPicker = newNavPicker("", []tuikit.PickerItem{{Display: "loading…", Value: "", Disabled: true}}).SetSize(m.contentSize())
			return m, fetchBackupOptionsCmd()
		case "restore":
			m.push(scrBackupRestore)
			m.backupPicker = newNavPicker("", []tuikit.PickerItem{{Display: "checking…", Value: "", Disabled: true}}).SetSize(m.contentSize())
			return m, fetchBackupsCmd()
		case "back":
			m.pop()
			return m, nil
		}

	case scrBackupOptions:
		switch res.Value {
		case "apps":
			m.push(scrBackupApps)
			m.backupAppsPicker = m.rebuildBackupApps()
			return m, nil
		case "vst":
			switch m.backupOpts.VST {
			case "list":
				m.backupOpts.VST = "full"
			case "full":
				m.backupOpts.VST = "none"
			default:
				m.backupOpts.VST = "list"
			}
			m.backupOptPicker = m.rebuildBackupOptions()
			return m, nil
		case "keepass":
			m.backupOpts.Keepass = !m.backupOpts.Keepass
			m.backupOptPicker = m.rebuildBackupOptions()
			return m, nil
		case "encrypt":
			m.backupOpts.Encrypt = !m.backupOpts.Encrypt
			m.backupOptPicker = m.rebuildBackupOptions()
			return m, nil
		case "start":
			return m.beginBackup()
		case "back":
			m.pop()
			return m, nil
		}

	case scrBackupApps:
		// Enter on any row returns to the options (the checkmarks are kept).
		m.pop()
		m.backupOptPicker = m.rebuildBackupOptions()
		return m, nil

	case scrBackupRestore:
		if res.Value == "back" {
			m.pop()
			m.backupPicker = newNavPicker("", backupActions()).SetSize(m.contentSize())
			return m, nil
		}
		m.pendingFile = res.Value
		if strings.HasSuffix(res.Value, ".gpg") {
			m.pendingAction = "restore-encrypted"
			m.push(scrPassphrase)
			m.passInput = tuikit.NewPasswordInput("Passphrase for "+res.Value+":", "")
			return m, m.passInput.Init()
		}
		m.pendingAction = "restore"
		label := res.Value
		for _, b := range m.backupRecs {
			if b.File == res.Value {
				label = b.File + " (" + b.Size + ", " + b.Date + ")"
			}
		}
		m.pendingMsg = "Restore the backup " + label + "?\n\nOverwrites the files it contains with the archived versions."
		m.pendingNo = "Cancel"
		m.pendingYes = "Restore"
		m.push(scrConfirm)
		m.confirm = tuikit.NewConfirm(m.pendingMsg, m.pendingNo, m.pendingYes)
		return m, nil
	}
	return m, nil
}

// closeConfirm opens the "Close mosquitOmarchy?" confirmation, shared by the
// Close row and by Esc at the main menu.
func (m model) closeConfirm() (model, tea.Cmd) {
	m.pendingAction = "close"
	m.pendingMsg = "Close mosquitOmarchy?\n\nNothing is changed — you can reopen it from the Omarchy menu at any time."
	m.pendingNo = "Cancel"
	m.pendingYes = "Close"
	m.push(scrConfirm)
	m.confirm = tuikit.NewConfirm(m.pendingMsg, m.pendingNo, m.pendingYes)
	return m, nil
}

// startWorking swaps to the runner screen and starts a streamed action.
// args are the full mosquitomarchy-actions command line (subcommand first).
func (m model) startWorking(label string, args ...string) (model, tea.Cmd) {
	m.replace(scrWorking)
	m.runner = tuikit.NewRunner().SetSize(m.contentSize())
	var cmd tea.Cmd
	m.runner, cmd = m.runner.Start(label, actionsBin(), args...)
	return m, cmd
}

// workingArgs returns the action's full command line with a leading
// subcommand plus the given positional arguments.
func workingArgs(sub string, args []string) []string {
	out := make([]string, 0, len(args)+1)
	out = append(out, sub)
	out = append(out, args...)
	return out
}

// rebuildSetup rebuilds the LEVEL-1 Setup picker: the categories as plain
// options. The folder tree lives one level down (rebuildSetupCat), so the
// horizontal arrows are not used here.
func (m model) rebuildSetup() navPicker {
	idx := m.setupPicker.Index()
	items := make([]tuikit.PickerItem, 0, len(m.setupFolders)+4)
	// Advertise available updates first (mosquitOmarchy scripts/repo + the
	// changed apps/tuis/modules the update-check found) so Setup surfaces them
	// automatically.
	if n := len(m.updateRec.Modules); m.updateRec.RepoUpdate || n > 0 {
		label := "⟳ mosquitOmarchy update available — update the repo/scripts"
		if !m.updateRec.RepoUpdate && n > 0 {
			label = fmt.Sprintf("⟳ %d module update(s) available", n)
		}
		items = append(items, tuikit.PickerItem{Display: label, Value: "updates"})
	}
	for _, f := range m.setupFolders {
		it := tuikit.PickerItem{Display: f.Label, Value: folderValue(f.Folder)}
		total := len(m.setupItemsOf(f.Folder))
		if sel := m.categorySelectedCount(f.Folder); sel > 0 {
			// A square (like the audio manager's applied-fix badge) plus the
			// selected count: this category has checked items in its submenu.
			it.Suffix = fmt.Sprintf("  (%d/%d)", sel, total)
			it.TrailingBadge = "■"
		} else if total > 0 {
			it.Suffix = fmt.Sprintf("  (%d)", total)
		}
		if f.Accent {
			it.Accent = m.blinkOn
		}
		items = append(items, it)
	}
	items = append(items, tuikit.PickerItem{Display: "Menu entry", Value: "menu-entry"})
	install := tuikit.PickerItem{Display: "Install selection", Value: "install-selection"}
	if m.selectedCount() == 0 {
		install.Disabled = true
	}
	items = append(items, install)
	items = append(items, tuikit.PickerItem{Display: "Back", Value: "back"})
	return newNavPicker("", items).SetSize(m.contentSize()).SelectIndex(idx)
}

// categorySelectedCount counts the checked items of one category.
func (m model) categorySelectedCount(cat string) int {
	n := 0
	for _, it := range m.setupItemsOf(cat) {
		if m.selected[setupValue(cat, it.Key)] {
			n++
		}
	}
	return n
}

// selectionSummary lists every checked item grouped by category, one line per
// category ("Category: item, item").
func (m model) selectionSummary() string {
	var b strings.Builder
	for _, f := range m.setupFolders {
		var names []string
		for _, it := range m.setupItemsOf(f.Folder) {
			if m.selected[setupValue(f.Folder, it.Key)] {
				names = append(names, it.Label)
			}
		}
		if len(names) > 0 {
			b.WriteString(f.Label + ":\n  " + strings.Join(names, "\n  ") + "\n")
		}
	}
	return strings.TrimRight(b.String(), "\n")
}

// categorySummary lists the checked items of ONE category, one per line.
func (m model) categorySummary(cat string) string {
	var names []string
	for _, it := range m.setupItemsOf(cat) {
		if m.selected[setupValue(cat, it.Key)] {
			names = append(names, it.Label)
		}
	}
	return strings.Join(names, "\n")
}

// menuEntryInfo is the "i" popup for the Setup "Menu entry" option.
const menuEntryInfo = "Menu entry\n\nAdds (or refreshes) the mosquitOmarchy entry in the Omarchy Install menu — Omarchy menu → Install → mosquitOmarchy — so this TUI can be opened at any time from the launcher without a terminal or a manual path.\n\nIdempotent: running it again just keeps the entry up to date."

// setupCatLabel returns the display label of the open category.
func (m model) setupCatLabel() string {
	for _, f := range m.setupFolders {
		if f.Folder == m.setupCat {
			return f.Label
		}
	}
	return m.setupCat
}

// rebuildSetupCat rebuilds the LEVEL-2 folder tree for the open category,
// preserving the cursor and restoring the folder help keys.
func (m model) rebuildSetupCat() navPicker {
	idx := m.setupCatPicker.Index()
	folders := make([]FolderRec, 0, 1)
	items := make([]SetupItemRec, 0, 8)
	for _, f := range m.setupFolders {
		if f.Folder == m.setupCat {
			folders = append(folders, f)
		}
	}
	for _, it := range m.setupItems {
		if it.Folder == m.setupCat {
			items = append(items, it)
		}
	}
	p := newNavPicker("", pickerTreeItems(folders, items, m.selected, m.folderOpen, m.blinkOn)).SetSize(m.contentSize()).
		SetHelpKeys(
			key.NewBinding(key.WithKeys("tab"), key.WithHelp("tab", "select")),
			key.NewBinding(key.WithKeys("i"), key.WithHelp("i", "info")),
			key.NewBinding(key.WithKeys("right"), key.WithHelp("→", "expand")),
			key.NewBinding(key.WithKeys("left"), key.WithHelp("←", "collapse")),
			key.NewBinding(key.WithKeys("enter"), key.WithHelp("enter", "install selection")),
		)
	return p.SelectIndex(idx)
}

// backupTreeItems is the same tree for the backup content selection.
func (m model) backupTreeItems() []tuikit.PickerItem {
	return pickerTreeItems(m.backupFolders, m.backupItems, m.backupChecked, m.backupOpen, false)
}

// pickerTreeItems builds the shared folder/item tree rows: a ▸/▾ chevron, an
// aggregate ●/○ mark and the label per folder, and indented ├─/└─ children
// with their own ●/○ marks when the folder is open. blinkOn toggles the
// Accent flag on rows whose folder sets Accent (the blinking "mosquito").
func pickerTreeItems(folders []FolderRec, items []SetupItemRec, checked, open map[string]bool, blinkOn bool) []tuikit.PickerItem {
	itemsOf := func(folder string) []SetupItemRec {
		out := make([]SetupItemRec, 0, 8)
		for _, it := range items {
			if it.Folder == folder {
				out = append(out, it)
			}
		}
		return out
	}
	out := make([]tuikit.PickerItem, 0, len(items)+len(folders)+1)
	for _, f := range folders {
		children := itemsOf(f.Folder)
		marked := 0
		for _, it := range children {
			if checked[setupValue(f.Folder, it.Key)] {
				marked++
			}
		}
		mark := "○"
		if len(children) > 0 && marked == len(children) {
			mark = "●"
		}
		chevron := "▸"
		if open[f.Folder] {
			chevron = "▾"
		}
		out = append(out, tuikit.PickerItem{
			Display: chevron + " " + mark + "  " + f.Label,
			Value:   folderValue(f.Folder),
			Accent:  f.Accent && blinkOn,
		})
		if open[f.Folder] {
			last := len(children) - 1
			for i, it := range children {
				pmark := "○"
				if checked[setupValue(f.Folder, it.Key)] {
					pmark = "●"
				}
				branch := "├─ "
				if i == last {
					branch = "└─ "
				}
				out = append(out, tuikit.PickerItem{
					Display: "    " + branch + pmark + "  " + it.Label,
					Value:   setupValue(f.Folder, it.Key),
				})
			}
		}
	}
	out = append(out, tuikit.PickerItem{Display: "Back", Value: "back"})
	return out
}

// rebuildUpdate rebuilds the Update screen picker with ○/● checkboxes, the
// "Apply N" row and (when the repo has changes) the repo-update row.
func (m model) rebuildUpdate() navPicker {
	idx := m.updatePicker.Index()
	hasUpdate := m.updateRec.RepoUpdate || len(m.updateRec.Modules) > 0
	upd := tuikit.PickerItem{Display: "Update modules", Value: "update-modules"}
	if !hasUpdate {
		upd.Disabled = true
	}
	items := []tuikit.PickerItem{
		upd,
		{Display: "Back", Value: "back"},
	}
	p := newNavPicker("", items).SetSize(m.contentSize()).
		SetHelpKeys(key.NewBinding(key.WithKeys("enter"), key.WithHelp("enter", "update")))
	return p.SelectIndex(idx)
}

func categoryItems(cats []CatRec) []tuikit.PickerItem {
	items := make([]tuikit.PickerItem, 0, len(cats)+1)
	for _, c := range cats {
		items = append(items, tuikit.PickerItem{Display: c.Label, Value: c.Id})
	}
	items = append(items, tuikit.PickerItem{Display: "Back", Value: "back"})
	return items
}

func backupActions() []tuikit.PickerItem {
	return []tuikit.PickerItem{
		{Display: "Back up now…", Value: "backup"},
		{Display: "Restore from a backup", Value: "restore"},
		{Display: "Back", Value: "back"},
	}
}

// rebuildBackupOptions rebuilds the "what to include" options picker. Enter
// on a row changes it (cycles/toggles) or navigates.
func (m model) rebuildBackupOptions() navPicker {
	idx := m.backupOptPicker.Index()
	vst := "list only"
	switch m.backupOpts.VST {
	case "full":
		vst = "full files (~hundreds of MB)"
	case "none":
		vst = "skip"
	}
	items := []tuikit.PickerItem{
		{Display: fmt.Sprintf("Apps / TUIs / webapps: %d selected", len(m.backupChecked)), Value: "apps"},
		{Display: "VST plugins: " + vst, Value: "vst"},
	}
	if m.backupOpts.HasKeep {
		items = append(items, tuikit.PickerItem{Display: "KeePassXC passwords: " + yesno(m.backupOpts.Keepass), Value: "keepass"})
	}
	enc := "no"
	if m.backupOpts.Encrypt {
		enc = "yes — passphrase (AES-256)"
	}
	items = append(items,
		tuikit.PickerItem{Display: "Encrypt: " + enc, Value: "encrypt"},
		tuikit.PickerItem{Display: "Start the backup", Value: "start"},
		tuikit.PickerItem{Display: "Back", Value: "back"},
	)
	p := newNavPicker("", items).SetSize(m.contentSize()).
		SetHelpKeys(key.NewBinding(key.WithKeys("enter"), key.WithHelp("enter", "change/start")))
	return p.SelectIndex(idx)
}

// rebuildBackupApps rebuilds the backup content tree picker.
func (m model) rebuildBackupApps() navPicker {
	idx := m.backupAppsPicker.Index()
	p := newNavPicker("", m.backupTreeItems()).SetSize(m.contentSize()).
		SetHelpKeys(
			key.NewBinding(key.WithKeys("tab"), key.WithHelp("tab", "select")),
			key.NewBinding(key.WithKeys("right"), key.WithHelp("→", "expand")),
			key.NewBinding(key.WithKeys("left"), key.WithHelp("←", "collapse")),
			key.NewBinding(key.WithKeys("enter"), key.WithHelp("enter", "done")),
		)
	return p.SelectIndex(idx)
}

func yesno(b bool) string {
	if b {
		return "yes"
	}
	return "no"
}

// beginBackup writes the apps.selected content the user checked to a temp
// file, then starts the backup (asking for a passphrase first when encrypting).
func (m model) beginBackup() (model, tea.Cmd) {
	f, err := os.CreateTemp("", "mosquitomarchy-apps-selected-")
	if err != nil {
		m.toast, _ = m.toast.SetErr(err.Error())
		return m, nil
	}
	fmt.Fprintln(f, "# apps.selected — written by the mosquitOmarchy TUI (backup)")
	for _, it := range m.backupItems {
		if m.backupChecked[setupValue(it.Folder, it.Key)] {
			fmt.Fprintln(f, it.Key)
		}
	}
	f.Close()
	m.backupSelFile = f.Name()
	m.pendingArgs = []string{
		"--vst=" + m.backupOpts.VST,
		"--keepass=" + yesno(m.backupOpts.Keepass),
		"--selection=" + m.backupSelFile,
	}
	if m.backupOpts.Encrypt {
		m.pendingAction = "backup-encrypted"
		m.push(scrPassphrase)
		m.passInput = tuikit.NewPasswordInput("Backup passphrase (AES-256):", "")
		return m, m.passInput.Init()
	}
	m.pendingAction = "backup"
	m.pendingMsg = fmt.Sprintf("Create a dated backup now?\n\nApps/TUIs/webapps: %d selected · VST: %s · KeePassXC: %s",
		len(m.backupChecked), m.backupOpts.VST, yesno(m.backupOpts.Keepass))
	m.pendingNo = "Cancel"
	m.pendingYes = "Backup"
	m.push(scrConfirm)
	m.confirm = tuikit.NewConfirm(m.pendingMsg, m.pendingNo, m.pendingYes)
	return m, nil
}

func (m model) backupsList() []tuikit.PickerItem {
	items := make([]tuikit.PickerItem, 0, len(m.backupRecs)+1)
	for _, b := range m.backupRecs {
		items = append(items, tuikit.PickerItem{
			Display: b.File + "  (" + b.Size + ", " + b.Date + ")",
			Value:   b.File,
		})
	}
	if len(items) == 0 {
		items = append(items, tuikit.PickerItem{Display: "no backup found in ~/omarchy-backups", Value: "", Disabled: true})
	}
	items = append(items, tuikit.PickerItem{Display: "Back", Value: "back"})
	return items
}

// statusView builds the module status text with state dots.
func (m model) statusView() string {
	var b strings.Builder
	for _, s := range m.statusRecs {
		dot := "·"
		switch s.State {
		case "ok":
			dot = tuikit.StyleOK.Render("●")
		case "partial":
			dot = tuikit.StyleWarn.Render("◐")
		case "missing":
			dot = tuikit.StyleErr.Render("○")
		case "na":
			dot = tuikit.StyleMuted.Render("·")
		}
		label := s.Label
		if s.Excluded {
			label += tuikit.StyleMuted.Render("  (uninstalled by you)")
		}
		b.WriteString(dot + "  " + label + "\n\n")
	}
	return b.String()
}

func backupItems(items []tuikit.PickerItem) []tuikit.PickerItem { return items }
