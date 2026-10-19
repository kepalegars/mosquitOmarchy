// Interactive TUI — Bubble Tea over the shared tui-kit.
//
// Layout mirrors evotui (vanzaho/audient-evo-py): a device picker, a CONTROLS
// page (input gains/mutes/48V, output volumes/mutes) and a loopback MIXER
// page with a MIX bus selector, fronted by section headings. Differences from
// evotui: tui-kit components (Picker, Confirm, Info, Toast, CursorMemory,
// live Omarchy theme), immediate-apply Left/Right (no curses sliders), EVO 8
// first (4 inputs, 2 output pairs, 2 mix buses), and every device in
// drivers.Registry() instead of EVO-only. Only capability-advertised rows
// are ever offered: an ALSA box never shows a gain slider for an analog
// knob, and EVO 8 never shows a monitor-blend slider it does not have.
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"mosquitomarchy.local/mosquitomixbay-tui/drivers"
	tuikit "mosquitomarchy.local/tui-kit"
)

type screen int

const (
	scrDevices screen = iota
	scrControls
	scrMixer
	scrSettings
	scrInfo
	scrConfirm
)

type model struct {
	w, h int
	nav  []screen

	deviceID string
	status   drivers.Status
	loading  bool
	mixBus   int
	ui       uiPrefs

	picker  tuikit.Picker
	confirm tuikit.Confirm
	info    tuikit.Info
	toast   tuikit.Toast
	cursor  *tuikit.CursorMemory

	// numBuf is an in-progress numeric dB entry, started by typing a digit
	// on a volume/gain/mixer row: Enter applies it, Esc cancels. evotui's
	// dial buffer, without the curses.
	numBuf   string
	numRow   string
	numTitle string

	// confirm carries one pending destructive/simple action.
	confirmTitle string
	confirmAct   func() tea.Cmd

	// evo is the faithful evotui-style state for the EVO 4 / EVO 8 screens.
	evo evoUI

	quit bool
}

func initialModel() model {
	m := model{nav: []screen{scrDevices}, deviceID: defaultDevice(), ui: loadUIPrefs()}
	m.picker = tuikit.NewPicker("", nil)
	m.cursor = tuikit.NewCursorMemory()
	return m
}

func (m model) Init() tea.Cmd { return tea.Batch(fetchStatus(m.deviceID), tuikit.ThemeWatchCmd()) }
func (m model) top() screen   { return m.nav[len(m.nav)-1] }

func (m *model) push(s screen) {
	m.cursor.Remember(strconv.Itoa(int(m.top())), m.picker)
	m.nav = append(m.nav, s)
}
func (m *model) pop() {
	m.cursor.Remember(strconv.Itoa(int(m.top())), m.picker)
	if len(m.nav) > 1 {
		m.nav = m.nav[:len(m.nav)-1]
	}
	m.toast = m.toast.ClearNonCritical()
	m.numBuf, m.numRow = "", ""
	m.syncPicker()
	m.picker = m.cursor.Restore(strconv.Itoa(int(m.top())), m.picker)
}

func (m model) contentSize() (int, int) {
	w, h := m.w, m.h
	if w <= 0 {
		w = 90
	}
	if h <= 0 {
		h = 26
	}
	return w, h
}

// uiPrefs is the tiny interface-side preferences file (NOT device state):
// ~/.config/mosquitomixbay/ui.json. One key for now.
type uiPrefs struct {
	ShowOnlineOnly bool `json:"show_online_only"`
}

func uiPrefsFile() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "mosquitomixbay", "ui.json")
}

func loadUIPrefs() uiPrefs {
	var p uiPrefs
	if data, err := os.ReadFile(uiPrefsFile()); err == nil {
		_ = json.Unmarshal(data, &p)
	}
	return p
}

func saveUIPrefs(p uiPrefs) error {
	_ = os.MkdirAll(filepath.Dir(uiPrefsFile()), 0o755)
	data, _ := json.MarshalIndent(p, "", "  ")
	return os.WriteFile(uiPrefsFile(), data, 0o644)
}

// --- data fetching -----------------------------------------------------

type statusMsg struct {
	status drivers.Status
	err    error
}

func fetchStatus(dev string) tea.Cmd {
	return func() tea.Msg {
		d, err := drivers.Open(dev)
		if err != nil {
			return statusMsg{err: err}
		}
		st, err := d.Status()
		return statusMsg{status: st, err: err}
	}
}

