package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"mosquitomarchy.local/mosquitomixbay-tui/drivers"
	tuikit "mosquitomarchy.local/tui-kit"
)

func demoStatus(t *testing.T, id string) drivers.Status {
	t.Helper()
	// Force demo mode even where a real /dev/evo* node exists, so the
	// assertions below always exercise the demo path deterministically.
	t.Setenv("MOSQUITOMIXBAY_EVO_DEVDIR", t.TempDir())
	d, err := drivers.Open(id)
	if err != nil {
		t.Fatalf("open %s: %v", id, err)
	}
	st, err := d.Status()
	if err != nil {
		t.Fatalf("status %s: %v", id, err)
	}
	if st.Online {
		t.Skipf("%s hardware online, demo assertions skipped", id)
	}
	return st
}

func TestControlItemsEVO8(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	st := demoStatus(t, drivers.DevEVO8)
	items := controlItems(st)
	// Sections: INPUTS + OUTPUTS + ACTIONS headings, 4 inputs x
	// (gain+mute+48V), 2 pairs x (vol+mute), mixer + save + load + back.
	want := 3 + 4*3 + 2*2 + 4
	if len(items) != want {
		t.Errorf("evo8 control rows = %d, want %d", len(items), want)
	}
	joined := ""
	for _, it := range items {
		joined += it.Display + "\n"
	}
	for _, needle := range []string{"INPUTS", "OUTPUTS", "INPUT3", "OUTPUT2", "48V", "Loopback mixer"} {
		if !strings.Contains(joined, needle) {
			t.Errorf("control list missing %q", needle)
		}
	}
}

func TestControlItemsEVO4HasMonitor(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	st := demoStatus(t, drivers.DevEVO4)
	found := false
	for _, it := range controlItems(st) {
		if strings.Contains(it.Display, "MONITOR") {
			found = true
		}
	}
	if !found {
		t.Errorf("evo4 controls should include the monitor blend row")
	}
}

func TestControlItemsALSAShowsNoGainRows(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	st := demoStatus(t, drivers.DevUGM192)
	for _, it := range controlItems(st) {
		if strings.Contains(it.Display, "gain") || strings.Contains(it.Display, "48V") {
			t.Errorf("ALSA box must not offer %q", it.Display)
		}
		if strings.Contains(it.Display, "Loopback mixer") {
			t.Errorf("ALSA box must not offer a mixer row")
		}
	}
}

func TestMixerItemsBusSelectorFirst(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	st := demoStatus(t, drivers.DevEVO8)
	items := mixerItems(st, 1)
	if len(items) == 0 || items[0].Value != "bus" {
		t.Fatalf("first mixer row must be the bus selector, got %+v", items[:1])
	}
	if !strings.Contains(items[0].Display, "MIX 3|4") {
		t.Errorf("bus 1 should display MIX 3|4, got %q", items[0].Display)
	}
	// Bus 1 routes carry the @1 suffix.
	found := false
	for _, it := range items {
		if strings.HasPrefix(it.Value, "mix:") && strings.HasSuffix(it.Value, "@1") {
			found = true
		}
	}
	if !found {
		t.Errorf("bus-1 mixer rows should use @1 keys")
	}
}

func TestMixerSourcesStableOrder(t *testing.T) {
	a := drivers.MixerSources(drivers.EVO8Spec, 0)
	b := drivers.MixerSources(drivers.EVO8Spec, 1)
	if len(a) != len(b) {
		t.Fatalf("bus key count differs: %d vs %d", len(a), len(b))
	}
	for i := range a {
		if a[i] != b[i][:len(b[i])-2] && b[i] != a[i]+"@1" {
			t.Fatalf("bus suffix mismatch at %d: %q vs %q", i, a[i], b[i])
		}
	}
	if !strings.HasPrefix(a[0], "input") {
		t.Errorf("inputs should sort before playback sources, got %q first", a[0])
	}
}

