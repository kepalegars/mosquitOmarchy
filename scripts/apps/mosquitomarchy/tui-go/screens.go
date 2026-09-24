package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
	"unicode"

	"github.com/charmbracelet/bubbles/key"
	tea "github.com/charmbracelet/bubbletea"
	tuikit "mosquitomarchy.local/tui-kit"
)

// firstRunMsg is delivered once, at startup, when the "add a shortcut?" question
// has never been answered (marker file absent).
type firstRunMsg struct{}

func shortcutMarkerPath() string {
	return filepath.Join(os.Getenv("HOME"), ".local/state/mosquitomarchy/shortcut-prompted")
}

func firstRunCmd() tea.Cmd {
	return func() tea.Msg {
		if _, err := os.Stat(shortcutMarkerPath()); err != nil {
			return firstRunMsg{}
		}
		return nil
	}
}

// markShortcutPrompted records that the first-run shortcut question was asked,
// so it is never asked again.
func markShortcutPrompted() {
	_ = os.MkdirAll(filepath.Dir(shortcutMarkerPath()), 0o755)
	_ = os.WriteFile(shortcutMarkerPath(), []byte("1\n"), 0o644)
}

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
		// whatever screen we land back on. A success toast is shown ONLY when
		// the run really succeeded. The FINAL STATE decides: the backend is
		// authoritative (it verifies every installed piece against the disk —
		// module_state checks — and exits non-zero when something did not
		// land), so a non-zero exit is the one failure signal here. Output
		// markers (✗/ERROR) are NOT consulted: scripts print them for
		// recoverable sub-steps, which used to flag whole successful runs
		// ("installation failed" false positives).
		if m.top() == scrWorking {
			out := m.runner.Output()
			m.lastOutput = out
			hadErr := m.runner.Err() != nil
			m.pop()
			if hadErr {
				// One dated log per failed run + clickable AI diagnosis; the
				// exit code goes in the header so a success-looking log with
				// a non-zero exit is diagnosable on sight.
				rerr := m.runner.Err()
				if rerr != nil {
					out = fmt.Sprintf("# exit: %v\n%s", rerr, out)
				}
				reportCrash(m.workingLabel, out)
				m.toast, _ = m.toast.SetErr("finished with errors")
				m.pendingAction = "run-errors"
				m.pendingMsg = "The action finished with errors.\n\nView the full log, or go back?"
				m.pendingNo = "Back"
				m.pendingYes = "View the log"
				m.push(scrConfirm)
				m.confirm = tuikit.NewConfirm(m.pendingMsg, m.pendingNo, m.pendingYes)
				return m, nil
			}
			m.toast, _ = m.toast.SetOK("done")
			// A successful run consumed the selection: clear the checkmarks so
			// the tree does not keep the installed/removed items ticked.
			if m.pendingAction == "apply" || m.pendingAction == "uninstall" {
				m.selected = map[string]bool{}
				if m.top() == scrSetupCat {
					m.setupCatPicker = m.rebuildSetupCat()
				} else if m.top() == scrSetup {
					m.setupPicker = m.rebuildSetup()
				}
			}
			// After a successful app apply, propose the patch script(s) that are
			// actually present (and stay silent when there is none).
			if m.pendingAction == "apply" && len(m.pendingArgs) > 0 {
				return m, fetchPatchesCmd(m.pendingArgs)
			}
			// Keybindings writes: always offer the Hyprland reload that makes
			// them live (and validates the config), then refresh the list.
			switch m.pendingAction {
			case "kb-remove":
				for _, k := range m.pendingArgs {
					delete(m.kbSel, k)
				}
				m.pendingAction = "kb-reload-ask"
				m.pendingMsg = "Reload Hyprland now to apply the change and validate the config?"
				m.pendingNo = "Later"
				m.pendingYes = "Reload"
				m.push(scrConfirm)
				m.confirm = tuikit.NewConfirm(m.pendingMsg, m.pendingNo, m.pendingYes)
				return m, nil
			case "kb-reset":
				m.kbSel = map[string]bool{}
				m.pendingAction = "kb-reload-ask"
				m.pendingMsg = "Reload Hyprland now to apply the change and validate the config?"
				m.pendingNo = "Later"
				m.pendingYes = "Reload"
				m.push(scrConfirm)
				m.confirm = tuikit.NewConfirm(m.pendingMsg, m.pendingNo, m.pendingYes)
				return m, nil
			case "kb-add":
				delete(m.kbSel, m.pendingArgs[0])
				m.pendingAction = "kb-reload-ask"
				m.pendingMsg = "Reload Hyprland now to apply the change and validate the config?"
				m.pendingNo = "Later"
				m.pendingYes = "Reload"
				m.push(scrConfirm)
				m.confirm = tuikit.NewConfirm(m.pendingMsg, m.pendingNo, m.pendingYes)
				return m, nil
			case "kb-reload":
				return m, fetchKbCmd()
			}
			// A global uninstall also removes the keybindings the user ticked
			// on the Uninstall ▸ keybindings screen (the selection persists
			// while walking the other uninstall pages).
			if m.pendingAction == "uninstall" {
				keys := m.kbCheckedKeys()
				if len(keys) > 0 {
					m.kbSel = map[string]bool{}
					m.pendingAction = "kb-remove"
					return m.startWorking("Removing the selected keybindings", workingArgs("kb-remove", keys)...)
				}
			}
			// After an uninstall, refresh the installed-only tree so the entry
			// disappears from the list.
			if m.pendingAction == "uninstall" {
				return m, fetchTreeCmd("uninstall-tree")
			}
			switch m.top() {
			case scrMain:
				return m, fetchStatusCmd()
			case scrUpdate:
				return m, fetchUpdateCheckCmd()
			}
		}
		return m, cmd

	case firstRunMsg:
		// First ever launch: offer to add the global shortcut, once.
		if m.top() == scrMain {
			m.pendingAction = "add-shortcut"
			m.pendingMsg = "Add a keyboard shortcut (SUPER + ALT + M) to open mosquitOmarchy at any time?"
			m.pendingNo = "Not now"
			m.pendingYes = "Add shortcut"
			m.push(scrConfirm)
			m.confirm = tuikit.NewConfirm(m.pendingMsg, m.pendingNo, m.pendingYes)
		}
		return m, nil

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
			// Everything found changed is preselected: the Update screen
			// lists the modules with ● marks and the user can un-tick any
			// module they want to skip before pressing Update.
			m.preselectUpdate()
			if m.top() == scrUpdate {
				m.updatePicker = m.rebuildUpdate()
			}
			if m.top() == scrHealth {
				m.healthPicker = m.rebuildHealth()
			}
			if m.top() == scrKBList {
				m.kbListPicker = m.rebuildKBList()
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
				// KeePassXC REPLACES gnome-keyring completely: ticking its row
				// in the SETUP tree triggers an explicit consent prompt —
				// declining un-ticks it. The Uninstall tree never asks again.
				if m.treeMode == "install" && strings.HasSuffix(v, ":keepassxc") && m.selected[v] {
					// Rebuild FIRST so the ticked row shows up even while the
					// consent prompt is on screen (the prompt pops over it).
					m.setupCatPicker = m.rebuildSetupCat()
					m.pendingAction = "keepassxc-consent"
					m.pendingArgs = []string{v}
					m.pendingMsg = "Select KeePassXC secret service?\n\nIt REPLACES gnome-keyring completely:\n• your existing gnome-keyring secrets must be migrated to KeePassXC MANUALLY (password/settings transfer comes later);\n• a second prompt during the install asks whether to also remove the gnome-keyring package — its settings stay on disk either way, reinstalling it recovers them;\n• uninstalling this module restores the Omarchy default (gnome-keyring)."
					m.pendingNo = "Cancel"
					m.pendingYes = "Select it"
					m.push(scrConfirm)
					// Focus Yes: plain Enter = "Select it" (the common answer).
					m.confirm = tuikit.NewConfirm(m.pendingMsg, m.pendingNo, m.pendingYes).SetFocus(1)
					return m, nil
				}
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
		case scrHealth:
			m.toggleHealth(msg.Value)
			m.healthPicker = m.rebuildHealth()
		case scrSetup:
			if strings.HasPrefix(msg.Value, "item:") {
				m.toggle(msg.Value)
				m.setupPicker = m.rebuildSetup()
			}
		case scrKBList:
			if strings.HasPrefix(msg.Value, "kb:") {
				v := strings.TrimPrefix(msg.Value, "kb:")
				if m.kbSel[v] {
					delete(m.kbSel, v)
				} else {
					m.kbSel[v] = true
				}
				m.kbListPicker = m.rebuildKBList()
			}
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
		if m.pendingAction == "add-shortcut" {
			// Answered either way: never ask again.
			markShortcutPrompted()
		}
		m.pop()
		if msg.Canceled || !msg.Yes {
			if m.pendingAction == "kb-reload-ask" {
				return m, fetchKbCmd() // declined reload: refresh the list anyway
			}
			if m.pendingAction == "keepassxc-consent" {
				// Declined: un-tick the module back so it is never installed
				// without this explicit consent.
				if len(m.pendingArgs) > 0 {
					delete(m.selected, m.pendingArgs[0])
					m.setupCatPicker = m.rebuildSetupCat()
				}
				m.toast, _ = m.toast.SetWarn("keepassxc un-ticked")
				return m, nil
			}
			if m.pendingAction == "keepassxc-gnomerm" {
				// Declined = KEEP the gnome-keyring package. This is a
				// legitimate answer, not a cancel: continue the apply.
				m.kpxGnomeRm = 2
				os.Setenv("MOSQUITOMARCHY_KEEPASSXC_REMOVE_GNOME_KEYRING", "0")
				return m, fetchMissingAssetsCmd(m.pendingArgs)
			}
			return m, nil
		}
		if m.pendingAction == "keepassxc-consent" {
			// Accepted: keep the selection; the module is in the plan only
			// when the user installs it with Enter as usual.
			m.toast, _ = m.toast.SetOK("keepassxc selected — the gnome-keyring questions come during the install")
			// Refresh the visible tree immediately so the tick reads
			// without having to leave the Plugins screen.
			m.setupCatPicker = m.rebuildSetupCat()
			return m, nil
		}
		switch m.pendingAction {
		case "keepassxc-gnomerm":
			if msg.Yes {
				m.kpxGnomeRm = 1
				os.Setenv("MOSQUITOMARCHY_KEEPASSXC_REMOVE_GNOME_KEYRING", "1")
			} else {
				m.kpxGnomeRm = 2
				os.Setenv("MOSQUITOMARCHY_KEEPASSXC_REMOVE_GNOME_KEYRING", "0")
			}
			// Continue the apply that was interrupted by this question.
			return m, fetchMissingAssetsCmd(m.pendingArgs)
		case "add-shortcut":
			return m.startWorking("Adding the shortcut", workingArgs("add-shortcut", nil)...)
		case "kb-add":
			return m.startWorking("Binding the key", workingArgs("kb-add", m.pendingArgs)...)
		case "kb-remove":
			return m.startWorking("Removing keybindings", workingArgs("kb-remove", m.pendingArgs)...)
		case "kb-reset":
			return m.startWorking("Resetting keybindings", workingArgs("kb-reset", nil)...)
		case "kb-reload-ask":
			return m.startWorking("Reloading Hyprland", workingArgs("kb-reload", nil)...)
		case "apply":
			// KeePassXC's SECOND question (remove the gnome-keyring package?)
			// belongs to the INSTALL moment: ask once, then forward the
			// decision to the script through the environment. Cancel = keep.
			if planHasKeepassxc(m.pendingArgs) && m.kpxGnomeRm == 0 {
				m.pendingAction = "keepassxc-gnomerm"
				m.pendingMsg = "Remove the gnome-keyring package during the install?\n\nIts settings stay on the disk — reinstalling gnome-keyring (pacman -S gnome-keyring) recovers them. Refusing keeps the package; only its session daemon is shadowed."
				m.pendingNo = "Keep it"
				m.pendingYes = "Remove it"
				m.push(scrConfirm)
				m.confirm = tuikit.NewConfirm(m.pendingMsg, m.pendingNo, m.pendingYes)
				return m, nil
			}
			// Pre-flight: some apps need a manually-downloaded installer. Check
			// BEFORE running so a missing file becomes a clear prompt naming it,
			// instead of a failure buried in the run log.
			return m, fetchMissingAssetsCmd(m.pendingArgs)
		case "update":
			return m.startWorking("Re-applying modules", workingArgs("update", m.pendingArgs)...)
		case "update-modules":
			if n := m.updateSelectedCount(); n == 0 && len(m.updateRec.Modules) > 0 {
				m.toast, _ = m.toast.SetWarn("all modules skipped — press tab on the Update screen to re-include them")
				return m, nil
			}
			return m.startWorking("Updating modules", workingArgs("update-modules", m.updateKeys())...)
		case "update-repo":
			return m.startWorking("Updating the repo", workingArgs("update-repo", nil)...)
		case "backup":
			return m.startWorking("Backing up", workingArgs("backup", m.pendingArgs)...)
		case "backup-encrypted":
			return m.startWorking("Backing up (encrypted)", workingArgs("backup", m.pendingArgs)...)
		case "restore":
			return m.startWorking("Restoring", workingArgs("restore", []string{m.pendingFile})...)
		case "toggle-crash-notify":
			if crashNotify() {
				_, _ = runQuick("crash-notify", "off")
			} else {
				_, _ = runQuick("crash-notify", "on")
			}
			if m.top() == scrSettings {
				m.pickPicker = newNavPicker("Settings:", settingsItems2()).SetSize(m.contentSize())
			} else if m.top() == scrSetup {
				m.setupPicker = m.rebuildSetup()
			}
			return m, nil
		case "menu-entry":
			return m.startWorking("Adding the menu entry", workingArgs("menu-entry", nil)...)
		case "apply-patches":
			args := append([]string{"apps"}, m.pendingPatchKeys...)
			return m.startWorking("Applying the patch", workingArgs("run-patch", args)...)
		case "remove-patches":
			args := append([]string{"apps"}, m.pendingPatchKeys...)
			return m.startWorking("Removing the patch", workingArgs("remove-patch", args)...)
		case "heal":
			return m.startWorking("Re-applying the missing pieces", workingArgs("heal", m.pendingArgs)...)
		case "uninstall":
			return m.startWorking("Uninstalling", workingArgs("uninstall", m.pendingArgs)...)
		case "close":
			m.quit = true
			return m, tea.Quit
		case "run-errors":
			// Show the full streamed log in the scrollable Info screen; the
			// prompt itself was already popped, so closing the log returns to
			// the previous menu.
			m.info = tuikit.NewInfo(m.lastOutput).SetSize(m.contentSize())
			m.push(scrInfo)
			return m, nil
		}
		return m, nil

	case tuikit.InputResultMsg:
		if m.top() != scrPassphrase && m.top() != scrKBInput {
			return m, nil
		}
		if m.top() == scrKBInput {
			if msg.Canceled || msg.Value == "" {
				m.toast, _ = m.toast.SetWarn("cancelled — the label and the command are both required")
				return m, nil
			}
			if strings.Contains(msg.Value, "\"") {
				m.toast, _ = m.toast.SetWarn("quotes are not allowed")
				return m, m.kbInput.Init()
			}
			if m.kbInputStep == 0 {
				m.kbCustomLabel = msg.Value
				m.kbInputStep = 1
				m.kbInput = tuikit.NewTextInput("Command to run:", "")
				return m, m.kbInput.Init()
			}
			m.kbPending = KbCatItem{Label: m.kbCustomLabel, Cmd: msg.Value, Type: "cmd"}
			m.kbInputStep = 0
			return m, fetchKbFreeCmd()
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

	case missingAssetsMsg:
		// A selection mentions an app whose manually-downloaded installer is
		// missing: name the exact file(s) and stop instead of running anything.
		if msg.err != nil || len(msg.items) == 0 {
			if len(msg.plan) == 0 {
				return m, nil
			}
			return m.startWorking("Applying the selection", workingArgs("apply", msg.plan)...)
		}
		var b strings.Builder
		b.WriteString("Cannot install — missing installer file(s).\n\n")
		b.WriteString("Download and drop them in the module folder, then retry:\n\n")
		for _, it := range msg.items {
			fmt.Fprintf(&b, "  • %s\n", it.Label)
			fmt.Fprintf(&b, "      file : %s\n", it.File)
			if it.URL != "" {
				fmt.Fprintf(&b, "      from : %s\n", it.URL)
			}
			if it.Note != "" {
				fmt.Fprintf(&b, "      note : %s\n", it.Note)
			}
			b.WriteString("\n")
		}
		m.info = tuikit.NewInfo(b.String()).SetSize(m.contentSize())
		m.push(scrInfo)
		return m, nil

	case patchesMsg:
		// Post-install: no patch script present (or the check failed) → just
		// refresh. Otherwise propose to run it, naming the app(s).
		if msg.err != nil || len(msg.items) == 0 {
			switch m.top() {
			case scrMain:
				return m, fetchStatusCmd()
			case scrUpdate:
				return m, fetchUpdateCheckCmd()
			}
			return m, nil
		}
		keys := make([]string, 0, len(msg.items))
		labels := make([]string, 0, len(msg.items))
		for _, it := range msg.items {
			keys = append(keys, it.Key)
			labels = append(labels, it.Label)
		}
		m.pendingPatchKeys = keys
		m.pendingAction = "apply-patches"
		m.pendingMsg = "Patch script available for: " + strings.Join(labels, ", ") + "\n\nApply it now?"
		m.pendingNo = "Not now"
		m.pendingYes = "Apply patch"
		m.push(scrConfirm)
		m.confirm = tuikit.NewConfirm(m.pendingMsg, m.pendingNo, m.pendingYes)
		return m, nil

	case healthMsg:
		if msg.err != nil {
			m.toast, _ = m.toast.SetErr("health check failed")
			return m, nil
		}
		if len(msg.items) == 0 {
			m.toast, _ = m.toast.SetOK("health check: everything is in place")
			return m, nil
		}
		// Missing pieces are the screen's rows: every one becomes a tab-toggle
		// row (all checked, since they're all there to be re-applied). Enter
		// re-applies only the kept rows — same multi-select convention as the
		// Setup/Update lists.
		m.healthItems = msg.items
		m.healthChecked = map[string]bool{}
		for _, it := range msg.items {
			m.healthChecked[it.ID] = true
		}
		m.push(scrHealth)
		m.healthPicker = m.rebuildHealth()
		return m, nil

	case kbMsg:
		if msg.err != nil {
			m.toast, _ = m.toast.SetErr("keybindings: " + msg.err.Error())
			if m.top() == scrKB || m.top() == scrKBList {
				m.pop()
			}
			return m, nil
		}
		m.kbItems = msg.items
		if m.top() == scrKBList {
			m.kbListPicker = m.rebuildKBList()
		}
		return m, nil

	case kbFreeMsg:
		if msg.err != nil {
			m.toast, _ = m.toast.SetErr("keybindings: " + msg.err.Error())
			return m, nil
		}
		m.kbFree = msg.keys
		m.push(scrKBKeys)
		m.kbKeyPicker = m.rebuildKBKeys()
		return m, nil

	case patchSecretMsg:
		// Secret "p": install mode proposes to PATCH every selection that has a
		// patch script; uninstall mode proposes to REMOVE only the patches that
		// are actually applied.
		var want []PatchRec
		for _, it := range msg.items {
			if msg.remove && !it.Applied {
				continue
			}
			want = append(want, it)
		}
		if len(want) == 0 {
			if msg.remove {
				m.toast, _ = m.toast.SetWarn("no installed patch to remove")
			} else {
				m.toast, _ = m.toast.SetWarn("no patch available for the selection")
			}
			return m, nil
		}
		keys := make([]string, 0, len(want))
		labels := make([]string, 0, len(want))
		for _, it := range want {
			keys = append(keys, it.Key)
			labels = append(labels, it.Label)
		}
		m.pendingPatchKeys = keys
		if msg.remove {
			m.pendingAction = "remove-patches"
			m.pendingMsg = "Remove the patch for: " + strings.Join(labels, ", ") + "?\n\nRestores the original files."
			m.pendingYes = "Remove patch"
		} else {
			m.pendingAction = "apply-patches"
			m.pendingMsg = "Apply the patch for: " + strings.Join(labels, ", ") + "?"
			m.pendingYes = "Apply patch"
		}
		m.pendingNo = "Cancel"
		m.push(scrConfirm)
		m.confirm = tuikit.NewConfirm(m.pendingMsg, m.pendingNo, m.pendingYes)
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
		// 'f' toggles the filter zone above the shortcut bar: a rectangular
		// search input that echoes every pressed key in real time.
		if km, ok := msg.(tea.KeyMsg); ok {
			switch km.String() {
			case "F", "shift+F":
				if m.filterOpen {
					// Closing also clears the filter (list resets full).
					m.filterOpen = false
					m.filterText = ""
				} else {
					m.filterOpen = true
				}
				m.setupPicker = m.rebuildSetup()
				return m, nil
			}
		}
		if m.filterOpen {
			// While the filter zone is open, printable keys update the live
			// tree filter (the list flattens to matching leaf rows) and
			// BACKSPACE refines; esc closes the zone.
			if km, ok := msg.(tea.KeyMsg); ok {
				switch {
				case km.String() == "backspace" && m.filterText != "":
					r := []rune(m.filterText)
					m.filterText = string(r[:len(r)-1])
					m.setupPicker = m.rebuildSetup()
					return m, nil
				case km.String() == "esc":
					m.filterOpen = false
					m.filterText = ""
					m.setupPicker = m.rebuildSetup()
					return m, nil
				}
				if runes := km.Runes; len(runes) == 1 && unicode.IsPrint(runes[0]) {
					m.filterText += string(runes[0])
					m.setupPicker = m.rebuildSetup()
					return m, nil
				}
			}
		}
		if km, ok := msg.(tea.KeyMsg); ok && km.String() == "i" {
			if m.setupPicker.SelectedValue() == "menu-entry" {
				m.info = tuikit.NewInfo(menuEntryInfo).SetSize(m.contentSize())
				m.push(scrInfo)
				return m, nil
			}
		}
		m.setupPicker, cmd = m.setupPicker.Update(msg)
	case scrSetupCat:
		// Same filter convention as the Setup screen: 'f' opens the little
		// rectangular LIVE filter zone above the shortcut bar; typing inside
		// refines this category's rows; esc closes the zone.
		if km, ok := msg.(tea.KeyMsg); ok {
			switch km.String() {
			case "F", "shift+F": // SHIFT+F toggles the filter zone (esc also closes)
				if m.filterOpen {
					m.filterOpen = false
					m.filterText = ""
				} else {
					m.filterOpen = true
				}
				m.setupCatPicker = m.rebuildSetupCat()
				return m, nil
			case "backspace", "esc":
				if !m.filterOpen {
					break
				}
				if km.String() == "backspace" && m.filterText == "" {
					break
				}
				if km.String() == "backspace" {
					r := []rune(m.filterText)
					m.filterText = string(r[:len(r)-1])
				} else {
					m.filterOpen = false
					m.filterText = ""
				}
				m.setupCatPicker = m.rebuildSetupCat()
				return m, nil
			}
			if m.filterOpen {
				if runes := km.Runes; len(runes) == 1 && unicode.IsPrint(runes[0]) {
					m.filterText += string(runes[0])
					m.setupCatPicker = m.rebuildSetupCat()
					return m, nil
				}
			}
		}
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
		// Secret "p" (documented nowhere): on apps that ship a patch script,
		// propose to PATCH (Setup) or to REMOVE the applied patch (Uninstall).
		if km, ok := msg.(tea.KeyMsg); ok && km.String() == "p" {
			keys := m.selectedKeysOfCat(m.setupCat)
			if len(keys) == 0 {
				keys = m.highlightedKey()
			}
			if len(keys) == 0 {
				m.toast, _ = m.toast.SetWarn("nothing selected")
				return m, nil
			}
			return m, fetchPatchSecretCmd(m.treeMode == "uninstall", keys)
		}
		m.setupCatPicker, cmd = m.setupCatPicker.Update(msg)
	case scrUpdate:
		// 'i' shows exactly which modules will be updated (the preselected
		// list the user can edit with tab).
		if km, ok := msg.(tea.KeyMsg); ok && km.String() == "i" {
			var lines []string
			if m.updateRec.RepoUpdate {
				lines = append(lines, "• mosquitOmarchy scripts repo — fast-forward to the GitHub version")
			}
			for _, key := range m.updateKeys() {
				lines = append(lines, "• "+key)
			}
			if len(lines) == 0 {
				lines = append(lines, "Nothing to update — everything is already current.")
			}
			m.info = tuikit.NewInfo(strings.Join(lines, "\n")).SetSize(m.contentSize())
			m.push(scrInfo)
			return m, nil
		}
		// Tab on the Update screen marks a module as SKIPPED (or re-includes
		// it).
		m.updatePicker, cmd = m.updatePicker.Update(msg)
	case scrHealth:
		if km, ok := msg.(tea.KeyMsg); ok && km.String() == "i" {
			if v := m.healthPicker.SelectedValue(); v != "" {
				for _, it := range m.healthItems {
					if it.ID != v {
						continue
					}
					txt := it.ID
					if it.Label != "" && it.Label != it.ID {
						txt += "\n\n" + it.Label
					}
					if it.Detail != "" {
						txt += "\n\n" + it.Detail
					}
					m.info = tuikit.NewInfo(txt).SetSize(m.contentSize())
					m.push(scrInfo)
					return m, nil
				}
			}
		}
		m.healthPicker, cmd = m.healthPicker.Update(msg)
	case scrKB:
		m.kbPicker, cmd = m.kbPicker.Update(msg)
	case scrKBList:
		m.kbListPicker, cmd = m.kbListPicker.Update(msg)
	case scrKBCat:
		m.kbCatPicker, cmd = m.kbCatPicker.Update(msg)
	case scrKBItems:
		m.kbItemPicker, cmd = m.kbItemPicker.Update(msg)
	case scrKBKeys:
		m.kbKeyPicker, cmd = m.kbKeyPicker.Update(msg)
	case scrKBInput:
		m.kbInput, cmd = m.kbInput.Update(msg)
	case scrSettings:
		m.pickPicker, cmd = m.pickPicker.Update(msg)
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

// planHasKeepassxc reports whether an install plan (TAB-separated folder key
// groups) contains the keepassxc module (the gnome-keyring question applies).
func planHasKeepassxc(plan []string) bool {
	for _, group := range plan {
		for _, k := range strings.Split(group, "\t") {
			if k == "keepassxc" {
				return true
			}
		}
	}
	return false
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
			m.treeMode = "install"
			m.selected = map[string]bool{}
			m.filterText = ""
			m.push(scrSetup)
			m.setupPicker = newNavPicker("", []tuikit.PickerItem{{Display: "loading…", Value: "", Disabled: true}}).SetSize(m.contentSize())
			// Auto-check for updates (mosquitOmarchy scripts/repo + changed
			// apps/tuis/modules) when Setup opens, so its first screen can
			// advertise them.
			return m, tea.Batch(fetchTreeCmd("setup"), blinkCmd(), fetchUpdateCheckCmd())
		case "uninstall":
			// Same category/folder tree as Setup, but only the INSTALLED
			// entries, and Enter uninstalls instead of installing.
			m.treeMode = "uninstall"
			m.selected = map[string]bool{}
			m.folderOpen = map[string]bool{}
			m.filterText = ""
			m.push(scrSetup)
			m.setupPicker = newNavPicker("", []tuikit.PickerItem{{Display: "loading…", Value: "", Disabled: true}}).SetSize(m.contentSize())
			return m, tea.Batch(fetchTreeCmd("uninstall-tree"), blinkCmd())
		case "health":
			// Re-apply any mosquitOmarchy piece / module whose files went missing.
			return m, fetchHealthCmd()
		case "backup":
			m.push(scrBackup)
			m.backupPicker = newNavPicker("", backupActions()).SetSize(m.contentSize())
			return m, nil
		case "settings":
			// Plugin-level toggles from the main menu (the "Settings" row
			// right before Close).
			m.push(scrSettings)
			m.pickPicker = newNavPicker("Settings:", settingsItems2()).SetSize(m.contentSize())
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
		if res.Value == "add-shortcut" {
			m.pendingAction = "add-shortcut"
			m.pendingMsg = "Add a keyboard shortcut (SUPER + ALT + M) to open mosquitOmarchy at any time?"
			m.pendingNo = "Cancel"
			m.pendingYes = "Add shortcut"
			m.push(scrConfirm)
			m.confirm = tuikit.NewConfirm(m.pendingMsg, m.pendingNo, m.pendingYes)
			return m, nil
		}
		if strings.HasPrefix(res.Value, "item:") {
			// Typing-filter rows: Enter acts on the ticked leaf rows (or the
			// focused row when nothing is ticked) — install in the Setup tree,
			// uninstall in the Uninstall tree.
			keys := m.filteredCheckedKeys()
			if len(keys) == 0 {
				keys = []string{strings.TrimPrefix(res.Value, "item:")}
			}
			if m.treeMode == "uninstall" {
				m.pendingAction = "uninstall"
				m.pendingArgs = keys
				m.kpxGnomeRm = 0
				m.pendingMsg = fmt.Sprintf("Uninstall %d selected item(s)?\n\n%s", len(keys), strings.Join(keys, "\n"))
				m.pendingNo = "Cancel"
				m.pendingYes = "Uninstall"
			} else {
				var groups []string
				for _, f := range m.setupFolders {
					var sel []string
					for _, it := range m.setupItemsOf(f.Folder) {
						if m.selected[setupValue(f.Folder, it.Key)] {
							sel = append(sel, it.Key)
						}
					}
					if len(sel) > 0 {
						groups = append(groups, f.Folder+"\t"+strings.Join(sel, "\t"))
					}
				}
				if len(groups) == 0 {
					name := strings.TrimPrefix(res.Value, "item:")
					groups = []string{name[:strings.Index(name, ":")] + "\t" + name[strings.Index(name, ":")+1:]}
				}
				m.pendingAction = "apply"
				m.pendingArgs = groups
				m.kpxGnomeRm = 0
				m.pendingMsg = fmt.Sprintf("Install %d selected item(s)?\n\n%s", len(keys), strings.Join(keys, "\n"))
				m.pendingNo = "Cancel"
				m.pendingYes = "Install"
			}
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
			m.kpxGnomeRm = 0 // each install plan answers the gnome-keyring question again
			m.pendingMsg = fmt.Sprintf("Install %d selected item(s)?\n\n%s", m.selectedCount(), m.selectionSummary())
			m.pendingNo = "Cancel"
			m.pendingYes = "Install"
			m.push(scrConfirm)
			m.confirm = tuikit.NewConfirm(m.pendingMsg, m.pendingNo, m.pendingYes)
			return m, nil
		}
		if res.Value == "uninstall-selection" {
			keys := m.allSelectedKeys()
			if len(keys) == 0 {
				m.toast, _ = m.toast.SetWarn("nothing selected")
				return m, nil
			}
			m.pendingAction = "uninstall"
			m.pendingArgs = keys
			m.pendingMsg = fmt.Sprintf("Uninstall %d selected item(s)?\n\n%s", len(keys), m.selectionSummary())
			m.pendingNo = "Cancel"
			m.pendingYes = "Uninstall"
			m.push(scrConfirm)
			m.confirm = tuikit.NewConfirm(m.pendingMsg, m.pendingNo, m.pendingYes)
			return m, nil
		}
		m.filterText = ""
		m.setupCat = folderOfValue(res.Value)
		m.folderOpen[m.setupCat] = true
		// Keybindings is a single screen, not a category folder: open its
		// manager directly (Setup flavor here; Uninstall flavor when the tree
		// is the uninstall one).
		if m.setupCat == "keybindings" {
			m.kbMode = "setup"
			if m.treeMode == "uninstall" {
				m.kbMode = "uninstall"
			}
			m.push(scrKB)
			m.kbPicker = m.rebuildKB()
			return m, nil
		}
		m.push(scrSetupCat)
		m.setupCatPicker = m.rebuildSetupCat()
		return m, nil

	case scrSetupCat:
		// Level 2: the folder tree. Enter installs ONLY the items checked in
		// this category (Uninstall mode: Enter uninstalls the checked items, or
		// the highlighted row when nothing is checked).
		if res.Value == "back" {
			m.pop()
			m.filterText = ""
			m.setupPicker = m.rebuildSetup()
			return m, nil
		}
		// The keybindings manager is PART of the TUI now: Enter directly on
		// that row (and nothing else ticked) opens its dedicated screen —
		// Setup flavor here, Uninstall flavor in uninstall mode.
		eff := m.selectedKeysOfCat(m.setupCat)
		if len(eff) == 0 {
			eff = m.highlightedKey()
		}
		if len(eff) == 1 && eff[0] == "keybindings" {
			m.kbMode = "setup"
			if m.treeMode == "uninstall" {
				m.kbMode = "uninstall"
			}
			m.push(scrKB)
			m.kbPicker = newNavPicker("", []tuikit.PickerItem{{Display: "loading…", Value: "", Disabled: true}}).SetSize(m.contentSize())
			return m, fetchKbCmd()
		}
		if m.treeMode == "uninstall" {
			keys := m.selectedKeysOfCat(m.setupCat)
			if len(keys) == 0 {
				keys = m.highlightedKey()
			}
			if len(keys) == 0 {
				m.toast, _ = m.toast.SetWarn("nothing to uninstall — press tab to select items")
				return m, nil
			}
			m.pendingAction = "uninstall"
			m.pendingArgs = keys
			m.pendingMsg = fmt.Sprintf("Uninstall %d item(s) in %s?\n\n%s",
				len(keys), m.setupCatLabel(), strings.Join(keys, "\n"))
			m.pendingNo = "Cancel"
			m.pendingYes = "Uninstall"
			m.push(scrConfirm)
			m.confirm = tuikit.NewConfirm(m.pendingMsg, m.pendingNo, m.pendingYes)
			return m, nil
		}
		plan := m.applyPlanCat(m.setupCat)
		if len(plan) == 0 {
			m.toast, _ = m.toast.SetWarn("nothing selected here — press tab to select items")
			return m, nil
		}
		m.pendingAction = "apply"
		m.pendingArgs = plan
		m.kpxGnomeRm = 0 // each install plan answers the gnome-keyring question again
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

	case scrHealth:
		// Esc on the list backs out; Enter confirms the pieces the user kept
		// checked (tab), mirroring the Setup/Update flow down to a Confirm.
		keys := m.healthKeys()
		if len(keys) == 0 {
			m.toast, _ = m.toast.SetWarn("nothing selected — press tab to pick the pieces to re-apply")
			return m, nil
		}
		m.pendingAction = "heal"
		m.pendingArgs = keys
		m.pendingMsg = fmt.Sprintf("Re-apply the %d missing piece(s) you ticked?\n\n%s", len(keys), strings.Join(keys, ", "))
		m.pendingNo = "Cancel"
		m.pendingYes = "Re-apply"
		m.push(scrConfirm)
		m.confirm = tuikit.NewConfirm(m.pendingMsg, m.pendingNo, m.pendingYes)
		return m, nil

	case scrKB:
		// The Keybindings menu: both flavors open "Managed keybindings" in
		// its own submenu; setup also offers "Add a keybinding".
		switch res.Value {
		case "managed":
			m.push(scrKBList)
			m.kbListPicker = newNavPicker("", []tuikit.PickerItem{{Display: "loading…", Value: "", Disabled: true}}).SetSize(m.contentSize())
			return m, fetchKbCmd()
		case "add":
			m.push(scrKBCat)
			m.kbCatPicker = m.rebuildKBCat()
			return m, nil
		case "back":
			m.pop()
			return m, nil
		}
		return m, nil

	case scrKBList:
		// The managed list: Enter on a ticked set removes it (confirm); Enter
		// on the Reset row (uninstall flavor) wipes the whole managed block.
		switch {
		case strings.HasPrefix(res.Value, "kb:"):
			checked := m.kbCheckedKeys()
			if len(checked) == 0 {
				m.toast, _ = m.toast.SetWarn("nothing selected — press tab to tick the bindings to remove")
				return m, nil
			}
			m.pendingAction = "kb-remove"
			m.pendingArgs = checked
			m.pendingMsg = fmt.Sprintf("Remove %d keybinding(s)?\n\n%s", len(checked), strings.Join(checked, "\n"))
			m.pendingNo = "Cancel"
			m.pendingYes = "Remove"
			m.push(scrConfirm)
			m.confirm = tuikit.NewConfirm(m.pendingMsg, m.pendingNo, m.pendingYes)
			return m, nil
		case res.Value == "reset":
			m.pendingAction = "kb-reset"
			m.pendingMsg = "Reset keybindings?\n\nThis removes EVERY keybinding managed by mosquitOmarchy (the whole bindings.lua marker block). Your own bindings outside the block, and Omarchy's defaults, are untouched."
			m.pendingNo = "Cancel"
			m.pendingYes = "Reset"
			m.push(scrConfirm)
			m.confirm = tuikit.NewConfirm(m.pendingMsg, m.pendingNo, m.pendingYes)
			return m, nil
		}
		return m, nil

	case scrKBCat:
		// "Add a keybinding" categories: Package app / Quick function /
		// Ableton Move / Custom command (no prefix — the header names it).
		if res.Canceled || res.Value == "back" {
			m.pop()
			return m, nil
		}
		id := strings.TrimPrefix(res.Value, "cat:")
		for _, c := range kbCatalog {
			if c.ID != id {
				continue
			}
			if c.ID == "custom" {
				// Custom command: prompt for the label, then the command.
				m.kbInputStep = 0
				m.kbInput = tuikit.NewTextInput("Label for the new keybinding:", "")
				m.push(scrKBInput)
				return m, m.kbInput.Init()
			}
			m.kbCatItems = c.Items
			m.push(scrKBItems)
			m.kbItemPicker = m.rebuildKBItems()
			return m, nil
		}
		return m, nil

	case scrKBItems:
		if res.Canceled || res.Value == "back" {
			m.pop()
			return m, nil
		}
		var idx int
		if _, err := fmt.Sscanf(res.Value, "item:%d", &idx); err != nil || idx < 0 || idx >= len(m.kbCatItems) {
			return m, nil
		}
		m.kbPending = m.kbCatItems[idx]
		return m, fetchKbFreeCmd()

	case scrKBKeys:
		if res.Canceled || res.Value == "back" {
			m.pop()
			return m, nil
		}
		m.pendingAction = "kb-add"
		m.pendingArgs = []string{res.Value, m.kbPending.Label, m.kbPending.Cmd, m.kbPending.Type}
		m.pendingMsg = fmt.Sprintf("Bind %s → %s?\n\nThe binding is written to the mosquitOmarchy block in bindings.lua. Hyprland needs a reload for it to take effect — you'll be asked right after.", res.Value, m.kbPending.Label)
		m.pendingNo = "Cancel"
		m.pendingYes = "Bind"
		m.push(scrConfirm)
		m.confirm = tuikit.NewConfirm(m.pendingMsg, m.pendingNo, m.pendingYes)
		return m, nil

	case scrSettings:
		if res.Value == "toggle-crash-notify" {
			if crashNotify() {
				_, _ = runQuick("crash-notify", "off")
			} else {
				_, _ = runQuick("crash-notify", "on")
			}
			m.pickPicker = newNavPicker("Settings:", settingsItems2()).SetSize(m.contentSize())
			return m, nil
		}
		if res.Value == "back" {
			m.pop()
			return m, nil
		}
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
	m.workingLabel = label
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
// rebuildFilteredSetup flattens the Setup/Uninstall tree into matching leaf
// rows only (no category folders): this is the typing-filter view. Rows keep
// their full item values ("item:<folder>:<key>"), so tab-ticking and the
// install/uninstall flows work on them unchanged.
func (m model) rebuildFilteredSetup() navPicker {
	uninstall := m.treeMode == "uninstall"
	items := make([]tuikit.PickerItem, 0, 32)
	ft := strings.ToLower(m.filterText)
	for _, f := range m.setupFolders {
		for _, it := range m.setupItemsOf(f.Folder) {
			if !strings.Contains(strings.ToLower(it.Label), ft) {
				continue
			}
			v := setupValue(f.Folder, it.Key)
			mark := "○"
			if m.selected[v] {
				mark = "●"
			}
			items = append(items, tuikit.PickerItem{Display: it.Label, Value: v, Badge: mark})
		}
	}
	// Box-drawn filter input zone (small framed area) + the header already
	// shows the typed query — keeps the filter visible above the bottom
	// shortcut hint row (the picker body itself sits above the hint).
	header := "  filter: ┃ " + m.filterText + " ▏  (type to refine · esc clear · tab select · enter "
	if uninstall {
		header += "uninstall"
	} else {
		header += "install"
	}
	header += ")"
	enterDesc := "install selection"
	if m.treeMode == "uninstall" {
		enterDesc = "uninstall selection"
	}
	// Hide quick-fixes folder entries (they are a separate quick-fix
	// category in Setup, not part of the module tree).
	filtered := make([]tuikit.PickerItem, 0, len(items))
	for _, it := range items {
		v := it.Value
		// Item values start with "item:<folder>:<key>" — skip the "fixes" folder.
		if strings.HasPrefix(v, "item:fixes:") {
			continue
		}
		filtered = append(filtered, it)
	}
	return newNavPicker(header, filtered).SetSize(m.contentSize()).
		SetHelpKeys(key.NewBinding(key.WithKeys("tab"), key.WithHelp("tab", "select")),
			key.NewBinding(key.WithKeys("F"), key.WithHelp("shift+f", "search")),
			key.NewBinding(key.WithKeys("enter"), key.WithHelp("enter", enterDesc)))
}

func (m model) rebuildSetup() navPicker {
	if m.filterText != "" {
		return m.rebuildFilteredSetup()
	}
	idx := m.setupPicker.Index()
	uninstall := m.treeMode == "uninstall"
	items := make([]tuikit.PickerItem, 0, len(m.setupFolders)+4)
	if !uninstall {
		// Advertise available updates first (mosquitOmarchy scripts/repo + the
		// changed apps/tuis/modules the update-check found) so Setup surfaces
		// them automatically.
		if n := len(m.updateRec.Modules); m.updateRec.RepoUpdate || n > 0 {
			label := "⟳ mosquitOmarchy update available — update the repo/scripts"
			if !m.updateRec.RepoUpdate && n > 0 {
				label = fmt.Sprintf("⟳ %d module update(s) available", n)
			}
			items = append(items, tuikit.PickerItem{Display: label, Value: "updates"})
		}
	}
	for _, f := range m.setupFolders {
		it := tuikit.PickerItem{Display: f.Label, Value: folderValue(f.Folder)}
		// Keybindings is NOT a category of scripts: it is ONE screen. No
		// count, no checkbox folder — Enter opens the manager directly.
		if f.Folder != "keybindings" {
			total := len(m.setupItemsOf(f.Folder))
			if sel := m.categorySelectedCount(f.Folder); sel > 0 {
				// A square (like the audio manager's applied-fix badge) plus the
				// selected count: this category has checked items in its submenu.
				it.Suffix = fmt.Sprintf("  (%d/%d)", sel, total)
				it.TrailingBadge = "■"
			} else if total > 0 {
				it.Suffix = fmt.Sprintf("  (%d)", total)
			}
		}
		if f.Accent {
			it.Accent = m.blinkOn
		}
		items = append(items, it)
	}
	if !uninstall {
		items = append(items, tuikit.PickerItem{Display: "Menu entry", Value: "menu-entry"})
		items = append(items, tuikit.PickerItem{Display: "Add shortcut for mosquitOmarchy", Value: "add-shortcut"})
		// Crash AI-diagnosis notifications: ON by default, toggleable.
		items = append(items, tuikit.PickerItem{
			Display: crashNotifyLabel(), Value: "toggle-crash-notify"})

		install := tuikit.PickerItem{Display: "Install selection", Value: "install-selection"}
		if m.selectedCount() == 0 {
			install.Disabled = true
		}
		items = append(items, install)
	} else {
		// Mirror of "Install selection": uninstall everything ticked in any
		// submenu at once (greyed out and skipped when nothing is checked).
		un := tuikit.PickerItem{Display: "Uninstall selection", Value: "uninstall-selection"}
		if m.selectedCount() == 0 {
			un.Disabled = true
		}
		items = append(items, un)
	}
	items = append(items, tuikit.PickerItem{Display: "Back", Value: "back"})
	return newNavPicker("", items).SetSize(m.contentSize()).
		SetHelpKeys(key.NewBinding(key.WithKeys("F"), key.WithHelp("shift+f", "search"))).
		SelectIndex(idx)
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
	ft := strings.ToLower(m.filterText)
	for _, it := range m.setupItems {
		if it.Folder == m.setupCat {
			if ft != "" && !strings.Contains(strings.ToLower(it.Label), ft) {
				continue
			}
			items = append(items, it)
		}
	}
	enterHelp := "install selection"
	if m.treeMode == "uninstall" {
		enterHelp = "uninstall selection"
	}
	p := newNavPicker("", pickerTreeItems(folders, items, m.selected, m.folderOpen, m.blinkOn)).SetSize(m.contentSize()).
		SetHelpKeys(
			key.NewBinding(key.WithKeys("tab"), key.WithHelp("tab", "select")),
			key.NewBinding(key.WithKeys("i"), key.WithHelp("i", "info")),
			key.NewBinding(key.WithKeys("F"), key.WithHelp("shift+f", "search")),
			key.NewBinding(key.WithKeys("right"), key.WithHelp("→", "expand")),
			key.NewBinding(key.WithKeys("left"), key.WithHelp("←", "collapse")),
			key.NewBinding(key.WithKeys("enter"), key.WithHelp("enter", enterHelp)),
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
// aiRemovalDone reports whether a prior remove-ai uninstall marked the state
// file (a tiny internal log inside ~/.local/state/mosquitomarchy). Setup
// shows the "bring back..." entry GREYED when nothing was ever removed.
func aiRemovalLogged() bool {
	out, err := runQuick("ai-removed")
	if err != nil {
		return false
	}
	var v struct { Removed bool `json:"removed"` }
	if err := json.Unmarshal(bytes.TrimSpace(out), &v); err != nil { return false }
	return v.Removed
}

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
				entry := tuikit.PickerItem{
					Display: "    " + branch + pmark + "  " + it.Label,
					Value:   setupValue(f.Folder, it.Key),
				}
				// "remove-ai" leaf: GREYED until a prior remove-ai uninstall
				// was actually recorded (nothing to "bring back" otherwise).
				if it.Key == "remove-ai" && !aiRemovalLogged() {
					entry.Disabled = true
				}
				out = append(out, entry)
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
	items := make([]tuikit.PickerItem, 0, len(m.updateRec.Modules)+2)
	if len(m.updateRec.Modules) > 0 {
		items = append(items, tuikit.PickerItem{Display: "Modules to update (tab = skip one):", Disabled: true})
		for _, it := range m.updateRec.Modules {
			mark := "○"
			if m.updateSelected[it.Key] {
				mark = "●"
			}
			items = append(items, tuikit.PickerItem{Display: it.Label, Value: it.Key, Badge: mark})
		}
		items = append(items, tuikit.PickerItem{Display: "", Disabled: true})
	}
	items = append(items,
		upd,
		tuikit.PickerItem{Display: "Back", Value: "back"},
	)
	p := newNavPicker("", items).SetSize(m.contentSize()).
		SetHelpKeys(
			key.NewBinding(key.WithKeys("tab"), key.WithHelp("tab", "skip module")),
			key.NewBinding(key.WithKeys("i"), key.WithHelp("i", "what updates")),
			key.NewBinding(key.WithKeys("enter"), key.WithHelp("enter", "update")))
	return p.SelectIndex(idx)
}

func (m model) rebuildHealth() navPicker {
	idx := m.healthPicker.Index()
	items := make([]tuikit.PickerItem, 0, len(m.healthItems))
	for _, it := range m.healthItems {
		mark := "○"
		if m.healthChecked[it.ID] {
			mark = "●"
		}
		items = append(items, tuikit.PickerItem{Display: it.ID, Value: it.ID, Badge: mark})
	}
	p := newNavPicker("Files went missing on these modules :", items).SetSize(m.contentSize()).
		SetHelpKeys(key.NewBinding(key.WithKeys("tab"), key.WithHelp("tab", "select/reapply")),
			key.NewBinding(key.WithKeys("i"), key.WithHelp("i", "info")),
			key.NewBinding(key.WithKeys("enter"), key.WithHelp("enter", "re-apply")))
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

// crashNotify reads the crash-notification flag ONCE (cheap bash query) and
// returns its on/off state; the module item's label uses it.
func crashNotify() bool {
	out, err := runQuick("crash-notify", "get")
	if err != nil || len(bytes.TrimSpace(out)) == 0 {
		return true // default ON
	}
	var v struct {
		CrashNotify bool `json:"crashNotify"`
	}
	if err := json.Unmarshal(bytes.TrimSpace(out), &v); err != nil {
		return true
	}
	return v.CrashNotify
}

func crashNotifyLabel() string {
	if crashNotify() {
		return "Crash notifications (AI diagnosis): on — Enter to disable"
	}
	return "Crash notifications (AI diagnosis): off — Enter to enable"
}


// settingsItems2 backs the new TOP-LEVEL Settings screen (before Close).
func settingsItems2() []tuikit.PickerItem {
	return []tuikit.PickerItem{
		{Display: crashNotifyLabel(), Value: "toggle-crash-notify"},
		{Display: "Back", Value: "back"},
	}
}

func backupItems(items []tuikit.PickerItem) []tuikit.PickerItem { return items }
