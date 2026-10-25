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
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"mosquitomarchy.local/mosquitomixbay-tui/drivers"
	"mosquitomarchy.local/mosquitomixbay-tui/meters"
	"mosquitomarchy.local/mosquitomixbay-tui/patchbay"
	tuikit "mosquitomarchy.local/tui-kit"
)

type screen int

const (
	scrDevices screen = iota
	scrControls
	scrMixer
	scrSettings
	scrPatchbay
	scrInput
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

	// text is the small modal name prompt (patchbay save). textAct runs with
	// the submitted value after the prompt closes.
	text    tuikit.TextInput
	textAct func(string) tea.Cmd

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

	// patchbay is loaded on demand only: no polling, no auto-apply.
	patchbay patchbayView

	// meter captures the EVO USB streams while an EVO panel is visible, even
	// when the terminal loses focus. Freezing is a pure UI decision.
	meter         *meters.Engine
	meterStarting bool
	meterSnap     meters.Snapshot
	meterPeakIn   [6]float64
	meterPeakOut  [6]float64
	meterFrozen   bool

	// focused is the terminal's focus state (DECSET 1004 via WithReportFocus).
	// Terminals that do not report focus keep the initial true: polling then
	// simply never pauses, which is the safe fallback.
	focused bool
	// session owns live/online/freeze/staleness for the current device.
	session liveSession
	// pollGen kills stale tick chains when focus changes.
	pollGen int

	quit bool
}

func initialModel() model {
	m := model{nav: []screen{scrDevices}, deviceID: defaultDevice(), ui: loadUIPrefs(), focused: true}
	m.picker = tuikit.NewPicker("", nil)
	m.cursor = tuikit.NewCursorMemory()
	return m
}

func (m model) Init() tea.Cmd {
	return tea.Batch(fetchStatus(m.deviceID), tuikit.ThemeWatchCmd(), evoDotBlinkTick(), evoPollTick(m.pollGen))
}
func (m model) top() screen { return m.nav[len(m.nav)-1] }

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
// ~/.config/mosquitomixbay/ui.json.
type uiPrefs struct {
	ShowOnlineOnly bool `json:"show_online_only"`
	// ArtistMixOff keeps OUT 1|2 and OUT 3|4 unified (one mirrored mix).
	ArtistMixOff bool `json:"artist_mix_off"`
	// AllowNativeVolume lets the Omarchy audio panel and the media keys touch
	// the EVO's USB hardware volume. Default false: Mixbay owns those values.
	AllowNativeVolume bool `json:"allow_native_volume"`
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
	// dev is the device the reply was requested for. A slow reply from the
	// device we just left must not overwrite the new device's status (that
	// mismatch is what crashed the EVO mixer).
	dev    string
	status drivers.Status
	err    error
	// quiet marks a background poll: its errors must not raise toasts.
	quiet bool
	// gen is session.dataGen at request time; a reply older than the latest
	// write is dropped instead of flashing a stale value.
	gen int
	// demo marks the explicit DEMO fallback of Status(). It can seed a demo
	// session but must never demote a live one.
	demo bool
}

func fetchStatus(dev string) tea.Cmd {
	return func() tea.Msg {
		d, err := drivers.Open(dev)
		if err != nil {
			return statusMsg{dev: dev, err: err}
		}
		st, err := d.Status()
		return statusMsg{dev: dev, status: st, err: err, demo: st.Backend == drivers.BackendDemo}
	}
}

// evoPollEvery is the hardware read cadence while the EVO screen is focused.
// One Status() is ~14 GET_CUR on the EVO protocol: negligible at 2 Hz, and
// immediate enough that a physical knob/button shows up before the eye moves.
const evoPollEvery = 500 * time.Millisecond

type evoPollMsg struct{ gen int }

func evoPollTick(gen int) tea.Cmd {
	return tea.Tick(evoPollEvery, func(time.Time) tea.Msg { return evoPollMsg{gen: gen} })
}

func pollStatus(dev string, gen int) tea.Cmd {
	return func() tea.Msg {
		d, err := drivers.Open(dev)
		if err != nil {
			return statusMsg{dev: dev, err: err, quiet: true, gen: gen}
		}
		if lr, ok := d.(drivers.LiveReader); ok {
			st, err := lr.Read()
			return statusMsg{dev: dev, status: st, err: err, quiet: true, gen: gen}
		}
		// Non-EVO drivers have no live seam yet; they are not polled today.
		st, err := d.Status()
		return statusMsg{dev: dev, status: st, err: err, quiet: true, gen: gen, demo: st.Backend == drivers.BackendDemo}
	}
}

