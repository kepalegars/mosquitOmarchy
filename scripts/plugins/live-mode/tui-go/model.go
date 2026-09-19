package main

import (
	"fmt"
	"os"
	"strconv"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	tuikit "mosquitomarchy.local/tui-kit"
)

// settingsDwell is how long a Left/Right-adjusted settings value is shown as
// "pending" before it is written automatically. Every fresh Left/Right
// restarts the clock (see settingsDwellMsg/cycleSetting).
const settingsDwell = 800 * time.Millisecond

// settingsDwellMsg fires when a pending settings value has been left alone
// for settingsDwell. seq guards against stale timers: every Left/Right bumps
// dwellSeq, so an older tick whose seq no longer matches is ignored.
type settingsDwellMsg struct {
	row string
	seq int
}

// One persistent Bubble Tea program mirrors the audio/move managers: a main
// settings screen plus the background-apps chooser. Enter on a main-screen
// item toggles or cycles it (thermal limit also obeys Left/Right), writes
// the settings file immediately, and confirms with a toast. Reset defaults
// restores the shipped defaults in one press.

type screen int

const (
	scrMain screen = iota
	scrApps
	scrQuit
)

// thermalOrder is what Left/Right cycle through on the thermal-limit row.
var thermalSteps = []int{95, 90, 85, 80, 75}

type model struct {
	w, h       int
	settings   Settings
	nav        []screen
	picker     tuikit.Picker
	appsPicker tuikit.Picker
	confirm    tuikit.Confirm
	toast      tuikit.Toast
	quit       bool

	// pending holds a Left/Right-adjusted but not-yet-saved value per
	// settings row (the target: "on"/"off", or the thermal step as a
	// string). The label is overridden from it immediately; the value is
	// written on the dwell timer, when the cursor leaves the row, or when
	// the screen is left. dwellSeq invalidates older dwell timers.
	pending  map[string]string
	dwellSeq int
}

func initialModel() model {
	m := model{nav: []screen{scrMain}, settings: loadSettings()}
	m.picker = tuikit.NewPicker("", m.mainItems()).SetSize(m.contentSize())
	// Build the apps picker up front: Update() calls SetSize on both pickers
	// for every WindowSizeMsg, and a zero Picker has no delegate — SetSize on
	// it would nil-deref inside bubbles' updatePagination and crash the TUI
	// on the very first size message (the launch-blocking bug).
	m.appsPicker = tuikit.NewPicker("",
		m.settings.appItems(),
	).SetSize(m.contentSize())
	return m
}

func (m model) Init() tea.Cmd { return tuikit.ThemeWatchCmd() }

func (m model) top() screen { return m.nav[len(m.nav)-1] }

func (m *model) pop() {
	if len(m.nav) > 1 {
		m.nav = m.nav[:len(m.nav)-1]
	}
	m.toast = m.toast.ClearNonCritical()
}

func (m model) mainItems() []tuikit.PickerItem {
	s := m.settings
	return []tuikit.PickerItem{
		{Display: fmt.Sprintf("Thermal limit: %d°C", s.ThermalLimitC), Value: "thermal"},
		{Display: "Ask to close background apps at start: " + boolLabel(s.CloseApps), Value: "close_apps"},
		{Display: "Choose background apps to close at start", Value: "choose_apps"},
		{Display: "Audio routing tool in the scratchpad: " + boolLabel(s.RoutingTool), Value: "routing"},
		{Display: "Window gaps disabled during the session: " + boolLabel(s.NoGaps), Value: "gaps"},
		{Display: "Silence notifications: " + boolLabel(s.SilenceNotifs), Value: "notifs"},
		{Display: "Reset defaults", Value: "reset"},
		{Display: "Close", Value: "quit"},
	}
}

// appsItems renders the known background apps with a ✓/○ marker for the
// configured close-at-start set (same shape as the managers' toggle lists).
func (s Settings) appItems() []tuikit.PickerItem {
	items := make([]tuikit.PickerItem, len(knownApps))
	for i, name := range knownApps {
		mark := "○"
		if hasApp(s.CloseAppsList, name) {
			mark = "✓"
		}
		items[i] = tuikit.PickerItem{Display: mark + " " + name, Value: name}
	}
	return items
}

