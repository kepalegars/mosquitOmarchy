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
	case menuEntriesMsg:
		// Handled GLOBALLY, not under scrMenuEntries: the menu blocks are now
		// listed under their own folder on the Setup page, so the fetch that
		// fills that folder arrives while Setup is the current screen. Scoped
		// to the entries screen, the result was dropped and the folder stayed
		// empty.
		return m.applyMenuEntries(msg), nil
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
			// The only thing blinkOn changes is the accent on the "mosquito"
			// category. If that row is not in the visible window there is
			// nothing on screen to blink, so skip the rebuild entirely rather
			// than rebuild the whole tree twice a second for a row nobody can
			// see.
			if !m.setupPicker.RowVisible(folderValue("mosquito")) {
				m.blinkOn = !m.blinkOn
				return m, blinkCmd()
			}
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
			// The selection is consumed FIRST, while pendingAction still names
			// the action: overwriting it below would make this test never match.
			wasApplyOrUninstall := m.pendingAction == "apply" || m.pendingAction == "uninstall"
			if wasApplyOrUninstall {
				m.selected = map[string]bool{}
				if m.top() == scrSetupCat {
					m.setupCatPicker = m.rebuildSetupCat()
				} else if m.top() == scrSetup {
					m.setupPicker = m.rebuildSetup()
				}
			}
			// A SUCCESSFUL run used to get a bare toast and drop straight back
			// to the previous screen, with no way to read what happened and no
			// mention of the log. The failure path has always asked; success now
			// asks the same question.
			reportCrash(m.workingLabel, out)
			m.pendingAction = "run-done-log"
			m.pendingMsg = "The action finished successfully.\n\nView the full log, or go back?"
			m.pendingNo = "Back"
			m.pendingYes = "See log"
			m.push(scrConfirm)
			m.confirm = tuikit.NewConfirm(m.pendingMsg, m.pendingNo, m.pendingYes)
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
			// in the Keybindings manager (the selection persists while walking
			// the other uninstall pages, so ticking them once is enough).
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
				// rebuildStatus, NOT a bare statusTree(): it is the one that
				// seeds statusOpen with the categories we now know about, all
				// expanded. Calling statusTree() directly built the rows before
				// that seeding, so Status arrived with every folder collapsed
				// and the first ←/→ then flipped the whole set at once.
				m.statusPicker = m.rebuildStatus()
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
			// The main menu's Update square is the one place a pending update
			// is visible without opening anything, so it has to be rebuilt when
			// the check result lands — the root list is built once at startup
			// and never revisited otherwise, which is why the square only ever
			// appeared after going into Setup (that screen rebuilds) and never
			// on the main menu.
			if m.top() == scrMain {
				m.mainPicker = m.rebuildMainMenu()
			}
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
			// "Back" is navigation, not a healable piece: ticking it would
			// draw a selection mark on a row that has nothing to re-apply.
			if msg.Value != "back" {
				m.toggleHealth(msg.Value)
			}
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
		case scrMenuEntries:
			// Handled HERE and not in the scrMenuEntries screen case below:
			// this global switch runs first and returned unconditionally, so
			// the screen's own PickerToggleMsg branch was dead code and tab/x
			// did nothing at all on the Menu entries screen.
			if m.menuEntryChecked != nil {
				name := strings.TrimPrefix(msg.Value, "mentry:")
				if name != msg.Value {
					// Only the DESIRED state flips here. Present stays as the
					// backend reported it, so "(installed)" keeps telling the
					// truth until the apply really ran.
					m.menuEntryChecked[name] = !m.menuEntryChecked[name]
					m.menuEntriesPicker = m.rebuildMenuEntriesPicker()
				}
			}
		}
		return m, nil

	case tuikit.PickerSortMsg:
		// Left/Right collapse/expand the folder under the cursor (the
		// audio-plugin-manager's folder convention), not a sort.
		switch m.top() {
		case scrSetup:
			// Left/Right fold the folder under the cursor, on the ONE page:
			// there is no second level to go into any more, so the arrows that
			// used to sort here have nothing else to do. "Menu entries" folds
			// like a category; its blocks open their own page on Enter.
			if prefix, id, ok := tuikit.TreeSplit(m.setupPicker.SelectedValue()); ok && prefix == tuikit.TreeFolderPrefix {
				if msg.Dir > 0 {
					m.folderOpen[id] = true
				} else {
					delete(m.folderOpen, id)
				}
				keep := m.setupPicker.SelectedValue()
				m.setupPicker = m.rebuildSetup()
				m.setupPicker = m.setupPicker.KeepCursor(keep)
			}
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
			if m.pendingAction == "preinstalls-remove" {
				// "Keep them" (or Cancel): the ticked selection is left as it
				// was and the picker is NOT left behind, since a cancel that
				// stays on a half-done screen is easy to misread.
				m.toast, _ = m.toast.SetWarn("preinstalls kept")
				return m, nil
			}
			if m.pendingAction == "davinci-spektra" {
				// Declined = install Resolve without the optional OFX. That is a
				// legitimate answer, not a cancel: continue the apply.
				m.dvcSpektra = 2
				os.Setenv("MOSQUITOMARCHY_DAVINCI_SPEKTRAFILM", "0")
				return m, fetchMissingAssetsCmd(m.pendingArgs)
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

		case "preinstalls-remove":
			// The only path that ever reaches `pacman -Rns`: an explicit "Remove
			// them". Reached from Enter AND from back, both through the same
			// confirmation.
			return m, preinstallsRemoveCmd(m.pendingArgs)

		case "davinci-spektra":
			if msg.Yes {
				m.dvcSpektra = 1
				os.Setenv("MOSQUITOMARCHY_DAVINCI_SPEKTRAFILM", "1")
				m.toast, _ = m.toast.SetOK("spektrFilm OFX will be installed with Resolve")
			} else {
				m.dvcSpektra = 2
				os.Setenv("MOSQUITOMARCHY_DAVINCI_SPEKTRAFILM", "0")
			}
			// Continue the apply that was interrupted by this question.
			return m, fetchMissingAssetsCmd(m.pendingArgs)

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
			// DaVinci ships an optional free OFX plugin. setup-davinci.sh only
			// offers it under `((YES == 0)) && ask`, and the TUI applies with
			// YES=1, so it was never proposed from here. Ask now, where the
			// answer can still be a real question, and hand the decision to
			// the script as --with-spektrafilm.
			if planHasDavinci(m.pendingArgs) && m.dvcSpektra == 0 {
				m.pendingAction = "davinci-spektra"
				m.pendingMsg = "Install the free spektrFilm OFX too?\n\nPhotochemical film simulation for Resolve (SpektraFilm 114c.de, free). Installed into Resolve's OFX folder, removable later from the DaVinci uninstall."
				m.pendingNo = "Resolve only"
				m.pendingYes = "Add spektrFilm"
				m.push(scrConfirm)
				// Focus "Resolve only": the plugin is optional, so the plain
				// Enter answer should be the one that does not change the plan.
				m.confirm = tuikit.NewConfirm(m.pendingMsg, m.pendingNo, m.pendingYes)
				return m, nil
			}
			// Pre-flight: some apps need a manually-downloaded installer. Check
			// BEFORE running so a missing file becomes a clear prompt naming it,
			// instead of a failure buried in the run log.
			return m, fetchMissingAssetsCmd(m.pendingArgs)
		case "update":
			return m.startWorking("Re-applying modules", workingArgs("update", m.pendingArgs)...)
		case "menu-entries":
			// Strip or restore each changed entry, then re-list so the rows
			// show what is really in the menu file instead of the state that
			// was asked for.
			for _, name := range m.pendingArgs {
				how := "strip"
				if m.menuEntryChecked[name] {
					how = "restore"
				}
				if _, eErr := runQuick("menu-entries", how, name); eErr != nil {
					m.toast, _ = m.toast.SetErr("could not apply " + name)
				}
			}
			return m, fetchMenuEntriesCmd()
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
				m.pickPicker = newNavPicker("Extras:", settingsItems2()).SetSize(m.contentSize())
			} else if m.top() == scrSetup {
				m.setupPicker = m.rebuildSetup()
			}
			return m, nil
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
		case "run-errors", "run-done-log":
			// Show the full streamed log in the scrollable Info screen; the
			// prompt itself was already popped, so closing the log returns to
			// the previous menu. "run-done-log" is the same prompt on the
			// success path — a successful run has just as much to show.
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

	case tuikit.InfoCopiedMsg:
		// `c` on any Info (a log, an `i` popup): report what happened, since
		// the copy is silent and a keypress that appears to do nothing is
		// indistinguishable from one that failed.
		if msg.Err != nil {
			m.toast, _ = m.toast.SetErr("copy failed: " + msg.Err.Error())
			return m, nil
		}
		m.toast, _ = m.toast.SetOK(fmt.Sprintf("log copied to the clipboard (%d bytes)", msg.Bytes))
		return m, nil

	case tuikit.InfoDismissedMsg:
		// The Status screen pushes a real scrInfo popup for `i`, so dismissal
		// always pops scrInfo and lands back on the picker. scrStatus is no
		// longer an Info pane of its own.
		if m.top() == scrInfo {
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
		// `i` and Enter both read the module under the cursor (the detail
		// popup); Enter on a folder header or "Back" behaves like the folder
		// rows elsewhere (header = no-op, Back leaves). Status is READ-ONLY:
		// there is no action to run from here. `esc` leaves the screen.
		if km, ok := msg.(tea.KeyMsg); ok {
			switch km.String() {
			case "esc":
				m.pop()
				return m, nil
			case "right", "left", "enter":
				// Categories fold/unfold exactly like Setup's folders, with
				// the same keys: right/Enter opens, left closes. They used to
				// be inert headings, so a category could not be reached at all
				// and the list could not be narrowed.
				v := m.statusPicker.SelectedValue()
				if cat, ok := statusCatOf(v); ok {
					if km.String() == "left" {
						m.statusOpen[cat] = false
					} else {
						m.statusOpen[cat] = true
					}
					keep := m.statusPicker.SelectedValue()
					m.statusPicker = m.rebuildStatus()
					m.statusPicker = m.statusPicker.KeepCursor(keep)
					return m, nil
				}
				if km.String() == "enter" {
					if strings.HasPrefix(v, "status:") {
						m.info = tuikit.NewInfo(m.statusDetail(strings.TrimPrefix(v, "status:"))).SetSize(m.contentSize())
						m.push(scrInfo)
						return m, nil
					}
					if v == "back" {
						m.pop()
						return m, nil
					}
				}
				// left/right on a module row are the kit's sort keys; let them
				// through unchanged.
			case "i":
				if v := m.statusPicker.SelectedValue(); strings.HasPrefix(v, "status:") {
					m.info = tuikit.NewInfo(m.statusDetail(strings.TrimPrefix(v, "status:"))).SetSize(m.contentSize())
					m.push(scrInfo)
					return m, nil
				}
				return m, nil
			}
		}
		m.statusPicker, cmd = m.statusPicker.Update(msg)
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
			if v := m.setupPicker.SelectedValue(); strings.HasPrefix(v, "cat:") {
				m.info = tuikit.NewInfo(m.categoryInfo(strings.TrimPrefix(v, "cat:"))).SetSize(m.contentSize())
				m.push(scrInfo)
				return m, nil
			}
			if m.setupPicker.SelectedValue() == "menu-entries" {
				m.info = tuikit.NewInfo(
					"Menu entries — every marked block mosquito installs into the\n" +
						"Omarchy menu (mega caffeine, live mode, mosquito Move Manager,\n" +
						"mosquitomarchy itself).\n\n" +
						"Each line starts from what is installed right now. The tick is what\n" +
						"Enter will make true: un-tick an installed entry to strip it from the\n" +
						"Omarchy menu, tick a missing one to add it back. Only the lines you\n" +
						"actually changed are applied.").SetSize(m.contentSize())
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
			if v := m.setupCatPicker.SelectedValue(); strings.HasPrefix(v, "cat:") {
				m.info = tuikit.NewInfo(m.categoryInfo(strings.TrimPrefix(v, "cat:"))).SetSize(m.contentSize())
				m.push(scrInfo)
				return m, nil
			}
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
	case scrPreinstalls:
		if pm, ok := msg.(preinstallsMsg); ok {
			if pm.err != nil {
				m.toast, _ = m.toast.SetErr(pm.err.Error())
				return m, nil
			}
			if pm.done != "" {
				m.pop()
				m.toast, _ = m.toast.SetOK("preinstalls removed")
				return m, tea.Batch(fetchTreeCmd("uninstall-tree"), blinkCmd())
			}
			if len(pm.rows) > 0 {
				m.preinstalls = pm.rows
				if m.preinstallChecked == nil {
					m.preinstallChecked = map[string]bool{}
				}
				for _, r := range pm.rows {
					// Everything still removable starts TICKED: the ask is
					// "which do you want to KEEP", and an unticked row is kept.
					if _, seen := m.preinstallChecked[r.Name]; !seen {
						m.preinstallChecked[r.Name] = r.Removable
					}
				}
			}
			m.preinstallPicker = m.rebuildPreinstallPicker()
			return m, nil
		}
		if tg, ok := msg.(tuikit.PickerToggleMsg); ok {
			if m.preinstallChecked != nil {
				m.preinstallChecked[tg.Value] = !m.preinstallChecked[tg.Value]
			}
			m.preinstallPicker = m.rebuildPreinstallPicker()
			return m, nil
		}
		if _, ok := msg.(tuikit.PickerResultMsg); ok {
			return m, nil
		}
		m.preinstallPicker, cmd = m.preinstallPicker.Update(msg)
		return m, cmd
	case scrMenuEntries:
		// PickerToggleMsg is consumed by the global switch at the top of
		// update(), which returns before this case is ever reached.
		// Enter and Esc arrive here as PickerResultMsg and are handled by
		// screenPicked (the global case at the top of update routes them
		// there). Catching one here too would swallow it: this is the very
		// bug that made Enter do nothing on this screen.
		if _, ok := msg.(tuikit.PickerResultMsg); ok {
			return m, nil
		}
		m.menuEntriesPicker, cmd = m.menuEntriesPicker.Update(msg)
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

// planHasDavinci reports whether an install plan contains the davinci module
// (the spektrFilm question applies).
func planHasDavinci(plan []string) bool {
	for _, group := range plan {
		for _, k := range strings.Split(group, "\t") {
			if k == "davinci-resolve" {
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
			m.statusOpen = map[string]bool{}
			m.statusPicker = newNavPicker("", []tuikit.PickerItem{{Display: "loading…", Value: "", Disabled: true}}).SetSize(m.contentSize())
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
			// The menu entries are listed under their own folder on this page,
			// so they have to be fetched here too — they used to be fetched
			// only when their screen was opened.
			m.menuEntryChecked = map[string]bool{}
			m.menuEntryOrig = map[string]bool{}
			m.menuEntries = nil
			m.menuEntriesLoaded = false
			// Auto-check for updates (mosquitomarchy scripts/repo + changed
			// apps/tuis/modules) when Setup opens, so its first screen can
			// advertise them.
			return m, tea.Batch(fetchTreeCmd("setup"), blinkCmd(), fetchUpdateCheckCmd(), fetchMenuEntriesCmd())
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
		case "keybindings":
			// Its own row in the main menu, next to the other tools, rather
			// than buried as one more folder inside Setup and Uninstall: the
			// two trees only ever added a hop before reaching the same screen.
			m.push(scrKB)
			m.kbPicker = m.rebuildKB()
			return m, nil
		case "health":
			// Re-apply any mosquitOmarchy piece / module whose files went missing.
			return m, fetchHealthCmd()
		case "backup":
			m.push(scrBackup)
			m.backupPicker = newNavPicker("", backupActions()).SetSize(m.contentSize())
			return m, nil
		case "settings":
			// Plugin-level toggles from the main menu (the "Extras" row
			// right before Close).
			m.push(scrSettings)
			m.pickPicker = newNavPicker("Extras:", settingsItems2()).SetSize(m.contentSize())
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
		// The typing-filter view (m.filterText != "") is the ONLY case whose
		// rows are bare "item:<folder>:<key>" leaves: there Enter acts on the
		// ticked set. In the normal tree the item rows are handled further
		// down, so without this guard the filter branch swallowed every module
		// press and the apply/uninstall of a single module was impossible.
		if m.filterText != "" && strings.HasPrefix(res.Value, "item:") {
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
		// Back closes the page, exactly as before.
		if res.Value == "back" {
			m.pop()
			return m, nil
		}
		// Enter on a CATEGORY row does NOTHING, on purpose. Folding is the
		// left/right arrows' job and they already do it, so Enter folding too
		// meant the key meant two different things depending on what it landed
		// on. Enter is reserved for the one thing only a user can ask for:
		// install (or uninstall) the module under the cursor.
		if strings.HasPrefix(res.Value, tuikit.TreeFolderPrefix) {
			return m, nil
		}
		// Enter on a MODULE row installs just that one: a single click for a
		// single module, with no tick-then-apply round trip. Tab is still there
		// to select several and apply them in one go.
		if strings.HasPrefix(res.Value, tuikit.TreeItemPrefix) {
			v := res.Value
			if it, ok := m.setupByValue[v]; ok {
				if it.Disabled {
					m.toast, _ = m.toast.SetErr("nothing to do here")
					return m, nil
				}
				folder, key := splitSetupValue(v)
				// Uninstall mirrors install on the same page: Enter on a module
				// removes exactly that one, in either mode.
				if m.treeMode == "uninstall" {
					m.pendingAction = "uninstall"
					m.pendingArgs = []string{key}
					m.pendingMsg = fmt.Sprintf("Uninstall %s?", it.Label)
					m.pendingNo = "Cancel"
					m.pendingYes = "Uninstall"
					m.push(scrConfirm)
					m.confirm = tuikit.NewConfirm(m.pendingMsg, m.pendingNo, m.pendingYes).SetFocus(1)
					return m, nil
				}
				plan := []string{strings.Join([]string{folder, key}, "\t")}
				m.pendingAction = "apply"
				m.pendingArgs = plan
				m.kpxGnomeRm = 0
				m.pendingMsg = fmt.Sprintf("Install %s?", it.Label)
				m.pendingNo = "Cancel"
				m.pendingYes = "Install"
				m.push(scrConfirm)
				m.confirm = tuikit.NewConfirm(m.pendingMsg, m.pendingNo, m.pendingYes).SetFocus(1)
				return m, nil
			}
		}
		if res.Value == "menu-entries" {
			// "Menu entries" is a level-1 Setup row but NOT a category
			// folder, so it needs its own branch here. Without it the value
			// fell through to the category path below, folderOfValue() returned
			// "" and Setup opened an empty category screen instead: the screen
			// looked broken because the menu-entries screen was never pushed.
			// (The branch used to live in the ConfirmResultMsg switch, where
			// nothing could ever reach it.)
			m.push(scrMenuEntries)
			m.menuEntryChecked = map[string]bool{}
			m.menuEntryOrig = map[string]bool{}
			m.menuEntries = nil
			m.menuEntriesLoaded = false
			return m, fetchMenuEntriesCmd()
		}
		m.filterText = ""
		m.setupCat = folderOfValue(res.Value)
		m.folderOpen[m.setupCat] = true
		// Keybindings is a single screen, not a category folder: open its
		// manager directly (Setup flavor here; Uninstall flavor when the tree
		// is the uninstall one).
		// Everything else on this page folds in place now (Enter on a category
		// toggles it), so there is no second level to enter. This branch is
		// unreachable for categories; it stays as a no-op guard so a future
		// row that somehow falls through does not push a dead screen.
		return m, nil

	case scrPreinstalls:
		// The ticked-and-removable list, which is what would be handed to
		// `pacman -Rns`.
		preinstallsTargets := func() []string {
			var out []string
			for _, r := range m.preinstalls {
				if m.preinstallChecked[r.Name] && r.Removable {
					out = append(out, r.Name)
				}
			}
			return out
		}
		// Nothing ticked -> just leave. Never pop straight out of a screen whose
		// whole purpose is destructive without saying what is about to happen.
		askRemove := func() (model, tea.Cmd) {
			pkgs := preinstallsTargets()
			if len(pkgs) == 0 {
				m.toast, _ = m.toast.SetWarn("nothing ticked — no preinstall is removed")
				m.pop()
				return m, nil
			}
			names := strings.Join(pkgs, ", ")
			m.pendingAction = "preinstalls-remove"
			m.pendingArgs = pkgs
			m.pendingMsg = fmt.Sprintf("Remove %d Omarchy preinstall(s)?\n\n%s\n\nThey are removed with `pacman -Rns`; their settings stay on disk, so reinstalling the package brings the app back.", len(pkgs), names)
			m.pendingNo = "Keep them"
			m.pendingYes = "Remove them"
			m.push(scrConfirm)
			// Focus "Keep them": a removal must be a deliberate yes.
			m.confirm = tuikit.NewConfirm(m.pendingMsg, m.pendingNo, m.pendingYes).SetFocus(0)
			return m, nil
		}
		if res.Canceled {
			return askRemove()
		}
		if res.Value == "back" || res.Value == "" {
			// The user asked for "back" to apply the selection too. It now asks
			// the same question Enter does instead of removing silently.
			return askRemove()
		}
		return askRemove()
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
		// A greyed row is not an action: Enter on it says why instead of
		// opening a screen that would have nothing selectable in it.
		if len(eff) == 1 {
			if it, ok := m.setupByValue[setupValue(m.setupCat, eff[0])]; ok && it.Disabled {
				m.toast, _ = m.toast.SetWarn(it.Info)
				return m, nil
			}
		}
		// Uninstall ▸ Preinstalls opens its own picker: the whole Omarchy stock
		// list with the removed ones greyed, instead of being swept wholesale.
		if len(eff) == 1 && eff[0] == "preinstalls:choose" {
			m.push(scrPreinstalls)
			m.preinstallChecked = map[string]bool{}
			m.preinstallPicker = newNavPicker("", []tuikit.PickerItem{{Display: "loading…", Value: "", Disabled: true}}).SetSize(m.contentSize())
			return m, fetchPreinstallsCmd()
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
		case "update-repo":
			// Its own row so a pending fast-forward is a separate, named
			// action instead of being bundled behind "Update modules".
			m.pendingAction = "update-repo"
			m.pendingMsg = "Update mosquitOmarchy?\n\nThe local scripts repo is fast-forwarded to the GitHub version, and the setup script re-runs so the fresh scripts are the ones in use."
			m.pendingNo = "Cancel"
			m.pendingYes = "Update"
			m.push(scrConfirm)
			m.confirm = tuikit.NewConfirm(m.pendingMsg, m.pendingNo, m.pendingYes)
			return m, nil
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

	case scrMenuEntries:
		// Enter applies the delta. This branch did not exist: Enter was handled
		// in the scrMenuEntries case of the key switch, but PickerResultMsg is
		// caught by the global case at the top of update() and routed to
		// screenPicked, which had no scrMenuEntries case — so it fell off the
		// end of the switch and did nothing. Un-ticking an entry and pressing
		// Enter silently did nothing, and the ticks reset when the screen was
		// re-entered because the backend was re-read with nothing applied.
		if res.Canceled || res.Value == "back" {
			m.pop()
			return m, nil
		}
		changed := []string{}
		for _, e := range m.menuEntries {
			if v, ok := m.menuEntryChecked[e.Name]; ok && v != m.menuEntryOrig[e.Name] {
				changed = append(changed, e.Name)
			}
		}
		if len(changed) == 0 {
			m.toast, _ = m.toast.SetWarn("no change to apply")
			return m, nil
		}
		m.pendingAction = "menu-entries"
		m.pendingArgs = changed
		var b strings.Builder
		for i, name := range changed {
			verb := "remove from the menu"
			if m.menuEntryChecked[name] {
				verb = "add back to the menu"
			}
			if i > 0 {
				b.WriteString("\n")
			}
			b.WriteString("• " + name + " — " + verb)
		}
		m.pendingMsg = fmt.Sprintf("Apply %d menu entry change(s)?\n\n%s", len(changed), b.String())
		m.pendingNo = "Cancel"
		m.pendingYes = "Apply"
		m.push(scrConfirm)
		m.confirm = tuikit.NewConfirm(m.pendingMsg, m.pendingNo, m.pendingYes)
		return m, nil

	case scrHealth:
		// Esc on the list backs out; Enter confirms the pieces the user kept
		// checked (tab), mirroring the Setup/Update flow down to a Confirm.
		if m.healthPicker.SelectedValue() == "back" {
			m.pop()
			return m, nil
		}
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
		// The Keybindings menu: "Managed keybindings" lists them with the
		// removal ticks and the Reset row, "Add a keybinding" starts the flow.
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
		// Ableton Move / mosquitOmarchy / Custom command (no prefix — the
		// header names it).
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
			m.pickPicker = newNavPicker("Extras:", settingsItems2()).SetSize(m.contentSize())
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
	p := newNavPicker(header, filtered).SetSize(m.contentSize()).
		SetHelpKeys(key.NewBinding(key.WithKeys("tab"), key.WithHelp("tab", "select")),
			key.NewBinding(key.WithKeys("F"), key.WithHelp("shift+f", "search")),
			key.NewBinding(key.WithKeys("enter"), key.WithHelp("enter", enterDesc)))
	// Carry the cursor over from the list being replaced. This function used
	// to return the picker with no SelectIndex at all, so it always started at
	// row 0: with a filter active, the blink that repaints the mosquito row
	// fired about once a second and threw the cursor back to the first match,
	// which made the filtered list impossible to walk.
	return p.KeepCursor(m.setupPicker.SelectedValue())
}

// categoryInfo composes the "i" popup for one Setup/Uninstall category: what
// the category is for, then every row in it with its own description. The leaf
// rows already had an "i" (label + Info), but the category rows answered
// nothing, so the only way to read what a category covers was to open it.
func (m model) categoryInfo(folder string) string {
	label := folder
	for _, f := range m.setupFolders {
		if f.Folder == folder {
			label = f.Label
			break
		}
	}
	items := m.setupItemsOf(folder)
	var b strings.Builder
	b.WriteString(label)
	if n := len(items); n == 1 {
		b.WriteString("\n\n1 item")
	} else {
		fmt.Fprintf(&b, "\n\n%d items", n)
	}
	if n := m.categorySelectedCount(folder); n > 0 {
		fmt.Fprintf(&b, " — %d ticked", n)
	}
	if len(items) == 0 {
		b.WriteString(". Nothing to do here right now.")
		return b.String()
	}
	b.WriteString(":")
	for _, it := range items {
		b.WriteString("\n• " + it.Label)
		if it.Info != "" && it.Info != it.Label {
			b.WriteString(" — " + it.Info)
		}
	}
	return b.String()
}

// rebuildSetup renders Setup and Uninstall as ONE flat page: every category is
// a folder row and its modules are right there underneath it, folded open or
// shut with Left/Right. There is no second level any more.
//
// It used to be two levels — a page of categories, Enter to descend into one,
// tick rows, back, then an "Install selection" row to apply. That cost a whole
// navigation round trip to select a single module and made the apply step a
// separate thing to remember. Now Tab ticks a module where it is listed,
// Left/Right folds the folder, and Enter applies the whole selection at once.
func (m model) rebuildSetup() navPicker {
	if m.filterText != "" {
		return m.rebuildFilteredSetup()
	}
	idx := m.setupPicker.Index()
	uninstall := m.treeMode == "uninstall"
	out := make([]tuikit.PickerItem, 0, len(m.setupFolders)+8)

	if !uninstall && m.updatePending() {
		// Advertise an available update first, so Setup surfaces it on its
		// own. One short row, sized like every other line in this menu.
		out = append(out, tuikit.PickerItem{Display: "Update", Value: "updates", TrailingBadge: "■"})
	}

	// Map the backend's records onto the kit's generic tree, skipping the
	// quick-fixes folder: fixes are their own category, not module rows.
	seen := map[string][]tuikit.TreeItem{}
	for _, f := range m.setupFolders {
		if f.Folder == "fixes" {
			continue
		}
		for _, it := range m.setupItemsOf(f.Folder) {
			v := setupValue(f.Folder, it.Key)
			// BuildFolderTree writes the "item:" prefix itself, so the id here
			// is the value the host will look up — setupValue()'s suffix,
			// "<folder>:<key>" — with the folder in it so Enter can route a
			// single-module install back to the right category.
			row := tuikit.TreeItem{
				ID:       f.Folder + ":" + it.Key,
				Label:    it.Label,
				Checked:  m.selected[v],
				Info:     it.Info,
				Disabled: it.Disabled,
			}
			// "bring back omarchy's agentic stuff" only makes sense while
			// something is still missing. This used to be decided in
			// pickerTreeItems, which the flat Setup page no longer goes
			// through, so the row stayed tappable and offered a restore that
			// could change nothing.
			if it.Key == "remove-ai" && !uninstall && !aiRemovalLogged() {
				row.Disabled = true
				if row.Info == "" {
					row.Info = "already there — nothing to bring back"
				}
			}
			if row.Disabled && row.Info == "" {
				row.Info = "nothing left to do here"
			}
			seen[f.Folder] = append(seen[f.Folder], row)
		}
	}

	// The folders are emitted one at a time above (open state applied per
	// folder), so the tree is assembled here rather than by a single
	// BuildFolderTree call: BuildFolderTree needs every folder's children up
	// front, and open state is per folder.
	for _, f := range m.setupFolders {
		if f.Folder == "fixes" {
			continue
		}
		tf := tuikit.TreeFolder{
			ID:     f.Folder,
			Label:  f.Label,
			Total:  len(m.setupItemsOf(f.Folder)),
			Marked: m.categorySelectedCount(f.Folder),
			Accent: f.Accent,
		}
		if f.Folder == "keybindings" {
			tf.Total, tf.Marked = 0, 0
		}
		out = append(out, tuikit.BuildFolderTree([]tuikit.TreeFolder{tf}, seen, m.folderOpen, m.blinkOn)...)
	}

	if !uninstall {
		// "Menu entries" is a folder like any other, not a lone row that
		// opened a screen of its own: the arrows fold it, and its blocks are
		// listed under it on the same page. Ticking one still happens on the
		// entries page, where the backend result lands.
		meChildren := make([]tuikit.TreeItem, 0, len(m.menuEntries))
		for _, e := range m.menuEntries {
			meChildren = append(meChildren, tuikit.TreeItem{
				ID:      e.Name,
				Label:   e.Label,
				Checked: m.menuEntryChecked[e.Name],
			})
		}
		// Fold by default: the list is long, and this row is a corner of Setup
		// rather than the page's subject.
		if _, seen := m.folderOpen[menuEntriesFolder]; !seen {
			m.folderOpen[menuEntriesFolder] = false
		}
		out = append(out, tuikit.BuildFolderTree(
			[]tuikit.TreeFolder{{ID: menuEntriesFolder, Label: "Menu entries", Total: len(meChildren)}},
			map[string][]tuikit.TreeItem{menuEntriesFolder: meChildren},
			m.folderOpen, m.blinkOn)...)
	}
	out = append(out, tuikit.PickerItem{Display: "Back", Value: "back"})

	enterHelp := "install selection"
	if uninstall {
		enterHelp = "uninstall selection"
	}
	// KeepCursor is not optional here. rebuildSetup builds a FRESH picker, so
	// without it the cursor jumped back to the top — and rebuildSetup runs on
	// every blink tick, so holding "down" fought the blink and the cursor
	// crawled. It also matters for the fold, which rebuilds the list under a
	// cursor that is sitting on the very row that caused it.
	return newNavPicker("", out).SetSize(m.contentSize()).
		SetHelpKeys(
			key.NewBinding(key.WithKeys("tab", "x"), key.WithHelp("tab/x", "select")),
			key.NewBinding(key.WithKeys("F"), key.WithHelp("shift+f", "search")),
			key.NewBinding(key.WithKeys("right"), key.WithHelp("→", "open")),
			key.NewBinding(key.WithKeys("left"), key.WithHelp("←", "close")),
			key.NewBinding(key.WithKeys("enter"), key.WithHelp("enter", enterHelp)),
		).
		KeepCursor(m.setupPicker.SelectedValue()).
		// Fallback for when the row the cursor was on is genuinely gone (the
		// typing filter just hid it): land on the same index, not on row 0.
		SelectIndex(min(idx, len(out)-1))
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
	p := newNavPicker("", pickerTreeItems(folders, items, m.selected, m.folderOpen, m.blinkOn, m.treeMode)).SetSize(m.contentSize()).
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
	return pickerTreeItems(m.backupFolders, m.backupItems, m.backupChecked, m.backupOpen, false, "backup")
}

// pickerTreeItems builds the shared folder/item tree rows: a Fold glyph (drawn in
// the cursor slot by the kit), an
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
	var v struct {
		Removed bool `json:"removed"`
	}
	if err := json.Unmarshal(bytes.TrimSpace(out), &v); err != nil {
		return false
	}
	return v.Removed
}

func pickerTreeItems(folders []FolderRec, items []SetupItemRec, checked, open map[string]bool, blinkOn bool, mode string) []tuikit.PickerItem {
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
		fold := tuikit.FoldCollapsed
		if open[f.Folder] {
			fold = tuikit.FoldExpanded
		}
		// Folder: a folder glyph in the leading slot + a bold label, with the
		// "all of them ticked" mark moved to the trailing count. The leading
		// column now only says what KIND of row this is, so a folder can be
		// told from a leaf without reading the name.
		folder := tuikit.PickerItem{
			Display: f.Label,
			Value:   folderValue(f.Folder),
			Accent:  f.Accent && blinkOn,
			Fold:    fold,
			Folder:  true,
		}
		if total := len(children); total > 0 {
			folder.Suffix = fmt.Sprintf("  (%d/%d)", marked, total)
		}
		out = append(out, folder)
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
				// Same rule as rebuildPreinstallPicker: the mark belongs in
				// Badge. Rows are centered, so a mark inside Display made
				// every line a different width and none of them shared a
				// starting column.
				entry := tuikit.PickerItem{
					Display: "    " + branch + it.Label,
					Badge:   pmark,
					Value:   setupValue(f.Folder, it.Key),
				}
				// The backend greys a row that has nothing left to do (Preinstalls
				// once every stock app is gone or is your own). It stays listed so
				// the option does not silently vanish.
				if it.Disabled {
					entry.Disabled = true
					// A greyed row with no reason reads as a bug. The backend
					// already explains itself in `info` ("nothing left to
					// remove: every Omarchy preinstall is either already
					// removed or is one of your own apps"), so show that
					// instead of leaving "Choose which … to remove" sitting
					// there looking like a dead button.
					if it.Info != "" {
						entry.Sub = it.Info
					}
				}
				// "remove-ai" means the OPPOSITE thing in each tree, so the
				// grey-out rule has to follow the mode. Setup offers "bring back
				// omarchy's agentic stuff": nothing to bring back if no removal
				// was ever logged, hence greyed. Uninstall offers "remove
				// omarchy's agentic stuff": that is exactly what the user wants
				// precisely when the agentic parts are still present, i.e. when
				// NO removal was logged -- greying it there made the option
				// permanently unselectable, which is what it was reported as.
				if it.Key == "remove-ai" && mode != "uninstall" && !aiRemovalLogged() {
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
	prev := m.updatePicker.SelectedValue()
	items := make([]tuikit.PickerItem, 0, len(m.updateRec.Modules)+3)

	// Name the source of the update. The screen used to offer a single row
	// called "Update modules" whether or not there was any module to update,
	// and the module list was only ever visible by going through the separate
	// "what updates" popup — so a pending REPO fast-forward, the thing most
	// people actually need, looked like one anonymous checkbox with no
	// indication of where it came from. This is the same square the main
	// menu and the Setup tree use for "something is waiting here".
	if m.updateRec.RepoUpdate {
		items = append(items, tuikit.PickerItem{
			Display: "Update mosquitOmarchy (repo + scripts)",
			Value:   "update-repo",
			// Trailing, like every other square in the app, so the marker
			// always sits after the label and never shifts the text column.
			TrailingBadge: "■",
		})
	}
	upd := tuikit.PickerItem{Display: "Update modules", Value: "update-modules"}
	if len(m.updateRec.Modules) == 0 {
		// Only the repo changed, so "Update modules" had nothing to do and ran
		// a no-op fast-forward that looked like the update had been applied.
		upd.Disabled = true
	}
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
	if prev == "" {
		return p.selectFirst()
	}
	return p.KeepCursor(prev)
}

func (m model) rebuildHealth() navPicker {
	prev := m.healthPicker.SelectedValue()
	items := make([]tuikit.PickerItem, 0, len(m.healthItems)+1)
	// The rows used to be the raw module ids ("macos-vm", "menu"), so the
	// screen read like a debug dump and the labels the backend already
	// provides were only reachable through "i". The label is what identifies
	// the piece to the user; the id only has to stay in the Value for heal.
	for _, it := range m.healthItems {
		mark := "○"
		if m.healthChecked[it.ID] {
			mark = "●"
		}
		// The catalog label is a full sentence ("Live mode — performance
		// session mode (stay-awake + thermal guard + …)"), which wraps over
		// three rows and buries the list. Show the piece's own name and keep
		// the sentence as the sub-line, where it is one truncated line.
		display, long := healthShortLabel(it)
		row := tuikit.PickerItem{Display: display, Value: it.ID, Badge: mark}
		if it.Detail != "" {
			row.Sub = it.Detail
		} else if long != "" {
			row.Sub = long
		}
		items = append(items, row)
	}
	// Every other screen ends with a Back row. This one had none, so the only
	// way out was Esc, which does not read as "this is a page you can leave".
	items = append(items, tuikit.PickerItem{Display: "Back", Value: "back"})

	// The headline goes in as a disabled row rather than as the picker's
	// header: NewPicker's header becomes the bubbles list Title, which this
	// theme does not draw, so anything passed there is invisible.
	head := tuikit.PickerItem{Display: healthHeadline(len(m.healthItems)), Value: "", Disabled: true}
	items = append([]tuikit.PickerItem{head}, items...)

	p := newNavPicker("", items).SetSize(m.contentSize()).
		SetHelpKeys(key.NewBinding(key.WithKeys("tab"), key.WithHelp("tab", "select/reapply")),
			key.NewBinding(key.WithKeys("i"), key.WithHelp("i", "info")),
			key.NewBinding(key.WithKeys("enter"), key.WithHelp("enter", "re-apply")))
	// Keep the focused row where it was, matching by value like the Setup tree
	// does. This used to carry a raw index and decrement it by one "to
	// compensate for the headline row" — but rebuildHealth always prepends
	// that headline, so the index being read ALREADY counted it, and the
	// decrement moved the cursor up a row on every repaint. That is what made
	// ticking a fix seem to shift the selection: the mark landed one row
	// above the row you were on, and the next tick appeared to jump again.
	if prev == "" {
		// First build: there is nothing to restore yet, and index 0 is the
		// disabled headline. Selecting it put the cursor on a row that cannot
		// be acted on and drew no arrow, so the screen opened looking like it
		// had no cursor at all. Start on the first real fix, like every other
		// list.
		return p.selectFirst()
	}
	return p.KeepCursor(prev)
}

// healthHeadline states the finding in one plain sentence. The old header
// ("Files went missing on these modules :") described the mechanism rather
// than the result, and it was wrong for the infrastructure rows, which are not
// modules at all.
func healthHeadline(n int) string {
	switch n {
	case 0:
		return "Everything is in place — nothing to re-apply."
	case 1:
		return "1 piece needs attention (tick it, then Enter re-applies it):"
	default:
		return fmt.Sprintf("%d pieces need attention (tick the ones to re-apply, then Enter):", n)
	}
}

// healthShortLabel splits a catalog label into the piece's own name and the
// explanatory tail, so the row stays one line. "Live mode — performance
// session mode (…)" becomes "Live mode" + the rest as sub-text. Infra rows
// have no " — " and are already short, so they come back unchanged.
func healthShortLabel(it HealthRec) (short, long string) {
	label := it.Label
	if label == "" {
		return it.ID, ""
	}
	if i := strings.Index(label, " — "); i > 0 {
		return label[:i], label[i+3:]
	}
	return label, ""
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
// ── Status screen ───────────────────────────────────────────────────────────
// The Status screen used to be a static list of coloured dots dumped into a
// read-only Info pane, with a blank line between every module: no cursor, no
// per-row `i`, and the dots were the only thing on screen. It is now a real
// PICKER, laid out like Setup/Uninstall: modules grouped under their category
// folder (the backend tells us the category), a cursor you can move, and `i`
// on a module that opens its own detail. The circle is a STATUS dot, not a
// selection checkbox — nothing is ticked here.
//
//   - A row's leading circle is the module's state: ● ok, ◐ partial, ○ missing,
//     · na. It is styled with the theme colours like before, but the colour no
//     longer has to carry the meaning on its own: `i` spells the state out.
//   - `i` (or Enter) on a module shows its FULL detail — the compound state's
//     ":detail" half, e.g. "partial: missing its Omarchy menu row, its SUPER+ALT
//     keybinding" — plus the module id. It does NOT repeat the (long) module
//     description: the title in the list is already the description, and the
//     user asked for the status, not the marketing copy.
func statusDot(state string) string {
	switch state {
	case "ok":
		return tuikit.StyleOK.Render("●")
	case "partial":
		return tuikit.StyleWarn.Render("◐")
	case "missing":
		return tuikit.StyleErr.Render("○")
	default: // na
		return tuikit.StyleMuted.Render("·")
	}
}

// statusLabel renders a module's short label for the status list: the module
// id (NOT the long "what it does" description Setup shows), plus an explicit
// "uninstalled by you" marker when the user excluded it. The long description
// belongs to Setup; Status is about state, and the row stays one clean word.
func statusLabel(s StatusRec) string {
	label := s.Id
	if s.Excluded {
		label += tuikit.StyleMuted.Render("  (uninstalled by you)")
	}
	return label
}

// rebuildStatus rebuilds the Status screen's picker, preserving the cursor and
// restoring the folder help keys, exactly like rebuildSetup.
// rebuildStatus rebuilds the Status picker, preserving the cursor.
//
// EVERY category is opened first, unconditionally. Status is a health
// overview: a collapsed category hides modules the user came to read, and
// "open by default" has to hold on a REBUILD too, not only on first open —
// otherwise a collapse would be undone by the next refresh and the control
// would feel broken. A category the user has since collapsed keeps its state.
// rebuildStatus takes a POINTER receiver on purpose: it has to be able to
// create statusOpen when it is still nil. A value receiver would only seed a
// map belonging to its own copy, and the categories would stay collapsed for
// the caller — the state we were chasing when Status opened with every folder
// shut.
func (m *model) rebuildStatus() navPicker {
	idx := m.statusPicker.Index()
	if m.statusOpen == nil {
		m.statusOpen = map[string]bool{}
	}
	for _, s := range m.statusRecs {
		if s.Category != "" {
			if _, seen := m.statusOpen[s.Category]; !seen {
				m.statusOpen[s.Category] = true
			}
		}
	}
	if _, seen := m.statusOpen["other"]; !seen {
		m.statusOpen["other"] = true
	}
	return newNavPicker("", m.statusTree()).SetSize(m.contentSize()).
		SetHelpKeys(
			key.NewBinding(key.WithKeys("i"), key.WithHelp("i", "status")),
			key.NewBinding(key.WithKeys("right"), key.WithHelp("→", "open")),
			key.NewBinding(key.WithKeys("left"), key.WithHelp("←", "close")),
		).
		SelectIndex(idx)
}

// statusCategories returns the module categories in Setup's display order, the
// backend's own CATEGORIES order, so Status is organised exactly like Setup.
// Categories that end up with no module (a folder with nothing installed) are
// dropped — a Status row for an empty category is a dead end.
func (m model) statusCategories() []string {
	seen := map[string]bool{}
	for _, s := range m.statusRecs {
		if s.Category != "" {
			seen[s.Category] = true
		}
	}
	// Reuse the Setup/Uninstall folder order when it is loaded; otherwise fall
	// back to first-seen order so the list is still deterministic.
	order := make([]string, 0, len(seen))
	added := map[string]bool{}
	for _, f := range m.setupFolders {
		if seen[f.Folder] && !added[f.Folder] {
			order = append(order, f.Folder)
			added[f.Folder] = true
		}
	}
	if len(order) == 0 {
		for _, s := range m.statusRecs {
			if s.Category != "" && !added[s.Category] {
				order = append(order, s.Category)
				added[s.Category] = true
			}
		}
	}
	return order
}

// statusTree builds the folder tree of the Status screen. Every category is
// shown OPEN (status is read-only — there is nothing to fold away and the user
// asked for the list to be browsable with a single cursor), and each child is
// a module row.
func (m model) statusTree() []tuikit.PickerItem {
	byCat := map[string][]StatusRec{}
	var loose []StatusRec // modules the backend could not place in a category
	for _, s := range m.statusRecs {
		if s.Category == "" {
			loose = append(loose, s)
			continue
		}
		byCat[s.Category] = append(byCat[s.Category], s)
	}
	cats := m.statusCategories()
	items := make([]tuikit.PickerItem, 0, len(m.statusRecs)+len(cats)+1)

	// Children are INDENTED, with no "├─"/"└─" tree angles.
	//
	// Those angles were the file-tree convention and they read as a branch
	// hanging from the row above: on a list where a heading is inert and the
	// rows under it are the real content, a "└─" on the last child drew a line
	// back up towards the heading, which made each block look like it belonged
	// to the PREVIOUS category. Indentation alone says "these are under that
	// heading" without implying a connector.
	appendModule := func(s StatusRec) {
		items = append(items, tuikit.PickerItem{
			Display: "    " + statusDot(s.State) + "  " + statusLabel(s),
			Value:   "status:" + s.Id,
		})
		// A missing/na module stays SELECTABLE (you want `i` on it); only the
		// dot communicates the state.
	}

	// Folders fold like Setup's: a real row, selected normally, with the fold
	// glyph in the cursor slot. They were inert headings, which made them
	// impossible to reach and therefore impossible to collapse.
	appendFolder := func(cat, label string, mods []StatusRec, accent bool) {
		fold := tuikit.FoldExpanded
		if !m.statusOpen[cat] {
			fold = tuikit.FoldCollapsed
		}
		items = append(items, tuikit.PickerItem{
			Display: label,
			Value:   "status-cat:" + cat,
			Accent:  accent,
			Folder:  true,
			Fold:    fold,
		})
		if !m.statusOpen[cat] {
			return
		}
		for _, s := range mods {
			appendModule(s)
		}
	}

	for _, c := range cats {
		mods := byCat[c]
		if len(mods) == 0 {
			continue
		}
		appendFolder(c, m.categoryDisplayLabel(c), mods, c == "mosquito" && m.blinkOn)
	}
	// Modules with no category (the `apps` pseudo-module, mosquitomarchy-update)
	// go last under "Other" so nothing is ever hidden.
	if len(loose) > 0 {
		appendFolder("other", "Other", loose, false)
	}
	items = append(items, tuikit.PickerItem{Display: "Back", Value: "back"})
	return items
}

// statusCatOf extracts the category id from a status folder row value
// ("status-cat:<id>"), reporting false for anything else (a module row, Back).
func statusCatOf(v string) (string, bool) {
	if strings.HasPrefix(v, "status-cat:") {
		return strings.TrimPrefix(v, "status-cat:"), true
	}
	return "", false
}

// categoryDisplayLabel turns a category id into the human label the backend
// published for it (Setup's own folder label), falling back to the id when the
// tree has not been loaded yet. Keeps Status headers identical to Setup's.
func (m model) categoryDisplayLabel(id string) string {
	for _, f := range m.setupFolders {
		if f.Folder == id {
			return f.Label
		}
	}
	return id
}

// statusDetail is the `i`/Enter text for ONE module: its id and its pure
// status (state word + the ":detail" half when there is one). No module
// description — the list row is already the module's name.
func (m model) statusDetail(id string) string {
	for _, s := range m.statusRecs {
		if s.Id != id {
			continue
		}
		var b strings.Builder
		b.WriteString(tuikit.StyleHeader.Render(id) + "\n\n")
		state := s.State
		if s.Excluded {
			state += "  (uninstalled by you)"
		}
		b.WriteString("Status:  " + state + "\n")
		if s.Detail != "" {
			b.WriteString("Detail:  " + s.Detail + "\n")
		}
		if s.Category != "" {
			b.WriteString("Category: " + s.Category + "\n")
		}
		return b.String()
	}
	return "unknown module: " + id
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
		return "Crash notifications (AI diagnosis): on"
	}
	return "Crash notifications (AI diagnosis): off"
}

// settingsItems2 backs the new TOP-LEVEL Settings screen (before Close).
func settingsItems2() []tuikit.PickerItem {
	return []tuikit.PickerItem{
		{Display: crashNotifyLabel(), Value: "toggle-crash-notify"},
		{Display: "Back", Value: "back"},
	}
}

func backupItems(items []tuikit.PickerItem) []tuikit.PickerItem { return items }

// rebuildPreinstallPicker lists EVERY stock app, as asked: an app that is no
// longer installed (or is one of the user's own) is shown greyed and cannot be
// ticked, so the list does not silently shrink between two visits.
func (m model) rebuildPreinstallPicker() navPicker {
	items := []tuikit.PickerItem{{Display: "Omarchy preinstalls (tab = keep; enter or back asks before removing the ticked ones):", Value: "", Disabled: true}}
	checked := 0
	for _, r := range m.preinstalls {
		mark := "○"
		if m.preinstallChecked[r.Name] {
			mark = "●"
			checked++
		}
		// The mark goes in Badge, not glued onto Display. Rows are CENTERED as
		// a block, so a tick baked into the text made every line a different
		// width and therefore a different starting column — the list visibly
		// jumped, and a long "(your own app — kept)" shifted it again. Badge
		// sits in a fixed-width leading slot, so the labels stay in one column.
		it := tuikit.PickerItem{Display: r.Label, Value: r.Name, Badge: mark}
		switch {
		case !r.Installed:
			it.Suffix = "  (already removed)"
			it.Disabled = true
		case r.Protected:
			it.Suffix = "  (your own app — kept)"
			it.Disabled = true
		}
		items = append(items, it)
	}
	items = append(items,
		tuikit.PickerItem{Display: fmt.Sprintf("Remove the %d ticked preinstall(s)", checked), Value: "apply"},
		tuikit.PickerItem{Display: "Back", Value: "back"},
	)
	return newNavPicker("", items).SetSize(m.contentSize()).
		SetHelpKeys(
			key.NewBinding(key.WithKeys("tab"), key.WithHelp("tab", "keep / unkeep")),
		)
}

// applyMenuEntries folds a fetch result into the model: it re-seeds the tick
// baseline from what the menu file really contains, then rebuilds both the
// entries screen and the Setup folder that lists them.
//
// The baseline must be re-seeded on EVERY fetch, never only for names we have
// not seen: a fetch happens when Setup opens and again right after an apply,
// and the second one is where the old rule broke the screen — after stripping
// an entry the backend correctly said absent, but the baseline still said
// present because the name was already known, so ticking it again produced
// checked == orig and Enter answered "no changes to apply" for a restore the
// user had genuinely asked for.
//
// DEFAULT = what is installed right now. The picker applies a DELTA, so with
// everything unticked as the default only the ticked rows ever differed and
// Enter could only ever restore: the strip half of the screen was dead code.
func (m model) applyMenuEntries(me menuEntriesMsg) model {
	if me.err != nil {
		m.toast, _ = m.toast.SetErr(me.err.Error())
		m.menuEntriesLoaded = true
		return m
	}
	if len(me.rows) > 0 {
		m.menuEntries = me.rows
	}
	m.menuEntriesLoaded = true
	if m.menuEntryChecked == nil {
		m.menuEntryChecked, m.menuEntryOrig = map[string]bool{}, map[string]bool{}
	}
	for _, e := range m.menuEntries {
		m.menuEntryChecked[e.Name] = e.Present
		m.menuEntryOrig[e.Name] = e.Present
	}
	m.menuEntriesPicker = m.rebuildMenuEntriesPicker()
	// The Setup page shows them under their folder, so it has to be rebuilt
	// too or the folder keeps the list it had before the fetch.
	if m.top() == scrSetup {
		m.setupPicker = m.rebuildSetup()
	}
	return m
}

// rebuildMenuEntriesPicker renders the "Menu entries" cleaner: a tick mark =
// the marked menu block is present in the Omarchy menu. Tab/x toggle,
// Enter applies the delta (strip/restore via the backend).
func (m model) rebuildMenuEntriesPicker() navPicker {
	// rows
	items := make([]tuikit.PickerItem, 0, len(m.menuEntries)+1)
	prev := m.menuEntriesPicker.SelectedValue()
	if !m.menuEntriesLoaded {
		// Distinguishes "still fetching" and "the backend found nothing"
		// from "loaded fine": without it both cases render a lone "Back"
		// row, which is what made the screen look simply broken.
		items = append(items, tuikit.PickerItem{Display: "loading…", Value: "", Disabled: true})
	}
	for _, e := range m.menuEntries {
		// The tick is the DESIRED state (what Enter will apply) and the word is
		// the CURRENT one. They used to be the same field, so ticking an absent
		// entry made it announce itself as "installed" before anything ran.
		// The dot IS the state: ● = will be in the menu when you press Enter,
		// ○ = will be removed. The word "(installed)" used to sit beside every
		// row and only restated what the dot already said, at the cost of
		// doubling the width of the line. An entry that is currently absent
		// but ticked now (a pending restore) still reads correctly, because
		// the dot shows the DESIRED state, not the current one.
		tick := "○"
		if m.menuEntryChecked[e.Name] {
			tick = "●"
		}
		// Badge, not inline: rows are centered, so a tick baked into Display
		// gave every line a different width and none of them a shared start
		// column. Same rule as the preinstalls rows.
		items = append(items, tuikit.PickerItem{
			Display: e.Label,
			Badge:   tick,
			Value:   "mentry:" + e.Name,
		})
	}
	items = append(items, tuikit.PickerItem{Display: "Back", Value: "back"})
	p := newNavPicker("Menu entries — tick = keep in the Omarchy menu (Enter applies the change):", items).SetSize(m.contentSize()).
		SetHelpKeys(
			key.NewBinding(key.WithKeys("tab", "x"), key.WithHelp("tab/x", "toggle")),
			key.NewBinding(key.WithKeys("i"), key.WithHelp("i", "info")),
			key.NewBinding(key.WithKeys("enter"), key.WithHelp("enter", "apply")),
		)
	// Keep the row the user is on when this is a toggle repaint. Resetting to
	// 0 meant tab/x was not a toggle you could repeat down the list: every
	// press jumped you back to the top.
	return p.KeepCursor(prev)
}
