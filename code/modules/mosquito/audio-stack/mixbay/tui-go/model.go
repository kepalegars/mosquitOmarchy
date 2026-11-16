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

	"github.com/charmbracelet/bubbles/key"
	tea "github.com/charmbracelet/bubbletea"
	"mosquitomarchy.local/mosquitomixbay-tui/drivers"
	"mosquitomarchy.local/mosquitomixbay-tui/meters"
	"mosquitomarchy.local/mosquitomixbay-tui/patchbay"
	"mosquitomarchy.local/mosquitomixbay-tui/profiles"
	tuikit "mosquitomarchy.local/tui-kit"
)

type screen int

const (
	scrDevices screen = iota
	scrControls
	scrMixer
	scrSettings
	scrPatchbay
	scrFoundation
	scrFoundationDefault
	scrAddInterface
	scrLibrary
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
	// confirmLog is set when the confirm's Yes button opens a setup transcript
	// instead of running confirmAct.
	confirmLog string

	// evo is the faithful evotui-style state for the EVO 4 / EVO 8 screens.
	evo evoUI

	// patchbay is loaded on demand only: no polling, no auto-apply.
	patchbay patchbayView

	// foundation is the Settings → Audio foundation card list/default.
	foundation        foundationState
	foundationLoading bool

	// add-interface scan (Settings → Add an audio interface).
	scanCards   []scanCard
	scanLoading bool

	// hotplug is the "a supported card was just connected" path: a PipeWire
	// event, not a timer. key is the last connected set and offered keeps one
	// prompt per profile per session. pending defers the check while a dialog
	// owns the keyboard; pendingInstallID comes from a notification click.
	hotplugKey       string
	hotplugPending   bool
	pendingInstallID string
	offeredProfiles  map[string]bool

	// library is Settings → Audio interface profiles. The index is cached in
	// memory for the session; upstream/ is the only folder an import writes.
	libraryIndex    profiles.Index
	libraryUpstream map[string]profiles.Card
	libraryLoading  bool
	libraryErr      string
	libraryChecked  map[string]bool
	libraryManual   bool
	libraryTab      int
	// libraryFilter is the F search zone shared by both tabs: the text is
	// kept when switching tabs, and cleared when the zone closes.
	libraryFilterOpen bool
	libraryFilterText string
	dupPrompted       map[string]bool
	// profileChecking drives the blinking square on Settings → Audio interface
	// profiles; profileBlink is its on/off frame (see evoDotBlinkMsg).
	// profileChecked is "the repo was already checked this session": entering
	// Settings checks once, r refreshes on demand.
	profileChecking bool
	profileChecked  bool
	profileBlink    int

	// preset is the card's UI composition ("evo8", "ugm192", "auto"…). It
	// routes the renderer and can be overridden per card by user/layout.json.
	preset string

	// meter captures the EVO USB streams while an EVO panel is visible, even
	// when the terminal loses focus. Freezing is a pure UI decision.
	meter         *meters.Engine
	meterStarting bool
	meterSnap     meters.Snapshot
	meterPeakIn   [evoMaxMeterChannels]float64
	meterPeakOut  [evoMaxMeterChannels]float64
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
	m.libraryChecked = map[string]bool{}
	m.dupPrompted = map[string]bool{}
	m.offeredProfiles = map[string]bool{}
	m.bindPreset()
	return m
}

func (m model) Init() tea.Cmd {
	cmds := []tea.Cmd{
		fetchStatus(m.deviceID), tuikit.ThemeWatchCmd(), evoDotBlinkTick(),
		evoPollTick(m.pollGen), trackConnectionsCmd(), cardEventCmd(), installSignalCmd(),
	}
	// A notification clicked while Mixbay was closed left its request here.
	if id := takePendingInstall(); id != "" {
		cmds = append(cmds, func() tea.Msg { return installRequestMsg{id: id} })
	}
	return tea.Batch(cmds...)
}

// trackConnectionsCmd writes every currently connected USB interface to the
// connection log before the "Only used" list reads it. Without it the list
// only knew about cards seen by the beta scan, so a card used since the last
// scan never appeared.
type connectionsTrackedMsg struct{}

func trackConnectionsCmd() tea.Cmd {
	return func() tea.Msg {
		_ = exec.Command("mixbay-audio-foundation", "--track").Run()
		return connectionsTrackedMsg{}
	}
}
func (m model) top() screen { return m.nav[len(m.nav)-1] }

// modalOpen reports a dialog that owns the keyboard. The hotplug watcher waits
// for it to close instead of stacking a prompt on top.
func (m model) modalOpen() bool {
	switch m.top() {
	case scrConfirm, scrInfo, scrInput:
		return true
	}
	return false
}

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
	// ShowOnlineOnly is the old boolean; kept only to migrate an existing
	// ui.json into Listed. New code writes Listed.
	ShowOnlineOnly bool `json:"show_online_only,omitempty"`
	// Listed is "only_connected", "all_supported" or "only_used".
	Listed string `json:"listed,omitempty"`
	// ArtistMixOff keeps OUT 1|2 and OUT 3|4 unified (one mirrored mix).
	ArtistMixOff bool `json:"artist_mix_off"`
	// AllowNativeVolume is the "Control active audio interface volume with
	// keyboard" row: true lets Levels Guard drive the selected interface's
	// hardware volume through Mixbay. Default false: the media keys are blocked.
	AllowNativeVolume bool `json:"allow_native_volume"`
	// LaunchAtStartup and LaunchInScratchpad default to true on a fresh
	// install (the foundation/startup helper reads the same file).
	LaunchAtStartup    bool `json:"launch_at_startup"`
	LaunchInScratchpad bool `json:"launch_in_scratchpad"`
	// HandleExternalWindows lets Mixbay park itself (and focus the mixer) when
	// it opens an external GUI. Default true.
	HandleExternalWindows bool `json:"handle_external_windows"`
	// DetectCards and NotifyCards gate the supported-card watcher. Their
	// stored value is kept while watcher_mode is off, so turning the watcher
	// back on restores the previous choices instead of resetting them.
	DetectCards bool `json:"detect_cards"`
	NotifyCards bool `json:"notify_cards"`
	// WatcherMode is "always", "only_open" or "off". "off" forces the two
	// rows above to read off (and be inert) without touching their values.
	WatcherMode string `json:"watcher_mode"`
}

