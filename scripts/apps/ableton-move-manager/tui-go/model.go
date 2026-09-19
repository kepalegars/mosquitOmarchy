package main

import (
	"os"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	tuikit "mosquitomarchy.local/tui-kit"
)

// settingsDwell is how long a Left/Right-adjusted settings value is shown as
// "pending" before it is applied automatically. Every fresh Left/Right
// restarts the clock (see settingsDwellMsg/cycleSetting).
const settingsDwell = 800 * time.Millisecond

// settingsDwellMsg fires when a pending settings value has been left alone
// for settingsDwell. seq guards against stale timers: every Left/Right bumps
// settingsDwellSeq, so an older tick whose seq no longer matches is ignored.
type settingsDwellMsg struct {
	row string
	seq int
}

type screen int

const (
	scrMain screen = iota
	scrAddress
	scrSettings
	scrAbletonVersion
	scrBundlePick
	scrRoutePick
	scrConverting
	scrManagerWait
	scrClearAlsConfirm
	scrSuperfileInstallConfirm
	scrSuperfileInstalling
	scrBundleEmptyConfirm
	scrAbletonConflictConfirm
	scrAbletonClosing
	scrBitwigOpening
	scrQuitConfirm
	scrWorkingDirRunning
	scrManagerDownloadConfirm
	scrAbletonCloseRetryConfirm
	scrConvertRetryConfirm
	scrNoAlsConfirm
	scrConvertPresetSource
	scrConvertPresetPicking
	scrConvertPresetAddMore
	scrPresetConverting
	scrPresetUploadConfirm
	scrPresetUpload
	scrPresetNoMove
	scrSchwungMenu
	scrSchwungInstalling
	scrSchwungUninstallConfirm
	scrSchwungUninstalling
	scrBitwigMenu
	scrBitwigInstalling
	scrBitwigUninstallConfirm
	scrBitwigUninstalling
	scrBitwigModuleUninstallConfirm
	scrBitwigModuleUninstalling
	scrBitwigTipConfirm
	scrBitwigTipWait
)

type model struct {
	w, h int

	nav []screen

	status  MoveStatus
	loading bool
	fatal   error

	mainPicker        navPicker
	settingsPicker    navPicker
	abletonPicker     navPicker
	bundlePicker      navPicker
	routePicker       navPicker
	convertPresetPckr navPicker
	schwungPicker     navPicker
	bitwigPicker      navPicker
	addressInput      tuikit.TextInput
	confirm           tuikit.Confirm
	runner            tuikit.Runner
	toast             tuikit.Toast
	// tipInfo renders the Bitwig controller-setup tip in the Readme-style
	// framed modal (StyleModal) on scrBitwigTipWait.
	tipInfo tuikit.Info

	pendingBundle   string // chosen in scrBundlePick, consumed by scrRoutePick
	pendingAls      string // resolved by open-ableton-route, opened by scrBitwigOpening
	pendingRoute    string // set by startConvert / startAbletonConversion (als|bitwig|midi)
	managerPrompted string // last bundle shown in the download prompt (scrManagerWait flow)
	managerWaiting  bool   // true once the Manager is open and scrManagerWait switched to polling
	quit            bool

	// markerMode is the last mode written to this instance's state marker
	// ("" | "busy" | "discretion"). syncWorkMarker rewrites the file only on
	// a transition, so it can run on every Update cheaply.
	markerMode string

	// discretion: the post-Bitwig hidden daemon state. The window is off-screen,
	// nothing is rendered, all periodic ticks stop, and the only work left is the
	// Bitwig-close watchdog (see discretion.go).
	discretion bool

	// Convert a preset flow state.
	presetKind             string   // "ableton" (.adg) or "bitwig" (.bwpreset)
	presetFiles            []string // the source preset files accumulated for this run
	presetDir              string   // where converted presets land (presets_dir from the action)
	presetPickDir          string   // where the .adg picker starts (default_dir)
	presetBwPickDir        string   // where the .bwpreset picker starts (bw_default_dir)
	presetOutputs          []string // converted preset paths parsed from the runner output (post-conversion screen)
	presetUploadSawRunning bool     // post-conversion upload: saw the Manager running once, so a later "not running" means it closed

	presetNoMovePicker navPicker // "Move not connected" choices after a preset conversion
	bitwigSawRunning   bool      // scrBitwigTipWait: saw Bitwig running once, so a later "not running" means it was closed

	// Schwung menu state (filled by fetchSchwungInfo/wireSchwungMenu).
	schwungReachable bool
	schwungInstalled bool
	schwungVersion   string
	schwungLatest    string

	// Bitwig Move menu state (filled by fetchBitwigMoveStatus/wireBitwigMenu).
	bitwigInstalled   bool
	bitwigBin         string
	bitwigControllers bool
	bitwigOnDevice    string

	// settingsPending holds a Left/Right-adjusted but not-yet-applied value
	// per Settings row (the target: "on"/"off" or "default"/"superfile").
	// The displayed label is overridden from it immediately; the change is
	// applied on the dwell timer, when the cursor leaves the row, or when
	// the screen is left. settingsDwellSeq invalidates older dwell timers.
	settingsPending  map[string]string
	settingsDwellSeq int
}