func TestSetMixerSourceParsing(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	d, _ := drivers.Open(drivers.DevEVO8)
	if err := setMixerSource(d, "input2", -10, 20, 0); err != nil {
		t.Errorf("input2: %v", err)
	}
	if err := setMixerSource(d, "output3_4", -3, 0, 0); err != nil {
		t.Errorf("output3_4: %v", err)
	}
	if err := setMixerSource(d, "bogus", 0, 0, 0); err == nil {
		t.Errorf("bogus source should fail")
	}
}

func TestDbFmt(t *testing.T) {
	if dbFmt(-128) != "-inf" {
		t.Errorf("mixer silence should render -inf, got %q", dbFmt(-128))
	}
	if !strings.Contains(dbFmt(-20), "20") {
		t.Errorf("dbFmt(-20) = %q", dbFmt(-20))
	}
}

// A modal prompt (quit, 48V…) must sit dead-center in the window, never
// glued to a corner: measure equal-ish blank margins on all four sides.
// Goes through the full View (not just centerModal): the bug was View
// trimming the modal's bottom padding and re-centering the shorter block,
// which pushed every prompt down.
func TestConfirmModalIsCentered(t *testing.T) {
	m := initialModel()
	m.w, m.h = 100, 30
	m.confirm = tuikit.NewConfirm("Quit mosquito-mixbay?", "No", "Yes")
	m.nav = append(m.nav, scrConfirm)
	v := m.View()
	lines := strings.Split(strings.TrimRight(v, "\n"), "\n")
	if len(lines) > 30 {
		t.Fatalf("modal frame overflows: %d lines", len(lines))
	}
	topBlank := 0
	for _, l := range lines {
		if strings.TrimSpace(stripANSI(l)) == "" {
			topBlank++
		} else {
			break
		}
	}
	botBlank := 0
	for i := len(lines) - 1; i >= 0; i-- {
		if strings.TrimSpace(stripANSI(lines[i])) == "" {
			botBlank++
		} else {
			break
		}
	}
	if abs(topBlank-botBlank) > 1 {
		t.Errorf("modal not vertically centered: %d blank rows above, %d below", topBlank, botBlank)
	}
	// Horizontally: the first content row must start well past column 0.
	for _, l := range lines {
		if s := strings.TrimSpace(stripANSI(l)); s != "" {
			lead := len(l) - len(strings.TrimLeft(l, " "))
			if lead < 5 {
				t.Errorf("modal not horizontally centered: content starts at column %d", lead)
			}
			break
		}
	}
}

// The EVO screens are the evotui port: render both devices on both tabs and
// check the frame appears, fits the window, and carries evotui's own chrome
// (tab bar, boxed cards, the MIX bus labels) instead of the picker.
func TestEvoViewRendersEvotuiFrame(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("MOSQUITOMIXBAY_EVO_DEVDIR", t.TempDir())
	for _, id := range []string{drivers.DevEVO8, drivers.DevEVO4} {
		for _, window := range []int{0, 1} {
			m := initialModel()
			m.w, m.h = 110, 40
			m.deviceID = id
			st, err := m.driversStatus(id)
			if err != nil {
				t.Fatal(err)
			}
			m.status = st
			m.evoEnter()
			m.evo.window = window
			if window == 0 {
				m.nav = append(m.nav, scrControls)
			} else {
				m.nav = append(m.nav, scrMixer)
			}
			v := m.View()
			lines := strings.Split(strings.TrimRight(v, "\n"), "\n")
			if len(lines) > m.h {
				t.Errorf("%s window=%d: frame overflows (%d lines)", id, window, len(lines))
			}
			plain := stripANSI(v)
			if window == 0 {
				for _, needle := range []string{"CONTROLS", "MIXER", "IN 1"} {
					if !strings.Contains(plain, needle) {
						t.Errorf("%s controls: missing %q", id, needle)
					}
				}
			} else {
				bus := "MIX 1|2"
				if id == drivers.DevEVO4 {
					bus = "MIX 3|4"
				}
				for _, needle := range []string{"CONTROLS", "MIXER", bus} {
					if !strings.Contains(plain, needle) {
						t.Errorf("%s mixer: missing %q", id, needle)
					}
				}
			}
		}
	}
}