// shouldPoll reads the hardware only when its values are on screen and the app
// owns the keyboard. Non-EVO backends are left alone: their Status() shells
// out to amixer and is too heavy for a 2 Hz poll.
func (m model) shouldPoll() bool {
	return m.focused && m.isEvoDevice() && m.evo.mode == 0 &&
		(m.top() == scrControls || m.top() == scrMixer)
}

type applyMsg struct {
	what string
	err  error
}

func applyCmdMode(dev string, liveOnly bool, fn func(drivers.Driver) error, what string) tea.Cmd {
	return func() tea.Msg {
		open := drivers.Open
		if liveOnly {
			open = drivers.OpenLive
		}
		d, err := open(dev)
		if err != nil {
			return applyMsg{err: err}
		}
		if err := fn(d); err != nil {
			return applyMsg{err: err}
		}
		return applyMsg{what: what}
	}
}

// applyCmd writes through the live/write policy of the current session: once
// hardware has answered, a vanished interface must fail instead of silently
// updating the DEMO state.
func (m model) applyCmd(dev string, fn func(drivers.Driver) error, what string) tea.Cmd {
	return applyCmdMode(dev, m.session.live, fn, what)
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
	case scrPatchbay:
		m.picker = tuikit.NewPicker("PipeWire patchbay", m.patchbayItems()).SetSize(cw, ch)
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
	pb := tuikit.PickerItem{Display: "PipeWire patchbay…", Value: "patchbay"}
	if !patchbay.Available() {
		pb.Disabled = true
		pb.Suffix = "  (needs pw-dump and pw-link)"
	}
	items = append(items,
		tuikit.PickerItem{Display: "Settings", Value: "settings"},
		pb,
		tuikit.PickerItem{Display: "Close", Value: "quit"},
	)
	return items
}

var levelsGuardEnabled = queryLevelsGuardEnabled

func queryLevelsGuardEnabled() bool {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "omarchy-plugin-list", "--json").Output()
	if err != nil {
		return false
	}
	var plugins []struct {
		ID      string `json:"id"`
		Enabled bool   `json:"enabled"`
	}
	if json.Unmarshal(out, &plugins) != nil {
		return false
	}
	for _, p := range plugins {
		if p.ID == "mosquito.levels-guard" && p.Enabled {
			return true
		}
	}
	return false
}

func (m model) settingsItems() []tuikit.PickerItem {
	native := tuikit.PickerItem{
		Display: "Allow native volume controls: " + onOff(m.ui.AllowNativeVolume),
		Value:   "allow_native",
	}
	if !levelsGuardEnabled() {
		native.Disabled = true
		native.Suffix = "  (needs mosquito.levels-guard)"
	}
	return []tuikit.PickerItem{
		{Display: "Show only connected interfaces: " + onOff(m.ui.ShowOnlineOnly), Value: "online_only"},
		native,
		{Display: "Back", Value: "back"},
	}
}