type applyMsg struct {
	what string
	err  error
}

func applyCmd(dev string, fn func(drivers.Driver) error, what string) tea.Cmd {
	return func() tea.Msg {
		d, err := drivers.Open(dev)
		if err != nil {
			return applyMsg{err: err}
		}
		if err := fn(d); err != nil {
			return applyMsg{err: err}
		}
		return applyMsg{what: what}
	}
}

// --- picker builders -----------------------------------------------------

func (m *model) syncPicker() {
	cw, ch := m.contentSize()
	switch m.top() {
	case scrDevices:
		m.picker = tuikit.NewPicker("mosquitomixbay — interfaces", m.deviceItems()).SetSize(cw, ch)
	case scrControls:
		m.picker = tuikit.NewPicker(m.status.Spec.Display+" — controls", controlItems(m.status)).SetSize(cw, ch)
	case scrMixer:
		m.picker = tuikit.NewPicker(m.status.Spec.Display+" — loopback mixer "+drivers.BusLabel(m.mixBus), mixerItems(m.status, m.mixBus)).SetSize(cw, ch)
	case scrSettings:
		m.picker = tuikit.NewPicker("Settings", m.settingsItems()).SetSize(cw, ch)
	}
}

func (m model) deviceItems() []tuikit.PickerItem {
	var items []tuikit.PickerItem
	for _, spec := range drivers.Registry() {
		online := false
		if d, err := drivers.Open(spec.ID); err == nil && d.Probe() {
			online = true
		}
		if m.ui.ShowOnlineOnly && !online {
			continue
		}
		badge := "demo"
		if online {
			badge = "● online"
		}
		items = append(items, tuikit.PickerItem{
			Display: fmt.Sprintf("%-26s [%s]", spec.Display, badge),
			Value:   spec.ID,
		})
	}
	items = append(items,
		tuikit.PickerItem{Display: "Settings", Value: "settings"},
		tuikit.PickerItem{Display: "Close", Value: "quit"},
	)
	return items
}

func (m model) settingsItems() []tuikit.PickerItem {
	return []tuikit.PickerItem{
		{Display: "Show only connected interfaces: " + onOff(m.ui.ShowOnlineOnly), Value: "online_only"},
		{Display: "Back", Value: "back"},
	}
}

func onOff(b bool) string {
	if b {
		return "ON"
	}
	return "off"
}

func dbFmt(v float64) string {
	if v <= -127.5 {
		return "-inf"
	}
	return fmt.Sprintf("%+.1fdB", v)
}

// controlItems builds the CONTROLS page: INPUTS section (gain/mute/48V),
// OUTPUTS section (volume/mute), then the page actions. Only rows the
// device's Caps advertise are emitted.
func controlItems(st drivers.Status) []tuikit.PickerItem {
	caps := st.Spec.Caps
	var items []tuikit.PickerItem
	if len(st.Inputs) > 0 && (caps.Gain || caps.Phantom) {
		items = append(items, tuikit.PickerItem{Display: "INPUTS", Heading: true})
		for _, in := range st.Inputs {
			if caps.Gain {
				items = append(items, tuikit.PickerItem{
					Display: fmt.Sprintf("  %-8s gain %s", strings.ToUpper(in.Name), dbFmt(in.GainDb)),
					Value:   fmt.Sprintf("gain:%s", in.Name),
				})
			}
			items = append(items, tuikit.PickerItem{
				Display: fmt.Sprintf("  %-8s mute %s", strings.ToUpper(in.Name), onOff(in.Muted)),
				Value:   fmt.Sprintf("mute:%s", in.Name),
			})
			if caps.Phantom {
				items = append(items, tuikit.PickerItem{
					Display: fmt.Sprintf("  %-8s 48V %s", strings.ToUpper(in.Name), onOff(in.Phantom)),
					Value:   fmt.Sprintf("phantom:%s", in.Name),
				})
			}
		}
	}
	if len(st.Outputs) > 0 {
		items = append(items, tuikit.PickerItem{Display: "OUTPUTS", Heading: true})
		for i, o := range st.Outputs {
			items = append(items, tuikit.PickerItem{
				Display: fmt.Sprintf("  %-8s vol %s", strings.ToUpper(o.Name), dbFmt(o.VolumeDb)),
				Value:   fmt.Sprintf("vol:%d", i),
			})
			items = append(items, tuikit.PickerItem{
				Display: fmt.Sprintf("  %-8s mute %s", strings.ToUpper(o.Name), onOff(o.Muted)),
				Value:   fmt.Sprintf("mute:%s", o.Name),
			})
		}
	}
	if st.Monitor != nil {
		items = append(items, tuikit.PickerItem{
			Display: fmt.Sprintf("  %-8s %d%% (0=in · 100=playback)", "MONITOR", *st.Monitor),
			Value:   "monitor",
		})
	}
	items = append(items,
		tuikit.PickerItem{Display: "ACTIONS", Heading: true},
	)
	if caps.Mixer {
		items = append(items, tuikit.PickerItem{Display: "  Loopback mixer →", Value: "goto:mixer"})
	}
	items = append(items,
		tuikit.PickerItem{Display: "  Save state", Value: "save"},
		tuikit.PickerItem{Display: "  Reload saved state", Value: "load"},
		tuikit.PickerItem{Display: "  Back to devices", Value: "back"},
	)
	return items
}