// EVO 4 has a monitor blend knob; its card must render the IN/Mix/OUT fader.
func TestEvo4ControlsShowMonitorBlend(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("MOSQUITOMIXBAY_EVO_DEVDIR", t.TempDir())
	m := initialModel()
	m.w, m.h = 90, 40
	m.deviceID = drivers.DevEVO4
	st, err := m.driversStatus(drivers.DevEVO4)
	if err != nil {
		t.Fatal(err)
	}
	m.status = st
	m.evoEnter()
	m.nav = append(m.nav, scrControls)
	plain := stripANSI(m.View())
	if !strings.Contains(plain, "MONITOR") || !strings.Contains(plain, "Mix:") {
		t.Errorf("EVO4 controls should render the monitor blend fader")
	}
}

// evoModel prepares a demo-mode EVO model parked on a screen.
func evoModel(t *testing.T, id string, window int) model {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	t.Setenv("MOSQUITOMIXBAY_EVO_DEVDIR", t.TempDir())
	m := initialModel()
	m.w, m.h = 120, 40
	m.deviceID = id
	st, err := m.driversStatus(id)
	if err != nil {
		t.Fatal(err)
	}
	m.status = st
	m.evoEnter()
	m.evo.window = window
	if window == 0 {
		m.nav = append(m.nav, scrControls)
	} else {
		m.nav = append(m.nav, scrMixer)
	}
	return m
}

// Crossing controls columns must keep the row index (IN 3 -> OUT 3|4), not
// snap back to the first output.
func TestEvoControlsGridNavigation(t *testing.T) {
	m := evoModel(t, drivers.DevEVO8, 0)
	if m.evo.cursor != 0 {
		t.Fatalf("start cursor = %d", m.evo.cursor)
	}
	m.evoKey("j")
	m.evoKey("j") // IN 3 (index 2)
	if got := m.evo.activeElements()[m.evo.cursor].label; got != "IN 3" {
		t.Fatalf("expected IN 3, got %q", got)
	}
	m.evoKey("l") // into OUTPUTS, same row
	if m.evo.sub != 1 {
		t.Fatalf("expected outputs subsection, got %d", m.evo.sub)
	}
	if got := m.evo.activeElements()[m.evo.cursor].label; got != "OUT 3|4" {
		t.Fatalf("row not preserved: got %q", got)
	}
	// Only two outputs: IN 4 (index 3) clamps to the last output.
	m.evoKey("h")
	m.evoKey("j")
	m.evoKey("l")
	if got := m.evo.activeElements()[m.evo.cursor].label; got != "OUT 3|4" {
		t.Fatalf("clamped row wrong: got %q", got)
	}
}

// Artist Mix off mirrors a mixer edit to every bus.
func TestEvoArtistMixMirrorsBothBuses(t *testing.T) {
	m := evoModel(t, drivers.DevEVO8, 1)
	m.evo.artistMix = false
	msg := m.evoMxSetValTo("input1", "volume", -6)()
	if a, ok := msg.(applyMsg); !ok || a.err != nil {
		t.Fatalf("apply failed: %+v", msg)
	}
	d, _ := drivers.Open(drivers.DevEVO8)
	st, _ := d.Status()
	if c := st.Mixer["input1"]; c.VolumeDb != -6 {
		t.Errorf("bus 0 not set: %+v", c)
	}
	if c := st.Mixer["input1@1"]; c.VolumeDb != -6 {
		t.Errorf("bus 1 not mirrored: %+v", c)
	}
}