func boolLabel(b bool) string {
	if b {
		return "On"
	}
	return "Off"
}

// liveToggleTarget maps a boolean state to its pending-string target.
func liveToggleTarget(on bool) string {
	if on {
		return "on"
	}
	return "off"
}

// mainItemsWithPending overlays the not-yet-saved Left/Right value on the
// settings rows so the label moves the instant an arrow is pressed.
func (m model) mainItemsWithPending() []tuikit.PickerItem {
	items := m.mainItems()
	for i := range items {
		target, ok := m.pending[items[i].Value]
		if !ok {
			continue
		}
		switch items[i].Value {
		case "thermal":
			items[i].Display = fmt.Sprintf("Thermal limit: %s°C", target)
		case "close_apps":
			items[i].Display = "Ask to close background apps at start: " + boolLabel(target == "on")
		case "routing":
			items[i].Display = "Audio routing tool in the scratchpad: " + boolLabel(target == "on")
		case "gaps":
			items[i].Display = "Window gaps disabled during the session: " + boolLabel(target == "on")
		case "notifs":
			items[i].Display = "Silence notifications: " + boolLabel(target == "on")
		}
	}
	return items
}

func (m *model) rebuildMainPicker() {
	idx := m.picker.Index()
	m.picker = tuikit.NewPicker("", m.mainItemsWithPending()).SetSize(m.contentSize()).
		SetHelpKeys(thermalHelpKeys()...)
	m.picker = m.picker.SelectIndex(idx)
}

// setPending applies one pending row onto s (no persistence).
func setPending(s Settings, row, target string) Settings {
	switch row {
	case "thermal":
		if n, err := strconv.Atoi(target); err == nil {
			s.ThermalLimitC = n
		}
	case "close_apps":
		s.CloseApps = target == "on"
	case "routing":
		s.RoutingTool = target == "on"
	case "gaps":
		s.NoGaps = target == "on"
	case "notifs":
		s.SilenceNotifs = target == "on"
	}
	return s
}

// applyPendingRow writes the pending value of one row (if any) and clears it.
func (m *model) applyPendingRow(row string) {
	target, ok := m.pending[row]
	if !ok {
		return
	}
	s := setPending(m.settings, row, target)
	if err := saveSettings(s); err != nil {
		m.toast, _ = m.toast.SetErr("Could not save settings: " + err.Error())
		return
	}
	m.settings = s
	delete(m.pending, row)
	m.toast, _ = m.toast.SetOK("Settings saved")
}

// applyAllPending writes every pending row in one save, used when the screen
// is left.
func (m *model) applyAllPending() {
	if len(m.pending) == 0 {
		return
	}
	s := m.settings
	for row, target := range m.pending {
		s = setPending(s, row, target)
	}
	if err := saveSettings(s); err != nil {
		m.toast, _ = m.toast.SetErr("Could not save settings: " + err.Error())
		return
	}
	m.settings = s
	m.pending = map[string]string{}
	m.toast, _ = m.toast.SetOK("Settings saved")
}

// applyAllPendingExcept writes every pending row except the one the user is
// acting on with Enter (that row's own handler is the apply).
func (m *model) applyAllPendingExcept(except string) {
	delete(m.pending, except)
	// Save whatever remains in one save.
	if len(m.pending) == 0 {
		return
	}
	s := m.settings
	for row, target := range m.pending {
		s = setPending(s, row, target)
	}
	if err := saveSettings(s); err != nil {
		m.toast, _ = m.toast.SetErr("Could not save settings: " + err.Error())
		return
	}
	m.settings = s
	m.pending = map[string]string{}
	m.toast, _ = m.toast.SetOK("Settings saved")
}

