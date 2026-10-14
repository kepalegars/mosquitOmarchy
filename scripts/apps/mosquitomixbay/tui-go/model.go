// Interactive TUI — Bubble Tea over the shared tui-kit.
//
// Layout mirrors evotui (vanZaho): a Controls page (volumes, gains, mutes,
// phantom, monitor) and a Loopback Mixer page (sources → mix bus), fronted
// by a device picker. Differences from evotui: tui-kit components (Picker,
// Confirm, Info, Toast, CursorMemory, live Omarchy theme), immediate-apply
// Left/Right (no curses sliders), and every device in drivers.Registry()
// instead of EVO-only.
package main

import (
	"fmt"
	"strconv"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	tuikit "mosquitomarchy.local/tui-kit"
	"mosquitomarchy.local/mosquitomixbay-tui/drivers"
)

type screen int

const (
	scrDevices screen = iota
	scrControls
	scrMixer
	scrInfo
	scrConfirm
)

type model struct {
	w, h int
	nav  []screen

	deviceID string
	status   drivers.Status
	loading  bool

	picker  tuikit.Picker
	confirm tuikit.Confirm
	info    tuikit.Info
	toast   tuikit.Toast
	cursor  *tuikit.CursorMemory

	// confirm carries one pending destructive/simple action.
	confirmTitle string
	confirmAct   func() tea.Cmd

	quit bool
}

func initialModel() model {
	m := model{nav: []screen{scrDevices}, deviceID: defaultDevice()}
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

// --- picker builders ---------------------------------------------------

func (m *model) syncPicker() {
	cw, ch := m.contentSize()
	switch m.top() {
	case scrDevices:
		m.picker = tuikit.NewPicker("mosquitomixbay — interfaces", deviceItems()).SetSize(cw, ch)
	case scrControls:
		m.picker = tuikit.NewPicker(m.status.Spec.Display+" — controls  (←/→ adjust · enter toggle · m mixer · ? help)", controlItems(m.status)).SetSize(cw, ch)
	case scrMixer:
		m.picker = tuikit.NewPicker(m.status.Spec.Display+" — loopback mixer  (←/→ vol · ,/. pan · ? help)", mixerItems(m.status)).SetSize(cw, ch)
	}
}

func deviceItems() []tuikit.PickerItem {
	var items []tuikit.PickerItem
	for _, spec := range drivers.Registry() {
		badge := "demo"
		if d, err := drivers.Open(spec.ID); err == nil && d.Probe() {
			badge = "● online"
		}
		items = append(items, tuikit.PickerItem{
			Display: fmt.Sprintf("%-26s [%s]", spec.Display, badge),
			Value:   spec.ID,
		})
	}
	items = append(items, tuikit.PickerItem{Display: "Close", Value: "quit"})
	return items
}

func dbFmt(v float64) string {
	if v <= -127.5 {
		return "-inf"
	}
	return fmt.Sprintf("%+.1fdB", v)
}

func controlItems(st drivers.Status) []tuikit.PickerItem {
	var items []tuikit.PickerItem
	for i, o := range st.Outputs {
		items = append(items, tuikit.PickerItem{
			Display: fmt.Sprintf("%-12s %s", o.Name, dbFmt(o.VolumeDb)),
			Value:   fmt.Sprintf("vol:%d", i),
		})
		mute := "off"
		if o.Muted {
			mute = "ON"
		}
		items = append(items, tuikit.PickerItem{
			Display: fmt.Sprintf("%-12s mute %s", o.Name, mute),
			Value:   fmt.Sprintf("mute:%s", o.Name),
		})
	}
	for _, in := range st.Inputs {
		items = append(items, tuikit.PickerItem{
			Display: fmt.Sprintf("%-12s gain %s", in.Name, dbFmt(in.GainDb)),
			Value:   fmt.Sprintf("gain:%s", in.Name),
		})
		mute := "off"
		if in.Muted {
			mute = "ON"
		}
		items = append(items, tuikit.PickerItem{
			Display: fmt.Sprintf("%-12s mute %s", in.Name, mute),
			Value:   fmt.Sprintf("mute:%s", in.Name),
		})
		ph := "off"
		if in.Phantom {
			ph = "ON"
		}
		items = append(items, tuikit.PickerItem{
			Display: fmt.Sprintf("%-12s 48V %s", in.Name, ph),
			Value:   fmt.Sprintf("phantom:%s", in.Name),
		})
	}
	if st.Monitor != nil {
		items = append(items, tuikit.PickerItem{
			Display: fmt.Sprintf("%-12s %d%% (0=in · 100=playback)", "monitor", *st.Monitor),
			Value:   "monitor",
		})
	}
	items = append(items,
		tuikit.PickerItem{Display: "Loopback mixer →", Value: "goto:mixer"},
		tuikit.PickerItem{Display: "Save state", Value: "save"},
		tuikit.PickerItem{Display: "Reload saved state", Value: "load"},
		tuikit.PickerItem{Display: "Back to devices", Value: "back"},
	)
	return items
}

func mixerItems(st drivers.Status) []tuikit.PickerItem {
	var items []tuikit.PickerItem
	ordered := mixerKeys(st)
	for _, k := range ordered {
		c := st.Mixer[k]
		items = append(items, tuikit.PickerItem{
			Display: fmt.Sprintf("%-12s vol %s  pan %+.0f", k, dbFmt(c.VolumeDb), c.Pan),
			Value:   "mix:" + k,
		})
	}
	items = append(items,
		tuikit.PickerItem{Display: "← Back to controls", Value: "back"},
	)
	return items
}

func mixerKeys(st drivers.Status) []string {
	var ins, outs []string
	for k := range st.Mixer {
		if strings.HasPrefix(k, "input") {
			ins = append(ins, k)
		} else {
			outs = append(outs, k)
		}
	}
	// Stable order without importing sort in two places — insertion-style.
	sortStrings(ins)
	sortStrings(outs)
	return append(ins, outs...)
}

func sortStrings(s []string) {
	for i := 1; i < len(s); i++ {
		for j := i; j > 0 && s[j] < s[j-1]; j-- {
			s[j], s[j-1] = s[j-1], s[j]
		}
	}
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

	case statusMsg:
		m.loading = false
		if msg.err != nil {
			m.toast, _ = m.toast.SetErr(msg.err.Error())
			return m, nil
		}
		m.status = msg.status
		idx := m.picker.Index()
		m.syncPicker()
		if idx < 0 {
			idx = 0
		}
		m.picker = m.picker.SelectIndex(idx)
		return m, nil

	case applyMsg:
		if msg.err != nil {
			m.toast, _ = m.toast.SetErr(msg.err.Error())
			return m, nil
		}
		if msg.what != "" {
			m.toast, _ = m.toast.SetOK(msg.what)
		}
		return m, fetchStatus(m.deviceID)

	case tea.KeyMsg:
		return m.updateKey(msg)
	}

	// Picker navigation (up/down) on list screens.
	if m.top() == scrDevices || m.top() == scrControls || m.top() == scrMixer {
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
	// shortcut sees them. Without this, the quit confirmation rendered but
	// stayed inert.
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
			m.deviceID = m.picker.SelectedValue()
			m.loading = true
			m.push(scrControls)
			m.syncPicker()
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
			m.pop()
			return m, fetchStatus(m.deviceID)
		case "?":
			m.info = tuikit.NewInfo(helpText()).SetSize(m.contentSize())
			m.push(scrInfo)
			return m, nil
		case "m":
			m.push(scrMixer)
			m.syncPicker()
			return m, nil
		case "s":
			return m, applyCmd(m.deviceID, func(d drivers.Driver) error { return d.Save() }, "state saved")
		case "r":
			return m, fetchStatus(m.deviceID)
		case "enter":
			return m, m.activateControl(m.picker.SelectedValue())
		case "left", "right":
			return m, m.nudgeControl(m.picker.SelectedValue(), k == "right")
		case "shift+left", "shift+right":
			return m, m.nudgeControlBig(m.picker.SelectedValue(), k == "shift+right")
		}
	case scrMixer:
		switch k {
		case "esc":
			m.pop()
			return m, nil
		case "?":
			m.info = tuikit.NewInfo(helpText()).SetSize(m.contentSize())
			m.push(scrInfo)
			return m, nil
		case "r":
			return m, fetchStatus(m.deviceID)
		case "left", "right", ",", ".":
			return m, m.nudgeMixer(m.picker.SelectedValue(), k)
		}
	case scrInfo:
		m.pop()
		return m, nil
	}
	// Default: picker navigation.
	var cmd tea.Cmd
	m.picker, cmd = m.picker.Update(msg)
	return m, cmd
}