// The built-in preset is always listed and can never be overwritten.
func TestEvoProtectedDefaultConfig(t *testing.T) {
	m := evoModel(t, drivers.DevEVO8, 0)
	files := m.evoScanFiles()
	if len(files) == 0 || files[0] != drivers.ProtectedConfigName+".json" {
		t.Fatalf("default preset must lead the list, got %v", files)
	}
	m.evo.mode = 1
	m.evo.fileInput = drivers.ProtectedConfigName
	if cmd := m.evoPickerKey("enter"); cmd == nil {
		t.Fatal("expected an error status cmd")
	}
	if m.evo.mode != 1 {
		t.Error("picker should stay open after refusing the default name")
	}
	if m.evo.fileInput != "" {
		t.Errorf("input should be cleared to force a new name, got %q", m.evo.fileInput)
	}
	if !m.evo.statusErr {
		t.Error("expected an error status")
	}
}

// The MIX 1|2 and MIX 3|4 markers must start in the same column: outline and
// filled triangles have different advances in some fonts.
func TestEvoMixArrowsAligned(t *testing.T) {
	m := evoModel(t, drivers.DevEVO8, 1)
	m.evo.artistMix = false // both buses are shown and must line up
	var cols []int
	for _, line := range strings.Split(stripANSI(m.View()), "\n") {
		if !strings.Contains(line, "MIX 1|2") && !strings.Contains(line, "MIX 3|4") {
			continue
		}
		for i, r := range []rune(line) {
			if r == '▶' || r == '▷' {
				cols = append(cols, i)
			}
		}
	}
	if len(cols) != 2 || cols[0] != cols[1] {
		t.Fatalf("mix markers misaligned: %v", cols)
	}
}

// "Reset all" must ask before wiping every crosspoint on every bus.
func TestEvoResetAllConfirms(t *testing.T) {
	m := evoModel(t, drivers.DevEVO8, 1)
	if cmd := m.evoMxSetValTo("input1", "volume", -6); cmd != nil {
		cmd()
	}
	read := func() float64 {
		d, _ := drivers.Open(drivers.DevEVO8)
		st, _ := d.Status()
		return st.Mixer["input1"].VolumeDb
	}
	if read() != -6 {
		t.Fatalf("setup route not written: %v", read())
	}
	if cmd := m.evoMixerKey("R"); cmd != nil {
		t.Fatal("R must open a confirmation, not reset immediately")
	}
	if m.top() != scrConfirm {
		t.Fatalf("R should push the confirm screen, top=%v", m.top())
	}
	if read() != -6 {
		t.Errorf("opening the confirmation must not reset the mixer: %v", read())
	}
	act := m.confirmAct
	if act == nil {
		t.Fatal("no pending reset action")
	}
	if cmd := act(); cmd != nil {
		cmd()
	}
	if read() != -128 {
		t.Errorf("confirmed reset did not clear the mixer: %v", read())
	}
}

// The save picker's trailing "new preset" row accepts a typed name.
func TestEvoSavePickerNewPreset(t *testing.T) {
	m := evoModel(t, drivers.DevEVO8, 0)
	m.evoKey("s")
	if m.evo.mode != 1 {
		t.Fatalf("save mode not entered: mode=%d", m.evo.mode)
	}
	for i := 0; i < len(m.evo.fileList); i++ {
		m.evoKey("down")
	}
	if !m.evo.pickerEditable() {
		t.Fatal("new-preset row must accept typing")
	}
	for _, ch := range []string{"g", "i", "g"} {
		m.evoKey(ch)
	}
	if m.evo.fileInput != "gig" {
		t.Fatalf("typed input = %q", m.evo.fileInput)
	}
	if cmd := m.evoKey("enter"); cmd != nil {
		cmd()
	}
	if m.evo.mode != 0 {
		t.Error("picker should close after saving")
	}
	if _, err := os.Stat(filepath.Join(m.evoConfigDir(), "gig.json")); err != nil {
		t.Fatalf("new preset not written: %v", err)
	}
}