// cycleSetting steps the row under the cursor, shows the new value as a
// pending label without saving it, and arms the dwell timer that writes it
// if the user leaves the value alone.
func (m *model) cycleSetting(dir int) (tea.Model, tea.Cmd) {
	row := m.picker.SelectedValue()
	if m.pending == nil {
		m.pending = map[string]string{}
	}
	switch row {
	case "thermal":
		cur := m.settings.ThermalLimitC
		if p, ok := m.pending[row]; ok {
			if n, err := strconv.Atoi(p); err == nil {
				cur = n
			}
		}
		idx := 0
		for i, v := range thermalSteps {
			if v == cur {
				idx = i
				break
			}
		}
		idx = ((idx+dir)%len(thermalSteps) + len(thermalSteps)) % len(thermalSteps)
		m.pending[row] = itoa(thermalSteps[idx])
	case "close_apps":
		cur := m.settings.CloseApps
		if p, ok := m.pending[row]; ok {
			cur = p == "on"
		}
		m.pending[row] = liveToggleTarget(!cur)
	case "routing":
		cur := m.settings.RoutingTool
		if p, ok := m.pending[row]; ok {
			cur = p == "on"
		}
		m.pending[row] = liveToggleTarget(!cur)
	case "gaps":
		cur := m.settings.NoGaps
		if p, ok := m.pending[row]; ok {
			cur = p == "on"
		}
		m.pending[row] = liveToggleTarget(!cur)
	case "notifs":
		cur := m.settings.SilenceNotifs
		if p, ok := m.pending[row]; ok {
			cur = p == "on"
		}
		m.pending[row] = liveToggleTarget(!cur)
	default:
		return m, nil
	}
	m.rebuildMainPicker()
	m.dwellSeq++
	seq := m.dwellSeq
	rowID := row
	return m, tea.Tick(settingsDwell, func(time.Time) tea.Msg {
		return settingsDwellMsg{row: rowID, seq: seq}
	})
}