// --- control actions ---------------------------------------------------

func (m *model) drv() (drivers.Driver, error) { return drivers.Open(m.deviceID) }

func (m *model) activateControl(val string) tea.Cmd {
	dev := m.deviceID
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
			return applyCmd(dev, func(d drivers.Driver) error { return d.Load() }, "saved state re-applied")
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
	if !strings.HasPrefix(val, "mix:") {
		return nil
	}
	src := strings.TrimPrefix(val, "mix:")
	cell, ok := m.status.Mixer[src]
	if !ok {
		return nil
	}
	switch key {
	case "left", "right":
		d := 1.0
		if key == "left" {
			d = -1
		}
		return applyCmd(dev, func(dd drivers.Driver) error { return setMixerSource(dd, src, cell.VolumeDb+d, cell.Pan) }, "")
	case ",", ".":
		d := 5.0
		if key == "," {
			d = -5
		}
		return applyCmd(dev, func(dd drivers.Driver) error { return setMixerSource(dd, src, cell.VolumeDb, cell.Pan+d) }, "")
	}
	return nil
}

func setMixerSource(d drivers.Driver, src string, vol, pan float64) error {
	var n int
	if _, err := fmt.Sscanf(src, "input%d", &n); err == nil {
		return d.SetMixerInput(n, vol, pan, 0)
	}
	var l, r int
	if _, err := fmt.Sscanf(src, "output%d_%d", &l, &r); err == nil {
		return d.SetMixerOutput((l-1)/2, vol, -100, 100, 0)
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
	return "mosquitomixbay\n\n" +
		"Devices: pick your interface (EVO 8 first). [demo] = no hardware,\n" +
		"persistent simulated state for rehearsals and live-mode prep.\n\n" +
		"Controls page:\n" +
		"  ↑/↓ select · ←/→ ±1dB (Shift = ±5dB) · Enter toggles mute/48V\n" +
		"  m loopback mixer · s save · r refresh · esc back · ctrl+c quit\n\n" +
		"Mixer page (loopback bus, write-only on EVO — shadowed on disk):\n" +
		"  ←/→ source volume ±1dB · ,/. pan ±5\n\n" +
		"48V asks first (condenser mics only, monitors down).\n" +
		"Same commands exist non-interactively: mosquito-mixbay-actions --help"
}