// Pressing r renames the selected preset on disk, Enter commits, Esc cancels.
func TestEvoSavePickerRename(t *testing.T) {
	m := evoModel(t, drivers.DevEVO8, 0)
	dir := m.evoConfigDir()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "gig.json"), []byte("{}"), 0o644); err != nil {
		t.Fatal(err)
	}
	m.evoKey("s")
	idx := -1
	for i, f := range m.evo.fileList {
		if f == "gig.json" {
			idx = i
		}
	}
	if idx < 0 {
		t.Fatalf("gig.json not listed: %v", m.evo.fileList)
	}
	m.evo.fileCursor = idx
	if cmd := m.evoKey("r"); cmd != nil {
		t.Fatal("r must enter rename mode, not act")
	}
	if !m.evo.renaming {
		t.Fatal("rename mode not entered")
	}
	for n := len(m.evo.fileInput); n > 0; n-- {
		m.evoKey("backspace")
	}
	for _, ch := range []string{"l", "i", "v", "e"} {
		m.evoKey(ch)
	}
	if cmd := m.evoKey("enter"); cmd != nil {
		cmd()
	}
	if _, err := os.Stat(filepath.Join(dir, "live.json")); err != nil {
		t.Fatalf("rename target missing: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "gig.json")); err == nil {
		t.Error("original still present after rename")
	}
}

func (m model) driversStatus(id string) (drivers.Status, error) {
	d, err := drivers.Open(id)
	if err != nil {
		return drivers.Status{}, err
	}
	return d.Status()
}

func abs(n int) int {
	if n < 0 {
		return -n
	}
	return n
}

func stripANSI(s string) string {
	out := ""
	inEsc := false
	for _, r := range s {
		if r == 0x1b {
			inEsc = true
			continue
		}
		if inEsc {
			if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') {
				inEsc = false
			}
			continue
		}
		out += string(r)
	}
	return out
}

// The whole frame must fit the window: the picker used to be sized to the
// full height, so the frame ran 4 rows over and the vertical centering
// cropped the head of the device list (only the last rows stayed visible).
func TestFrameFitsTheWindow(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("MOSQUITOMIXBAY_EVO_DEVDIR", t.TempDir())
	for _, wh := range [][2]int{{100, 30}, {80, 24}, {120, 40}, {100, 12}} {
		m := initialModel()
		m.w, m.h = wh[0], wh[1]
		mm, _ := m.update(tea.WindowSizeMsg{Width: wh[0], Height: wh[1]})
		m = mm.(model)
		d, _ := drivers.Open(drivers.DevEVO8)
		st, _ := d.Status()
		mm2, _ := m.update(statusMsg{status: st})
		m = mm2.(model)
		v := m.View()
		lines := strings.Split(strings.TrimRight(v, "\n"), "\n")
		if len(lines) > wh[1] {
			t.Errorf("win %dx%d: frame overflows (%d lines)", wh[0], wh[1], len(lines))
		}
		if !strings.Contains(v, "Audient EVO 8") {
			t.Errorf("win %dx%d: first device missing", wh[0], wh[1])
		}
		lines0 := strings.Split(strings.TrimRight(v, "\n"), "\n")
		if !strings.HasPrefix(strings.TrimSpace(stripANSI(lines0[0])), "v1.0.0") {
			t.Errorf("win %dx%d: version not on row 0: %q", wh[0], wh[1], lines0[0])
		}
	}
}

func TestNumericDialAppliesGain(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	m := initialModel()
	m.deviceID = drivers.DevEVO8
	m.status = demoStatus(t, drivers.DevEVO8)
	if !m.startNumeric("2", "gain:input1") || !m.startNumeric("5", "gain:input1") {
		t.Fatalf("dial did not start: %q", m.numBuf)
	}
	if m.numBuf != "25" {
		t.Fatalf("dial buffer = %q, want 25", m.numBuf)
	}
}

// The devices page carries a Settings row before Close, and the settings
// page offers the connected-only filter.
func TestDevicesPageHasSettingsRow(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	m := initialModel()
	vals := map[string]bool{}
	for _, it := range m.deviceItems() {
		vals[it.Value] = true
	}
	if !vals["settings"] || !vals["quit"] {
		t.Fatalf("devices page missing settings/close rows: %v", vals)
	}
}