func (m *model) apply(choice string) {
	s := m.settings
	switch choice {
	case "choose_apps":
		// Leaving the settings screen commits any pending value first.
		m.applyAllPending()
		m.appsPicker = tuikit.NewPicker("",
			m.settings.appItems(),
		).SetSize(m.contentSize())
		m.picker = m.picker.SetSize(m.contentSize())
		m.nav = append(m.nav, scrApps)
		return
	case "quit":
		// "Close" asks the same quit confirmation Esc does (user's rule:
		// nothing exits without one confirm), so both paths land on the
		// same screen instead of quitting directly.
		m.applyAllPending()
		m.confirm = tuikit.NewConfirm("Quit mosquito Live Mode Manager?", "No", "Yes")
		m.nav = append(m.nav, scrQuit)
		return
	case "reset":
		s = defaultSettings()
		m.pending = map[string]string{}
	case "thermal":
		// Enter also advances the thermal step so the row is key-only usable.
		idx := 0
		for i, v := range thermalSteps {
			if v == s.ThermalLimitC {
				idx = i
				break
			}
		}
		s.ThermalLimitC = thermalSteps[(idx+1)%len(thermalSteps)]
	case "close_apps":
		s.CloseApps = !s.CloseApps
	case "routing":
		s.RoutingTool = !s.RoutingTool
	case "gaps":
		s.NoGaps = !s.NoGaps
	case "notifs":
		s.SilenceNotifs = !s.SilenceNotifs
	default:
		return
	}
	if err := saveSettings(s); err != nil {
		m.toast, _ = m.toast.SetErr("Could not save settings: " + err.Error())
		return
	}
	m.settings = s
	// Preserve the cursor across the rebuild: the picker is re-created
	// with the fresh row labels after every save, and a no-position
	// rebuild sent the cursor flying back to the top of the list on
	// every settings change (the user's complaint).
	m.rebuildMainPicker()
	if choice == "reset" {
		m.toast, _ = m.toast.SetOK("Defaults restored")
	} else {
		m.toast, _ = m.toast.SetOK("Settings saved")
	}
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
		m.appsPicker = m.appsPicker.SetSize(m.contentSize())
		return m, nil
	case tea.KeyMsg:
		if msg.String() == "ctrl+c" {
			// Any deeper screen: back out one level, like the other managers.
			if len(m.nav) == 1 {
				// Leaving the settings screen commits any pending value.
				m.applyAllPending()
				m.quit = true
				return m, tea.Quit
			}
			m.pop()
			return m, nil
		}

	case tuikit.ThemeTickMsg:
		tuikit.ApplyTheme()
		return m, tuikit.ThemeWatchCmd()
	case settingsDwellMsg:
		// Dwell elapsed: write the pending value of the row the user
		// stopped on (stale timers are dropped).
		if m.top() == scrMain && msg.seq == m.dwellSeq {
			m.applyPendingRow(msg.row)
			m.rebuildMainPicker()
		}
		return m, nil
	case tuikit.PickerSortMsg:
		if m.top() == scrMain {
			// Left/Right shows the next value as a pending label only; the
			// value is written on the dwell timer / blur / leave.
			return m.cycleSetting(msg.Dir)
		}
		return m, nil
	case tuikit.PickerToggleMsg:
		// Only the apps screen consumes Tab toggles.
		if m.top() == scrApps {
			name := msg.Value
			if hasApp(m.settings.CloseAppsList, name) {
				var next []string
				for _, a := range m.settings.CloseAppsList {
					if a != name {
						next = append(next, a)
					}
				}
				m.settings.CloseAppsList = next
			} else {
				m.settings.CloseAppsList = append(m.settings.CloseAppsList, name)
			}
			midx := m.appsPicker.Index()
			m.appsPicker = tuikit.NewPicker("",
				m.settings.appItems(),
			).SetSize(m.contentSize())
			m.appsPicker = m.appsPicker.SelectIndex(midx)
			return m, nil
		}
		return m, nil
	case tuikit.PickerResultMsg:
		switch m.top() {
		case scrMain:
			if msg.Canceled {
				// Esc on the home screen asks the same quit-confirmation
				// as the "Close" item — never a silent exit (user rule).
				// Leaving commits every pending value first.
				m.applyAllPending()
				m.confirm = tuikit.NewConfirm("Quit mosquito Live Mode Manager?", "No", "Yes")
				m.nav = append(m.nav, scrQuit)
				return m, nil
			}
			// Enter acts on this row directly: commit the other pending
			// rows, drop this one's mark to avoid a double apply.
			m.applyAllPendingExcept(msg.Value)
			m.apply(msg.Value)
			if m.quit {
				return m, tea.Quit
			}
			return m, nil
		case scrApps:
			if msg.Canceled {
				m.pop()
				return m, nil
			}
			// Enter saved the toggled set.
			if err := saveSettings(m.settings); err != nil {
				m.toast, _ = m.toast.SetErr("Could not save settings: " + err.Error())
				return m, nil
			}
			m.pop()
			m.rebuildMainPicker()
			m.toast, _ = m.toast.SetOK("Choices saved")
			return m, nil
		}
	case tuikit.ConfirmResultMsg:
		if m.top() == scrQuit {
			m.pop()
			if msg.Yes && !msg.Canceled {
				m.quit = true
				return m, tea.Quit
			}
			return m, nil
		}
	}

	var cmd tea.Cmd
	if m.top() == scrQuit {
		// The quit-confirmation owns every key while it's up (left/right
		// tab the buttons, enter answers, y/n shortcut) — the pickers
		// underneath must not also react to a plain Enter.
		m.confirm, cmd = m.confirm.Update(msg)
		m.toast = m.toast.Update(msg)
		return m, cmd
	}
	// Only feed the message to the picker that's actually on top of the
	// navigation stack — both pickers are kept in the model (one for the
	// home menu, one for the apps chooser) and both would otherwise react
	// to a single Enter, with the appsPicker's response overwriting the
	// home picker's and silently swallowing the action the user actually
	// intended (the user's report: "aucun des boutons [...] ne fonctionne
	// sauf le thermal" — Enter on a non-thermal row fired both pickers;
	// the appsPicker always won because it's processed last).
	switch m.top() {
	case scrMain:
		before := m.picker.SelectedValue()
		m.picker, cmd = m.picker.Update(msg)
		after := m.picker.SelectedValue()
		if before != "" && before != after {
			// Cursor moved to a different row: write what was left behind.
			m.applyPendingRow(before)
			m.rebuildMainPicker()
		}
	case scrApps:
		m.appsPicker, cmd = m.appsPicker.Update(msg)
	}
	m.toast = m.toast.Update(msg)
	return m, cmd
}

func main() {
	p := tea.NewProgram(initialModel(), tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		fmt.Fprintln(os.Stderr, "mosquito-live-mode-tui:", err)
		os.Exit(1)
	}
}