const (
	listedConnected = "only_connected"
	listedAll       = "all_supported"
	listedUsed      = "only_used"

	watcherAlways = "always"
	watcherOpen   = "only_open"
	watcherOff    = "off"
)

func watcherLabel(v string) string {
	switch v {
	case watcherOpen:
		return "Only when Mixbay is open"
	case watcherOff:
		return "Off"
	default:
		return "Always on"
	}
}

func nextWatcher(v string) string {
	switch v {
	case watcherAlways:
		return watcherOpen
	case watcherOpen:
		return watcherOff
	default:
		return watcherAlways
	}
}

// watcherOff / detects / notifies are the EFFECTIVE values the UI and the
// watcher use; the stored booleans are the user's choices to restore.
func (p uiPrefs) watcherOff() bool { return p.WatcherMode == watcherOff }
func (p uiPrefs) detects() bool    { return !p.watcherOff() && p.DetectCards }
func (p uiPrefs) notifies() bool   { return p.detects() && p.NotifyCards }

func listedLabel(v string) string {
	switch v {
	case listedConnected:
		return "Only connected"
	case listedUsed:
		return "Only used"
	default:
		return "All supported"
	}
}

func nextListed(v string) string {
	switch v {
	case listedConnected:
		return listedAll
	case listedUsed:
		return listedConnected
	default:
		return listedUsed
	}
}

func uiPrefsFile() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "mosquitomixbay", "ui.json")
}

func loadUIPrefs() uiPrefs {
	p := uiPrefs{
		Listed: listedConnected, LaunchAtStartup: true, LaunchInScratchpad: true,
		HandleExternalWindows: true, DetectCards: true, NotifyCards: true,
		WatcherMode: watcherAlways,
	}
	data, err := os.ReadFile(uiPrefsFile())
	if err != nil {
		return p
	}
	var raw map[string]json.RawMessage
	_ = json.Unmarshal(data, &raw)
	_ = json.Unmarshal(data, &p)
	if p.Listed == "" {
		if v, ok := raw["show_online_only"]; ok {
			var old bool
			_ = json.Unmarshal(v, &old)
			if old {
				p.Listed = listedConnected
			}
		}
	}
	if p.Listed != listedConnected && p.Listed != listedAll && p.Listed != listedUsed {
		p.Listed = listedConnected
	}
	if _, ok := raw["launch_at_startup"]; !ok {
		p.LaunchAtStartup = true
	}
	if _, ok := raw["launch_in_scratchpad"]; !ok {
		p.LaunchInScratchpad = true
	}
	if _, ok := raw["handle_external_windows"]; !ok {
		p.HandleExternalWindows = true
	}
	if _, ok := raw["detect_cards"]; !ok {
		p.DetectCards = true
	}
	if _, ok := raw["notify_cards"]; !ok {
		p.NotifyCards = true
	}
	if p.WatcherMode != watcherAlways && p.WatcherMode != watcherOpen && p.WatcherMode != watcherOff {
		p.WatcherMode = watcherAlways
	}
	return p
}