// The connected-only filter drops every demo interface but keeps the
// navigation rows, and the choice persists across launches.
func TestOnlineOnlyFilter(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	m := initialModel()
	m.ui.ShowOnlineOnly = true
	var shown []string
	for _, it := range m.deviceItems() {
		if it.Value == "settings" || it.Value == "quit" {
			continue
		}
		shown = append(shown, it.Value)
	}
	for _, id := range shown {
		d, _ := drivers.Open(id)
		if !d.Probe() {
			t.Errorf("offline device %q shown with the filter on", id)
		}
	}
	if err := saveUIPrefs(m.ui); err != nil {
		t.Fatal(err)
	}
	if got := loadUIPrefs(); !got.ShowOnlineOnly {
		t.Errorf("filter choice did not persist")
	}
}

// Switching EVO 4 -> EVO 8 used to leave the renderer bound to the EVO 4 spec
// while the header/layout used the EVO 8 status: the mixer then indexed a
// 4-section list at index 4 and panicked. The fresh status must rebind the
// spec, and a stale reply for a device already left must be ignored.
func TestEvoDeviceSwitchRebindsSpec(t *testing.T) {
	m := evoModel(t, drivers.DevEVO4, 1)
	st8, err := m.driversStatus(drivers.DevEVO8)
	if err != nil {
		t.Fatal(err)
	}
	m.deviceID = drivers.DevEVO8
	mm, _ := m.Update(statusMsg{dev: drivers.DevEVO8, status: st8})
	m = mm.(model)
	if m.evo.spec.ID != drivers.DevEVO8 {
		t.Fatalf("evo spec not rebound: %q", m.evo.spec.ID)
	}
	m.evo.window = 1
	_ = m.View()
}

func TestEvoStaleStatusIgnored(t *testing.T) {
	m := evoModel(t, drivers.DevEVO8, 0)
	st4, err := m.driversStatus(drivers.DevEVO4)
	if err != nil {
		t.Fatal(err)
	}
	mm, _ := m.Update(statusMsg{dev: drivers.DevEVO4, status: st4})
	m = mm.(model)
	if m.status.Spec.ID != drivers.DevEVO8 || m.evo.spec.ID != drivers.DevEVO8 {
		t.Fatalf("stale EVO 4 status was applied: status=%q spec=%q",
			m.status.Spec.ID, m.evo.spec.ID)
	}
}

// Esc out of the mixer must land on CONTROLS with the renderer in controls
// mode, not leave the mixer visible on the controls screen.
func TestEvoEscFromMixerLandsOnControls(t *testing.T) {
	m := evoModel(t, drivers.DevEVO8, 0)
	m.evo.window = 1
	m.nav = append(m.nav, scrMixer)
	mm, _ := m.Update(tea.KeyMsg{Type: tea.KeyEsc})
	m = mm.(model)
	if m.top() != scrControls || m.evo.window != 0 {
		t.Fatalf("esc left top=%v window=%d", m.top(), m.evo.window)
	}
}

// Pressing Enter on the device list clears evo.spec while status still holds
// the previous interface. With a real terminal size, View() used to draw the
// old spec's groups against an empty activeElements() list and panic with
// "index out of range [0] with length 0" before the new status arrived.
func TestEvoViewWhileSwitchingDeviceDoesNotPanic(t *testing.T) {
	for _, id := range []string{drivers.DevEVO8, drivers.DevEVO4} {
		m := evoModel(t, id, 0)
		m.w, m.h = 120, 40
		m.loading = true
		m.evo.spec = drivers.Spec{}
		_ = m.View()
		m.evo.window = 1
		m.nav = append(m.nav, scrMixer)
		_ = m.View()
	}
}

