package main

import (
	"path/filepath"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/key"
	tea "github.com/charmbracelet/bubbletea"
	tuikit "mosquitomarchy.local/tui-kit"
)

// newSettingsPicker builds the Settings picker with the universal
// left/right = toggle help hint, overlaying any not-yet-applied pending
// value so the label moves the instant an arrow is pressed. Kept in one
// place so the status-refresh rebuild (model.go) and the screen entry
// (enterCmd) always match.
func (m model) newSettingsPicker() navPicker {
	return newNavPicker("Settings", m.settingsItemsWithPending()).
		SetHelpKeys(key.NewBinding(key.WithKeys("left", "right"), key.WithHelp("←/→", "toggle")))
}

// settingsItemsWithPending overlays the pending Left/Right target on the
// Settings rows (see cycleSetting/applySettingPending).
func (m model) settingsItemsWithPending() []tuikit.PickerItem {
	items := settingsItems(m.status)
	for i := range items {
		switch items[i].Value {
		case "hide_converted":
			if p, ok := m.settingsPending["hide_converted"]; ok {
				items[i].Display = "Hide sets converted to Bitwig: " + onOffLabel(p == "on")
			}
		case "open_als_ydotool":
			if p, ok := m.settingsPending["open_als_ydotool"]; ok {
				items[i].Display = "Open the converted .als directly with Bitwig using ydotool: " + onOffLabel(p == "on")
			}
		case "switch_file_picker":
			if p, ok := m.settingsPending["switch_file_picker"]; ok {
				label := "Default"
				if p == "superfile" {
					label = "Superfile"
				}
				items[i].Display = "File picker: " + label
			}
		}
	}
	return items
}

func onOffLabel(on bool) string {
	if on {
		return "On"
	}
	return "Off"
}