func initialModel() model {
	m := model{nav: []screen{scrMain}}
	// Every list-backed picker must hold a real list.Model from the start
	// (not a zero value) — WindowSizeMsg can arrive before any screen has
	// fetched its real data and called newNavPicker for real, and
	// SetSize on a zero-value list.Model panics. Pre-populated with a
	// "checking…" placeholder (🟡 dot) rather than left empty: status-json
	// includes a real network probe (detect_move's ping, up to ~1.5s) that
	// used to block the very first frame behind a blank/loading screen —
	// the menu is now interactive from frame one, and just updates in
	// place a moment later once the real connection status comes back.
	// The ASCII banner on the home screen is the title; the picker header is
	// left empty so it doesn't render a duplicate white title under it. The
	// connection status (host + dot) is shown as a separate line under the
	// banner instead (see view.go's main screen).
	m.mainPicker = newNavPicker("", mainMenuItems(MoveStatus{}, true))
	m.settingsPicker = newNavPicker("", nil)
	m.abletonPicker = newNavPicker("", nil)
	m.bundlePicker = newNavPicker("", nil)
	m.routePicker = newNavPicker("", nil)
	m.convertPresetPckr = newNavPicker("", nil)
	m.presetNoMovePicker = newNavPicker("", nil)
	m.schwungPicker = newNavPicker("", nil)
	m.bitwigPicker = newNavPicker("", nil)
	m.runner = tuikit.NewRunner()
	return m
}

func (m model) Init() tea.Cmd {
	return tea.Batch(fetchStatus(), tuikit.ThemeWatchCmd())
}

func (m model) top() screen { return m.nav[len(m.nav)-1] }

// isActiveWork reports whether the manager is in a step that must not be
// treated as a replaceable visible instance: any conversion/Bitwig handoff,
// install/uninstall, or a poll loop still in flight. A plain menu, a confirm
// dialog, or a finished runner log the user is merely reading is NOT active,
// so the dispatcher may still offer to replace that instance.
func (m model) isActiveWork() bool {
	switch m.top() {
	case scrManagerWait:
		// Opening the Move Manager, then polling until it is closed.
		return m.managerWaiting || !m.runner.Done()
	case scrPresetUpload, scrBitwigTipWait:
		// Pure poll loops (Manager / Bitwig window).
		return true
	case scrConverting, scrAbletonClosing, scrBitwigOpening,
		scrPresetConverting, scrWorkingDirRunning, scrSchwungInstalling,
		scrSchwungUninstalling, scrBitwigInstalling, scrBitwigUninstalling,
		scrBitwigModuleUninstalling:
		return !m.runner.Done()
	}
	return false
}

// syncWorkMarker keeps this instance's marker in step with its current state
// on every Update: mode=discretion in the hidden watchdog, mode=busy while a
// step is active, and no marker at all on a normal visible menu. The busy
// marker is therefore set the instant a conversion starts — long before the
// old Bitwig-handoff write — so the detector never offers to replace an
// instance mid-operation, and is cleared again once the instance is back to a
// replaceable menu/log.
func (m *model) syncWorkMarker() {
	want := ""
	switch {
	case m.discretion:
		want = "discretion"
	case m.isActiveWork():
		want = "busy"
	}
	if want == m.markerMode {
		return
	}
	pid := os.Getpid()
	if want == "" {
		removeDiscretionMarker(pid)
	} else {
		writeStateMarker(pid, want)
	}
	m.markerMode = want
}

func (m *model) push(s screen) { m.nav = append(m.nav, s) }

func (m *model) pop() {
	if len(m.nav) > 1 {
		m.nav = m.nav[:len(m.nav)-1]
	}
	m.toast = m.toast.ClearNonCritical()
}