// Artist Mix shows only the selected bus. MIX 1|2 is one straight horizontal
// run; MIX 3|4 ends ON the fork (╗), with the label below and no right stub.
func TestEvoBusRouteArtistMixTrajectory(t *testing.T) {
	m := evoModel(t, drivers.DevEVO8, 1)
	m.evo.artistMix = true

	m.evo.mixBus = 0
	out := stripANSI(m.View())
	if !strings.Contains(out, "MIX 3|4") {
		t.Fatal("MIX 3|4 title must stay visible as the unselected legend")
	}
	if strings.Contains(out, "▶ MIX 3|4") {
		t.Fatal("unselected MIX 3|4 must not draw a second arrow")
	}
	if strings.Contains(out, "╗") {
		t.Fatal("MIX 1|2 must not draw a fork")
	}
	var arrowRow string
	for _, line := range strings.Split(out, "\n") {
		if strings.Contains(line, "▶ MIX 1|2") {
			arrowRow = line
		}
	}
	if arrowRow == "" {
		t.Fatal("MIX 1|2 label missing")
	}
	rs := []rune(arrowRow)
	for i, r := range rs {
		if r == '▶' {
			if i == 0 || rs[i-1] == ' ' {
				t.Fatalf("horizontal run does not reach the MIX 1|2 arrow: %q", arrowRow)
			}
			break
		}
	}

	m.evo.mixBus = 1
	out = stripANSI(m.View())
	if !strings.Contains(out, "MIX 1|2") {
		t.Fatal("MIX 1|2 title must stay visible as the unselected legend")
	}
	if strings.Contains(out, "▶ MIX 1|2") {
		t.Fatal("unselected MIX 1|2 must not draw a second arrow")
	}
	if !strings.Contains(out, "╚▶ MIX 3|4") {
		t.Fatal("MIX 3|4 label missing below the fork")
	}
	stopped := false
	for _, line := range strings.Split(out, "\n") {
		if i := strings.IndexRune(line, '╗'); i >= 0 {
			stopped = true
			rest := line[i+len("╗"):]
			if rest != "" && !strings.HasPrefix(rest, " ") {
				t.Fatalf("horizontal run must stop ON the ╗ fork, got %q", line)
			}
		}
	}
	if !stopped {
		t.Fatal("╗ fork missing for MIX 3|4")
	}
}

// The help legend always states the current Artist Mix mode.
func TestEvoArtistMixLegendState(t *testing.T) {
	m := evoModel(t, drivers.DevEVO8, 1)
	m.evo.artistMix = true
	if out := stripANSI(m.View()); !strings.Contains(out, "artist mix: on") {
		t.Fatal("legend must say artist mix: on")
	}
	m.evo.artistMix = false
	if out := stripANSI(m.View()); !strings.Contains(out, "artist mix: off") {
		t.Fatal("legend must say artist mix: off")
	}
}

// The accent separator under the tabs must be immediately followed by the
// cards: no blank row between them.
func TestEvoCardsTouchTopSeparator(t *testing.T) {
	m := evoModel(t, drivers.DevEVO8, 0)
	lines := strings.Split(stripANSI(m.View()), "\n")
	for i, line := range lines {
		if !strings.Contains(line, "CONTROLS") || !strings.Contains(line, "Audient EVO 8") {
			continue
		}
		if i+2 >= len(lines) {
			break
		}
		if !strings.Contains(lines[i+1], "─") {
			t.Fatalf("expected accent separator after tabs, got %q", lines[i+1])
		}
		if !strings.HasPrefix(strings.TrimSpace(lines[i+2]), "╭") {
			t.Fatalf("card must touch the separator, got %q", lines[i+2])
		}
		return
	}
	t.Fatal("controls header not found")
}

// The bottom accent separator must also touch the cards: no blank row between
// the last card border and the "s save" line.
func TestEvoCardsTouchBottomSeparator(t *testing.T) {
	m := evoModel(t, drivers.DevEVO8, 0)
	lines := strings.Split(stripANSI(m.View()), "\n")
	for i, line := range lines {
		if i == 0 || !strings.Contains(line, "s save") || !strings.Contains(line, "─") {
			continue
		}
		if !strings.Contains(lines[i-1], "╯") {
			t.Fatalf("bottom separator must touch the cards, got %q above %q", lines[i-1], line)
		}
		return
	}
	t.Fatal("bottom separator not found")
}