// mixerItems builds the loopback MIXER page for one mix bus: the bus
// selector first, then every source route (volume + pan), then back.
func mixerItems(st drivers.Status, bus int) []tuikit.PickerItem {
	items := []tuikit.PickerItem{
		{Display: fmt.Sprintf("MIX bus: %s  (←/→ switch bus)", drivers.BusLabel(bus)), Value: "bus"},
		{Display: "SOURCES → " + drivers.BusLabel(bus), Heading: true},
	}
	for _, k := range drivers.MixerSources(st.Spec, bus) {
		c := st.Mixer[k]
		items = append(items, tuikit.PickerItem{
			Display: fmt.Sprintf("  %-12s vol %s  pan %+.0f", k, dbFmt(c.VolumeDb), c.Pan),
			Value:   "mix:" + k,
		})
	}
	items = append(items, tuikit.PickerItem{Display: "  ← Back to controls", Value: "back"})
	return items
}

// --- update ------------------------------------------------------------

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
		cw, ch := m.contentSize()
		m.picker = m.picker.SetSize(cw, ch)
		m.info = m.info.SetSize(cw, ch)
		return m, nil

	case tuikit.ThemeTickMsg:
		tuikit.ApplyTheme()
		return m, tuikit.ThemeWatchCmd()

	case evoStatusExpireMsg:
		if msg.gen == m.evo.statusGen {
			m.evo.statusMsg = ""
		}
		return m, nil

	case statusMsg:
		m.loading = false
		if msg.err != nil {
			m.toast, _ = m.toast.SetErr(msg.err.Error())
			return m, nil
		}
		m.status = msg.status
		if m.isEvoDevice() && m.evo.spec.ID == "" {
			m.evoEnter()
		}
		idx := m.picker.Index()
		m.syncPicker()
		if idx < 0 {
			idx = 0
		}
		m.picker = m.picker.SelectIndex(idx)
		return m, nil

	case applyMsg:
		if msg.err != nil {
			if m.isEvoDevice() && (m.top() == scrControls || m.top() == scrMixer) {
				return m, m.evo.evoStatus(msg.err.Error(), true)
			}
			m.toast, _ = m.toast.SetErr(msg.err.Error())
			return m, nil
		}
		if msg.what != "" {
			if m.isEvoDevice() && (m.top() == scrControls || m.top() == scrMixer) {
				return m, tea.Batch(m.evo.evoStatus(msg.what, false), fetchStatus(m.deviceID))
			}
			m.toast, _ = m.toast.SetOK(msg.what)
		}
		return m, fetchStatus(m.deviceID)

	case tea.KeyMsg:
		return m.updateKey(msg)
	}

	// Picker navigation (up/down) on list screens.
	if m.top() == scrDevices || m.top() == scrControls || m.top() == scrMixer || m.top() == scrSettings {
		var cmd tea.Cmd
		m.picker, cmd = m.picker.Update(msg)
		return m, cmd
	}
	if m.top() == scrConfirm {
		if res, ok := msg.(tuikit.ConfirmResultMsg); ok {
			act := m.confirmAct
			m.confirmAct = nil
			m.pop()
			if !res.Canceled && res.Yes && act != nil {
				return m, act()
			}
			return m, nil
		}
		var cmd tea.Cmd
		m.confirm, cmd = m.confirm.Update(msg)
		return m, cmd
	}
	if m.top() == scrInfo {
		if k, ok := msg.(tea.KeyMsg); ok && (k.String() == "esc" || k.String() == "enter" || k.String() == "q") {
			m.pop()
			return m, nil
		}
		var cmd tea.Cmd
		m.info, cmd = m.info.Update(msg)
		return m, cmd
	}
	return m, nil
}