func (m *model) replace(s screen) { m.nav[len(m.nav)-1] = s }

func mainMenuItems(s MoveStatus, checking bool) []tuikit.PickerItem {
	managerLabel := "Open the Move Manager & convert"
	managerDisabled := false
	switch {
	case checking:
		// No "(checking…)" text: the move.local status line already shows
		// an ORANGE dot while the check is in flight (same meaning).
		managerDisabled = true
	case !s.Connected:
		// No "(unavailable)" suffix anymore — the label is the label. The
		// row just stays non-selectable while the Move is unreachable.
		managerDisabled = true
	}
	items := []tuikit.PickerItem{
		{Display: "Refresh connection status", Value: "refresh"},
		{Display: "Set the Move address", Value: "address"},
		{Display: managerLabel, Value: "manager", Disabled: managerDisabled},
		{Display: "Convert a Move set", Value: "convert"},
		{Display: "Convert a preset", Value: "convert_preset"},
	}
	// Schwung and the Bitwig Move controller both act on the Move device
	// itself — the user's rule: they are always VISIBLE but greyed out /
	// non-selectable while it is not connected.
	items = append(items,
		tuikit.PickerItem{Display: "Schwung", Value: "schwung", Disabled: !s.Connected},
		tuikit.PickerItem{Display: "Move as Bitwig controller", Value: "bitwig_move", Disabled: !s.Connected},
	)
	items = append(items, tuikit.PickerItem{Display: "Settings", Value: "settings"})
	items = append(items, tuikit.PickerItem{Display: "Close", Value: "quit"})
	return items
}

// wireSchwungMenu builds the Schwung submenu from the last fetched state.
// It also reports targets for install vs update based on what schwung-status
// found on the device — "install" when not installed (or not answering),
// "update" once it is.
func (m model) wireSchwungMenu() []tuikit.PickerItem {
	if !m.status.Connected {
		return []tuikit.PickerItem{
			{Display: "Move not connected — plug it in to use Schwung", Disabled: true},
			{Display: "Back", Value: "back"},
		}
	}
	verb := "Install Schwung"
	if m.schwungInstalled {
		verb = "Update Schwung"
		if m.schwungVersion != "" {
			verb += " (device v" + m.schwungVersion + ")"
		}
		if m.schwungLatest != "" && m.schwungLatest != m.schwungVersion {
			verb += " → v" + m.schwungLatest
		}
	}
	items := []tuikit.PickerItem{
		{Display: verb, Value: "install"},
	}
	if m.schwungInstalled {
		items = append(items, tuikit.PickerItem{Display: "Open the Schwung Manager", Value: "open"})
		items = append(items, tuikit.PickerItem{Display: "Uninstall Schwung", Value: "uninstall"})
	} else {
		openLabel := "Open the Schwung Manager"
		if !m.schwungReachable {
			openLabel = "Open the Schwung Manager (only after installation)"
		}
		items = append(items, tuikit.PickerItem{Display: openLabel, Value: "open", Disabled: true})
	}
	items = append(items, tuikit.PickerItem{Display: "Back", Value: "back"})
	return items
}

// wireBitwigMenu builds the Bitwig Move controller submenu from the last
// fetched state. Both the host controller scripts (Bitwig side) and the
// on-device Move module are offered for install AND uninstall: on-device
// detection needs ssh to the Move, so when that is unavailable the status
// reads "unknown" and the menu still offers both, explaining the caveat.
func (m model) wireBitwigMenu() []tuikit.PickerItem {
	if !m.bitwigInstalled {
		return []tuikit.PickerItem{
			{Display: "Bitwig Studio isn't installed on this system", Disabled: true},
			{Display: "Uninstall the Move module from the device", Value: "uninstall_module"},
			{Display: "Back", Value: "back"},
		}
	}
	statusLine := "module on the Move: unknown (detection needs ssh to the Move)"
	if m.bitwigOnDevice == "yes" {
		statusLine = "module on the Move: installed"
	} else if m.bitwigOnDevice == "no" {
		statusLine = "module on the Move: not found (install with Schwung first)"
	}
	if !m.bitwigControllers {
		statusLine = "controller scripts: not installed · " + statusLine
	} else {
		statusLine = "controller scripts: installed · " + statusLine
	}
	main := "Install the controller & Move module"
	if m.bitwigControllers {
		main = "Update the controller & Move module"
	}
	return []tuikit.PickerItem{
		{Display: main, Value: "install"},
		{Display: "Uninstall the controller scripts", Value: "uninstall", Disabled: !m.bitwigControllers},
		{Display: "Uninstall the Move module from the device", Value: "uninstall_module"},
		{Display: statusLine, Disabled: true},
		{Display: "Back", Value: "back"},
	}
}

