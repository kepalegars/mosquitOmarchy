package main

import (
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