func (m model) updateKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	k := msg.String()
	if k == "ctrl+c" {
		if len(m.nav) == 1 {
			m.quit = true
			return m, tea.Quit
		}
		m.pop()
		return m, nil
	}
	// Modal screens must consume their own keys before any list-screen
	// shortcut sees them.
	if m.top() == scrConfirm {
		var cmd tea.Cmd
		m.confirm, cmd = m.confirm.Update(msg)
		return m, cmd
	}
	if m.top() == scrInfo {
		if k == "esc" || k == "enter" || k == "q" {
			m.pop()
			return m, nil
		}
		var cmd tea.Cmd
		m.info, cmd = m.info.Update(msg)
		return m, cmd
	}
	// EVO 4 / EVO 8 draw their own evotui frame and own their keys.
	if m.isEvoDevice() && (m.top() == scrControls || m.top() == scrMixer) {
		return m, m.evoKey(k)
	}
	switch m.top() {
	case scrDevices:
		switch k {
		case "enter":
			if m.picker.SelectedValue() == "quit" {
				m.confirm = tuikit.NewConfirm("Quit mosquito-mixbay?", "No", "Yes")
				m.confirmAct = func() tea.Cmd {
					m.quit = true
					return tea.Quit
				}
				m.push(scrConfirm)
				return m, nil
			}
			if m.picker.SelectedValue() == "settings" {
				m.push(scrSettings)
				m.syncPicker()
				return m, nil
			}
			m.deviceID = m.picker.SelectedValue()
			m.loading = true
			m.push(scrControls)
			m.syncPicker()
			m.evoEnter()
			return m, fetchStatus(m.deviceID)
		case "q", "esc":
			m.confirm = tuikit.NewConfirm("Quit mosquito-mixbay?", "No", "Yes")
			m.confirmAct = func() tea.Cmd {
				m.quit = true
				return tea.Quit
			}
			m.push(scrConfirm)
			return m, nil
		}
	case scrControls:
		switch k {
		case "esc":
			if m.numBuf != "" {
				m.cancelNumeric()
				return m, nil
			}
			m.pop()
			return m, fetchStatus(m.deviceID)
		case "tab":
			if !m.status.Spec.Caps.Mixer {
				m.toast, _ = m.toast.SetWarn("No loopback mixer on this interface")
				return m, nil
			}
			m.push(scrMixer)
			m.syncPicker()
			return m, nil
		case "?":
			m.info = tuikit.NewInfo(helpText()).SetSize(m.contentSize())
			m.push(scrInfo)
			return m, nil
		case "m":
			if !m.status.Spec.Caps.Mixer {
				m.toast, _ = m.toast.SetWarn("No loopback mixer on this interface")
				return m, nil
			}
			m.push(scrMixer)
			m.syncPicker()
			return m, nil
		case "s":
			return m, applyCmd(m.deviceID, func(d drivers.Driver) error { return d.Save() }, "state saved")
		case "o":
			m.confirmTitle = "Reload the saved state onto the hardware?"
			m.confirm = tuikit.NewConfirm(m.confirmTitle, "Cancel", "Reload")
			m.confirmAct = func() tea.Cmd {
				return applyCmd(m.deviceID, func(d drivers.Driver) error { return d.Load() }, "saved state re-applied")
			}
			m.push(scrConfirm)
			return m, nil
		case "p":
			v := m.picker.SelectedValue()
			if strings.HasPrefix(v, "phantom:") {
				return m, m.activateControl(v)
			}
			m.toast, _ = m.toast.SetWarn("phantom only on an input row")
			return m, nil
		case "r":
			return m, fetchStatus(m.deviceID)
		case "enter":
			return m, m.activateControl(m.picker.SelectedValue())
		case "left", "right", "[", "]":
			if m.numBuf != "" {
				m.cancelNumeric()
				return m, nil
			}
			up := k == "right" || k == "]"
			return m, m.nudgeControl(m.picker.SelectedValue(), up)
		case "shift+left", "shift+right", "{", "}":
			up := k == "shift+right" || k == "}"
			return m, m.nudgeControlBig(m.picker.SelectedValue(), up)
		default:
			if m.startNumeric(k, m.picker.SelectedValue()) {
				return m, nil
			}
		}
	case scrMixer:
		switch k {
		case "esc":
			if m.numBuf != "" {
				m.cancelNumeric()
				return m, nil
			}
			m.pop()
			return m, nil
		case "tab":
			m.pop()
			return m, nil
		case "?":
			m.info = tuikit.NewInfo(helpText()).SetSize(m.contentSize())
			m.push(scrInfo)
			return m, nil
		case "s":
			return m, applyCmd(m.deviceID, func(d drivers.Driver) error { return d.Save() }, "state saved")
		case "r":
			return m, fetchStatus(m.deviceID)
		case "enter":
			return m, m.activateMixer(m.picker.SelectedValue())
		case "[", "]":
			// adjust the selected source's volume (evotui [ ] rule)
			return m, m.nudgeMixer(m.picker.SelectedValue(), map[string]string{"[": "left", "]": "right"}[k])
		case "{", "}":
			return m, m.nudgeMixer(m.picker.SelectedValue(), map[string]string{"{": ",", "}": "."}[k])
		case "left", "right", ",", ".":
			if m.numBuf != "" {
				m.cancelNumeric()
				return m, nil
			}
			return m, m.nudgeMixer(m.picker.SelectedValue(), k)
		default:
			if m.startNumeric(k, m.picker.SelectedValue()) {
				return m, nil
			}
		}
	case scrInfo:
		m.pop()
		return m, nil
	case scrSettings:
		switch k {
		case "esc":
			m.pop()
			return m, nil
		case "enter", "left", "right":
			if m.picker.SelectedValue() == "back" {
				m.pop()
				return m, nil
			}
			m.ui.ShowOnlineOnly = !m.ui.ShowOnlineOnly
			if err := saveUIPrefs(m.ui); err != nil {
				m.toast, _ = m.toast.SetErr("Could not save settings: " + err.Error())
				return m, nil
			}
			m.syncPicker()
			m.toast, _ = m.toast.SetOK("Settings saved")
			return m, nil
		}
	}
	// Default: picker navigation.
	var cmd tea.Cmd
	m.picker, cmd = m.picker.Update(msg)
	return m, cmd
}

