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
	// Flush whatever a branch could not return itself, so a deferCmd() call
	// survives the early returns of the update() switch.
	if m.deferred != nil {
		cmd = tea.Batch(cmd, m.deferred.Cmd)
		m.deferred = nil
	}
	return m, cmd
}

func (m model) update(msg tea.Msg) (model, tea.Cmd) {
	switch msg := msg.(type) {
	// THE SETTINGS RULE (see PickerItem.Toggle). A toggle repaints FIRST and
	// applies SECOND, so the row answers the instant it is chosen and the menu
	// never blocks on a subprocess. The write is a command, and its result is
	// reconciled against the setting that is REALLY in place, so a refused
	// write puts the row back instead of leaving the menu lying.
	case tuikit.PickerToggleOptionMsg:
		if msg.Value != crashNotifyValue {
			return m, nil
		}
		m.crashNotify = msg.Next
		m.pickPicker = newNavPicker("Extras:", m.settingsItems2()).SetSize(m.contentSize()).
			KeepCursor(m.pickPicker.SelectedValue())
		return m, crashNotifyApplyCmd(msg.Next)

	case tuikit.ToggleOptionResultMsg:
		if msg.Value != crashNotifyValue {
			return m, nil
		}
		if m.crashNotify != msg.On {
			m.crashNotify = msg.On
			m.pickPicker = newNavPicker("Extras:", m.settingsItems2()).SetSize(m.contentSize()).
				KeepCursor(m.pickPicker.SelectedValue())
		}
		if msg.Failed {
			m.toast, _ = m.toast.SetWarn("could not change the setting — put back")
		}
		return m, nil

	case crashNotifyMsg:
		m.crashNotify = msg.on
		m.crashNotifyLoaded = true
		if m.top() == scrSettings {
			m.pickPicker = newNavPicker("Extras:", m.settingsItems2()).SetSize(m.contentSize())
		}
		return m, nil

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
			if m.top() == scrPreinstalls {
				// ctrl+c leaves the preinstalls like "Back" does: it cancels the
				// uninstall they were in front of rather than letting the user
				// fall into a confirmation they never finished choosing.
				m = m.cancelUninstall()
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
				// An apply/uninstall is the one thing that can change the
				// agentic-stuff answer, so ask again — in the background, as
				// ever. aiRemovedMsg rebuilds the row when it lands.
				m.deferCmd(fetchAIRemovedCmd())
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
			// writeRunLog, NOT reportCrash: reportCrash also raises the critical
			// "<tool> failed" notification, and calling it here fired that on every
			// successful run — a crash log full of green ticks plus an AI diagnosis
			// offer for a backup that had just worked.
			writeRunLog(m.workingLabel, out)
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
			case "theme-create":
				// The generator finished. Deliberately no toast and no
				// auto-apply: the whole point is that the user sees the three
				// options (log / back / apply) and applies on purpose. The
				// name screen's value is still in m.themeInput.
				m.themeCreated = m.themePendingName
				m.themeLog = defaultThemeLog()
				m.pendingAction = ""
				m.themeDonePicker = m.rebuildThemeDone()
				// REPLACE, not push. The runner screen is still underneath:
				// startWorking replaced the stack with [working], and pushing
				// here made it [working, done]. "Back" then popped the done
				// screen and landed the user back on the runner -- the raw log,
				// no frame, nothing to press. It read as "Back takes me to the
				// log and traps me there", which is exactly what it did. The
				// runner's work is finished, so its screen is what the success
				// screen should take over from: [done] over [main].
				m.replace(scrThemeDone)
				return m, nil
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

	case themeImagesMsg:
		// Guard on the screen: a slow answer for a folder the user already
		// backed out of must not rebuild a picker that is no longer on screen.
		if m.top() != scrThemeImage {
			return m, nil
		}
		m = m.themeImagesArrived(msg)
		return m, nil

	case themeCreateMsg:
		// The apply finished. The runner screen replaced the main menu, so
		// drop it: the user is back at the menu they started from, with the
		// confirmation as a toast. Leaving the runner on the stack made Esc
		// pop an empty stack instead of the menu.
		m.nav = []screen{scrMain}
		m.themeApplyName = ""
		if msg.err != nil {
			m.toast, _ = m.toast.SetErr("could not apply: " + msg.err.Error())
			return m, nil
		}
		m.toast, _ = m.toast.SetOK(fmt.Sprintf("'%s' applied", msg.name))
		return m, nil

	case firstRunMsg:
		if m.top() == scrMain {
			m.pendingAction = "add-shortcut"
			m.pendingMsg = "Add a keyboard shortcut (SUPER + ALT + M) to open mosquitOmarchy at any time?"
			m.pendingNo = "Not now"
			m.pendingYes = "Add shortcut"
			m.push(scrConfirm)
			m.confirm = tuikit.NewConfirm(m.pendingMsg, m.pendingNo, m.pendingYes)
		}
		return m, nil

	case aiRemovedMsg:
		// The answer only changes the greyed-out state of one row, so rebuild
		// whichever Setup-shaped screen is on top and nothing else.
		m.aiRemoved, m.aiRemovedKnown = msg.removed, msg.err == nil
		switch m.top() {
		case scrSetup:
			m.setupPicker = m.rebuildSetup()
		case scrSetupCat:
			m.setupCatPicker = m.rebuildSetupCat()
		case scrBackupOptions:
			m.backupPicker = m.rebuildBackupOptions()
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
		m.backupOpts.HasZen = msg.zen
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
		case "fixes":
			// The fetch existed (fetchFixesCmd) and nothing ever handled its
			// answer, so the catalog was fetched by nobody. The screen rebuilds
			// only when the list lands, which is why it opens on "loading…".
			if msg.err != nil {
				m.toast, _ = m.toast.SetErr("could not read the quick fixes: " + msg.err.Error())
				m.pop()
				return m, nil
			}
			m.quickFixes = msg.fixes
			m.quickFixLoaded = true
			if m.top() == scrQuickFixes {
				m.quickFixPicker = m.rebuildQuickFixes()
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

	case themeImagePickedMsg:
		// An image chosen in the external chooser (Theming → Select Image…).
		// Empty means the window was closed without choosing, which is a cancel
		// and must leave the screen exactly as it was — not an error to report.
		if msg.path == "" {
			return m, nil
		}
		m.themeDir = msg.dir
		m.themeImage = filepath.Base(msg.path)
		// Straight to the name: the folder is settled by having picked a file
		// inside it, so the folder and image screens have nothing left to ask.
		return m, m.themeAskName(stripImageExt(m.themeImage), "")

	case themeFolderPickedMsg:
		if msg.path == "" {
			return m, nil
		}
		return m, setThemeDefaultDirCmd(msg.path)

	case themeListMsg:
		if msg.err != nil {
			m.toast, _ = m.toast.SetWarn("could not list the themes: " + msg.err.Error())
			return m, nil
		}
		m.themeList = msg.themes
		m.themeChecked = map[string]bool{}
		m.push(scrThemeUninstall)
		m.themeUninstallPicker = m.rebuildThemeUninstall()
		return m, nil

	case themeStockMsg:
		if msg.err != nil {
			m.toast, _ = m.toast.SetWarn("could not read the stock themes: " + msg.err.Error())
			return m, nil
		}
		m.themeStock = msg.present
		m.push(scrThemeRestore)
		m.themeRestorePicker = m.rebuildThemeRestore()
		return m, nil

	case toastThemeMsg:
		m.toast, _ = m.toast.SetOK(msg.text)
		return m, nil

	case themePickErrMsg:
		m.toast, _ = m.toast.SetWarn(msg.err.Error())
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
			// Saved HERE, on the keystroke, not when the backup runs: leaving
			// this screen and coming back has to show the same ticks, and so
			// does quitting the TUI.
			saveBackupSelection(m.backupItems, m.backupChecked)
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
		case scrQuickFixes:
			// Same reasoning as scrMenuEntries below: this global switch runs
			// first and returns unconditionally, so a Tab branch inside the
			// screen's own case would be dead code and tab/x would do nothing.
			if m.quickFixChecked == nil {
				m.quickFixChecked = map[string]bool{}
			}
			if _, id, ok := tuikit.TreeSplit(msg.Value); ok {
				m.quickFixChecked[id] = !m.quickFixChecked[id]
				m.quickFixPicker = m.rebuildQuickFixes()
			}
			return m, nil
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
			// ←/→ act on the folder the cursor is IN, not only on its title:
			// walking down into a category and pressing ← closes that category.
			if id, inTree := tuikit.TreeParentOf(m.setupPicker.items, m.setupPicker.SelectedValue()); inTree {
				if msg.Dir > 0 {
					m.folderOpen[id] = true
				} else {
					delete(m.folderOpen, id)
				}
				keep := m.setupPicker.SelectedValue()
				// Folding from inside a category removes the very row the
				// cursor is on, so there is nothing to keep — land on the
				// category we just closed, which is where the user came from.
				if msg.Dir < 0 {
					keep = tuikit.TreeValue(tuikit.TreeFolderPrefix, id)
				}
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
			case "zen":
				m.backupOpts.Zen = !m.backupOpts.Zen
			case "encrypt":
				m.backupOpts.Encrypt = !m.backupOpts.Encrypt
			}
			// Saved on every change, not on the way out: "retained when leaving
			// the page" also has to cover closing the TUI by any route, and a
			// save-on-leave only fires for the leave that happens to be coded.
			saveBackupOpts(m.backupOpts)
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
			if m.pendingAction == "quick-fixes" {
				// Declined: nothing runs, and the ticks stay as they were so
				// the set can be adjusted and applied straight away.
				return m, nil
			}
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
				// "Keep them" (or Cancel): the stock apps stay. That was a
				// decision about the PREINSTALLS, not about the uninstall that
				// this page was in front of, so the uninstall carries on. (To
				// cancel the uninstall itself, back out of the preinstalls page
				// instead — that is the only exit that drops it.)
				m.toast, _ = m.toast.SetWarn("preinstalls kept")
				return m.resumeUninstall()
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
		case "add-shortcut":
			return m.startWorking("Adding the shortcut", workingArgs("add-shortcut", nil)...)
		case "theme-remove-any":
			names := append([]string{}, m.pendingArgs...)
			m.pendingArgs = nil
			mm, cmd := m.startWorking(
				fmt.Sprintf("Removing %d theme(s)", len(names)),
				workingArgs("theme-remove-any", names)...)
			mm.themeRemoveCount = len(names)
			return mm, cmd
		case "theme-create":
			// Streamed through the runner like every other long action, so a
			// slow palette extraction is visible instead of freezing the
			// screen. The name comes from themePendingName, set when the name
			// field was submitted: TextInput has no getter, so it cannot be
			// read back here.
			name := m.themePendingName
			unlock := "off"
			if m.themeUnlockStyle {
				unlock = "on"
			}
			// Drop the WHOLE theming stack, not one screen. The flow grew a
			// step — main -> folder -> name -> unlock -> this confirm — and
			// popping once left folder and unlock underneath, so the runner
			// replaced the confirm on a five-deep stack. The success screen then
			// pushed on top of that: it WAS shown, but "Back" walked up through
			// screens the user thought they had already left, and the prompt to
			// apply read as one step of a wizard nobody could get out of.
			//
			// Rewinding to main and pushing the runner is what the other
			// actions do, and it makes the success screen the only thing between
			// the user and the menu.
			m.nav = []screen{scrMain}
			m.themeDonePicker = m.rebuildThemeDone()
			return m.startWorking("Creating the theme",
				workingArgs("theme-create", []string{m.themeDir, m.themeImage, name, "no", unlock})...)
		case "quick-fixes":
			// One backend call runs the whole marked set through the same
			// run_fixes() the shell launcher uses, so RESULTS accounting and the
			// final report are identical whichever way a fix is started.
			ids := m.pendingFixIDs
			m.pendingFixIDs = nil
			return m, quickFixesRunCmd(ids)
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
		// The theme flow's two text screens. Handled here, before the
		// passphrase/keybinding cases, because Enter on a TextInput arrives as
		// InputResultMsg and never as a picker result.
		if m.top() == scrThemeInput {
			if msg.Canceled {
				m.pop()
				return m, nil
			}
			return m.themeInputDone(msg.Value)
		}
		if m.top() == scrThemeName {
			if msg.Canceled {
				m.pop() // back to the image list
				return m, nil
			}
			name := strings.TrimSpace(msg.Value)
			if name == "" {
				m.toast, _ = m.toast.SetWarn("a theme needs a name")
				return m, nil
			}
			m.themePendingName = name
			// Then the lock/boot-screen toggle: it comes AFTER the name on
			// purpose. Before the name there is no theme to talk about, and the
			// row would read as a generic setting; after it, the question is
			// about THIS theme, and it is the moment where knowing the name
			// makes the choice obvious.
			m.push(scrThemeUnlock)
			m.themeUnlockPicker = m.rebuildThemeUnlock()
			return m, nil
		}
		if m.top() == scrBackupName {
			if msg.Canceled {
				m.pop()
				return m, nil
			}
			// Trimmed, and an empty answer is a VALID answer: it means "name it
			// by its date", which is what the row said before anything was typed.
			// Refusing empty here would make the name un-clearable.
			m.backupOpts.Name = strings.TrimSpace(msg.Value)
			saveBackupOpts(m.backupOpts)
			m.backupOptPicker = m.rebuildBackupOptions()
			m.pop()
			return m, nil
		}
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
			// If we're on the loading health screen, pop it
			if m.top() == scrHealth && m.healthItems == nil {
				m.pop()
			}
			return m, nil
		}
		if len(msg.items) == 0 {
			m.toast, _ = m.toast.SetOK("health check: everything is in place")
			// Stay on the health screen (show empty list) instead of popping to main.
			m.healthItems = nil
			m.healthPicker = m.rebuildHealth()
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
		// Screen is already pushed; just rebuild the picker
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
		// `i` was free here: navpicker and the kit's own key set do not claim
		// it, and it is already the "explain this" key on six other screens, so
		// using it again is the consistent choice rather than a new one.
		if km, ok := msg.(tea.KeyMsg); ok && km.String() == "i" {
			m.info = tuikit.NewInfo(m.homePageInfo()).SetSize(m.contentSize())
			m.push(scrInfo)
			return m, nil
		}
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
				// The category the cursor is IN, not only the one it is on:
				// sitting on a module and pressing ← closes its category.
				if cat, ok := tuikit.ParentFolderOf(m.statusPicker.items, "status-cat:", v); ok {
					if km.String() == "left" {
						m.statusOpen[cat] = false
					} else {
						m.statusOpen[cat] = true
					}
					keep := v
					if km.String() == "left" {
						// The row we were on is gone with the category; land on
						// the category we just closed.
						keep = "status-cat:" + cat
					}
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
		// "i" opens the INFO for the row under the cursor, and Enter performs
		// the action.
		//
		// It used to be the other way round: `i` re-dispatched Enter, so `i`
		// installed the selection, and the description moved to `?`. The reason
		// given at the time was that `i` had no info branch for a plain module
		// row, so it did nothing at all on the thing you actually install — but
		// the gap was a missing branch, not a wrong key. The branch exists now
		// (a module row is an "item:" row, and the handler below answers it from
		// setupByValue), so `i` can go back to doing what its help text and
		// every other screen in these apps say it does.
		if km, ok := msg.(tea.KeyMsg); ok && (km.String() == "i" || km.String() == "?") {
			v := m.setupPicker.SelectedValue()
			// Menu entries FIRST: it is a cat: row, but its description is not
			// built from setupItems (it has none), so the generic branch below
			// would answer "Nothing to do here right now" about a folder that
			// plainly has something in it.
			if v == tuikit.TreeValue(tuikit.TreeFolderPrefix, menuEntriesFolder) {
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
			if strings.HasPrefix(v, "cat:") {
				m.info = tuikit.NewInfo(m.categoryInfo(strings.TrimPrefix(v, "cat:"))).SetSize(m.contentSize())
				m.push(scrInfo)
				return m, nil
			}
			if strings.HasPrefix(v, "item:") {
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
				if len(m.uninstallWait) > 0 {
					// The preinstalls removal failed, but that is no reason to
					// swallow the uninstall the user asked for: say what failed
					// and let the uninstall proceed.
					return m.resumeUninstall()
				}
				return m, nil
			}
			if pm.done != "" {
				m.pop()
				m.toast, _ = m.toast.SetOK("preinstalls removed")
				// The preinstalls step was the FIRST step of an uninstall that
				// was waiting, so the uninstall now gets its confirmation and
				// only then runs. Before, removing preinstalls and uninstalling
				// modules were two independent actions.
				if len(m.uninstallWait) > 0 {
					return m.resumeUninstall()
				}
				return m, tea.Batch(fetchTreeCmd("uninstall-tree"), blinkCmd(), fetchAIRemovedCmd())
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
	case scrQuickFixes:
		// Enter and Esc arrive as PickerResultMsg and are handled by
		// screenPicked; catching one here would swallow it, which is the very
		// bug that made Enter do nothing on the menu entries screen.
		if _, ok := msg.(tuikit.PickerResultMsg); ok {
			return m, nil
		}
		if km, ok := msg.(tea.KeyMsg); ok && km.String() == "i" {
			// The fix's own long description, same key and same Info screen as
			// everywhere else. The backend already sends it in the row's `info`.
			if _, id, ok := tuikit.TreeSplit(m.quickFixPicker.SelectedValue()); ok {
				txt := id
				for _, f := range m.quickFixes {
					if f.Key == id && f.Info != "" {
						txt = f.Info
						break
					}
				}
				m.info = tuikit.NewInfo(txt).SetSize(m.contentSize())
				m.push(scrInfo)
			}
			return m, nil
		}
		if qf, ok := msg.(quickFixesRunMsg); ok {
			if qf.err != nil {
				m.toast, _ = m.toast.SetErr("quick fix failed: " + qf.err.Error())
				return m, nil
			}
			m.toast, _ = m.toast.SetOK(qf.what)
			// Straight back to the Setup page the folder was opened from, so the
			// result of the fix is visible on the row it fixed.
			m.pop()
			m.setupPicker = m.rebuildSetup()
			return m, nil
		}
		m.quickFixPicker, cmd = m.quickFixPicker.Update(msg)
	case scrBackupRestore:
		m.backupPicker, cmd = m.backupPicker.Update(msg)
	case scrBackupOptions:
		m.backupOptPicker, cmd = m.backupOptPicker.Update(msg)
	case scrBackupApps:
		m.backupAppsPicker, cmd = m.backupAppsPicker.Update(msg)
	case scrThemeFolder:
		// Needed: without a case here the picker never receives the KeyMsg, so
		// the screen draws its rows but arrows and Enter go nowhere — which
		// reads as a freeze, not as a missing handler.
		m.themeFolderPicker, cmd = m.themeFolderPicker.Update(msg)
	case scrThemeUninstall:
		if tl, ok := msg.(tuikit.PickerToggleMsg); ok {
			m.toggleThemeTick(tl.Value)
			m.themeUninstallPicker = m.rebuildThemeUninstall()
			return m, nil
		}
		if res, ok := msg.(tuikit.PickerResultMsg); ok {
			if res.Canceled || res.Value == "back" {
				m.pop()
				return m, nil
			}
			// Tab ticks, so Enter on an unticked row still removes that one
			// theme: the multi-select is the convenience, not a gate.
			targets := []string{res.Value}
			if m.themeChecked[res.Value] {
				targets = targets[:0]
				for _, t := range m.themeList {
					if m.themeChecked[t.Name] {
						targets = append(targets, t.Name)
					}
				}
			}
			n := len(targets)
			m.pendingArgs = targets
			m.pendingAction = "theme-remove-any"
			m.pendingMsg = fmt.Sprintf("Delete %d theme(s)?\n\n%s\n\nNothing is kept: the theme folder is removed, not moved to a trash.",
				n, strings.Join(targets, ", "))
			m.pendingNo = "Cancel"
			m.pendingYes = "Delete"
			m.push(scrConfirm)
			m.confirm = tuikit.NewConfirm(m.pendingMsg, m.pendingNo, m.pendingYes)
			return m, nil
		}
		var cmd tea.Cmd
		m.themeUninstallPicker, cmd = m.themeUninstallPicker.Update(msg)
		return m, cmd

	case scrThemeRestore:
		if res, ok := msg.(tuikit.PickerResultMsg); ok {
			if res.Canceled || res.Value == "back" {
				m.pop()
				return m, nil
			}
			return m.startWorking("Restoring the stock themes", "theme-restore-stock")
		}
		var cmd tea.Cmd
		m.themeRestorePicker, cmd = m.themeRestorePicker.Update(msg)
		return m, cmd

	case scrThemeUnlock:
		if km, ok := msg.(tea.KeyMsg); ok {
			switch km.String() {
			case "left", "right", "l", "r":
				m.themeUnlockStyle = !m.themeUnlockStyle
				m.themeUnlockPicker = m.rebuildThemeUnlock()
				return m, nil
			}
		}
		m.themeUnlockPicker, cmd = m.themeUnlockPicker.Update(msg)
	case scrThemeImage:
		m.themeImagePicker, cmd = m.themeImagePicker.Update(msg)
	case scrThemeDone:
		m.themeDonePicker, cmd = m.themeDonePicker.Update(msg)
	case scrConfirm:
		m.confirm, cmd = m.confirm.Update(msg)
	case scrPassphrase:
		m.passInput, cmd = m.passInput.Update(msg)
	case scrBackupName:
		m.backupNameInput, cmd = m.backupNameInput.Update(msg)
	case scrThemeInput, scrThemeName:
		// Both text screens share one field; themeInputStep says which question
		// it is answering, and scrThemeInput's Enter is handled in the
		// InputResultMsg case rather than here.
		m.themeInput, cmd = m.themeInput.Update(msg)
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
func folderLabel(m model, fid string) string {
	for _, f := range m.setupFolders {
		if f.Folder == fid {
			return f.Label
		}
	}
	return fid
}

// screenPicked routes a picker's Enter result.
// quickFixesFolder is the Setup folder id the backend gives the quick fixes.
const quickFixesFolder = "fixes"

// isQuickFixKey reports whether a tree key is one of the quick fixes.
//
// The list is read from the backend's own catalog rather than hard-coded, so a
// fix added to FIXES in the setup script is recognised here without touching
// the TUI — the two lists cannot drift, which is the same reason module_version
// stopped carrying its own.
func (m model) isQuickFixKey(key string) bool {
	for _, f := range m.quickFixes {
		if f.Key == key {
			return true
		}
	}
	// Before the catalog lands, the rows on the Setup page are the only
	// evidence there is; they are already in m.setupItems.
	for _, it := range m.setupItems {
		if it.Folder == quickFixesFolder && it.Key == key {
			return true
		}
	}
	return false
}

// openQuickFixes pushes the Quick fixes screen.
//
// The folder row used to be the ONLY entry point the shell launcher had, and
// the TUI dropped it on the floor, so this is the route that makes the ten
// fixes reachable from Setup at all.
func (m model) openQuickFixes() (tea.Model, tea.Cmd) {
	m.push(scrQuickFixes)
	m.quickFixChecked = map[string]bool{}
	m.quickFixPicker = newNavPicker("", []tuikit.PickerItem{{Display: "loading…", Value: "", Disabled: true}}).SetSize(m.contentSize())
	return m, fetchFixesCmd()
}

// quickFixesList renders the catalog, grouped by category, the way the shell
// picker groups it. The rows are ticks, not choices: Tab marks, Enter applies
// the marked set.
func (m model) quickFixesList() []tuikit.PickerItem {
	if len(m.quickFixes) == 0 {
		return []tuikit.PickerItem{{Display: "no quick fix available", Value: "", Disabled: true}}
	}
	var order []string
	byCat := map[string][]tuikit.TreeItem{}
	for _, f := range m.quickFixes {
		cat := f.Cat
		if cat == "" {
			cat = "Other"
		}
		if _, seen := byCat[cat]; !seen {
			order = append(order, cat)
		}
		byCat[cat] = append(byCat[cat], tuikit.TreeItem{
			ID:      f.Key,
			Label:   f.Label,
			Checked: m.quickFixChecked[f.Key],
			Info:    f.Info,
		})
	}
	var out []tuikit.PickerItem
	for _, cat := range order {
		items := byCat[cat]
		open := map[string]bool{cat: true}
		out = append(out, tuikit.BuildFolderTree(
			[]tuikit.TreeFolder{{ID: cat, Label: cat, Total: len(items), Marked: m.markedFixes(items)}},
			map[string][]tuikit.TreeItem{cat: items}, open, false)...)
	}
	return out
}

func (m model) markedFixes(items []tuikit.TreeItem) int {
	n := 0
	for _, it := range items {
		if m.quickFixChecked[it.ID] {
			n++
		}
	}
	return n
}

// checkedQuickFixes is the marked set, in catalog order so the confirmation
// reads the same way every time.
func (m model) checkedQuickFixes() []string {
	var out []string
	for _, f := range m.quickFixes {
		if m.quickFixChecked[f.Key] {
			out = append(out, f.Key)
		}
	}
	return out
}

// rebuildQuickFixes re-renders the Quick fixes list under the current ticks.
func (m model) rebuildQuickFixes() navPicker {
	idx := map[string]int{}
	for i, it := range m.quickFixPicker.Items() {
		if _, id, ok := tuikit.TreeSplit(it.Value); ok {
			idx[id] = i
		}
	}
	cur := m.quickFixPicker.SelectedValue()
	return newNavPicker("", m.quickFixesList()).SetSize(m.contentSize()).
		SetHelpKeys(
			key.NewBinding(key.WithKeys("tab", "x"), key.WithHelp("tab/x", "select")),
			key.NewBinding(key.WithKeys("i"), key.WithHelp("i", "info")),
			key.NewBinding(key.WithKeys("enter"), key.WithHelp("enter", "apply selection")),
		).
		KeepCursor(cur)
}

func (m model) screenPicked(res tuikit.PickerResultMsg) (model, tea.Cmd) {
	if res.Canceled {
		// Esc at the main menu asks for the same exit confirmation as Close;
		// anywhere else it backs out one level.
		if m.top() == scrMain {
			return m.closeConfirm()
		}
		m.pop()
		// Anything whose rows are DERIVED from a sub-screen has to be rebuilt on
		// the way back out, and esc is the way people actually leave.
		//
		// The Backup options screen is the one that was broken: its "N selected"
		// figure is computed from the ticks made in the Apps sub-menu, and the
		// handler that rebuilt it (`case scrBackupApps:` below) is unreachable
		// from here because Canceled returns before the switch. So esc left the
		// count stale, and it only caught up when an unrelated key in the options
		// screen happened to rebuild the picker — which is exactly the symptom
		// reported: "it does not update, then an arrow key updates it".
		switch m.top() {
		case scrSetup:
			m.setupPicker = m.rebuildSetup()
		case scrBackupOptions:
			m.backupOptPicker = m.rebuildBackupOptions()
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
			return m, tea.Batch(fetchTreeCmd("setup"), blinkCmd(), fetchUpdateCheckCmd(), fetchMenuEntriesCmd(), fetchAIRemovedCmd())
		case "uninstall":
			// Same category/folder tree as Setup, but only the INSTALLED
			// entries, and Enter uninstalls instead of installing.
			m.treeMode = "uninstall"
			m.selected = map[string]bool{}
			m.folderOpen = map[string]bool{}
			m.filterText = ""
			m.push(scrSetup)
			m.setupPicker = newNavPicker("", []tuikit.PickerItem{{Display: "loading…", Value: "", Disabled: true}}).SetSize(m.contentSize())
			return m, tea.Batch(fetchTreeCmd("uninstall-tree"), blinkCmd(), fetchAIRemovedCmd())
		case "keybindings":
			// Its own row in the main menu, next to the other tools, rather
			// than buried as one more folder inside Setup and Uninstall: the
			// two trees only ever added a hop before reaching the same screen.
			m.push(scrKB)
			m.kbPicker = m.rebuildKB()
			return m, nil
		case "theme":
			// Right after Keybindings: both are "configure the desktop", not
			// "install something", which is why neither lives under Setup.
			m.themeFolderPicker = m.rebuildThemeFolderPicker()
			m.push(scrThemeFolder)
			return m, nil
		case "health":
			// Push the health screen immediately with a loading indicator, then fetch.
			m.healthItems = nil
			m.healthChecked = map[string]bool{}
			m.push(scrHealth)
			m.healthPicker = m.rebuildHealth()
			return m, fetchHealthCmd()
		case "backup":
			m.push(scrBackup)
			m.backupPicker = newNavPicker("", backupActions()).SetSize(m.contentSize())
			return m, nil
		case "settings":
			// Plugin-level toggles from the main menu (the "Extras" row
			// right before Close).
			m.push(scrSettings)
			// Show the cached value straight away, then correct it if the
			// backend says otherwise. The list is a pure function of the cache
			// now, so opening Extras costs no subprocess to draw.
			m.pickPicker = newNavPicker("Extras:", m.settingsItems2()).SetSize(m.contentSize())
			if !m.crashNotifyLoaded {
				return m, fetchCrashNotifyCmd()
			}
			return m, nil
		case "close":
			return m.closeConfirm()
		}

	case scrQuickFixes:
		// A leaf row is a TICK, not a choice: pressing Enter on it applies the
		// whole marked set, which is what the shell picker did and what a batch
		// of repairs needs. A folder row does nothing (the arrows fold it).
		if strings.HasPrefix(res.Value, tuikit.TreeFolderPrefix) {
			return m, nil
		}
		if !strings.HasPrefix(res.Value, tuikit.TreeItemPrefix) {
			return m, nil
		}
		ids := m.checkedQuickFixes()
		if len(ids) == 0 {
			// Nothing marked: the row under the cursor is the one being asked
			// about, so Enter is never a dead key.
			if _, id, ok := tuikit.TreeSplit(res.Value); ok {
				ids = []string{id}
			}
		}
		if len(ids) == 0 {
			m.toast, _ = m.toast.SetWarn("no quick fix selected")
			return m, nil
		}
		m.pendingAction = "quick-fixes"
		m.pendingFixIDs = ids
		m.pendingMsg = fmt.Sprintf("Apply %d quick fix(es)?\n\n%s", len(ids), strings.Join(ids, "\n"))
		m.pendingNo = "Cancel"
		m.pendingYes = "Apply"
		m.push(scrConfirm)
		m.confirm = tuikit.NewConfirm(m.pendingMsg, m.pendingNo, m.pendingYes)
		return m, nil

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
				m.kpxGnomeRm = 0
				return m.startUninstall(keys, fmt.Sprintf("Uninstall %d selected item(s)?\n\n%s", len(keys), strings.Join(keys, "\n")))
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
		// "Menu entries" is a folder row too, but Enter on it opens the
		// entries screen. It has to be recognised BEFORE the generic
		// folder early-return below, which swallowed `cat:menu-entries`
		// whole: the row took focus, the arrows set the fold state, and
		// nothing ever happened on Enter — so the menu blocks could not be
		// deployed from Setup at all. The value here is the TREE value
		// ("cat:menu-entries"), not the bare folder id the old check
		// compared against, which is why it never matched.
		if res.Value == tuikit.TreeValue(tuikit.TreeFolderPrefix, menuEntriesFolder) {
			m.push(scrMenuEntries)
			m.menuEntryChecked = map[string]bool{}
			m.menuEntryOrig = map[string]bool{}
			m.menuEntries = nil
			m.menuEntriesLoaded = false
			return m, fetchMenuEntriesCmd()
		}
		// Fixes are NOT a sub-screen. The backend already returns every fix as a
		// child row of the "fixes" folder, in the same tree as every other
		// category, so the folder expands where it stands and Enter on it does
		// what Enter on every other folder does: nothing but keep you on the
		// page. It used to push its own list, which was the same rows a second
		// time behind an extra keystroke — the whole point of the tree is that
		// a category opens in place.
		//
		// A fix's own row still routes here, because it is a repair and not a
		// module: falling through to the module path would offer to "install"
		// something that does not exist.
		if _, key := splitSetupValue(res.Value); key != "" && m.isQuickFixKey(key) {
			mm, cmd := m.openQuickFixes()
			return mm.(model), cmd
		}
		if strings.HasPrefix(res.Value, tuikit.TreeFolderPrefix) {
			return m, nil
		}
		// Enter on a MODULE row installs just that one: a single click for a
		// single module, with no tick-then-apply round trip. Tab is still there
		// to select several and apply them in one go.
		if strings.HasPrefix(res.Value, tuikit.TreeItemPrefix) {
			v := res.Value
			// The Preinstalls row opens its list. It is not a module, so it
			// must not fall through to the install path below and produce a
			// confirmation for removing a package called "preinstalls:choose".
			if _, key := splitSetupValue(v); key == preinstallsKey {
				return m.openPreinstalls()
			}
			if it, ok := m.setupByValue[v]; ok {
				if it.Disabled {
					m.toast, _ = m.toast.SetErr("nothing to do here")
					return m, nil
				}
				folder, key := splitSetupValue(v)
				// Uninstall mirrors install on the same page: Enter on a module
				// removes exactly that one, in either mode.
				if m.treeMode == "uninstall" {
					return m.startUninstall([]string{key}, fmt.Sprintf("Uninstall %s?", it.Label))
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
				// Nothing ticked: no removal to confirm, so the step is over and
				// the uninstall it was in front of carries on. Backing out of
				// the page is the way to cancel the whole thing.
				m.toast, _ = m.toast.SetWarn("no preinstall removed")
				return m.resumeUninstall()
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
		if res.Canceled || res.Value == "back" || res.Value == "" {
			// Backing out cancels the uninstall this page was in front of.
			// It used to apply the selection instead, which meant there was no
			// way to change your mind once you had opened the preinstalls: the
			// only exit removed something. pop() reports the cancellation and
			// leaves the module ticks exactly as they were.
			m = m.cancelUninstall()
			m.pop()
			return m, nil
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

		if m.treeMode == "uninstall" {
			keys := m.selectedKeysOfCat(m.setupCat)
			if len(keys) == 0 {
				keys = m.highlightedKey()
			}
			if len(keys) == 0 {
				m.toast, _ = m.toast.SetWarn("nothing to uninstall — press tab to select items")
				return m, nil
			}
			return m.startUninstall(keys, fmt.Sprintf("Uninstall %d item(s) in %s?\n\n%s",
				len(keys), m.setupCatLabel(), strings.Join(keys, "\n")))
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
				// The backend sends the repo's VERSION. An empty one means the
				// fetch failed or the file is missing, and saying "v0.1.0" here
				// would state a version nothing ships any more.
				ver = "unknown"
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
		// A ToggleSpec row never arrives here: the kit emits
		// PickerToggleOptionMsg for it, handled below. Only Back does.
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
		case "name":
			// Pre-filled with the current name, so editing one is an edit rather
			// than a retype, and clearing it is possible without a second key.
			m.push(scrBackupName)
			m.backupNameInput = tuikit.NewTextInput(
				"Name for this backup (empty = its date):", m.backupOpts.Name)
			return m, m.backupNameInput.Init()
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
			saveBackupOpts(m.backupOpts)
			m.backupOptPicker = m.rebuildBackupOptions()
			return m, nil
		case "keepass":
			m.backupOpts.Keepass = !m.backupOpts.Keepass
			saveBackupOpts(m.backupOpts)
			m.backupOptPicker = m.rebuildBackupOptions()
			return m, nil
		case "zen":
			// Enter toggles it too. It used to be ←/→ only, so a row that
			// answered every other key silently did nothing on the most natural
			// one — the bug that made the option look broken.
			m.backupOpts.Zen = !m.backupOpts.Zen
			saveBackupOpts(m.backupOpts)
			m.backupOptPicker = m.rebuildBackupOptions()
			return m, nil
		case "encrypt":
			m.backupOpts.Encrypt = !m.backupOpts.Encrypt
			saveBackupOpts(m.backupOpts)
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
			// Keep the row you came back to. Returning from the restore list
			// rebuilt the picker from scratch, so the cursor went to the top and
			// walking down to the next backup meant starting over every time.
			was := m.backupPicker.SelectedValue()
			m.pop()
			m.backupPicker = newNavPicker("", backupActions()).SetSize(m.contentSize())
			m.backupPicker = m.backupPicker.KeepCursor(was)
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

	case scrThemeFolder, scrThemeImage, scrThemeDone, scrThemeUnlock:
		// One router for the three picker screens of the theme flow; the
		// two text screens (scrThemeInput, scrThemeName) are handled in the
		// key switch because Enter on a TextInput never arrives as a pick.
		return m.themePicked(m.top(), res)

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

// startUninstall routes an uninstall THROUGH the preinstalls page.
//
// Choosing which stock apps to remove used to be a row of its own in the tree.
// It is now a step that comes before the uninstallations begin: the same page
// opens, but it is opened by asking for an uninstall rather than by ticking a
// row, and the uninstall it interrupted resumes once the preinstalls step is
// done. The confirmation that was about to be shown is held in uninstallMsg
// and shown only after, so a removal can never be confirmed before the list of
// apps it is about to remove has been read.
func (m model) startUninstall(keys []string, prompt string) (model, tea.Cmd) {
	// The Preinstalls row is not a module. It is ticked like any other row and
	// means "let me choose which stock apps go too", so its key has to come out
	// of the list before the command is built — handing "preinstalls:choose" to
	// the uninstall would ask the backend to remove a package by that name.
	mods, wantPre := splitPreinstallsKey(keys)
	// Callers hand the key over in two shapes — "reaper" from the tree row,
	// "apps:reaper" from the filter's ticked set — and the backend wants the
	// bare module key. Normalise here rather than at every call site.
	for i, k := range mods {
		if c := strings.IndexByte(k, ':'); c >= 0 {
			mods[i] = k[c+1:]
		}
	}
	if len(mods) == 0 && !wantPre {
		return m, nil
	}
	m.uninstallWait = mods
	m.uninstallMsg = prompt
	m.pendingAction = "uninstall"
	m.pendingArgs = append([]string(nil), mods...)
	m.pendingMsg = prompt
	m.pendingNo = "Cancel"
	m.pendingYes = "Uninstall"
	// The preinstalls list opens only when its row is TICKED. That is the whole
	// point of keeping the row: the step is opt-in, visible in the tree, and
	// decided before anything is confirmed. Unticked, the uninstall goes
	// straight to its own confirmation and never visits the page.
	if !wantPre {
		return m.resumeUninstall()
	}
	m.push(scrPreinstalls)
	m.preinstallChecked = map[string]bool{}
	m.preinstallPicker = newNavPicker("", []tuikit.PickerItem{{Display: "loading…", Value: "", Disabled: true}}).
		SetSize(m.contentSize())
	return m, fetchPreinstallsCmd()
}

// preinstallsFolder / preinstallsKey identify the Preinstalls row of the
// Uninstall tree. It is a request to open the stock-app list, never something
// to uninstall.
const (
	preinstallsFolder = "preinstalls"
	preinstallsKey    = "preinstalls:choose"
)

// splitPreinstallsKey separates the modules to uninstall from the preinstalls
// request, reporting whether the request was there at all.
func splitPreinstallsKey(keys []string) (mods []string, wantPre bool) {
	mods = make([]string, 0, len(keys))
	for _, k := range keys {
		if k == preinstallsKey {
			wantPre = true
			continue
		}
		mods = append(mods, k)
	}
	return mods, wantPre
}

// openPreinstalls visits the stock-app list on its own, with no uninstall
// waiting behind it. That is what Enter (and therefore "i") on the Preinstalls
// row does: look at the list, tick what should go, and nothing else happens.
func (m model) openPreinstalls() (model, tea.Cmd) {
	m.uninstallWait, m.uninstallMsg = nil, ""
	m.push(scrPreinstalls)
	m.preinstallChecked = map[string]bool{}
	m.preinstallPicker = newNavPicker("", []tuikit.PickerItem{{Display: "loading…", Value: "", Disabled: true}}).
		SetSize(m.contentSize())
	return m, fetchPreinstallsCmd()
}

// resumeUninstall shows the uninstall confirmation that startUninstall held
// back, and forgets the preinstalls step: from here the uninstall is a plain
// uninstall again.
func (m model) resumeUninstall() (model, tea.Cmd) {
	keys, msg := m.uninstallWait, m.uninstallMsg
	m.uninstallWait, m.uninstallMsg = nil, ""
	if len(keys) == 0 {
		return m, nil
	}
	m.pendingAction = "uninstall"
	m.pendingArgs = keys
	m.pendingMsg = msg
	m.pendingNo = "Cancel"
	m.pendingYes = "Uninstall"
	m.push(scrConfirm)
	m.confirm = tuikit.NewConfirm(m.pendingMsg, m.pendingNo, m.pendingYes).SetFocus(1)
	return m, nil
}

// cancelUninstall backs out of the preinstalls step: the uninstall that was
// waiting is dropped WITHOUT losing what the user had ticked on the page —
// only the preinstalls ticks go, since they were never part of the module
// selection in the first place.
func (m model) cancelUninstall() model {
	m.uninstallWait, m.uninstallMsg = nil, ""
	m.preinstallChecked = nil
	return m
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
			fid := folderOfValue(v)
			fl := folderLabel(m, fid)
			items = append(items, tuikit.PickerItem{Display: fl + " › " + it.Label, Value: v, Badge: mark})
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
// homePageInfo is the `i` popup on the main menu: what the page UNDER THE
// CURSOR does.
//
// It used to be one wall of text describing all ten pages at once, on the
// reasoning that the rows ARE the pages so one text answered everything. It did
// answer the question, but not the one being asked: standing on Backup, the only
// line that helps is the one about Backup, and it was twenty lines up in a wall
// you had to read to find. Every other screen already scopes `i` to the row
// under the cursor — Status, Setup, Uninstall, the categories — and the home
// screen is where someone is CHOOSING which page they want, so that is exactly
// where the scoped answer is the useful one.
//
// The full map is still reachable: it is what the Close row shows, because
// "what does this page do" is a strange question to ask of the row that leaves.
func (m model) homePageInfo() string {
	return homePageInfoFor(m.mainPicker.SelectedValue())
}

// homePageInfoFor maps a main-menu row value to its explanation. An unknown
// value falls back to the whole map rather than to nothing: a page added to
// mainMenuItems without a paragraph here should still answer `i`.
func homePageInfoFor(page string) string {
	switch page {
	case "status":
		return "Status — every module, what it installed and what is missing.\n\n" +
			"Press i on a row for the detail behind its state.\n" +
			"Read-only: nothing on this page installs or changes anything."

	case "update":
		return "Update — fetch the scripts repo when a newer version exists.\n\n" +
			"Owner mode updates as fast as possible; anyone else can re-apply\n" +
			"per module. Installs nothing new and never overwrites your files."

	case "setup":
		return "Setup — install, update or re-run modules, grouped in folders.\n\n" +
			"Tab ticks, Left/Right folds a folder, i explains a row, Enter applies\n" +
			"the whole ticked selection. Every script is idempotent, so re-running\n" +
			"one on a configured machine is safe.\n\n" +
			"A row greyed out has nothing to install: its installer file is not on\n" +
			"this machine. Drop the file where the row says and it comes back."

	case "uninstall":
		return "Uninstall — the same tree as Setup, filtered to what is installed,\n" +
			"in reverse.\n\n" +
			"i explains a row. Uninstalling a module removes what it deployed; it\n" +
			"never touches the project data that module was working on."

	case "keybindings":
		return "Keybindings — add, remove and reset the managed SUPER shortcuts.\n\n" +
			"Every change asks whether to reload Hyprland afterwards."

	case "theme":
		return "Theming — build an Omarchy theme from an image in the Wallpapers\n" +
			"folder, or switch between the themes already installed."

	case "health":
		return "Health check — the checks worth running before blaming something.\n\n" +
			"Tick the ones you want, Enter runs them. It re-applies any module left\n" +
			"half-installed rather than reinstalling everything."

	case "backup":
		return "Backup / Restore — DATED ARCHIVES of your configuration, written to\n" +
			"~/omarchy-backups as omarchy-backup-<date>.tar.gz.\n\n" +
			"  Back up now  — walks three pages: what to include (apps/TUIs/\n" +
			"                 webapps, VST plugins, KeePassXC passwords, Zen\n" +
			"                 settings), an optional name for the archive, and\n" +
			"                 encryption. It ASKS for a passphrase rather than\n" +
			"                 storing one. The options are remembered, including\n" +
			"                 when you leave the page without making a backup.\n" +
			"  Restore      — RESTORING OVERWRITES the files an archive contains.\n" +
			"                 It restores FILES, not packages: the pkglist.txt and\n" +
			"                 aurlist.txt inside the archive list what to reinstall\n" +
			"                 with pacman afterwards. RESTORE.md inside the\n" +
			"                 archive is the step-by-step version."

	case "settings":
		return "Extras — the smaller switches: crash notifications, live mode, and\n" +
			"the other tools that do not need a page of their own."
	}
	return homePagesOverview()
}

// homePagesOverview is every page at once. It is what the Close row answers
// with, and the fallback for a page added without a paragraph above.
func homePagesOverview() string {
	var b strings.Builder
	b.WriteString("What each page does\n")
	for _, page := range []string{"status", "update", "setup", "uninstall", "keybindings",
		"theme", "health", "backup", "settings"} {
		b.WriteString("\n")
		b.WriteString(homePageInfoFor(page))
	}
	b.WriteString("\n\nClose — leave. Nothing is applied on the way out; everything in\n" +
		"this app is applied by the Enter you press on the row that does it.")
	return b.String()
}

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
	out, full := m.setupRows(uninstall)

	// Pin the row-block width to the FULL tree — every folder open — so the
	// text column is a constant of the screen instead of a function of the
	// fold state. The row block is centered, so its width IS the left margin:
	// measuring only the visible rows made opening a folder with long children
	// ("lame language models") re-center the whole page and shove every other
	// line sideways. Now folding only ever adds lines; it moves nothing.
	//
	// `full` is built alongside the visible rows rather than in a second pass:
	// rebuilding the tree to measure it was half the cost of a keystroke.
	pinned := tuikit.RowsWidth(full)
	if uninstall {
		// The install tree is the superset: a child action that still exists
		// on the install side is already gone on the uninstall side, so
		// "lame language models" contributes a long row here and no row at
		// all there. Pinning each tab to its OWN width made the row block —
		// which, once it is wider than the pane, is the left margin — differ
		// between the two tabs: the same modules sat on different columns
		// depending on which tab was open. Taking the wider of the two keeps
		// the block a constant of the screen, so switching tab moves
		// nothing. The row block is capped to the pane width at render time
		// (blockFor), so a tree wider than the terminal lays out flush left
		// on both tabs instead of overflowing.
		if _, installFull := m.setupRows(false); tuikit.RowsWidth(installFull) > pinned {
			pinned = tuikit.RowsWidth(installFull)
		}
	}

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
		SetContentWidth(pinned).
		SetHelpKeys(
			key.NewBinding(key.WithKeys("tab", "x"), key.WithHelp("tab/x", "select")),
			key.NewBinding(key.WithKeys("i"), key.WithHelp("i", "info")),
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

// allFoldersOpen returns a copy of the fold state with every folder expanded.
// It exists only to be measured: RowsWidth needs the widest row the page can
// ever show, and a collapsed folder hides exactly the rows that would be
// widest.
func allFoldersOpen(m model) map[string]bool {
	all := make(map[string]bool, len(m.folderOpen)+len(m.setupFolders)+1)
	for k, v := range m.folderOpen {
		all[k] = v
	}
	for _, f := range m.setupFolders {
		all[f.Folder] = true
	}
	all[menuEntriesFolder] = true
	return all
}

// setupRows builds the Setup/Uninstall rows for an arbitrary fold state. It is
// split out of rebuildSetup so the width can be measured over the expanded tree
// (allFoldersOpen) while the visible rows use the real one.
// setupCategory is one folder's rows plus the two numbers its header needs.
// Everything Setup asks about a category comes from here, gathered in a single
// pass over setupItems: the rows to render, the count for the header, and the
// count of ticked ones (which also decides the accent square).
type setupCategory struct {
	rows   []tuikit.TreeItem
	total  int
	marked int
}

// trimOwnPrefix drops a leading "mosquito" (or "mosquito-") from a row label,
// but only inside the "mosquito" folder, which is the only one whose name the
// rows would otherwise just repeat:
//
//	mosquito
//	  mosquito-audio-plugin-manager - v1.0.0
//	  mosquito-jamjamjam - v1.0.0
//	  mosquito-live-mode - v1.0.0
//
// The folder header is already on screen directly above, so the prefix carries
// no information and costs four characters on every row. This is DISPLAY ONLY:
// it.Run() and the backend both dispatch on the key, never on the label, so
// "audio-plugin-manager" installs exactly the same module as
// "mosquito-audio-plugin-manager" did.
//
// Scoped to the folder on purpose. The same "mosquito-" prefix in "plugins"
// (mosquitomarchy - v1.0.0) or a "mosquito" in the middle of a name is carrying
// real information there, and stripping it globally would rename things the user
// did not ask about. The version suffix is left alone: "- v1.0.0" is what tells
// you a module can be updated.
func trimOwnPrefix(folder, label string) string {
	if folder != "mosquito" {
		return label
	}
	for _, p := range []string{"mosquito-", "mosquito"} {
		if strings.HasPrefix(label, p) {
			rest := strings.TrimLeft(label[len(p):], " -")
			// Only strip when something is left: a label that IS "mosquito"
			// must not become empty.
			if rest != "" {
				return rest
			}
		}
	}
	return label
}

// setupIndex groups the backend records by category in ONE pass.
//
// It exists because setupRows used to ask setupItemsOf() for the same data
// three separate times per category — once for the header total, once inside
// categorySelectedCount() for the ticked count, and once more for the accent
// mark — and setupRows itself ran twice per rebuild, once to measure the full
// tree for the pinned width. On the real 46-item tree that is ~50 pointer-full
// slice allocations per keystroke, and the GC time in between is what the user
// felt as a cursor that lagged and stuttered.
func (m model) setupIndex(uninstall bool) map[string]*setupCategory {
	idx := make(map[string]*setupCategory, len(m.setupFolders)+1)
	for _, f := range m.setupFolders {
		// The quick fixes used to be skipped here and in buildSetupRows, on the
		// grounds that they are "their own category, not module rows" — and
		// nothing ever carried that category into the TUI. The backend has
		// emitted the `fixes` folder and its ten rows the whole time, so the
		// Setup page silently dropped them and no quick fix was reachable from
		// the TUI at all. They are rows like any other; the category exists and
		// is now shown.
		idx[f.Folder] = &setupCategory{}
	}
	for i := range m.setupItems {
		it := &m.setupItems[i]
		c := idx[it.Folder]
		if c == nil {
			continue
		}
		v := setupValue(it.Folder, it.Key)
		// BuildFolderTree writes the "item:" prefix itself, so the id here
		// is the value the host will look up — setupValue()'s suffix,
		// "<folder>:<key>" — with the folder in it so Enter can route a
		// single-module install back to the right category.
		row := tuikit.TreeItem{
			ID:       it.Folder + ":" + it.Key,
			Label:    it.Label,
			Checked:  m.selected[v],
			Info:     it.Info,
			Disabled: it.Disabled,
		}
		row.Label = trimOwnPrefix(it.Folder, it.Label)
		// "bring back omarchy's agentic stuff" only makes sense while
		// something is still missing. This used to be decided in
		// pickerTreeItems, which the flat Setup page no longer goes
		// through, so the row stayed tappable and offered a restore that
		// could change nothing.
		if it.Key == "remove-ai" && !uninstall && !m.aiRemovalLogged() {
			// The row is greyed because there is nothing to bring back, and it
			// is NOT given a sub-line saying so. The backend no longer sends a
			// description for it and neither does this: a second line under a
			// single greyed row used to be enough to make the whole Setup page
			// render two lines per option, blank band included.
			row.Disabled = true
		}
		if row.Disabled && row.Info == "" && it.Key != "remove-ai" {
			row.Info = "nothing left to do here"
		}
		c.rows = append(c.rows, row)
		c.total++
		if row.Checked {
			c.marked++
		}
	}
	return idx
}

// setupRows returns the Setup page twice: the FULL tree with every folder open,
// and the visible list for the current fold state.
//
// Both used to be independent calls, each building the whole tree from scratch.
// The full tree is what the pinned width is measured on, and the visible list
// is what gets rendered — building the full one and filtering it down gives
// both for the price of one.
func (m model) setupRows(uninstall bool) (visible, full []tuikit.PickerItem) {
	idx := m.setupIndex(uninstall)
	full = m.buildSetupRows(uninstall, allFoldersOpen(m), idx)
	visible = visibleSetupRows(full, m.folderOpen)
	return visible, full
}

// visibleSetupRows folds a fully-open tree down to the current fold state.
// Filtering is O(rows) and allocation-light, which is why the visible list is
// derived instead of rebuilt.
//
// The folder rows keep their label, counts and accent mark but get their Fold
// rewritten, because they were built with every folder open. Leaving that stale
// drew an EXPANDED arrow on a folder whose children had just been filtered out
// — a folder that looked open and showed nothing.
func visibleSetupRows(full []tuikit.PickerItem, open map[string]bool) []tuikit.PickerItem {
	out := make([]tuikit.PickerItem, 0, len(full))
	for _, r := range full {
		if r.Folder {
			_, id, ok := tuikit.TreeSplit(r.Value)
			if ok {
				if open[id] {
					r.Fold = tuikit.FoldExpanded
				} else {
					r.Fold = tuikit.FoldCollapsed
				}
			}
			out = append(out, r)
			continue
		}
		_, id, ok := tuikit.TreeSplit(r.Value)
		if !ok {
			out = append(out, r) // Update / Back and any other plain row
			continue
		}
		folder := id
		if i := strings.IndexByte(id, ':'); i >= 0 {
			folder = id[:i]
		}
		if open[folder] {
			out = append(out, r)
		}
	}
	return out
}

func (m model) buildSetupRows(uninstall bool, open map[string]bool, idx map[string]*setupCategory) []tuikit.PickerItem {
	out := make([]tuikit.PickerItem, 0, len(m.setupFolders)+8)

	// Setup no longer carries an Update row. The Update screen is its own entry
	// on the main menu, and the row here only ever appeared when a check had
	// already found something — so it popped in and out of the tree depending on
	// a background check, which moved every other row on the page. The update is
	// still advertised on the main menu and still one key away.

	seen := make(map[string][]tuikit.TreeItem, len(idx))
	for f, c := range idx {
		seen[f] = c.rows
	}

	// The folders are emitted one at a time above (open state applied per
	// folder), so the tree is assembled here rather than by a single
	// BuildFolderTree call: BuildFolderTree needs every folder's children up
	// front, and open state is per folder.
	for _, f := range m.setupFolders {
		c := idx[f.Folder]
		tf := tuikit.TreeFolder{
			ID:     f.Folder,
			Label:  f.Label,
			Total:  c.total,
			Marked: c.marked,
			Accent: f.Accent,
		}
		if f.Folder == "keybindings" {
			tf.Total, tf.Marked = 0, 0
		}
		out = append(out, tuikit.BuildFolderTree([]tuikit.TreeFolder{tf}, seen, open, m.blinkOn)...)
	}

	if !uninstall {
		// "Menu entries" is a folder like any other, not a lone row that
		// opened a screen of its own: the arrows fold it, and its blocks are
		// listed under it on the same page. Ticking one still happens on the
		// entries page, where the backend result lands.
		meChildren := make([]tuikit.TreeItem, 0, len(m.menuEntries))
		for _, e := range m.menuEntries {
			meChildren = append(meChildren, tuikit.TreeItem{
				// Folder-qualified, exactly like every module row
				// ("item:apps:reaper"). It used to be the bare entry name, so
				// the child came out as "item:mega": visibleSetupRows resolves
				// a leaf's owner folder from the value, found a folder called
				// "mega" that is never open, and threw the row away. The fold
				// state was being set correctly the whole time — the children
				// were simply filtered out on the way to the screen, so pressing
				// → on "Menu entries" appeared to do nothing.
				ID:      menuEntriesFolder + ":" + e.Name,
				Label:   e.Label,
				Checked: m.menuEntryChecked[e.Name],
			})
		}
		// Fold by default: the list is long, and this row is a corner of Setup
		// rather than the page's subject.
		if _, seen := open[menuEntriesFolder]; !seen {
			open[menuEntriesFolder] = false
		}
		out = append(out, tuikit.BuildFolderTree(
			[]tuikit.TreeFolder{{ID: menuEntriesFolder, Label: "Menu entries", Total: len(meChildren)}},
			map[string][]tuikit.TreeItem{menuEntriesFolder: meChildren},
			open, m.blinkOn)...)
	}
	// A category with something ticked inside it carries the accent square at
	// the end of its row — the same marker the plugin manager puts on a folder
	// that has an applied fix. Setup and Uninstall are mostly a wall of
	// category names with a count on the right, and the count alone does not
	// say whether the ticked thing is in there yet, so the two are easy to
	// confuse. The square answers that at a glance, and because it only
	// appears once something is ticked, it never becomes noise.
	out = tuikit.WithCategoryMark(out, func(v string) int {
		_, cat, ok := tuikit.TreeSplit(v)
		if !ok {
			return 0
		}
		if cat == menuEntriesFolder {
			// Menu entries are not setup items — they live in their own cache
			// and are ticked on their own page — so the per-category count
			// would always report 0 here and the folder would never light up.
			return m.menuEntriesCheckedCount()
		}
		if c := idx[cat]; c != nil {
			return c.marked
		}
		return 0
	})

	out = append(out, tuikit.PickerItem{Display: "Back", Value: "back"})
	return out
}

// menuEntriesCheckedCount counts the ticked menu entries, so the "Menu
// entries" folder carries the same accent square as a module category instead
// of staying bare while things inside it are ticked.
func (m model) menuEntriesCheckedCount() int {
	n := 0
	for _, e := range m.menuEntries {
		if m.menuEntryChecked[e.Name] {
			n++
		}
	}
	return n
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
	p := newNavPicker("", pickerTreeItems(folders, items, m.selected, m.folderOpen, m.blinkOn, m.treeMode, m.aiRemovalLogged())).SetSize(m.contentSize()).
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
	return pickerTreeItems(m.backupFolders, m.backupItems, m.backupChecked, m.backupOpen, false, "backup", m.aiRemovalLogged())
}

// pickerTreeItems builds the shared folder/item tree rows: a Fold glyph (drawn in
// the cursor slot by the kit), an
// aggregate ●/○ mark and the label per folder, and indented ├─/└─ children
// with their own ●/○ marks when the folder is open. blinkOn toggles the
// Accent flag on rows whose folder sets Accent (the blinking "mosquito").
// aiRemovalDone reports whether a prior remove-ai uninstall marked the state
// file (a tiny internal log inside ~/.local/state/mosquitomarchy). Setup
// shows the "bring back..." entry GREYED when nothing was ever removed.
// deferredCmd is a one-shot command slot. See model.deferred.
type deferredCmd struct{ tea.Cmd }

// deferCmd schedules a command to run once the current Update is done, for the
// branches of update() that already have to return a different command.
func (m *model) deferCmd(c tea.Cmd) {
	if c == nil {
		return
	}
	m.deferred = &deferredCmd{Cmd: c}
}

// aiRemovalLogged is the cached read used while rows are being built. It never
// forks anything: an answer that has not arrived yet counts as "nothing was
// removed", which greys the "bring back" row rather than offering a restore
// that could change nothing.
func (m model) aiRemovalLogged() bool { return m.aiRemovedKnown && m.aiRemoved }

// queryAIRemoved is the blocking backend call behind the cached answer. Only
// fetchAIRemovedCmd may call it: see the aiRemoved field on the model for why
// it must never run while rows are being built.
// aiRemovedQuery is a seam for the tests: it lets them count the backend calls
// without spawning a shell. Production code must not assign it.
var aiRemovedQuery = queryAIRemoved

func queryAIRemoved() (bool, error) {
	out, err := runQuick("ai-removed")
	if err != nil {
		return false, err
	}
	var v struct {
		Removed bool `json:"removed"`
	}
	if err := json.Unmarshal(bytes.TrimSpace(out), &v); err != nil {
		return false, err
	}
	return v.Removed, nil
}

func pickerTreeItems(folders []FolderRec, items []SetupItemRec, checked, open map[string]bool, blinkOn bool, mode string, aiRemoved bool) []tuikit.PickerItem {
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
				// The backend greys a row that has nothing left to do, and it
				// stays listed so the option does not silently vanish. When the
				// backend explains itself in `info`, show that as the sub-line
				// rather than leaving a dead-looking row with no reason.
				if it.Disabled {
					entry.Disabled = true
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
				if it.Key == "remove-ai" && mode != "uninstall" && !aiRemoved {
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
			key.NewBinding(key.WithKeys("i"), key.WithHelp("i", "info")),
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
	if len(m.healthItems) == 0 {
		items = append(items, tuikit.PickerItem{Display: "Everything is in place — no action needed", Value: "", Disabled: true})
	} else {
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
	nameRow := "(none — the date names it)"
	if m.backupOpts.Name != "" {
		nameRow = m.backupOpts.Name
	}
	items := []tuikit.PickerItem{
		{Display: "Archive name: " + nameRow, Value: "name"},
		{Display: fmt.Sprintf("Apps / TUIs / webapps: %d selected", len(m.backupChecked)), Value: "apps"},
		{Display: "VST plugins: " + vst, Value: "vst"},
	}
	if m.backupOpts.HasKeep {
		items = append(items, tuikit.PickerItem{Display: "KeePassXC passwords: " + yesno(m.backupOpts.Keepass), Value: "keepass"})
	}
	if m.backupOpts.HasZen {
		items = append(items, tuikit.PickerItem{Display: "Zen browser settings: " + yesno(m.backupOpts.Zen), Value: "zen"})
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
		"--zen=" + yesno(m.backupOpts.Zen),
		"--selection=" + m.backupSelFile,
		// Always sent, empty or not: the backend treats an empty name as "use
		// the dated name", and omitting the flag entirely would make an edit
		// that cleared the name impossible to express.
		"--name=" + m.backupOpts.Name,
	}
	if m.backupOpts.Encrypt {
		m.pendingAction = "backup-encrypted"
		m.push(scrPassphrase)
		m.passInput = tuikit.NewPasswordInput("Backup passphrase (AES-256):", "")
		return m, m.passInput.Init()
	}
	m.pendingAction = "backup"
	label := "named by its date"
	if m.backupOpts.Name != "" {
		label = "named \"" + m.backupOpts.Name + "\""
	}
	m.pendingMsg = fmt.Sprintf("Create a backup now?\n\nApps/TUIs/webapps: %d selected · VST: %s · KeePassXC: %s · Zen: %s\nArchive: %s",
		len(m.backupChecked), m.backupOpts.VST, yesno(m.backupOpts.Keepass), yesno(m.backupOpts.Zen), label)
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
			key.NewBinding(key.WithKeys("i"), key.WithHelp("i", "info")),
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

// crashNotifyValue is the option's stable identity, separate from its label so
// the label can change with the state without the handler losing the row.
const crashNotifyValue = "toggle-crash-notify"

func crashNotifyLabel(on bool) string {
	if on {
		return "Crash notifications (AI diagnosis): on"
	}
	return "Crash notifications (AI diagnosis): off"
}

// settingsItems2 backs the TOP-LEVEL Settings screen (before Close).
//
// The setting is a tuikit ToggleSpec, so the row follows the kit's rule for
// settings: it shows the state it is moving to the instant it is chosen, and
// the write happens after. It used to be a plain row whose label was rebuilt
// by shelling out to the backend — the write ran first, synchronously, and the
// new label only appeared once the subprocess was done, so flipping it froze
// the whole TUI for the duration and looked like nothing had happened.
func (m model) settingsItems2() []tuikit.PickerItem {
	return []tuikit.PickerItem{
		{
			Value:   crashNotifyValue,
			Display: crashNotifyLabel(m.crashNotify),
			Toggle: &tuikit.ToggleSpec{
				On:    crashNotifyLabel(true),
				Off:   crashNotifyLabel(false),
				Value: m.crashNotify,
			},
		},
		{Display: "Back", Value: "back"},
	}
}

func backupItems(items []tuikit.PickerItem) []tuikit.PickerItem { return items }

// rebuildPreinstallPicker lists EVERY stock app, as asked: an app that is no
// longer installed (or is one of the user's own) is shown greyed and cannot be
// ticked, so the list does not silently shrink between two visits.
func (m model) rebuildPreinstallPicker() navPicker {
	// No header row. The instruction used to sit in the list as a greyed
	// 76-column row ("Omarchy preinstalls (tab = keep; enter or back asks…"),
	// which is one of the two rows that made this page wider than the pane.
	// The screen title says what the page is, and the bar below it already
	// spells out the keys.
	var items []tuikit.PickerItem
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