func settingsItems(s MoveStatus) []tuikit.PickerItem {
	hc := "Off"
	if s.HideConverted {
		hc = "On"
	}
	av := s.AbletonVer
	if av == "" {
		av = "(not set)"
	}
	fp := "Default"
	if s.FilePicker == "superfile" {
		fp = "Superfile"
	}
	ya := "Off"
	if s.OpenAlsYdotool {
		ya = "On"
	}
	return []tuikit.PickerItem{
		{Display: "Hide sets converted to Bitwig: " + hc, Value: "hide_converted"},
		{Display: "Open the converted .als directly with Bitwig using ydotool: " + ya, Value: "open_als_ydotool"},
		{Display: "Select Ableton version for conversion: " + av, Value: "ableton_version"},
		{Display: "Change working directory location: " + s.MoveDir, Value: "working_dir"},
		{Display: "File picker: " + fp, Value: "switch_file_picker"},
		{Display: "Clear the als working folder", Value: "clear_als"},
		{Display: "Back", Value: "back"},
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
	m.syncWorkMarker()
	if m.toast.Gen() != before {
		cmd = tea.Batch(cmd, m.toast.ExpireCmd())
	}
	return m, cmd
}

func (m model) update(msg tea.Msg) (tea.Model, tea.Cmd) {
	// Discretion (hidden watchdog) mode: the only event that matters is the
	// watched Bitwig instance closing. Every other message (keys, ticks, size
	// changes) is dropped, without rendering or re-arming anything, so a
	// hidden manager costs no CPU.
	if _, ok := msg.(bitwigClosedMsg); ok {
		removeDiscretionMarker(os.Getpid())
		m.quit = true
		return m, tea.Quit
	}
	if m.discretion {
		return m, nil
	}
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.w, m.h = msg.Width, msg.Height
		m.mainPicker = m.mainPicker.SetSize(m.mainContentSize())
		m.settingsPicker = m.settingsPicker.SetSize(m.contentSize())
		m.abletonPicker = m.abletonPicker.SetSize(m.contentSize())
		m.bundlePicker = m.bundlePicker.SetSize(m.contentSize())
		m.routePicker = m.routePicker.SetSize(m.contentSize())
		m.convertPresetPckr = m.convertPresetPckr.SetSize(m.contentSize())
		m.presetNoMovePicker = m.presetNoMovePicker.SetSize(m.contentSize())
		m.schwungPicker = m.schwungPicker.SetSize(m.contentSize())
		m.bitwigPicker = m.bitwigPicker.SetSize(m.contentSize())
		m.runner = m.runner.SetSize(m.contentSize())
		return m, nil

	case tea.KeyMsg:
		if msg.String() == "ctrl+c" {
			// Top level: quit immediately, no confirm needed — same as
			// esc there. Any deeper screen: ctrl+c backs out one level,
			// exactly like esc, so it can never leave a half-drawn
			// sub-screen behind (the single persistent Program is never
			// interrupted mid-render the way repeated `gum` subprocesses
			// could be).
			if len(m.nav) == 1 {
				m.quit = true
				return m, tea.Quit
			}
			if m.top() == scrSettings {
				// Leaving Settings commits any pending Left/Right value
				// before the screen is popped (a value that needs a confirm
				// pushes that confirm instead).
				cmd := m.applyAllPending()
				if m.top() == scrSettings {
					m.pop()
				}
				return m, tea.Batch(cmd, m.enterCmd())
			}
			m.pop()
			return m, m.enterCmd()
		}

	case tuikit.ThemeTickMsg:
		// Live theme following: re-stamp every package-level color/style
		// var from the active Omarchy palette, then schedule the next
		// poll. A theme switched while the manager is open takes effect
		// on the next rendered frame (see tui-kit/theme.go).
		tuikit.ApplyTheme()
		return m, tuikit.ThemeWatchCmd()

	case statusMsg:
		if msg.skip {
			// Retry once, immediately — an empty result on the very
			// first load (before any menu has ever been built) must
			// not leave the picker permanently blank.
			return m, fetchStatus()
		}
		m.loading = false
		if msg.err != nil {
			m.toast, _ = m.toast.SetErr(msg.err.Error())
			return m, nil
		}
		m.status = msg.status
		// A pending settings value whose target the server now reports is
		// settled: drop the override so the row shows the applied value.
		m.settleSettingsPending()
		// Post-preset "Move not connected" screen: a refresh that now finds
		// the Move moves straight on to the "open the Manager?" confirm;
		// otherwise say so and stay put.
		if m.top() == scrPresetNoMove {
			if msg.status.Connected {
				m.replace(scrPresetUploadConfirm)
				return m, m.enterCmd()
			}
			m.toast, _ = m.toast.SetWarn("Move still not connected")
			return m, nil
		}
		// Preserve the cursor across the rebuild: "Refresh connection
		// status" re-creates the home picker with the current state's
		// labels and, without re-selecting, threw the cursor back to
		// the top of the list at the end of the refresh. Never reset it.
		idx := m.mainPicker.Index()
		items := mainMenuItems(msg.status, false)
		if idx > len(items)-1 {
			idx = len(items) - 1
		}
		if idx < 0 {
			idx = 0
		}
		m.mainPicker = newNavPicker("", items).SetSize(m.mainContentSize())
		m.mainPicker = m.mainPicker.SelectIndex(idx)
		if m.top() == scrSettings {
			m.rebuildSettingsPicker()
		}
		return m, nil

	case bundlesMsg:
		m.loading = false
		if msg.err != nil {
			m.toast, _ = m.toast.SetErr(msg.err.Error())
			m.pop()
			return m, m.enterCmd()
		}
		if len(msg.items) == 0 {
			m.replace(scrBundleEmptyConfirm)
			return m, m.enterCmd()
		}
		items := make([]tuikit.PickerItem, len(msg.items))
		for i, b := range msg.items {
			items[i] = tuikit.PickerItem{Display: b.Label, Value: b.Path}
		}
		m.bundlePicker = newNavPicker("Which ablbundle set?", items).SetSize(m.contentSize())
		return m, nil

	case abletonConflictMsg:
		m.loading = false
		if msg.err != nil {
			m.toast, _ = m.toast.SetErr(msg.err.Error())
			return m, nil
		}
		if msg.running {
			if m.top() == scrAbletonConflictConfirm {
				// A "Re-check" found Ableton still open: refresh the same
				// prompt in place (do NOT push a second copy of it) and tell
				// the user why nothing moved forward.
				m.toast, _ = m.toast.SetWarn("Ableton is still open")
				return m, m.enterCmd()
			}
			m.push(scrAbletonConflictConfirm)
			return m, m.enterCmd()
		}
		if m.top() == scrAbletonConflictConfirm {
			m.toast, _ = m.toast.SetOK("Ableton is closed — continuing")
		}
		return m.startAbletonConversion()

	case pathMsg:
		m.loading = false
		if msg.err != nil {
			m.toast, _ = m.toast.SetErr(msg.err.Error())
			return m, nil
		}
		if msg.kind == "pick-file" {
			if msg.path == "" {
				m.toast, _ = m.toast.SetWarn("no file selected")
				m.pop()
				return m, m.enterCmd()
			}
			m.pendingBundle = msg.path
			m.replace(scrRoutePick)
			return m, m.enterCmd()
		}
		if msg.kind == "pick-adg" || msg.kind == "pick-bwpreset" {
			if msg.path == "" {
				m.toast, _ = m.toast.SetWarn("no file selected")
				m.presetFiles = nil
				m.nav = []screen{scrMain}
				return m, m.enterCmd()
			}
			m.presetFiles = append(m.presetFiles, msg.path)
			m.replace(scrConvertPresetAddMore)
			return m, m.enterCmd()
		}
		return m, nil

	case exesMsg:
		m.loading = false
		if msg.err != nil {
			m.toast, _ = m.toast.SetErr(msg.err.Error())
			m.pop()
			return m, m.enterCmd()
		}
		if len(msg.items) == 0 {
			m.toast, _ = m.toast.SetWarn("no Ableton installation found")
			m.pop()
			return m, m.enterCmd()
		}
		items := make([]tuikit.PickerItem, len(msg.items))
		for i, e := range msg.items {
			items[i] = tuikit.PickerItem{Display: e.Label, Value: e.Path}
		}
		m.abletonPicker = newNavPicker("Which Ableton version should conversions use?", items).SetSize(m.contentSize())
		return m, nil

	case actionOKMsg:
		m.loading = false
		m.toast, _ = m.toast.SetOK(msg.what)
		m.pop()
		return m, tea.Batch(m.enterCmd(), fetchStatus())

	case actionErrMsg:
		m.loading = false
		m.toast, _ = m.toast.SetErr(msg.err.Error())
		return m, nil

	case silentDoneMsg:
		if msg.err != nil {
			m.toast, _ = m.toast.SetErr(msg.err.Error())
		}
		return m, nil

	case toastOKMsg:
		m.toast, _ = m.toast.SetOK(msg.what)
		return m, fetchStatus()

	case presetStatusMsg:
		m.loading = false
		if msg.err != nil {
			m.toast, _ = m.toast.SetErr(msg.err.Error())
			return m, nil
		}
		m.presetDir = msg.presetsDir
		m.presetPickDir = msg.defaultDir
		m.presetBwPickDir = msg.bwDefaultDir
		// When the flow is mid-pick with the superfile pref, this fetch was
		// armed just to learn the start directory — go pick with it now.
		if m.top() == scrConvertPresetPicking {
			pickAction, pickDir := "pick-adg", m.presetPickDir
			if m.presetKind == "bitwig" {
				pickAction, pickDir = "pick-bwpreset", m.presetBwPickDir
			}
			return m, pickViaSuperfileEmbedded(pickAction, pickDir)
		}
		return m, nil

	case schwungInfoMsg:
		m.loading = false
		if msg.err != nil {
			m.toast, _ = m.toast.SetErr(msg.err.Error())
			return m, nil
		}
		m.schwungReachable = msg.reachable
		m.schwungInstalled = msg.installed
		m.schwungVersion = msg.version
		m.schwungLatest = msg.latest
		if m.top() == scrSchwungMenu {
			m.schwungPicker = newNavPicker("", m.wireSchwungMenu()).SetSize(m.contentSize())
		}
		return m, nil

	case bitwigMoveStatusMsg:
		m.loading = false
		if msg.err != nil {
			m.toast, _ = m.toast.SetErr(msg.err.Error())
			return m, nil
		}
		m.bitwigInstalled = msg.bitwig
		m.bitwigBin = msg.bitwigBin
		m.bitwigControllers = msg.controllers
		m.bitwigOnDevice = msg.onDevice
		if m.top() == scrBitwigMenu {
			m.bitwigPicker = newNavPicker("", m.wireBitwigMenu()).SetSize(m.contentSize())
		}
		return m, nil

	case bitwigRunningMsg:
		if msg.err != nil {
			m.toast, _ = m.toast.SetWarn("bitwig check failed")
			return m, m.enterCmd()
		}
		// auto-return: only after we saw it running once (a stale first
		// tick must not read as "closed right away")
		if m.bitwigSawRunning && !msg.running && m.top() == scrBitwigTipWait {
			m.bitwigSawRunning = false
			m.toast, _ = m.toast.SetOK("Bitwig closed — back to the menu")
			m.pop()
			return m, m.enterCmd()
		}
		if msg.running {
			m.bitwigSawRunning = true
		}
		return m, bitwigRunningCmd()

	case tuikit.RunnerLineMsg, tuikit.RunnerDoneMsg:
		// Keep the runner's own state in step (scrolling viewport, done
		// flag) — the completion of a runner is a real state change the
		// top screen must react to (auto-advance to the next step, "open
		// in Bitwig?", retry prompts), not just a log to sit on. Line
		// messages only ever concern the runner's viewport; the done
		// message is then dispatched to the top screen, whose handlers
		// can read runner.Done()/Output() thanks to the update above.
		var cmd tea.Cmd
		m.runner, cmd = m.runner.Update(msg)
		if _, ok := msg.(tuikit.RunnerLineMsg); ok {
			return m, cmd
		}
		return m.updateScreen(msg)
	}

	return m.updateScreen(msg)
}

// headerFor renders the main menu's title line the same way the bash
// version did: "mosquito Move Manager — <host> <dot>". checking=true (only
// ever true for the very first frame, before the connection check most of
// startConvert/status-json's work does has had a chance to come back) shows
// a neutral "still looking" dot instead of a possibly-wrong red one.
func headerFor(s MoveStatus, checking bool) string {
	dot := "🔴"
	switch {
	case checking:
		// ORANGE while the refresh fetch is in flight (the user's rule:
		// the status dot turns orange during the refresh so the state of
		// the connection check is visible at a glance).
		dot = "🟠"
	case s.Connected:
		dot = "🟢"
	}
	host := s.Host
	if host == "" {
		host = "move.local"
	}
	return host + " " + dot
}