// --- numeric entry (evotui dial buffer) ----------------------------------

func numericRowKind(val string) string {
	switch {
	case strings.HasPrefix(val, "vol:"),
		strings.HasPrefix(val, "gain:"),
		val == "monitor",
		strings.HasPrefix(val, "mix:"):
		return val
	}
	return ""
}

// startNumeric begins a dB dial entry when a digit (or -/.) is typed on an
// adjustable row. Enter (handled by the caller through finishNumeric)
// applies it; Esc cancels.
func (m *model) startNumeric(k, val string) bool {
	if len(k) != 1 {
		return false
	}
	c := k[0]
	if (c < '0' || c > '9') && c != '-' && c != '.' {
		return false
	}
	if numericRowKind(val) == "" {
		return false
	}
	if m.numRow != "" && m.numRow != val {
		m.cancelNumeric()
	}
	if m.numRow == "" {
		m.numBuf = k
		m.numRow = val
		m.numTitle = m.picker.SelectedValue()
	} else {
		m.numBuf += k
	}
	return true
}

func (m *model) cancelNumeric() {
	m.numBuf, m.numRow, m.numTitle = "", "", ""
}

func (m *model) finishNumeric() tea.Cmd {
	v, err := strconv.ParseFloat(m.numBuf, 64)
	row := m.numRow
	m.cancelNumeric()
	if err != nil {
		m.toast, _ = m.toast.SetWarn("Not a number: " + m.numBuf)
		return nil
	}
	dev := m.deviceID
	switch {
	case strings.HasPrefix(row, "vol:"):
		var pair int
		fmt.Sscanf(strings.TrimPrefix(row, "vol:"), "%d", &pair)
		return applyCmd(dev, func(d drivers.Driver) error { return d.SetVolume(pair, v) }, "")
	case strings.HasPrefix(row, "gain:"):
		t := strings.TrimPrefix(row, "gain:")
		var n int
		fmt.Sscanf(t, "input%d", &n)
		return applyCmd(dev, func(d drivers.Driver) error { return d.SetGain(n, v) }, "")
	case row == "monitor":
		return applyCmd(dev, func(d drivers.Driver) error { return d.SetMonitor(int(v)) }, "")
	case strings.HasPrefix(row, "mix:"):
		src := strings.TrimPrefix(row, "mix:")
		cell, ok := m.status.Mixer[src]
		if !ok {
			m.toast, _ = m.toast.SetWarn("Unknown mixer route " + src)
			return nil
		}
		return applyCmd(dev, func(dd drivers.Driver) error { return setMixerSource(dd, src, v, cell.Pan, m.mixBus) }, "")
	}
	return nil
}