// settingTargetMatchesStatus reports whether a pending row's target is now
// what the server reports — the signal to drop the override so the row shows
// the applied value.
func (m model) settingTargetMatchesStatus(row, target string) bool {
	switch row {
	case "hide_converted":
		return (target == "on") == m.status.HideConverted
	case "open_als_ydotool":
		return (target == "on") == m.status.OpenAlsYdotool
	case "switch_file_picker":
		return target == m.status.FilePicker
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
// keeping the cursor on the row (the status refresh re-selects it). It is a
// no-op when the target already matches the server, and it pushes the
// Superfile install confirm when switching to a not-yet-installed Superfile
// is what the pending value asks for.
func (m *model) applySettingPending(row string) tea.Cmd {
	target, ok := m.settingsPending[row]
	if !ok {
		return nil
	}
	switch row {
	case "hide_converted":
		if (target == "on") == m.status.HideConverted {
			delete(m.settingsPending, row)
			return nil
		}
		return fireToast("setting saved", "toggle-hide-converted")
	case "open_als_ydotool":
		if (target == "on") == m.status.OpenAlsYdotool {
			delete(m.settingsPending, row)
			return nil
		}
		return fireToast("setting saved", "toggle-open-als-ydotool")
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

// rebuildSettingsPicker re-creates the Settings picker preserving the cursor
// (the status refresh after a pending apply lands here).
func (m *model) rebuildSettingsPicker() {
	sidx := m.settingsPicker.Index()
	m.settingsPicker = m.newSettingsPicker().SetSize(m.contentSize())
	m.settingsPicker = m.settingsPicker.SelectIndex(sidx)
}

// cycleSetting steps the row under the cursor, shows the new value as a
// pending label without applying it, and arms the dwell timer that applies
// it if the user leaves the value alone.
func (m *model) cycleSetting() (tea.Model, tea.Cmd) {
	row := m.settingsPicker.SelectedValue()
	if m.settingsPending == nil {
		m.settingsPending = map[string]string{}
	}
	switch row {
	case "hide_converted":
		cur := m.status.HideConverted
		if p, ok := m.settingsPending[row]; ok {
			cur = p == "on"
		}
		m.settingsPending[row] = boolTarget(!cur)
	case "open_als_ydotool":
		cur := m.status.OpenAlsYdotool
		if p, ok := m.settingsPending[row]; ok {
			cur = p == "on"
		}
		m.settingsPending[row] = boolTarget(!cur)
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
	default:
		return m, nil
	}
	m.rebuildSettingsPicker()
	m.settingsDwellSeq++
	seq := m.settingsDwellSeq
	rowID := row
	return m, tea.Tick(settingsDwell, func(time.Time) tea.Msg {
		return settingsDwellMsg{row: rowID, seq: seq}
	})
}

func boolTarget(on bool) string {
	if on {
		return "on"
	}
	return "off"
}

// enterCmd prepares (and, where the screen needs remote data, fetches) the
// screen currently on top of the nav stack. Called whenever the stack
// changes — pushing a new screen or popping back to a previous one, since
// a previous screen's data (status, bundle list) may be stale by then.
func (m *model) enterCmd() tea.Cmd {
	switch m.top() {
	case scrMain:
		m.loading = true
		return fetchStatus()
	case scrSettings:
		m.settingsPicker = m.newSettingsPicker().SetSize(m.contentSize())
		return nil
	case scrAbletonVersion:
		m.loading = true
		return fetchAbletonExes()
	case scrBundlePick:
		m.loading = true
		return fetchBundles()
	case scrAddress:
		m.addressInput = tuikit.NewTextInput("Move address number (1…99, empty = move.local)", m.status.Address)
		return m.addressInput.Init()
	case scrRoutePick:
		m.routePicker = newNavPicker("Convert to:", []tuikit.PickerItem{
			{Display: "Bitwig (Ableton → Bitwig)", Value: "bitwig"},
			{Display: "MIDI", Value: "midi"},
			{Display: ".ablbundle to .als auto converter (beta)", Value: "als"},
		}).SetSize(m.contentSize())
		return nil
	case scrClearAlsConfirm:
		m.confirm = tuikit.NewConfirm("Delete all items in the als working folder? This can't be undone.", "No", "Yes, delete")
		return nil
	case scrSuperfileInstallConfirm:
		m.confirm = tuikit.NewConfirm(
			"Superfile isn't installed. Install it now (pacman, official repo — opens a terminal for the sudo password) and switch to it?",
			"No", "Yes, install")
		return nil
	case scrBundleEmptyConfirm:
		m.confirm = tuikit.NewConfirm("No set found — point to a specific file instead?", "No", "Yes")
		return nil
	case scrAbletonConflictConfirm:
		m.confirm = tuikit.NewConfirm(
			"Ableton is already open. The conversion needs it closed — continuing will force-quit Ableton, so any unsaved work is lost.\n\nSave your project in Ableton first, then continue.",
			"No", "Yes, close it").WithExtra("Re-check", "r")
		return nil
	case scrAbletonCloseRetryConfirm:
		m.confirm = tuikit.NewConfirm(
			"Ableton is still open after the close wait timed out. Save your project, close Ableton (it will otherwise be force-quit), then continue.",
			"Cancel", "Continue")
		return nil
	case scrConvertRetryConfirm:
		m.confirm = tuikit.NewConfirm(
			"The conversion stopped partway. Retry it?",
			"Cancel", "Retry")
		return nil
	case scrNoAlsConfirm:
		m.confirm = tuikit.NewConfirm(
			"Ableton closed but no new .als was saved — the project may not have been exported into the als working folder. Close Ableton and make sure it saved, then retry?",
			"Cancel", "Retry")
		return nil
	case scrConvertPresetSource:
		m.convertPresetPckr = newNavPicker("What kind of preset?", []tuikit.PickerItem{
			{Display: "An Ableton Live preset (.adg)", Value: "ableton"},
			{Display: "A Bitwig preset (.bwpreset)", Value: "bitwig"},
		}).SetSize(m.contentSize())
		// Background fetch of the flow facts (output folder, picker start
		// dir) — the picker stays answerable, nothing waits on it; the only
		// consumer of the dir is the superfile pick, which needs it later.
		return fetchPresetStatus()
	case scrConvertPresetPicking:
		m.loading = true
		pickAction, pickDir := "pick-adg", m.presetPickDir
		if m.presetKind == "bitwig" {
			pickAction, pickDir = "pick-bwpreset", m.presetBwPickDir
		}
		if m.status.FilePicker == "superfile" && m.status.SuperfileInstalled {
			// Needs the preset start dir; when the background fetch already
			// answered, pick straight away, else fetch then pick (the
			// presetStatusMsg handler drives the embedded superfile).
			if pickDir != "" {
				return pickViaSuperfileEmbedded(pickAction, pickDir)
			}
			return fetchPresetStatus()
		}
		return fetchPath(pickAction, pickAction)
	case scrConvertPresetAddMore:
		m.confirm = tuikit.NewConfirm(
			"Added "+filepath.Base(m.presetFiles[len(m.presetFiles)-1])+".\n\nConvert now, or add another preset?",
			"Convert now", "Add another")
		return nil
	case scrPresetUploadConfirm:
		m.confirm = tuikit.NewConfirm(
			"Preset converted. Open the Move Manager to upload it to the Move?",
			"Not now", "Yes, open")
		return nil
	case scrPresetNoMove:
		m.presetNoMovePicker = newNavPicker("Preset converted — Move not connected", []tuikit.PickerItem{
			{Display: "Refresh connection status", Value: "refresh"},
			{Display: "Back to the main menu", Value: "main"},
		}).SetSize(m.contentSize())
		return nil
	case scrSchwungMenu:
		m.loading = true
		return fetchSchwungInfo()
	case scrSchwungUninstallConfirm:
		m.confirm = tuikit.NewConfirm(
			"Remove Schwung from the Move?\n\nInstalled modules keep working until removed separately.",
			"No", "Yes, remove")
		return nil
	case scrBitwigMenu:
		m.loading = true
		return fetchBitwigMoveStatus()
	case scrBitwigUninstallConfirm:
		m.confirm = tuikit.NewConfirm(
			"Remove the Move controller scripts from Bitwig Studio?\n\nThe module stays on the Move (remove it in the Schwung Manager).",
			"Keep", "Remove")
		return nil
	case scrBitwigModuleUninstallConfirm:
		m.confirm = tuikit.NewConfirm(
			"Remove the Move Bitwig module from the Move device?\n\n"+
				"This runs over ssh to the Move in a visible terminal. On-device detection\n"+
				"needs ssh; if ssh is unavailable the module is removed directly with\n"+
				"rm -rf /data/UserData/schwung/modules/overtake/move-bitwig.",
			"Cancel", "Remove")
		return nil
	case scrBitwigTipConfirm:
		// A true gate: the instruction body lives on the tip screen and is
		// only shown after an explicit Yes — never dumped into the question.
		m.confirm = tuikit.NewConfirm(
			"Open Bitwig to set up the controller in Settings?",
			"No", "Yes")
		return nil
	case scrBitwigTipWait:
		m.bitwigSawRunning = false
		// The tip body is a Readme-style framed modal (StyleModal via
		// tuikit.Info), not bare lines — same bounded, wrapping frame the
		// audio manager's Readme uses.
		m.tipInfo = tuikit.NewInfo(bitwigTipText()).SetSize(m.contentSize())
		return bitwigRunningCmd()
	case scrQuitConfirm:
		m.confirm = tuikit.NewConfirm("Quit mosquito Move Manager?", "No", "Yes")
		return nil
	case scrConverting, scrManagerWait, scrWorkingDirRunning,
		scrPresetConverting, scrSchwungInstalling, scrSchwungUninstalling,
		scrBitwigInstalling, scrBitwigUninstalling, scrBitwigModuleUninstalling:
		// Started explicitly by the handler that pushed this screen
		// (it already knows which command to run) — nothing to do here.
		return nil
	}
	return nil
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
		m.mainPicker, cmd = m.mainPicker.Update(msg)
		return m, cmd

	case scrSettings:
		if dm, ok := msg.(settingsDwellMsg); ok {
			// Dwell elapsed: apply the pending value of the row the user
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
			mm, cmd := m.handleSettingsChoice(res.Value)
			return mm, tea.Batch(applyCmd, cmd)
		}
		// Left/Right shows the next value as a pending label without
		// applying it; the value is applied on the dwell timer / blur /
		// leave (the status refresh re-selects the same row).
		if _, ok := msg.(tuikit.PickerSortMsg); ok {
			return m.cycleSetting()
		}
		before := m.settingsPicker.SelectedValue()
		var cmd tea.Cmd
		m.settingsPicker, cmd = m.settingsPicker.Update(msg)
		after := m.settingsPicker.SelectedValue()
		var applyCmd tea.Cmd
		if before != "" && before != after {
			// Cursor moved to a different row: apply what was left behind.
			applyCmd = m.applySettingPending(before)
		}
		return m, tea.Batch(cmd, applyCmd)

	case scrAbletonVersion:
		if res, ok := msg.(tuikit.PickerResultMsg); ok {
			if res.Canceled {
				m.pop()
				return m, m.enterCmd()
			}
			m.loading = true
			return m, runFireAndForget("Ableton version set", "select-ableton-version", res.Value)
		}
		var cmd tea.Cmd
		m.abletonPicker, cmd = m.abletonPicker.Update(msg)
		return m, cmd

	case scrBundlePick:
		if res, ok := msg.(tuikit.PickerResultMsg); ok {
			if res.Canceled {
				m.pop()
				return m, m.enterCmd()
			}
			m.pendingBundle = res.Value
			m.push(scrRoutePick)
			return m, m.enterCmd()
		}
		var cmd tea.Cmd
		m.bundlePicker, cmd = m.bundlePicker.Update(msg)
		return m, cmd

	case scrRoutePick:
		if res, ok := msg.(tuikit.PickerResultMsg); ok {
			if res.Canceled {
				m.pop()
				return m, m.enterCmd()
			}
			return m.startConvert(res.Value)
		}
		var cmd tea.Cmd
		m.routePicker, cmd = m.routePicker.Update(msg)
		return m, cmd

	case scrAddress:
		if res, ok := msg.(tuikit.InputResultMsg); ok {
			if res.Canceled {
				m.pop()
				return m, m.enterCmd()
			}
			m.pop()
			return m, tea.Batch(m.enterCmd(), runFireAndForget("address saved", "set-address", res.Value))
		}
		var cmd tea.Cmd
		m.addressInput, cmd = m.addressInput.Update(msg)
		return m, cmd

	case scrClearAlsConfirm:
		if res, ok := msg.(tuikit.ConfirmResultMsg); ok {
			m.pop()
			if !res.Yes {
				return m, m.enterCmd()
			}
			return m, tea.Batch(m.enterCmd(), runFireAndForget("als folder cleared", "clear-als"))
		}
		var cmd tea.Cmd
		m.confirm, cmd = m.confirm.Update(msg)
		return m, cmd

	case scrConvertPresetSource:
		if res, ok := msg.(tuikit.PickerResultMsg); ok {
			if res.Canceled {
				m.pop()
				return m, m.enterCmd()
			}
			m.presetKind = res.Value // "ableton" (.adg) or "bitwig" (.bwpreset)
			m.presetFiles = nil
			m.replace(scrConvertPresetPicking)
			return m, m.enterCmd()
		}
		var cmd tea.Cmd
		m.convertPresetPckr, cmd = m.convertPresetPckr.Update(msg)
		return m, cmd

	case scrConvertPresetPicking:
		// No interactive component here: scrConvertPresetPicking's enterCmd
		// armed the pick (superfile embedded or the default pick-adg action)
		// and pathMsg/presetStatusMsg carries the result through.
		if km, ok := msg.(tea.KeyMsg); ok {
			if km.String() == "esc" || km.String() == "ctrl+c" {
				m.presetFiles = nil
				m.nav = []screen{scrMain}
				m.toast, _ = m.toast.SetWarn("preset selection canceled")
				return m, m.enterCmd()
			}
		}
		return m, nil

	case scrConvertPresetAddMore:
		if res, ok := msg.(tuikit.ConfirmResultMsg); ok {
			if res.Canceled {
				m.presetFiles = nil
				m.nav = []screen{scrMain}
				m.toast, _ = m.toast.SetWarn("preset selection canceled")
				return m, m.enterCmd()
			}
			if res.Yes { // "Add another"
				m.replace(scrConvertPresetPicking)
				return m, m.enterCmd()
			}
			// "Convert now" — .adg (Ableton) or .bwpreset (Bitwig), both
			// streamed into the runner viewport.
			action, title := "convert-preset", "Converting preset"
			if m.presetKind == "bitwig" {
				action, title = "convert-bwpreset", "Converting Bitwig preset"
			}
			args := []string{action}
			args = append(args, m.presetFiles...)
			m.replace(scrPresetConverting)
			m.loading = true
			m.runner = tuikit.NewRunner().SetSize(m.contentSize())
			var cmd tea.Cmd
			m.runner, cmd = m.runner.Start(title, actionsBin(), args...)
			return m, cmd
		}
		var cmd tea.Cmd
		m.confirm, cmd = m.confirm.Update(msg)
		return m, cmd

	case scrPresetUploadConfirm:
		if res, ok := msg.(tuikit.ConfirmResultMsg); ok {
			if res.Canceled || !res.Yes {
				// "Not now" → straight back to the calling (main) menu.
				m.presetUploadSawRunning = false
				m.nav = []screen{scrMain}
				return m, m.enterCmd()
			}
			// Open the Manager webapp (normally — no forced tiling/floating)
			// and keep this screen up showing the converted preset's path(s)
			// and what to do with them. Poll so that when the Manager is
			// closed we refocus this window and return to the menu.
			m.replace(scrPresetUpload)
			m.presetUploadSawRunning = false
			return m, tea.Batch(openMoveManagerCmd(), managerPollCmd())
		}
		var cmd tea.Cmd
		m.confirm, cmd = m.confirm.Update(msg)
		return m, cmd

	case scrPresetUpload:
		if pr, ok := msg.(managerPollResultMsg); ok {
			return m.handlePresetUploadPoll(pr)
		}
		if km, ok := msg.(tea.KeyMsg); ok &&
			(km.String() == "esc" || km.String() == "enter" || km.String() == "ctrl+c") {
			m.presetUploadSawRunning = false
			m.nav = []screen{scrMain}
			// The user dismissed the upload screen while the Manager is
			// (possibly) still open — bring this window back up so the menu
			// is usable above it.
			return m, tea.Batch(m.enterCmd(), runSilent("raise-own-window"))
		}
		return m, nil

	case scrPresetNoMove:
		if res, ok := msg.(tuikit.PickerResultMsg); ok {
			if res.Canceled || res.Value == "main" {
				m.nav = []screen{scrMain}
				return m, m.enterCmd()
			}
			if res.Value == "refresh" {
				m.loading = true
				return m, fetchStatus()
			}
		}
		var cmd tea.Cmd
		m.presetNoMovePicker, cmd = m.presetNoMovePicker.Update(msg)
		return m, cmd

	case scrPresetConverting:
		if done, ok := msg.(tuikit.RunnerDoneMsg); ok {
			return m.handlePresetConvertDone(done)
		}
		if km, ok := msg.(tea.KeyMsg); ok && (km.String() == "esc" || km.String() == "enter") {
			if km.String() == "esc" && !m.runner.Done() {
				m.runner.Cancel()
			}
			if m.runner.Done() || km.String() == "esc" {
				m.presetFiles = nil
				m.pop()
				return m, m.enterCmd()
			}
			return m, nil
		}
		var cmd tea.Cmd
		m.runner, cmd = m.runner.Update(msg)
		return m, cmd

	case scrSchwungMenu:
		if res, ok := msg.(tuikit.PickerResultMsg); ok {
			if res.Canceled || res.Value == "back" {
				m.pop()
				return m, m.enterCmd()
			}
			return m.handleSchwungChoice(res.Value)
		}
		var cmd tea.Cmd
		m.schwungPicker, cmd = m.schwungPicker.Update(msg)
		return m, cmd

	case scrSchwungInstalling:
		if done, ok := msg.(tuikit.RunnerDoneMsg); ok {
			if done.Err != nil {
				return m, nil // stay on the log; esc/enter leave
			}
			m.pop() // back to the Schwung menu
			m.toast, _ = m.toast.SetOK("Schwung installed — now set up through the Schwung Manager")
			return m, tea.Batch(m.enterCmd(), fetchStatus())
		}
		if km, ok := msg.(tea.KeyMsg); ok && (km.String() == "esc" || km.String() == "enter") {
			if km.String() == "esc" && !m.runner.Done() {
				m.runner.Cancel()
			}
			if m.runner.Done() || km.String() == "esc" {
				m.pop()
				return m, m.enterCmd()
			}
			return m, nil
		}
		var cmd tea.Cmd
		m.runner, cmd = m.runner.Update(msg)
		return m, cmd

	case scrSchwungUninstallConfirm:
		if res, ok := msg.(tuikit.ConfirmResultMsg); ok {
			if res.Canceled || !res.Yes {
				m.pop()
				return m, m.enterCmd()
			}
			m.push(scrSchwungUninstalling)
			m.runner = tuikit.NewRunner().SetSize(m.contentSize())
			var cmd tea.Cmd
			m.runner, cmd = m.runner.Start("Uninstalling Schwung", actionsBin(), "schwung-uninstall")
			return m, cmd
		}
		var cmd tea.Cmd
		m.confirm, cmd = m.confirm.Update(msg)
		return m, cmd

	case scrSchwungUninstalling:
		if done, ok := msg.(tuikit.RunnerDoneMsg); ok {
			if done.Err != nil {
				return m, nil
			}
			m.nav = []screen{scrMain}
			m.toast, _ = m.toast.SetOK("Schwung uninstalled from the Move")
			return m, tea.Batch(m.enterCmd(), fetchStatus())
		}
		if km, ok := msg.(tea.KeyMsg); ok && (km.String() == "esc" || km.String() == "enter") {
			if km.String() == "esc" && !m.runner.Done() {
				m.runner.Cancel()
			}
			if m.runner.Done() || km.String() == "esc" {
				m.nav = []screen{scrMain}
				return m, m.enterCmd()
			}
			return m, nil
		}
		var cmd tea.Cmd
		m.runner, cmd = m.runner.Update(msg)
		return m, cmd

	case scrBitwigMenu:
		if res, ok := msg.(tuikit.PickerResultMsg); ok {
			if res.Canceled || res.Value == "back" {
				m.pop()
				return m, m.enterCmd()
			}
			return m.handleBitwigChoice(res.Value)
		}
		var cmd tea.Cmd
		m.bitwigPicker, cmd = m.bitwigPicker.Update(msg)
		return m, cmd

	case scrBitwigInstalling:
		if done, ok := msg.(tuikit.RunnerDoneMsg); ok {
			if done.Err != nil {
				return m, nil // stay on the log; esc/enter leave
			}
			m.pop() // back to the Bitwig menu
			m.push(scrBitwigTipConfirm)
			return m, m.enterCmd()
		}
		if km, ok := msg.(tea.KeyMsg); ok && (km.String() == "esc" || km.String() == "enter") {
			if km.String() == "esc" && !m.runner.Done() {
				m.runner.Cancel()
			}
			if m.runner.Done() || km.String() == "esc" {
				m.pop()
				return m, m.enterCmd()
			}
			return m, nil
		}
		var cmd tea.Cmd
		m.runner, cmd = m.runner.Update(msg)
		return m, cmd

	case scrBitwigUninstallConfirm:
		if res, ok := msg.(tuikit.ConfirmResultMsg); ok {
			if res.Canceled || !res.Yes {
				m.pop()
				return m, m.enterCmd()
			}
			// Leave the confirm before the runner takes over, or a
			// successful run's own pop would land back on this prompt and
			// leave it stuck on screen until the user pressed "Keep".
			m.pop()
			m.push(scrBitwigUninstalling)
			m.runner = tuikit.NewRunner().SetSize(m.contentSize())
			var cmd tea.Cmd
			m.runner, cmd = m.runner.Start("Removing controller scripts", actionsBin(), "bitwig-move-uninstall")
			return m, cmd
		}
		var cmd tea.Cmd
		m.confirm, cmd = m.confirm.Update(msg)
		return m, cmd

	case scrBitwigUninstalling:
		if done, ok := msg.(tuikit.RunnerDoneMsg); ok {
			m.pop() // back to the Bitwig menu, on success or failure
			if done.Err != nil {
				m.toast, _ = m.toast.SetErr(done.Err.Error())
				return m, tea.Batch(m.enterCmd(), fetchStatus())
			}
			m.toast, _ = m.toast.SetOK("controller scripts removed")
			return m, tea.Batch(m.enterCmd(), fetchStatus())
		}
		if km, ok := msg.(tea.KeyMsg); ok && (km.String() == "esc" || km.String() == "enter") {
			if km.String() == "esc" && !m.runner.Done() {
				m.runner.Cancel()
			}
			if m.runner.Done() || km.String() == "esc" {
				m.pop()
				return m, m.enterCmd()
			}
			return m, nil
		}
		var cmd tea.Cmd
		m.runner, cmd = m.runner.Update(msg)
		return m, cmd

	case scrBitwigModuleUninstallConfirm:
		if res, ok := msg.(tuikit.ConfirmResultMsg); ok {
			m.pop() // back to the Bitwig menu
			if res.Canceled || !res.Yes {
				return m, m.enterCmd()
			}
			m.push(scrBitwigModuleUninstalling)
			m.runner = tuikit.NewRunner().SetSize(m.contentSize())
			var cmd tea.Cmd
			m.runner, cmd = m.runner.Start("Removing the Move module", actionsBin(), "bitwig-move-uninstall-module")
			return m, cmd
		}
		var cmd tea.Cmd
		m.confirm, cmd = m.confirm.Update(msg)
		return m, cmd

	case scrBitwigModuleUninstalling:
		if done, ok := msg.(tuikit.RunnerDoneMsg); ok {
			m.pop() // back to the Bitwig menu, on success or failure
			if done.Err != nil {
				m.toast, _ = m.toast.SetErr(done.Err.Error())
				return m, tea.Batch(m.enterCmd(), fetchStatus())
			}
			m.toast, _ = m.toast.SetOK("Move module removal done — check the terminal for ssh output")
			return m, tea.Batch(m.enterCmd(), fetchStatus())
		}
		if km, ok := msg.(tea.KeyMsg); ok && (km.String() == "esc" || km.String() == "enter") {
			if km.String() == "esc" && !m.runner.Done() {
				m.runner.Cancel()
			}
			if m.runner.Done() || km.String() == "esc" {
				m.pop() // back to the Bitwig menu
				return m, tea.Batch(m.enterCmd(), fetchStatus())
			}
			return m, nil
		}
		var cmd tea.Cmd
		m.runner, cmd = m.runner.Update(msg)
		return m, cmd

	case scrBitwigTipConfirm:
		if res, ok := msg.(tuikit.ConfirmResultMsg); ok {
			m.pop()
			if res.Canceled || !res.Yes {
				return m, m.enterCmd()
			}
			m.push(scrBitwigTipWait)
			return m, tea.Batch(m.enterCmd(), runSilent("open-bitwig"))
		}
		var cmd tea.Cmd
		m.confirm, cmd = m.confirm.Update(msg)
		return m, cmd

	case scrBitwigTipWait:
		if km, ok := msg.(tea.KeyMsg); ok {
			if km.String() == "esc" || km.String() == "ctrl+c" {
				m.bitwigSawRunning = false
				m.pop()
				return m, m.enterCmd()
			}
		}
		return m, bitwigRunningCmd()

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
		if km, ok := msg.(tea.KeyMsg); ok && (km.String() == "esc" || km.String() == "enter") {
			// Esc: cancel the runner (if still running) AND pop back to
			// the previous screen immediately — never sit on a half-drawn
			// waiting view the user has already dismissed.
			// Enter: only meaningful once done; otherwise let the run finish.
			if km.String() == "esc" && !m.runner.Done() {
				m.runner.Cancel()
			}
			if m.runner.Done() || km.String() == "esc" {
				m.pop()
				return m, m.enterCmd()
			}
			return m, nil
		}
		var cmd tea.Cmd
		m.runner, cmd = m.runner.Update(msg)
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

	case scrBundleEmptyConfirm:
		if res, ok := msg.(tuikit.ConfirmResultMsg); ok {
			if res.Canceled || !res.Yes {
				m.pop()
				return m, m.enterCmd()
			}
			if m.status.FilePicker == "superfile" && m.status.SuperfileInstalled {
				return m, pickBundleFileViaSuperfileEmbedded()
			}
			m.loading = true
			return m, fetchPath("pick-file", "pick-file")
		}
		var cmd tea.Cmd
		m.confirm, cmd = m.confirm.Update(msg)
		return m, cmd

	case scrAbletonConflictConfirm:
		if res, ok := msg.(tuikit.ConfirmResultMsg); ok {
			if res.Extra {
				// Re-check: re-run the conflict query WITHOUT leaving the
				// prompt. abletonConflictMsg re-shows this same prompt when
				// Ableton is still open, or proceeds to the conversion if
				// the user closed it in the meantime.
				m.loading = true
				return m, checkAbletonConflictCmd()
			}
			if res.Canceled || !res.Yes {
				m.nav = []screen{scrMain}
				m.toast, _ = m.toast.SetWarn("canceled — an existing Ableton instance is still open")
				return m, m.enterCmd()
			}
			m.push(scrAbletonClosing)
			m.runner = tuikit.NewRunner().SetSize(m.contentSize())
			var cmd tea.Cmd
			m.runner, cmd = m.runner.Start("Closing Ableton", actionsBin(), "close-ableton-and-wait")
			return m, cmd
		}
		var cmd tea.Cmd
		m.confirm, cmd = m.confirm.Update(msg)
		return m, cmd

	case scrAbletonClosing:
		if done, ok := msg.(tuikit.RunnerDoneMsg); ok {
			if done.Err != nil {
				// The automatic close waited MAX_WAIT_ABLETON and gave up:
				// the decision "close it yourself and continue, or stop"
				// is Go's to make (the script's ui_confirm is stubbed).
				m.push(scrAbletonCloseRetryConfirm)
				return m, m.enterCmd()
			}
			return m.startAbletonConversion()
		}
		if km, ok := msg.(tea.KeyMsg); ok && (km.String() == "esc" || km.String() == "enter") {
			// Esc: cancel the close-wait AND pop back to main immediately
			// so the user is never trapped on a waiting screen they've
			// already dismissed. Enter does nothing while the wait runs;
			// once done it leaves the log.
			if km.String() == "esc" && !m.runner.Done() {
				m.runner.Cancel()
			}
			if m.runner.Done() || km.String() == "esc" {
				m.nav = []screen{scrMain}
				m.toast, _ = m.toast.SetWarn("Ableton close wait canceled")
				return m, m.enterCmd()
			}
			return m, nil
		}
		var cmd tea.Cmd
		m.runner, cmd = m.runner.Update(msg)
		return m, cmd

	case scrBitwigOpening:
		if done, ok := msg.(tuikit.RunnerDoneMsg); ok {
			if done.Err == nil {
				// Bitwig now has the project (the .als was handed over,
				// including the ydotool routine). The manager does NOT quit:
				// it goes into hidden discretion mode, its window already
				// off-screen, and waits for Bitwig to close — then exits and
				// cleans up. The watched PID comes from the action's
				// BITWIG_PID= sentinel.
				return m.enterDiscretion(extractBitwigPID(m.runner.Output()))
			}
			// Opening failed: the action re-showed the window so the error on
			// this log screen is readable. The runner is done, so the
			// state-driven marker drops to "no marker" on the next Update and
			// this visible instance is detected as conflicting again. Stay
			// here, esc/enter leaves.
			return m, nil
		}
		if km, ok := msg.(tea.KeyMsg); ok && (km.String() == "esc" || km.String() == "enter") {
			// Esc: cancel the Bitwig open AND quit the TUI — there's
			// nothing useful left on this screen once the user has
			// dismissed it, so don't strand them on a half-drawn wait.
			// Enter does nothing while the open runs; once done, quit.
			if km.String() == "esc" && !m.runner.Done() {
				m.runner.Cancel()
			}
			if m.runner.Done() || km.String() == "esc" {
				m.quit = true
				return m, tea.Quit
			}
			return m, nil
		}
		var cmd tea.Cmd
		m.runner, cmd = m.runner.Update(msg)
		return m, cmd

	case scrConverting, scrWorkingDirRunning:
		if done, ok := msg.(tuikit.RunnerDoneMsg); ok {
			return m.handleRunnerDone(done)
		}
		if km, ok := msg.(tea.KeyMsg); ok && (km.String() == "esc" || km.String() == "enter") {
			// Esc: cancel/abort the conversion AND pop back to main
			// immediately so the user is never trapped on a running screen
			// they've already dismissed. Enter does nothing while the run
			// is in flight; once done it leaves the log.
			if km.String() == "esc" && !m.runner.Done() {
				m.runner.Cancel()
			}
			if m.runner.Done() || km.String() == "esc" {
				m.pop()
				return m, m.enterCmd()
			}
			return m, nil
		}
		var cmd tea.Cmd
		m.runner, cmd = m.runner.Update(msg)
		return m, cmd

	case scrManagerWait:
		if done, ok := msg.(tuikit.RunnerDoneMsg); ok {
			return m.handleRunnerDone(done)
		}
		if pr, ok := msg.(managerPollResultMsg); ok {
			return m.handleManagerPoll(pr)
		}
		if km, ok := msg.(tea.KeyMsg); ok {
			if km.String() == "esc" || km.String() == "enter" {
				// Esc: cancel the runner (if running) AND pop back
				// immediately. Enter: only meaningful once the manager is
				// up (managerWaiting) or the runner is done.
				if km.String() == "esc" && !m.managerWaiting && !m.runner.Done() {
					m.runner.Cancel()
				}
				if m.managerWaiting || m.runner.Done() || km.String() == "esc" {
					m.managerWaiting = false
					m.pop()
					m.toast, _ = m.toast.SetOK("stopped waiting — the Move Manager stays open")
					return m, m.enterCmd()
				}
				return m, nil
			}
		}
		if m.managerWaiting {
			return m, nil
		}
		var cmd tea.Cmd
		m.runner, cmd = m.runner.Update(msg)
		return m, cmd

	case scrManagerDownloadConfirm:
		if res, ok := msg.(tuikit.ConfirmResultMsg); ok {
			// Either way, go back to waiting for the Manager. "Close &
			// continue" also fires the close; the poll loop then spots
			// running=false and drops into the bundle picker.
			m.pop()
			if res.Yes {
				return m, tea.Batch(managerPollCmd(), runSilent("close-manager"))
			}
			return m, managerPollCmd()
		}
		var cmd tea.Cmd
		m.confirm, cmd = m.confirm.Update(msg)
		return m, cmd

	case scrAbletonCloseRetryConfirm:
		if res, ok := msg.(tuikit.ConfirmResultMsg); ok {
			if res.Canceled || !res.Yes {
				m.nav = []screen{scrMain}
				m.toast, _ = m.toast.SetWarn("canceled — Ableton is still open")
				return m, m.enterCmd()
			}
			// Back onto scrAbletonClosing, restart the close runner so a
			// manual close can round-trip into startAbletonConversion.
			m.pop()
			m.runner = tuikit.NewRunner().SetSize(m.contentSize())
			var cmd tea.Cmd
			m.runner, cmd = m.runner.Start("Closing Ableton", actionsBin(), "close-ableton-and-wait")
			return m, cmd
		}
		var cmd tea.Cmd
		m.confirm, cmd = m.confirm.Update(msg)
		return m, cmd

	case scrConvertRetryConfirm, scrNoAlsConfirm:
		if res, ok := msg.(tuikit.ConfirmResultMsg); ok {
			if res.Canceled || !res.Yes {
				m.nav = []screen{scrMain}
				return m, m.enterCmd()
			}
			return m.restartAbletonConversion()
		}
		var cmd tea.Cmd
		m.confirm, cmd = m.confirm.Update(msg)
		return m, cmd
	}
	return m, nil
}

func (m model) handleMainChoice(v string) (tea.Model, tea.Cmd) {
	switch v {
	case "refresh":
		m.loading = true
		return m, fetchStatus()
	case "address":
		m.push(scrAddress)
		return m, m.enterCmd()
	case "manager":
		if !m.status.Connected {
			m.toast, _ = m.toast.SetWarn("Move not connected — change address or plug in USB")
			return m, nil
		}
		m.push(scrManagerWait)
		m.managerWaiting = false
		m.runner = tuikit.NewRunner().SetSize(m.contentSize())
		var cmd tea.Cmd
		m.runner, cmd = m.runner.Start("Opening the Move Manager", actionsBin(), "open-manager")
		return m, cmd
	case "convert":
		m.push(scrBundlePick)
		return m, m.enterCmd()
	case "convert_preset":
		m.push(scrConvertPresetSource)
		return m, m.enterCmd()
	case "schwung":
		if !m.status.Connected {
			m.toast, _ = m.toast.SetWarn("Move not connected — plug it in to manage Schwung")
			return m, nil
		}
		m.push(scrSchwungMenu)
		return m, m.enterCmd()
	case "bitwig_move":
		m.push(scrBitwigMenu)
		return m, m.enterCmd()
	case "settings":
		m.push(scrSettings)
		return m, m.enterCmd()
	case "quit":
		m.push(scrQuitConfirm)
		return m, m.enterCmd()
	}
	return m, nil
}

func (m model) handleSettingsChoice(v string) (tea.Model, tea.Cmd) {
	switch v {
	case "hide_converted":
		m.loading = true
		return m, runFireAndForget("setting saved", "toggle-hide-converted")
	case "open_als_ydotool":
		m.loading = true
		return m, runFireAndForget("setting saved", "toggle-open-als-ydotool")
	case "ableton_version":
		m.push(scrAbletonVersion)
		return m, m.enterCmd()
	case "working_dir":
		m.push(scrWorkingDirRunning)
		m.runner = tuikit.NewRunner().SetSize(m.contentSize())
		var cmd tea.Cmd
		m.runner, cmd = m.runner.Start("Changing working directory", actionsBin(), "change-working-dir")
		return m, cmd
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
	case "clear_als":
		m.push(scrClearAlsConfirm)
		return m, m.enterCmd()
	}
	return m, nil
}

func (m model) startConvert(route string) (tea.Model, tea.Cmd) {
	m.pendingRoute = route
	if route == "midi" {
		m.replace(scrConverting)
		m.runner = tuikit.NewRunner().SetSize(m.contentSize())
		var cmd tea.Cmd
		m.runner, cmd = m.runner.Start("Exporting to MIDI", actionsBin(), "export-midi", m.pendingBundle)
		return m, cmd
	}
	// .als (beta) route: like MIDI, no Ableton involved, but its runner ends
	// with an ALS_PATH= sentinel that scrConverting's done-handler picks up
	// to ask "open in Bitwig?" — the same primary-decision screen as the
	// Ableton route.
	if route == "als" {
		m.replace(scrConverting)
		m.runner = tuikit.NewRunner().SetSize(m.contentSize())
		var cmd tea.Cmd
		m.runner, cmd = m.runner.Start("Converting to .als (beta)", actionsBin(), "export-als", m.pendingBundle)
		return m, cmd
	}
	// Bitwig route: "is Ableton already open?" is a PRIMARY decision Go
	// must make itself (see lib-move-manager-core.sh's open_ableton_route
	// comment) -- check first, rather than starting the conversion runner
	// straight away.
	m.loading = true
	return m, checkAbletonConflictCmd()
}

// startConversionCmd launches the Bitwig-route conversion runner, returning
// the updated model (a VALUE receiver that only returned the command would
// leave the host's runner pointing at the PREVIOUS conversion, so its output
// and its Cancel() wiring would be reused — the "project conversion
// shows the preset-conversion log" bug). The model is returned so the fresh
// runner actually lands on the host.
func (m model) startConversionCmd() (tea.Model, tea.Cmd) {
	m.runner = tuikit.NewRunner().SetSize(m.contentSize())
	var cmd tea.Cmd
	m.runner, cmd = m.runner.Start("Converting to Bitwig", actionsBin(), "open-ableton-route", m.pendingBundle)
	return m, cmd
}

// startAbletonConversion actually starts the Ableton->Bitwig runner, once
// any conflict has already been resolved (or there wasn't one). The runner
// launches Ableton, tells the user where to save, waits (no automation) for
// them to save and close it, then detects the .als and opens it in Bitwig.
func (m model) startAbletonConversion() (tea.Model, tea.Cmd) {
	m.nav = []screen{scrMain, scrConverting}
	m.pendingRoute = "bitwig"
	return m.startConversionCmd()
}

func (m model) restartAbletonConversion() (tea.Model, tea.Cmd) {
	m.pop() // drop the retry confirm, land back on scrConverting
	return m.startConversionCmd()
}

func (m model) handleRunnerDone(done tuikit.RunnerDoneMsg) (tea.Model, tea.Cmd) {
	switch m.top() {
	case scrManagerWait:
		if done.Err != nil {
			return m, nil // stay, showing why the opener failed; esc leaves
		}
		// The Move Manager webapp is up — switch from the short "opening"
		// runner to the read-only poll loop (scrManagerWaitView). The wait
		// itself is Go's to make; the actions script can't prompt here.
		m.managerWaiting = true
		m.managerPrompted = ""
		return m, managerPollCmd()
	case scrConverting:
		return m.handleConvertDone(done)
	default:
		return m, nil // scrWorkingDirRunning et al: stay on the finished log
	}
}

func (m model) handleConvertDone(done tuikit.RunnerDoneMsg) (tea.Model, tea.Cmd) {
	// Only open-ableton-route (the Bitwig route) ever prints this sentinel;
	// export-midi's output never will, so this is a no-op there. A non-empty
	// path means Ableton closed and a new .als was found: open it in Bitwig
	// immediately — there is no confirm screen anymore (the sole remaining
	// Bitwig-open decision is the ydotool setting, applied inside
	// finish_bitwig_open). The sentinel is checked BEFORE the error so a
	// phase that printed a path and then exited non-zero still proceeds.
	if alsPath, found := extractAlsPath(m.runner.Output()); found && alsPath != "" {
		m.pendingAls = alsPath
		// The Bitwig handoff / final step has begun. The state-driven marker
		// records this instance as "busy" from the scrBitwigOpening screen the
		// instant the runner below starts — before this step can be disturbed.
		m.push(scrBitwigOpening)
		m.runner = tuikit.NewRunner().SetSize(m.contentSize())
		var cmd tea.Cmd
		m.runner, cmd = m.runner.Start("Opening in Bitwig", actionsBin(), "finish-bitwig-open", m.pendingBundle, m.pendingAls)
		return m, cmd
	}
	if m.pendingRoute == "bitwig" {
		// Ableton closed but nothing new appeared in the als working folder.
		// Exit 2 is the "clean close, no .als" case and gets the dedicated
		// screen; any other failure (exit 1 = the window never appeared) is
		// a launch problem, so keep the retry prompt.
		if done.Err != nil && runnerExitCode(done.Err) != 2 {
			m.push(scrConvertRetryConfirm)
			return m, m.enterCmd()
		}
		m.push(scrNoAlsConfirm)
		return m, m.enterCmd()
	}
	if done.Err != nil {
		return m, nil // midi/.als beta failed: stay on the log; esc/enter leave
	}
	return m, nil // nothing to open in Bitwig -- stay showing the log; esc/enter to leave
}

// handlePresetUploadPoll drives the post-preset "import it in the Move
// Manager" screen: it waits until the Manager window has been seen running at
// least once, then — when it disappears (the user closed it) — refocuses this
// terminal (so the foot/TUI window comes back to the foreground) and returns
// to the calling menu. Ignoring the `newest` bundle is deliberate: this flow
// is about importing a converted preset, not downloading a set.
func (m model) handlePresetUploadPoll(p managerPollResultMsg) (tea.Model, tea.Cmd) {
	if p.err != nil {
		return m, managerPollCmd() // transient (Manager may still be launching)
	}
	if p.running {
		m.presetUploadSawRunning = true
		return m, managerPollCmd()
	}
	if !m.presetUploadSawRunning {
		// The webapp hasn't appeared yet — don't mistake launch latency for
		// the user having already closed it.
		return m, managerPollCmd()
	}
	m.presetUploadSawRunning = false
	m.nav = []screen{scrMain}
	m.toast, _ = m.toast.SetOK("Move Manager closed — back to the menu")
	return m, tea.Batch(m.enterCmd(), runSilent("raise-own-window"))
}

func (m model) handleManagerPoll(p managerPollResultMsg) (tea.Model, tea.Cmd) {
	if p.err != nil {
		m.toast, _ = m.toast.SetWarn("manager poll failed: " + p.err.Error())
		return m, managerPollCmd() // transient (manager may not be up yet) — keep polling
	}
	if !p.running {
		// The Manager window closed: deposit any set downloaded in the
		// auto-download folders, then drop straight into the bundle picker —
		// the natural next step of the old open-manager-and-wait flow.
		m.managerWaiting = false
		m.loading = true
		m.replace(scrBundlePick)
		return m, finishManagerAndList()
	}
	if p.newest != "" && p.newest != m.managerPrompted {
		// A set finished downloading while we waited. Report it (raise our
		// own floating window so the prompt is visible above the Move
		// Manager) and let Go own the "close it and continue?" decision.
		m.managerPrompted = p.newest
		m.confirm = tuikit.NewConfirm(
			filepath.Base(p.newest)+" finished downloading on the Move — close the Manager and continue?",
			"Keep waiting", "Close & continue")
		m.push(scrManagerDownloadConfirm)
		return m, runSilent("raise-own-window")
	}
	return m, managerPollCmd()
}

func (m model) handleSchwungChoice(v string) (tea.Model, tea.Cmd) {
	switch v {
	case "install":
		m.push(scrSchwungInstalling)
		m.loading = true
		m.runner = tuikit.NewRunner().SetSize(m.contentSize())
		var cmd tea.Cmd
		title := "Installing Schwung"
		if m.schwungInstalled {
			title = "Updating Schwung"
		}
		m.runner, cmd = m.runner.Start(title, actionsBin(), "schwung-install")
		return m, cmd
	case "open":
		// Same dedicated-profile webapp behaviour as the Move Manager webapp
		// (its launcher installs on first use; never touches this script's
		// own process — the "must not open/close mosquito" rule). Just
		// reports it back as a toast, no wait screen: schwung is managed on
		// the device itself, there's nothing host-side left to poll for.
		return m, openSchwungManagerCmd()
	case "uninstall":
		m.push(scrSchwungUninstallConfirm)
		return m, m.enterCmd()
	}
	return m, nil
}

// bitwigTipText is the controller-setup instruction shown inside the framed
// tip modal. It leads with the essential path — Bitwig → Settings →
// Controllers → Add Controller → vendor Ableton, controller Move — then the
// MIDI port hint and the restart note.
func bitwigTipText() string {
	return strings.Join([]string{
		"In Bitwig: Settings → Controllers → Add Controller →",
		tuikit.StyleAccent.Render("choose vendor  Ableton , then controller  Move ."),
		"",
		"Then select the MIDI ports  midiin4 / midiou4  (the Move).",
		"",
		"Restart Bitwig (or rescan Controllers) after installing so the",
		"Ableton vendor and Move controller show up.",
		"",
		"Close Bitwig to return to the menu, or esc to go back now.",
	}, "\n")
}

func (m model) handleBitwigChoice(v string) (tea.Model, tea.Cmd) {
	switch v {
	case "install":
		m.push(scrBitwigInstalling)
		m.loading = true
		m.runner = tuikit.NewRunner().SetSize(m.contentSize())
		var cmd tea.Cmd
		m.runner, cmd = m.runner.Start("Installing the Move controller", actionsBin(), "bitwig-move-install")
		return m, cmd
	case "uninstall":
		m.push(scrBitwigUninstallConfirm)
		return m, m.enterCmd()
	case "uninstall_module":
		m.push(scrBitwigModuleUninstallConfirm)
		return m, m.enterCmd()
	}
	return m, nil
}

// handlePresetConvertDone finalizes a "Convert a preset" run. The converter
// exits 0 even when a bundle was skipped (samples missing on disk) — that's
// a partial success by design and reads as OK here, with the run's output
// still visible on the log before esc returns home.
func (m model) handlePresetConvertDone(done tuikit.RunnerDoneMsg) (tea.Model, tea.Cmd) {
	if done.Err != nil {
		return m, nil // stay on the log; esc/enter leave
	}
	// Capture what the converter actually produced before the runner state
	// is reset — the post-conversion screen shows these paths.
	m.presetOutputs = presetOutputPaths(m.runner.Output())
	if len(m.presetOutputs) == 0 && m.presetDir != "" {
		m.presetOutputs = []string{m.presetDir}
	}
	msg := "preset converted"
	if m.presetDir != "" {
		msg += " → " + m.presetDir
	}
	m.presetFiles = nil
	m.nav = []screen{scrMain}
	m.toast, _ = m.toast.SetOK(msg)
	// Next step depends on whether the Move is connected: with it, offer to
	// open the Move Manager and show where the preset is to upload; without
	// it, say so and offer refresh / back to the main menu.
	if m.status.Connected {
		m.push(scrPresetUploadConfirm)
	} else {
		m.push(scrPresetNoMove)
	}
	return m, m.enterCmd()
}