func onOff(b bool) string {
	if b {
		return "on"
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
	if meterCmd := m.syncMeters(); meterCmd != nil {
		cmd = tea.Batch(cmd, meterCmd)
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

	case evoDotBlinkMsg:
		m.evo.dotLit = !m.evo.dotLit
		m.evo.caretOn = !m.evo.caretOn
		return m, evoDotBlinkTick()

	case evoAnimTickMsg:
		if msg.gen != m.evo.animGen {
			return m, nil
		}
		if m.evo.tickAnims(time.Now()) {
			return m, evoAnimTick(msg.gen)
		}
		return m, nil

	case tea.FocusMsg:
		m.focused = true
		m.pollGen++
		cmds := []tea.Cmd{evoPollTick(m.pollGen)}
		if m.shouldPoll() {
			cmds = append(cmds, pollStatus(m.deviceID, m.session.beginRead()))
		}
		return m, tea.Batch(cmds...)

	case tea.BlurMsg:
		// No hardware reads while another window owns the keyboard.
		m.focused = false
		m.pollGen++
		return m, nil

	case evoPollMsg:
		if msg.gen != m.pollGen {
			return m, nil
		}
		cmds := []tea.Cmd{evoPollTick(m.pollGen)}
		if m.shouldPoll() {
			cmds = append(cmds, pollStatus(m.deviceID, m.session.beginRead()))
		}
		return m, tea.Batch(cmds...)

	case statusMsg:
		// Drop a reply for a device we have already navigated away from.
		if msg.dev != "" && msg.dev != m.deviceID {
			return m, nil
		}
		if !msg.quiet {
			m.loading = false
		}
		// Quiet errors (offline polls) go through the session: it decides
		// whether to freeze. User-visible errors keep the toast.
		if msg.err != nil && !msg.quiet {
			m.toast, _ = m.toast.SetErr(msg.err.Error())
			return m, nil
		}
		st, ok := m.session.apply(msg)
		if !ok {
			return m, nil
		}
		oldStatus := m.status
		m.status = st
		// (Re)bind the EVO renderer to THIS status's spec. Selecting a new
		// device leaves evo.spec empty until its real status arrives, so the
		// mixer can never iterate an old spec's section list over a new
		// device's layout.
		if m.isEvoDevice() {
			switch {
			case m.evo.spec.ID == "":
				m.evoEnter()
				// A fast Tab while the status was loading can already have
				// pushed the mixer; keep the screen and the nav stack in step.
				if m.top() == scrMixer {
					m.evo.window = evoWinMixer
				}
			case m.evo.spec.ID != msg.status.Spec.ID:
				m.evoRebindSpec()
			}
		}
		if msg.quiet {
			// Polls must not rebuild the picker 2x/s; only user-visible
			// refreshes resync it. Hardware changes get a short ramp instead
			// of a 500 ms jump.
			if m.startEvoRamps(oldStatus, st) {
				return m, evoAnimTick(m.evo.animGen)
			}
			return m, nil
		}
		// A user-visible refresh follows a local write or a re-selection:
		// show the hardware value immediately, no ramp.
		m.evo.clearAnims()
		idx := m.picker.Index()
		m.syncPicker()
		if idx < 0 {
			idx = 0
		}
		m.picker = m.picker.SelectIndex(idx)
		return m, nil

	case meterStartedMsg:
		if !m.wantsMeters() {
			msg.engine.Stop()
			m.meterStarting = false
			return m, nil
		}
		m.meter = msg.engine
		m.meterStarting = false
		m.meterPeakIn, m.meterPeakOut = [6]float64{}, [6]float64{}
		return m, waitMetersCmd(msg.engine)

	case meterSnapshotMsg:
		if m.meter == nil || m.meter != msg.engine {
			return m, nil
		}
		if m.meterFrozen {
			return m, waitMetersCmd(m.meter)
		}
		m.meterSnap = msg.snap
		copy(m.meterPeakIn[:], msg.snap.Peaks[meters.KeyInput])
		copy(m.meterPeakOut[:], msg.snap.Peaks[meters.KeyPlayback])
		return m, waitMetersCmd(m.meter)

	case meterClosedMsg:
		if m.meter == msg.engine {
			m.meter = nil
		}
		return m, nil

	case applyMsg:
		// Any completed write invalidates polls that started before it.
		m.session.wrote()
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

	case patchbayLoadedMsg:
		m.patchbay.loading = false
		m.patchbay.err, m.patchbay.states = "", msg.states
		if msg.err != nil {
			m.patchbay.err = msg.err.Error()
		}
		if m.top() == scrPatchbay {
			m.syncPicker()
		}
		return m, nil

	case patchbaySavedMsg:
		m.patchbay.loading = false
		if msg.err != nil {
			m.toast, _ = m.toast.SetErr(msg.err.Error())
			return m, nil
		}
		m.toast, _ = m.toast.SetOK("saved patchbay preset " + msg.name)
		m.patchbay.loading = true
		return m, loadPatchbayCmd()

	case patchbayAppliedMsg:
		m.patchbay.loading = false
		if msg.err != nil {
			m.toast, _ = m.toast.SetErr(msg.err.Error())
		} else if len(msg.res.Missing) > 0 {
			m.toast, _ = m.toast.SetWarn(fmt.Sprintf("%s: %d added, %d skipped", msg.name, msg.res.Added, len(msg.res.Missing)))
		} else {
			m.toast, _ = m.toast.SetOK(fmt.Sprintf("%s: %d added, %d already present", msg.name, msg.res.Added, msg.res.Present))
		}
		m.patchbay.loading = true
		return m, loadPatchbayCmd()

	case evoPresetDeletedMsg:
		u := &m.evo
		if msg.err != nil {
			return m, u.evoStatus("delete failed: "+msg.err.Error(), true)
		}
		u.fileList = m.evoScanFiles()
		if u.fileCursor >= len(u.fileList) {
			u.fileCursor = len(u.fileList) - 1
		}
		if u.fileCursor < 0 {
			u.fileCursor = 0
		}
		maxScroll := len(u.fileList) - evoPickerListH
		if maxScroll < 0 {
			maxScroll = 0
		}
		if u.fileScroll > maxScroll {
			u.fileScroll = maxScroll
		}
		if u.fileCursor < len(u.fileList) {
			u.fileInput = strings.TrimSuffix(u.fileList[u.fileCursor], ".json")
		} else {
			u.fileInput = ""
		}
		return m, u.evoStatus("deleted "+msg.name, false)

	case tea.KeyMsg:
		return m.updateKey(msg)
	}

	if m.top() == scrInput {
		if res, ok := msg.(tuikit.InputResultMsg); ok {
			act := m.textAct
			m.textAct = nil
			m.pop()
			if res.Canceled || act == nil {
				return m, nil
			}
			return m, act(res.Value)
		}
		var cmd tea.Cmd
		m.text, cmd = m.text.Update(msg)
		return m, cmd
	}

	// Picker navigation (up/down) on list screens.
	if m.top() == scrDevices || m.top() == scrControls || m.top() == scrMixer || m.top() == scrSettings || m.top() == scrPatchbay {
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
	if m.top() == scrInput {
		var cmd tea.Cmd
		m.text, cmd = m.text.Update(msg)
		return m, cmd
	}
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
	if m.top() == scrPatchbay {
		return m.patchbayKey(msg)
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
			if m.picker.SelectedValue() == "patchbay" {
				if !patchbay.Available() {
					m.toast, _ = m.toast.SetWarn("Patchbay needs pw-dump and pw-link")
					return m, nil
				}
				m.patchbay.loading, m.patchbay.err = true, ""
				m.push(scrPatchbay)
				m.syncPicker()
				return m, loadPatchbayCmd()
			}
			m.deviceID = m.picker.SelectedValue()
			m.loading = true
			// A deliberate (re)selection starts a fresh session: a device can
			// be picked in DEMO mode even if it was online earlier.
			m.session.selectDevice()
			// Unbind the previous device's spec: evoEnter() here would copy
			// the STALE status.Spec (the interface we just left) into the
			// renderer. The fresh statusMsg binds the real spec instead.
			m.evo.spec = drivers.Spec{}
			m.evo.window = evoWinControls
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
			return m, m.applyCmd(m.deviceID, func(d drivers.Driver) error { return d.Save() }, "state saved")
		case "o":
			m.confirmTitle = "Reload the saved state onto the hardware?"
			m.confirm = tuikit.NewConfirm(m.confirmTitle, "Cancel", "Reload")
			m.confirmAct = func() tea.Cmd {
				return m.applyCmd(m.deviceID, func(d drivers.Driver) error { return d.Load() }, "saved state re-applied")
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
			return m, m.applyCmd(m.deviceID, func(d drivers.Driver) error { return d.Save() }, "state saved")
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
			switch m.picker.SelectedValue() {
			case "back":
				m.pop()
				return m, nil
			case "allow_native":
				if !levelsGuardEnabled() {
					m.toast, _ = m.toast.SetWarn("Install Levels Guard to use native volume controls")
					return m, nil
				}
				m.ui.AllowNativeVolume = !m.ui.AllowNativeVolume
			default:
				m.ui.ShowOnlineOnly = !m.ui.ShowOnlineOnly
			}
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
		return m.applyCmd(dev, func(d drivers.Driver) error { return d.SetVolume(pair, v) }, "")
	case strings.HasPrefix(row, "gain:"):
		t := strings.TrimPrefix(row, "gain:")
		var n int
		fmt.Sscanf(t, "input%d", &n)
		return m.applyCmd(dev, func(d drivers.Driver) error { return d.SetGain(n, v) }, "")
	case row == "monitor":
		return m.applyCmd(dev, func(d drivers.Driver) error { return d.SetMonitor(int(v)) }, "")
	case strings.HasPrefix(row, "mix:"):
		src := strings.TrimPrefix(row, "mix:")
		cell, ok := m.status.Mixer[src]
		if !ok {
			m.toast, _ = m.toast.SetWarn("Unknown mixer route " + src)
			return nil
		}
		return m.applyCmd(dev, func(dd drivers.Driver) error { return setMixerSource(dd, src, v, cell.Pan, m.mixBus) }, "")
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
		return m.applyCmd(dev, func(d drivers.Driver) error { return d.Save() }, "state saved")
	case val == "load":
		m.confirmTitle = "Reload the saved state onto the hardware?"
		m.confirm = tuikit.NewConfirm(m.confirmTitle, "Cancel", "Reload")
		m.confirmAct = func() tea.Cmd {
			return m.applyCmd(m.deviceID, func(d drivers.Driver) error { return d.Load() }, "saved state re-applied")
		}
		m.push(scrConfirm)
		return nil
	case strings.HasPrefix(val, "mute:"):
		t := strings.TrimPrefix(val, "mute:")
		cur := findMute(m.status, t)
		return m.applyCmd(dev, func(d drivers.Driver) error { return d.SetMute(t, !cur) }, muteToast(t, !cur))
	case strings.HasPrefix(val, "phantom:"):
		t := strings.TrimPrefix(val, "phantom:")
		var n int
		fmt.Sscanf(t, "input%d", &n)
		cur := findPhantom(m.status, t)
		if cur {
			return m.applyCmd(dev, func(d drivers.Driver) error { return d.SetPhantom(n, false) }, t+" 48V off")
		}
		m.confirm = tuikit.NewConfirm(t+": enable 48V phantom power? (only with condenser mics, monitors muted)", "Cancel", "Enable 48V")
		m.confirmAct = func() tea.Cmd {
			return m.applyCmd(dev, func(d drivers.Driver) error { return d.SetPhantom(n, true) }, t+" 48V on")
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
		return m.applyCmd(dev, func(d drivers.Driver) error { return d.SetVolume(pair, cur+step) }, "")
	case strings.HasPrefix(val, "gain:"):
		t := strings.TrimPrefix(val, "gain:")
		var n int
		fmt.Sscanf(t, "input%d", &n)
		cur := findGain(m.status, t)
		return m.applyCmd(dev, func(d drivers.Driver) error { return d.SetGain(n, cur+step) }, "")
	case val == "monitor" && m.status.Monitor != nil:
		cur := *m.status.Monitor
		d := 1
		if !up {
			d = -1
		}
		return m.applyCmd(dev, func(dd drivers.Driver) error { return dd.SetMonitor(cur + d*5) }, "")
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
		return m.applyCmd(dev, func(dd drivers.Driver) error { return setMixerSource(dd, src, cell.VolumeDb+d, cell.Pan, m.mixBus) }, "")
	case ",", ".":
		d := 5.0
		if key == "," {
			d = -5
		}
		return m.applyCmd(dev, func(dd drivers.Driver) error { return setMixerSource(dd, src, cell.VolumeDb, cell.Pan+d, m.mixBus) }, "")
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
		"EVO movement vs adjustment (CONTROLS and MIXER):\n" +
		"  plain arrows or h/j/k/l move the cursor — h/l column/source, j/k row\n" +
		"  Ctrl+←/→ (or Ctrl+h/l): volume/gain/monitor ±5, pan ±25\n" +
		"  Ctrl+Shift+←/→: volume/gain/monitor ±1, pan ±5\n" +
		"  digits type a value, Enter applies · Space cycles pan/volume\n" +
		"  Tab switches CONTROLS/MIXER · m mute or mix · P 48V\n" +
		"  r reset · R reset all · s save · o load · esc back\n\n" +
		"Mixer page (loopback bus, write-only on EVO — shadowed on disk):\n" +
		"  the same movement/adjustment rules apply; the first row switches the\n" +
		"MIX bus (MIX 1|2, MIX 3|4 on EVO 8). Values refresh from the hardware\n" +
		"every 0.5 s while the window is focused.\n\n" +
		"48V asks first (condenser mics only, monitors down).\n" +
		"Same commands exist non-interactively: mosquito-mixbay-actions --help"
}