func saveUIPrefs(p uiPrefs) error {
	p.ShowOnlineOnly = p.Listed == listedConnected
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
// owns the keyboard. Other backends are left alone: their Status() shells out
// to amixer and is too heavy for a 2 Hz poll.
func (m model) shouldPoll() bool {
	if !m.focused {
		return false
	}
	if m.isUGMDevice() {
		return m.top() == scrControls
	}
	return m.isEvoDevice() && m.evo.mode == 0 &&
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
	// A settings change (or a status poll) rebuilds the list, and a fresh
	// Picker starts on row 0. Keep the cursor where the user left it; an
	// unknown value leaves the selection alone.
	sel := m.picker.SelectedValue()
	switch m.top() {
	case scrDevices:
		m.picker = tuikit.NewPicker("mosquitomixbay — interfaces", m.deviceItems()).
			SetSize(cw, ch).
			SetHelpKeys(key.NewBinding(key.WithKeys("r"), key.WithHelp("r", "refresh")))
	case scrControls:
		m.picker = tuikit.NewPicker(m.status.Spec.Display+" — controls", controlItems(m.status)).SetSize(cw, ch)
	case scrMixer:
		m.picker = tuikit.NewPicker(m.status.Spec.Display+" — loopback mixer "+drivers.BusLabel(m.mixBus), mixerItems(m.status, m.mixBus)).SetSize(cw, ch)
	case scrSettings:
		m.picker = tuikit.NewPicker("Settings", m.settingsItems()).SetSize(cw, ch)
	case scrPatchbay:
		m.picker = tuikit.NewPicker("PipeWire patchbay", m.patchbayItems()).SetSize(cw, ch)
	case scrFoundation:
		m.picker = tuikit.NewPicker("Audio foundation settings", m.foundationItems()).SetSize(cw, ch)
	case scrFoundationDefault:
		m.picker = tuikit.NewPicker("Default audio interface", m.foundationDefaultItems()).SetSize(cw, ch)
	case scrAddInterface:
		m.picker = tuikit.NewPicker("Add an audio interface", m.addInterfaceItems()).SetSize(cw, ch)
	case scrLibrary:
		m.picker = tuikit.NewPicker("Audio interface profiles", m.libraryItems()).SetSize(cw, ch)
	}
	if sel != "" {
		m.picker = m.picker.SelectValue(sel)
	}
}

func (m model) deviceItems() []tuikit.PickerItem {
	var items []tuikit.PickerItem
	specs := drivers.Registry()
	used := map[string]bool{}
	if m.ui.Listed == listedUsed {
		used = drivers.UsedIDs()
	}
	for _, spec := range specs {
		online := false
		if d, err := drivers.Open(spec.ID); err == nil && d.Probe() {
			online = true
		}
		switch m.ui.Listed {
		case listedConnected:
			if !online {
				continue
			}
		case listedUsed:
			if !used[spec.ID] {
				continue
			}
		}
		badge := "offline"
		if spec.Beta {
			badge = "offline-beta"
		}
		if online {
			badge = "● online"
			if spec.Beta {
				badge = "● online-beta"
			}
		}
		items = append(items, tuikit.PickerItem{
			Display: fmt.Sprintf("%-26s [%s]", spec.Display, badge),
			Value:   spec.ID,
		})
	}
	// The nav rows below always exist, so an empty card list must say why
	// instead of looking like a rendering bug. Disabled: grey, skipped.
	if len(items) == 0 {
		items = append(items, tuikit.PickerItem{Display: "No interfaces connected", Disabled: true})
	}
	pb := tuikit.PickerItem{Display: "PipeWire patchbay", Value: "patchbay"}
	if !patchbay.Available() {
		pb.Disabled = true
		pb.Suffix = "  (needs pw-dump and pw-link)"
	}
	items = append(items,
		pb,
		tuikit.PickerItem{Display: "Settings", Value: "settings"},
		tuikit.PickerItem{Display: "Close", Value: "quit"},
	)
	return items
}

var levelsGuardEnabled = queryLevelsGuardEnabled

func queryLevelsGuardEnabled() bool {
	// The media-key helper is the surface this option actually controls:
	// accept a partial install (helper + Hypr block) even when the cloned
	// panel plugin is not enabled yet.
	if home, err := os.UserHomeDir(); err == nil {
		if _, err := os.Stat(filepath.Join(home, ".local", "bin", "levels-guard")); err == nil {
			return true
		}
	}
	if _, err := exec.LookPath("levels-guard"); err == nil {
		return true
	}
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
	// Without Levels Guard nothing blocks the native surfaces, so keyboard
	// control is always on and the row only explains why it cannot change.
	guard := levelsGuardEnabled()
	native := tuikit.PickerItem{
		Display: "Control active audio interface volume with keyboard: " + onOff(!guard || m.ui.AllowNativeVolume),
		Value:   "allow_native",
	}
	if !guard {
		native.Disabled = true
		native.Suffix = "  (always on without Levels Guard)"
	}
	// The square mirrors mosquitomarchy: it blinks while a repo check runs and
	// stays solid while an installed card has a newer version to download.
	profilesRow := tuikit.PickerItem{Display: "Audio interface profiles", Value: "profiles"}
	if m.profileChecking {
		profilesRow.TrailingBadge = tuikit.LoadingGlyph(m.profileBlink)
	} else if updates, installs := m.repoNews(); updates+installs > 0 {
		profilesRow.TrailingBadge = "■"
	}
	// The watcher switch owns the two rows below it: off greys them and shows
	// off, while their stored choices wait for the switch to come back.
	detect := tuikit.PickerItem{Display: "Detect plugged cards: " + onOff(m.ui.detects()), Value: "detect_cards"}
	notify := tuikit.PickerItem{Display: "Notify when a supported card is connected: " + onOff(m.ui.notifies()), Value: "notify_cards"}
	if m.ui.watcherOff() {
		detect.Disabled = true
		notify.Disabled = true
	} else if !m.ui.DetectCards {
		notify.Disabled = true
	}
	return []tuikit.PickerItem{
		profilesRow,
		{Display: "Audio foundation settings", Value: "foundation"},
		{Display: "Listed interfaces: " + listedLabel(m.ui.Listed), Value: "listed"},
		native,
		{Display: "Launch Mixbay at startup: " + onOff(m.ui.LaunchAtStartup), Value: "launch_startup"},
		{Display: "Launch Mixbay in scratchpad: " + onOff(m.ui.LaunchInScratchpad), Value: "launch_scratchpad"},
		{Display: "Let Mixbay handle external windows: " + onOff(m.ui.HandleExternalWindows), Value: "external_windows"},
		detect,
		notify,
		{Display: "Card watcher: " + watcherLabel(m.ui.WatcherMode), Value: "watcher_mode"},
		{Display: "Add an audio interface", Value: "add_interface"},
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

// hasControls reports whether a card exposes any TUI control row. A card
// with none is driven entirely from its own mixer (RME → oscmix).
func hasControls(st drivers.Status) bool {
	c := st.Spec.Caps
	return c.Gain || c.Phantom || c.Volume || c.Mute || st.Monitor != nil
}

// controlItems builds the CONTROLS page: INPUTS section (gain/mute/48V),
// OUTPUTS section (volume/mute), then the page actions. Only rows the
// device's Caps advertise are emitted.
func controlItems(st drivers.Status) []tuikit.PickerItem {
	caps := st.Spec.Caps
	var items []tuikit.PickerItem
	hasControls := hasControls(st)
	if len(st.Inputs) > 0 && (caps.Gain || caps.Phantom) {
		items = append(items, tuikit.PickerItem{Display: "Inputs", Heading: true})
		for _, in := range st.Inputs {
			if caps.Gain {
				items = append(items, tuikit.PickerItem{
					Display: fmt.Sprintf("  %-8s gain %s", strings.ToUpper(in.Name), dbFmt(in.GainDb)),
					Value:   fmt.Sprintf("gain:%s", in.Name),
				})
			}
			if caps.Mute {
				items = append(items, tuikit.PickerItem{
					Display: fmt.Sprintf("  %-8s mute %s", strings.ToUpper(in.Name), onOff(in.Muted)),
					Value:   fmt.Sprintf("mute:%s", in.Name),
				})
			}
			if caps.Phantom {
				items = append(items, tuikit.PickerItem{
					Display: fmt.Sprintf("  %-8s 48V %s", strings.ToUpper(in.Name), onOff(in.Phantom)),
					Value:   fmt.Sprintf("phantom:%s", in.Name),
				})
			}
		}
	}
	if len(st.Outputs) > 0 && (caps.Volume || caps.Mute) {
		items = append(items, tuikit.PickerItem{Display: "Outputs", Heading: true})
		for i, o := range st.Outputs {
			if caps.Volume {
				items = append(items, tuikit.PickerItem{
					Display: fmt.Sprintf("  %-8s vol %s", strings.ToUpper(o.Name), dbFmt(o.VolumeDb)),
					Value:   fmt.Sprintf("vol:%d", i),
				})
			}
			if caps.Mute {
				items = append(items, tuikit.PickerItem{
					Display: fmt.Sprintf("  %-8s mute %s", strings.ToUpper(o.Name), onOff(o.Muted)),
					Value:   fmt.Sprintf("mute:%s", o.Name),
				})
			}
		}
	}
	if st.Monitor != nil {
		items = append(items, tuikit.PickerItem{
			Display: fmt.Sprintf("  %-8s %d%% (0=in · 100=playback)", "MONITOR", *st.Monitor),
			Value:   "monitor",
		})
	}
	// A card with no TUI controls gets its actions directly: no heading, no
	// indent. The action list IS the interface (RME cards open the oscmix
	// mixer; the card itself has nothing to set here).
	indent := "  "
	if !hasControls {
		indent = ""
	} else {
		items = append(items, tuikit.PickerItem{Display: "Actions", Heading: true})
	}
	add := func(label, value string) {
		items = append(items, tuikit.PickerItem{Display: indent + label, Value: value})
	}
	if caps.Mixer {
		add("Loopback mixer →", "goto:mixer")
	}
	if st.Spec.Setup == "oscmix" {
		// Web UI first: it works with no install at all. GTK second, Qt last —
		// it is an upstream preview AppImage that only some nightly builds
		// carry, so grey the row while there is nothing to launch.
		add("Open web UI", "oscmix:web")
		add("Open GTK mixer", "oscmix:gtk")
		qt := tuikit.PickerItem{Display: indent + "Open Qt UI", Value: "oscmix:qt"}
		if !oscmixQtInstalled() {
			qt.Disabled = true
			qt.Suffix = "  (not published upstream yet)"
		}
		items = append(items, qt)
		add("Set up / repair oscmix", "oscmix:setup")
	}
	if st.Spec.Beta {
		items = append(items,
			tuikit.PickerItem{Display: "Beta", Heading: true},
			tuikit.PickerItem{Display: "  Restart reverse engineering", Value: "beta:reverse"},
		)
	}
	if st.Spec.ID == drivers.DevSSL12 {
		add("Open Omarchy360 mixer", "ssl12:omarchy360")
		add("Set up / repair SSL 12 (douze)", "ssl12:setup")
	}
	if hasControls {
		add("Save state", "save")
		add("Reload saved state", "load")
	}
	add("Back to devices", "back")
	return items
}

// mixerItems builds the loopback MIXER page for one mix bus: the bus
// selector first, then every source route (volume + pan), then back.
func mixerItems(st drivers.Status, bus int) []tuikit.PickerItem {
	items := []tuikit.PickerItem{
		{Display: fmt.Sprintf("MIX bus: %s  (←/→ switch bus)", drivers.BusLabelFor(st.Spec, bus)), Value: "bus"},
		{Display: "Sources → " + drivers.BusLabelFor(st.Spec, bus), Heading: true},
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
	// Requests that arrived while a dialog owned the keyboard run as soon as
	// it closes, instead of stacking a second prompt or being dropped.
	if !m.modalOpen() {
		if id := m.pendingInstallID; id != "" {
			m.pendingInstallID = ""
			next, c := m.startInstall([]string{id})
			m = next.(model)
			cmd = tea.Batch(cmd, c)
		} else if m.hotplugPending {
			m.hotplugPending = false
			if m.ui.detects() {
				cmd = tea.Batch(cmd, hotplugCheckCmd())
			}
		}
	}
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
		if m.profileChecking {
			// Same clock as the online dot: the square blinks while a repo
			// check runs, then settles solid if something needs attention.
			m.profileBlink++
			m.syncPicker()
		}
		return m, evoDotBlinkTick()

	case connectionsTrackedMsg:
		// The connection log now lists every card in use; the "Only used"
		// list and the foundation default picker rebuild from it.
		m.syncPicker()
		return m, nil

	case libraryBusyMsg:
		m.libraryLoading = true
		m.toast, _ = m.toast.SetOK(msg.what)
		return m, nil

	case libraryIndexMsg:
		m.libraryLoading = false
		m.profileChecking = false
		manual := m.libraryManual
		m.libraryManual = false
		if msg.err != nil {
			m.libraryErr = msg.err.Error()
			if manual {
				m.toast, _ = m.toast.SetErr("Repo check failed: " + msg.err.Error())
			}
			m.syncPicker()
			return m, nil
		}
		m.libraryErr = ""
		m.libraryIndex = msg.ix
		m.libraryUpstream = msg.upstream
		if manual {
			updates, installs := m.repoNews()
			m.toast, _ = m.toast.SetOK("Repo checked · " + repoNewsLabel(updates, installs))
		}
		m.syncPicker()
		return m, nil

	case libraryApplyMsg:
		m.libraryLoading = false
		if msg.err != nil {
			m.toast, _ = m.toast.SetErr(msg.what + ": " + msg.err.Error())
			return m, nil
		}
		m.toast, _ = m.toast.SetOK(msg.what)
		m.syncPicker()
		// Downloaded cards that need their own integration (oscmix, evo-raw,
		// douze) run them now, one at a time in the real terminal. The audio
		// foundation waits until the card has been connected once.
		if len(msg.setupIDs) > 0 {
			return m, setupChain(msg.setupIDs, nil)
		}
		if msg.checkDups {
			if dups := profiles.Duplicates(); len(dups) > 0 {
				return m, m.promptDuplicate(dups[0])
			}
		}
		return m, nil

	case tuikit.PickerToggleMsg:
		if m.top() == scrLibrary && (strings.HasPrefix(msg.Value, "card:") || strings.HasPrefix(msg.Value, "repo:")) {
			id := strings.TrimPrefix(strings.TrimPrefix(msg.Value, "card:"), "repo:")
			m.libraryChecked[id] = !m.libraryChecked[id]
			m.syncPicker()
		}
		return m, nil

	case libraryUninstallMsg:
		if msg.err != nil {
			m.toast, _ = m.toast.SetErr("Uninstall: " + msg.err.Error())
		} else {
			m.toast, _ = m.toast.SetOK("Uninstalled " + strings.Join(msg.ids, ", "))
		}
		// The selected interface may be gone now: fall back to the first
		// installed card instead of leaving the app pointed at a dead id.
		for _, id := range msg.ids {
			if id != m.deviceID {
				continue
			}
			m.deviceID = ""
			if inst := profiles.Installed(); len(inst) > 0 {
				m.deviceID = inst[0].ID
			}
			m.bindPreset()
			break
		}
		m.libraryChecked = map[string]bool{}
		m.syncPicker()
		return m, nil

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

	case cardsChangedMsg:
		if msg.retry {
			// PipeWire is not up yet, or restarted: retry slowly, never spin.
			return m, tea.Tick(3*time.Second, func(time.Time) tea.Msg { return cardsChangedMsg{} })
		}
		cmds := []tea.Cmd{cardEventCmd()}
		if m.ui.detects() {
			if m.modalOpen() {
				m.hotplugPending = true
			} else {
				cmds = append(cmds, hotplugCheckCmd())
			}
		}
		return m, tea.Batch(cmds...)

	case installRequestedMsg:
		// The notification click found Mixbay already running.
		cmds := []tea.Cmd{installSignalCmd()}
		if id := takePendingInstall(); id != "" {
			cmds = append(cmds, func() tea.Msg { return installRequestMsg{id: id} })
		}
		return m, tea.Batch(cmds...)

	case installRequestMsg:
		if msg.id == "" {
			return m, nil
		}
		if m.modalOpen() {
			m.pendingInstallID = msg.id
			return m, nil
		}
		return m.startInstall([]string{msg.id})

	case hotplugMsg:
		if !msg.ok || msg.key == m.hotplugKey {
			return m, nil
		}
		if m.modalOpen() {
			// Re-run once the dialog is gone: the offer is still valid.
			m.hotplugPending = true
			return m, nil
		}
		m.hotplugKey = msg.key
		for _, o := range profiles.SortedOffers(msg.offers) {
			if o.Kind != "install" || m.offeredProfiles[o.ID] {
				continue
			}
			m.offeredProfiles[o.ID] = true
			id := o.ID
			m.confirm = tuikit.NewConfirm(fmt.Sprintf("%s is connected.\n\nMixbay supports it, but its profile (%s) is not installed. Install it now?", o.Display, o.Version), "Later", "Install")
			m.confirmAct = func() tea.Cmd {
				return tea.Sequence(
					func() tea.Msg { return libraryBusyMsg{what: "Installing " + id + "…"} },
					libraryImportCmd([]string{id}, false),
				)
			}
			m.push(scrConfirm)
			break
		}
		return m, nil

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
		// Preset routing is local-file driven; do not re-read it on every
		// 2 Hz poll, only when the device changes or the user refreshes.
		if !msg.quiet || oldStatus.Spec.ID != st.Spec.ID {
			m.bindPreset()
		}
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
		if msg.engine == nil {
			m.meterStarting = false
			m.toast, _ = m.toast.SetWarn("Meters: USB node not found")
			return m, nil
		}
		if !m.wantsMeters() {
			msg.engine.Stop()
			m.meterStarting = false
			return m, nil
		}
		m.meter = msg.engine
		m.meterStarting = false
		m.meterPeakIn, m.meterPeakOut = [evoMaxMeterChannels]float64{}, [evoMaxMeterChannels]float64{}
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

	case foundationMsg:
		m.foundationLoading = false
		if msg.err != nil {
			m.toast, _ = m.toast.SetErr("Foundation: " + msg.err.Error())
			return m, nil
		}
		m.foundation = msg.state
		if m.top() == scrFoundation || m.top() == scrFoundationDefault {
			m.syncPicker()
		}
		return m, nil

	case foundationActionMsg:
		if msg.err != nil {
			m.toast, _ = m.toast.SetErr("Foundation " + msg.action + ": " + msg.err.Error())
		} else {
			switch msg.action {
			case "default":
				m.toast, _ = m.toast.SetOK("Default audio interface: " + msg.id)
			case "reset":
				m.toast, _ = m.toast.SetOK("Connection history cleared")
			case "split-on":
				m.toast, _ = m.toast.SetOK(msg.id + " split on")
				m.confirm = tuikit.NewConfirm("Restart the Omarchy shell now so the audio panel lists every stereo pair?", "Later", "Restart now")
				m.confirmAct = func() tea.Cmd { return shellRestartCmd() }
				m.push(scrConfirm)
			case "split-off":
				m.toast, _ = m.toast.SetOK(msg.id + " split off")
				m.confirm = tuikit.NewConfirm("Restart the Omarchy shell now so the audio panel shows one EVO entry?", "Later", "Restart now")
				m.confirmAct = func() tea.Cmd { return shellRestartCmd() }
				m.push(scrConfirm)
			}
		}
		return m, foundationStatusCmd()

	case shellRestartMsg:
		if msg.err != nil {
			m.toast, _ = m.toast.SetErr("Shell restart: " + msg.err.Error())
		} else {
			m.toast, _ = m.toast.SetOK("Omarchy shell restarted")
		}
		return m, nil

	case scanMsg:
		m.scanLoading = false
		if msg.err != nil {
			m.toast, _ = m.toast.SetErr("Scan: " + msg.err.Error())
			return m, nil
		}
		m.scanCards = msg.cards
		if m.top() == scrAddInterface {
			m.syncPicker()
		}
		return m, nil

	case betaAddMsg:
		if msg.err != nil {
			m.toast, _ = m.toast.SetErr("Add interface: " + msg.err.Error())
			return m, nil
		}
		m.toast, _ = m.toast.SetOK(msg.name + " added as beta — starting guided capture")
		if m.top() == scrAddInterface {
			m.pop()
		}
		m.syncPicker()
		// Go straight into the guided harness: discover channels, walk the
		// controls, confirm, then return to the main menu.
		return m, reverseHarnessCmd(msg.name, msg.match, true)

	case reverseHarnessMsg:
		// The harness has its own final confirmation. Either way, the user is
		// back at the main menu, not left on the Add/Settings page.
		m.nav = []screen{scrDevices}
		m.deviceID = defaultDevice()
		m.syncPicker()
		if msg.err != nil {
			m.toast, _ = m.toast.SetErr("Reverse harness: " + msg.err.Error())
		} else {
			m.toast, _ = m.toast.SetOK("Capture saved — review with mixbay-reverse sessions")
		}
		return m, fetchStatus(m.deviceID)

	case startupMsg:
		if msg.err != nil {
			m.toast, _ = m.toast.SetErr("Startup: " + msg.err.Error())
		}
		return m, nil

	case setupDoneMsg:
		return m.setupResult(msg)

	case tuikit.InfoCopiedMsg:
		// A copy is silent; a keypress that looks like it did nothing is
		// indistinguishable from one that failed.
		if msg.Err != nil {
			m.toast, _ = m.toast.SetErr("copy failed: " + msg.Err.Error())
			return m, nil
		}
		m.toast, _ = m.toast.SetOK(fmt.Sprintf("log copied to the clipboard (%d bytes)", msg.Bytes))
		return m, nil

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
	if m.top() == scrDevices || m.top() == scrControls || m.top() == scrMixer || m.top() == scrSettings || m.top() == scrPatchbay || m.top() == scrFoundation || m.top() == scrFoundationDefault || m.top() == scrAddInterface || m.top() == scrLibrary {
		var cmd tea.Cmd
		m.picker, cmd = m.picker.Update(msg)
		return m, cmd
	}
	if m.top() == scrConfirm {
		if res, ok := msg.(tuikit.ConfirmResultMsg); ok {
			act := m.confirmAct
			m.confirmAct = nil
			log := m.confirmLog
			m.confirmLog = ""
			m.pop()
			if !res.Canceled && res.Yes {
				if log != "" {
					m.info = tuikit.NewInfo(readSetupLog(log)).SetSize(m.contentSize())
					m.push(scrInfo)
					return m, nil
				}
				if act != nil {
					return m, act()
				}
			}
			return m, nil
		}
		var cmd tea.Cmd
		m.confirm, cmd = m.confirm.Update(msg)
		return m, cmd
	}
	if m.top() == scrInfo {
		if k, ok := msg.(tea.KeyMsg); ok && (k.String() == "esc" || k.String() == "backspace" || k.String() == "enter" || k.String() == "q") {
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
		if k == "esc" || k == "backspace" || k == "enter" || k == "q" {
			m.pop()
			return m, nil
		}
		var cmd tea.Cmd
		m.info, cmd = m.info.Update(msg)
		return m, cmd
	}
	if m.top() == scrLibrary {
		return m.libraryKey(msg)
	}
	// EVO 4 / EVO 8 draw their own evotui frame and own their keys.
	if m.isEvoDevice() && (m.top() == scrControls || m.top() == scrMixer) {
		return m, m.evoKey(k)
	}
	// The UGM192 has its own single-panel frame (volume/mute + meters).
	if m.isUGMDevice() && m.top() == scrControls {
		return m, m.ugmKey(k)
	}
	if m.top() == scrPatchbay {
		return m.patchbayKey(msg)
	}
	switch m.top() {
	case scrDevices:
		switch k {
		case "r":
			// Re-probe every interface and rebuild the list in place. The repo
			// check belongs to Settings (once) and to its r shortcut.
			m.syncPicker()
			m.toast, _ = m.toast.SetOK("Connection status refreshed")
			return m, trackConnectionsCmd()
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
				// One repo check per session, on the first Settings visit.
				if !m.profileChecked {
					m.profileChecked = true
					m.profileChecking = true
					m.libraryLoading = m.libraryIndex.SchemaVersion == 0
					return m, libraryIndexCmd()
				}
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
			m.bindPreset()
			// A deliberate (re)selection starts a fresh session: a device can
			// be picked in DEMO mode even if it was online earlier.
			m.session.selectDevice()
			// Do NOT keep rendering the previous interface while the new one
			// loads. Selecting Quantum after EVO used to leave the EVO status
			// (and its OUT levels) on screen until the user restarted Mixbay.
			m.status = drivers.Status{}
			if m.meter != nil {
				m.meter.Stop()
				m.meter = nil
			}
			m.meterStarting = false
			m.meterSnap = meters.Snapshot{}
			m.meterPeakIn, m.meterPeakOut = [evoMaxMeterChannels]float64{}, [evoMaxMeterChannels]float64{}
			m.meterFrozen = false
			// Unbind the previous device's spec: evoEnter() here would copy
			// the STALE status.Spec (the interface we just left) into the
			// renderer. The fresh statusMsg binds the real spec instead.
			m.evo.spec = drivers.Spec{}
			m.evo.window = evoWinControls
			m.push(scrControls)
			m.syncPicker()
			return m, fetchStatus(m.deviceID)
		case "q", "esc", "backspace":
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
		case "esc", "backspace":
			if m.numBuf != "" {
				if k == "backspace" {
					m.numBuf = m.numBuf[:len(m.numBuf)-1]
				} else {
					m.cancelNumeric()
				}
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
			if !hasControls(m.status) {
				m.toast, _ = m.toast.SetWarn("No TUI controls on this interface — the mixer owns them")
				return m, nil
			}
			return m, m.applyCmd(m.deviceID, func(d drivers.Driver) error { return d.Save() }, "state saved")
		case "o":
			if !hasControls(m.status) {
				m.toast, _ = m.toast.SetWarn("No TUI controls on this interface — the mixer owns them")
				return m, nil
			}
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
		case "esc", "backspace":
			if m.numBuf != "" {
				if k == "backspace" {
					m.numBuf = m.numBuf[:len(m.numBuf)-1]
				} else {
					m.cancelNumeric()
				}
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
		// Info is the log screen: scrolling and `c` (copy) must reach the
		// component, not pop it. Only the "continue" keys leave.
		if k == "esc" || k == "enter" || k == "backspace" || k == "q" {
			m.pop()
			return m, nil
		}
		var cmd tea.Cmd
		m.info, cmd = m.info.Update(msg)
		return m, cmd
	case scrSettings:
		switch k {
		case "esc", "backspace":
			m.pop()
			return m, nil
		case "enter", "left", "right":
			var post tea.Cmd
			switch m.picker.SelectedValue() {
			case "back":
				m.pop()
				return m, nil
			case "allow_native":
				if !levelsGuardEnabled() {
					m.toast, _ = m.toast.SetWarn("Keyboard control is always on without Levels Guard")
					return m, nil
				}
				m.ui.AllowNativeVolume = !m.ui.AllowNativeVolume
			case "listed":
				m.ui.Listed = nextListed(m.ui.Listed)
			case "launch_startup":
				m.ui.LaunchAtStartup = !m.ui.LaunchAtStartup
				post = startupApplyCmd()
			case "launch_scratchpad":
				m.ui.LaunchInScratchpad = !m.ui.LaunchInScratchpad
				post = tea.Batch(startupApplyCmd(), startupPlaceCmd())
			case "external_windows":
				m.ui.HandleExternalWindows = !m.ui.HandleExternalWindows
			case "detect_cards":
				if !m.ui.watcherOff() {
					m.ui.DetectCards = !m.ui.DetectCards
				}
			case "notify_cards":
				if !m.ui.watcherOff() && m.ui.DetectCards {
					m.ui.NotifyCards = !m.ui.NotifyCards
				}
			case "watcher_mode":
				m.ui.WatcherMode = nextWatcher(m.ui.WatcherMode)
			case "foundation":
				m.foundationLoading = true
				m.push(scrFoundation)
				m.syncPicker()
				return m, foundationStatusCmd()
			case "profiles":
				return m, m.openLibrary()
			case "add_interface":
				m.scanCards = nil
				m.scanLoading = true
				m.push(scrAddInterface)
				m.syncPicker()
				return m, scanCardsCmd()
			}
			if err := saveUIPrefs(m.ui); err != nil {
				m.toast, _ = m.toast.SetErr("Could not save settings: " + err.Error())
				return m, nil
			}
			m.syncPicker()
			m.toast, _ = m.toast.SetOK("Settings saved")
			return m, post
		}
	case scrFoundation:
		switch k {
		case "esc", "backspace":
			m.pop()
			return m, nil
		case "r":
			m.foundationLoading = true
			return m, foundationStatusCmd()
		case "d":
			m.push(scrFoundationDefault)
			m.syncPicker()
			return m, nil
		case "s":
			c, ok := m.selectedSplitCard()
			if !ok {
				return m, nil
			}
			on := "on"
			if c.Split == "on" {
				on = "off"
			}
			m.confirm = tuikit.NewConfirm(
				fmt.Sprintf("Turn the %s split %s? This only changes the Omarchy audio panel: on lists every stereo pair, off leaves one EVO entry. Routing is unchanged.", c.Name, on),
				"Cancel", "Split "+on)
			id := c.ID
			m.confirmAct = func() tea.Cmd { return foundationSplitCmd(on, id) }
			m.push(scrConfirm)
			return m, nil
		case "enter":
			val := m.picker.SelectedValue()
			switch {
			case val == "back":
				m.pop()
				return m, nil
			case val == "refresh":
				m.foundationLoading = true
				return m, foundationStatusCmd()
			case val == "reset-history":
				m.confirm = tuikit.NewConfirm("Forget every interface ever connected? Installed splits/udev rules and the default card are kept; the card/default lists repopulate when interfaces reconnect.", "Cancel", "Reset history")
				m.confirmAct = func() tea.Cmd { return foundationResetHistoryCmd() }
				m.push(scrConfirm)
				return m, nil
			case val == "default":
				m.push(scrFoundationDefault)
				m.syncPicker()
				return m, nil
			case strings.HasPrefix(val, "card:"):
				id := strings.TrimPrefix(val, "card:")
				c, ok := m.foundationCardByID(id)
				if !ok {
					return m, nil
				}
				action := "apply"
				label := "Install"
				if c.Installed {
					action, label = "remove", "Remove"
				}
				// The foundation waits for a first connection: a card that was
				// only downloaded has nothing to match yet, and its setup
				// already ran at download time.
				if action == "apply" && !m.foundationConnected(c.ID) {
					m.toast, _ = m.toast.SetWarn(c.Name + " has not been connected yet — plug it in once, then install its foundation.")
					return m, nil
				}
				var msg string
				if action == "apply" && c.ID == "fireface-ucx2" {
					msg = "Install the audio foundation for RME Fireface UCX II? oscmix (engine + GTK mixer) is installed first, then the shared system floor. Nothing is written to the interface."
				} else if action == "apply" {
					msg = fmt.Sprintf("Install the audio foundation for %s? This writes udev/WirePlumber/PipeWire config and restarts the audio graph briefly.", c.Name)
				} else if c.ID == "ssl12" {
					msg = "Remove SSL 12? This uninstalls douze (service, udev rule, PipeWire split and Omarchy360 plugin). Mixer state in ~/.config/sslctl is kept."
				} else if c.ID == "fireface-ucx2" {
					msg = "Remove the foundation for RME Fireface UCX II? oscmix is uninstalled with it and the shared floor stays if another card uses it. The interface is untouched."
				} else {
					msg = fmt.Sprintf("Remove the audio foundation for %s? Its split/udev/default mapping is removed; the shared WirePlumber floor stays if another card uses it. Audio restarts briefly.", c.Name)
				}
				m.confirm = tuikit.NewConfirm(msg, "Cancel", label)
				m.confirmAct = func() tea.Cmd { return foundationActionCmd(action, id) }
				m.push(scrConfirm)
				return m, nil
			}
		}
	case scrFoundationDefault:
		switch k {
		case "esc", "backspace":
			m.pop()
			return m, nil
		case "enter":
			val := m.picker.SelectedValue()
			if val == "back" {
				m.pop()
				return m, nil
			}
			if strings.HasPrefix(val, "card:") {
				id := strings.TrimPrefix(val, "card:")
				m.pop()
				return m, foundationSetDefaultCmd(id)
			}
		}
	case scrAddInterface:
		switch k {
		case "esc", "backspace":
			m.pop()
			return m, nil
		case "r":
			m.scanLoading = true
			return m, scanCardsCmd()
		case "enter":
			val := m.picker.SelectedValue()
			switch {
			case val == "back":
				m.pop()
				return m, nil
			case val == "refresh":
				m.scanLoading = true
				return m, scanCardsCmd()
			case strings.HasPrefix(val, "scan:"):
				var i int
				if _, err := fmt.Sscanf(strings.TrimPrefix(val, "scan:"), "%d", &i); err != nil || i < 0 || i >= len(m.scanCards) {
					return m, nil
				}
				c := m.scanCards[i]
				m.confirm = tuikit.NewConfirm("Add "+c.Name+" as a beta interface and start the guided capture? Mixbay will discover its channels, walk each control, ask for a final confirmation, then return here. Capture needs sudo (usbmon); nothing is written to the card.", "Cancel", "Add + capture")
				m.confirmAct = func() tea.Cmd { return betaAddCmd(c.Name, c.Match) }
				m.push(scrConfirm)
				return m, nil
			}
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
	case val == "ssl12:omarchy360":
		if err := exec.Command("omarchy-shell", "shell", "toggle", "fenrirrhogar.omarchy360").Start(); err != nil {
			m.toast, _ = m.toast.SetWarn("Omarchy360 is not available — install it from Set up SSL 12")
		} else {
			m.toast, _ = m.toast.SetOK("Omarchy360 opened")
		}
		return nil
	case val == "ssl12:setup":
		m.confirm = tuikit.NewConfirm("Set up SSL 12 (douze): udev access, user service, PipeWire split and Omarchy360 plugin. Audio may restart for a second. Continue?", "Cancel", "Set up")
		m.confirmAct = func() tea.Cmd {
			return setupCmd("SSL 12 setup", fetchStatus(dev), "mixbay-setup-ssl12")
		}
		m.push(scrConfirm)
		return nil
	case val == "oscmix:web":
		// Upstream's browser frontend: Web MIDI straight to the card, no
		// engine and no AppImage. Installed as an Omarchy app on first use,
		// so it works with or without a card (CC mode warning is the
		// launcher's job, not a reason to refuse).
		if err := openExternal("mixbay-oscmix-web"); err != nil {
			m.toast, _ = m.toast.SetWarn("Web UI: run Set up / repair oscmix first (" + err.Error() + ")")
		}
		return nil
	case val == "oscmix:gtk", val == "oscmix:qt":
		// The GTK window opens even without a card (its offline device
		// picker); the launcher tells the user that CC mode may be off.
		bin := "mixbay-oscmix-gtk"
		if val == "oscmix:qt" {
			// The AppImage is a preview upstream publishes only sometimes:
			// do not spawn a launcher that can only fail.
			if !oscmixQtInstalled() {
				m.toast, _ = m.toast.SetWarn("Qt UI: upstream has not published an AppImage for this release yet — use Open GTK mixer or the web UI")
				return nil
			}
			bin = "mixbay-oscmix-qt"
		}
		if err := openExternal(bin); err != nil {
			m.toast, _ = m.toast.SetWarn(bin + " is not installed — run Set up / repair oscmix")
		}
		return nil
	case val == "oscmix:setup":
		m.confirm = tuikit.NewConfirm("Set up oscmix (engine + GTK mixer) for "+m.status.Spec.Display+"? Build dependencies are installed with pacman. Nothing is written to the interface. Continue?", "Cancel", "Set up")
		m.confirmAct = func() tea.Cmd {
			return setupCmd("oscmix setup", fetchStatus(dev), "mixbay-audio-foundation", "--setup", "--device", dev)
		}
		m.push(scrConfirm)
		return nil
	case val == "beta:reverse":
		name := m.status.Spec.Display
		match := name
		if len(m.status.Spec.CardMatch) > 0 {
			match = m.status.Spec.CardMatch[0]
		}
		m.confirm = tuikit.NewConfirm("Start the guided USB reverse-engineering harness for "+name+"? It captures a quiet baseline, then one action you perform, and saves the observed transfers. Nothing on the card is written until you replay and confirm. Capture needs sudo (usbmon).", "Cancel", "Start capture")
		m.confirmAct = func() tea.Cmd { return reverseHarnessCmd(name, match, true) }
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