// --- control actions ---------------------------------------------------

func (m *model) drv() (drivers.Driver, error) { return drivers.Open(m.deviceID) }

func (m *model) activateControl(val string) tea.Cmd {
	dev := m.deviceID
	// A finished dial entry applies on Enter.
	if m.numBuf != "" && val == m.numTitle {
		return m.finishNumeric()
	}
	m.cancelNumeric()
	switch {
	case val == "back":
		m.pop()
		return fetchStatus(dev)
	case val == "goto:mixer":
		m.push(scrMixer)
		m.syncPicker()
		return nil
	case val == "save":
		return applyCmd(dev, func(d drivers.Driver) error { return d.Save() }, "state saved")
	case val == "load":
		m.confirmTitle = "Reload the saved state onto the hardware?"
		m.confirm = tuikit.NewConfirm(m.confirmTitle, "Cancel", "Reload")
		m.confirmAct = func() tea.Cmd {
			return applyCmd(m.deviceID, func(d drivers.Driver) error { return d.Load() }, "saved state re-applied")
		}
		m.push(scrConfirm)
		return nil
	case strings.HasPrefix(val, "mute:"):
		t := strings.TrimPrefix(val, "mute:")
		cur := findMute(m.status, t)
		return applyCmd(dev, func(d drivers.Driver) error { return d.SetMute(t, !cur) }, muteToast(t, !cur))
	case strings.HasPrefix(val, "phantom:"):
		t := strings.TrimPrefix(val, "phantom:")
		var n int
		fmt.Sscanf(t, "input%d", &n)
		cur := findPhantom(m.status, t)
		if cur {
			return applyCmd(dev, func(d drivers.Driver) error { return d.SetPhantom(n, false) }, t+" 48V off")
		}
		m.confirm = tuikit.NewConfirm(t+": enable 48V phantom power? (only with condenser mics, monitors muted)", "Cancel", "Enable 48V")
		m.confirmAct = func() tea.Cmd {
			return applyCmd(dev, func(d drivers.Driver) error { return d.SetPhantom(n, true) }, t+" 48V on")
		}
		m.push(scrConfirm)
		return nil
	}
	return nil
}

func (m *model) nudgeControl(val string, up bool) tea.Cmd {
	return m.nudgeControlStep(val, up, 1)
}

func (m *model) nudgeControlBig(val string, up bool) tea.Cmd {
	return m.nudgeControlStep(val, up, 5)
}

func (m *model) nudgeControlStep(val string, up bool, step float64) tea.Cmd {
	dev := m.deviceID
	if !up {
		step = -step
	}
	switch {
	case strings.HasPrefix(val, "vol:"):
		var pair int
		fmt.Sscanf(strings.TrimPrefix(val, "vol:"), "%d", &pair)
		if pair < 0 || pair >= len(m.status.Outputs) {
			m.toast, _ = m.toast.SetWarn("No such output pair")
			return nil
		}
		cur := m.status.Outputs[pair].VolumeDb
		return applyCmd(dev, func(d drivers.Driver) error { return d.SetVolume(pair, cur+step) }, "")
	case strings.HasPrefix(val, "gain:"):
		t := strings.TrimPrefix(val, "gain:")
		var n int
		fmt.Sscanf(t, "input%d", &n)
		cur := findGain(m.status, t)
		return applyCmd(dev, func(d drivers.Driver) error { return d.SetGain(n, cur+step) }, "")
	case val == "monitor" && m.status.Monitor != nil:
		cur := *m.status.Monitor
		d := 1
		if !up {
			d = -1
		}
		return applyCmd(dev, func(dd drivers.Driver) error { return dd.SetMonitor(cur + d*5) }, "")
	case strings.HasPrefix(val, "mute:"):
		return m.activateControl(val)
	case strings.HasPrefix(val, "phantom:"):
		return m.activateControl(val)
	}
	return nil
}

func (m *model) nudgeMixer(val, key string) tea.Cmd {
	dev := m.deviceID
	if val == "bus" {
		n := drivers.MixBuses(m.status.Spec)
		if n < 1 {
			n = 1
		}
		if key == "left" || key == "," {
			m.mixBus = (m.mixBus - 1 + n) % n
		} else {
			m.mixBus = (m.mixBus + 1) % n
		}
		m.syncPicker()
		return nil
	}
	if !strings.HasPrefix(val, "mix:") {
		return nil
	}
	src := strings.TrimPrefix(val, "mix:")
	cell, ok := m.status.Mixer[src]
	if !ok {
		m.toast, _ = m.toast.SetWarn("Unknown mixer route " + src)
		return nil
	}
	switch key {
	case "left", "right":
		d := 1.0
		if key == "left" {
			d = -1
		}
		return applyCmd(dev, func(dd drivers.Driver) error { return setMixerSource(dd, src, cell.VolumeDb+d, cell.Pan, m.mixBus) }, "")
	case ",", ".":
		d := 5.0
		if key == "," {
			d = -5
		}
		return applyCmd(dev, func(dd drivers.Driver) error { return setMixerSource(dd, src, cell.VolumeDb, cell.Pan+d, m.mixBus) }, "")
	}
	return nil
}

// activateMixer handles Enter on the mixer page: bus row cycles the bus,
// back leaves, a finished dial entry applies.
func (m *model) activateMixer(val string) tea.Cmd {
	if m.numBuf != "" && val == m.numTitle {
		return m.finishNumeric()
	}
	m.cancelNumeric()
	switch val {
	case "bus":
		return m.nudgeMixer(val, "right")
	case "back":
		m.pop()
		return nil
	}
	return nil
}

func setMixerSource(d drivers.Driver, src string, vol, pan float64, bus int) error {
	var n int
	if _, err := fmt.Sscanf(src, "input%d", &n); err == nil {
		return d.SetMixerInput(n, vol, pan, bus)
	}
	var l, r int
	if _, err := fmt.Sscanf(src, "output%d_%d", &l, &r); err == nil && r == l+1 && l%2 == 1 {
		return d.SetMixerOutput((l-1)/2, vol, pan, pan, bus)
	}
	return fmt.Errorf("unknown mixer source %q", src)
}

func findMute(st drivers.Status, t string) bool {
	for _, o := range st.Outputs {
		if o.Name == t {
			return o.Muted
		}
	}
	for _, i := range st.Inputs {
		if i.Name == t {
			return i.Muted
		}
	}
	return false
}
func findPhantom(st drivers.Status, t string) bool {
	for _, i := range st.Inputs {
		if i.Name == t {
			return i.Phantom
		}
	}
	return false
}
func findGain(st drivers.Status, t string) float64 {
	for _, i := range st.Inputs {
		if i.Name == t {
			return i.GainDb
		}
	}
	return 0
}
func muteToast(t string, on bool) string {
	if on {
		return t + " muted"
	}
	return t + " unmuted"
}

func helpText() string {
	return "mosquitomixbay — EVO 8 first\n\n" +
		"Devices: pick your interface (EVO 8 first). [demo] = no hardware,\n" +
		"persistent simulated state for rehearsals and live-mode prep.\n\n" +
		"Controls page (INPUTS / OUTPUTS sections):\n" +
		"  j/k or ↑/↓ select · h/l switch subsections · Tab mixer · [ ] ±1dB · { } ±5dB\n" +
		"  digits type a dB value, Enter applies · Enter toggles mute (m) · P toggles 48V\n" +
		"  s save · o load · r refresh · ? help · esc back\n\n" +
		"Mixer page (loopback bus, write-only on EVO — shadowed on disk):\n" +
		"  Tab or esc controls · [ ] volume ±1dB · { } / ,/. pan ±5 · space next param\n" +
		"  first row switches the MIX bus (MIX 1|2, MIX 3|4 on EVO 8)\n\n" +
		"48V asks first (condenser mics only, monitors down).\n" +
		"Same commands exist non-interactively: mosquito-mixbay-actions --help"
}
