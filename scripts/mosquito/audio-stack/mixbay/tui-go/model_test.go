package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"mosquitomarchy.local/mosquitomixbay-tui/drivers"
	"mosquitomarchy.local/mosquitomixbay-tui/meters"
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

// Selected and unselected MIX titles must start on the same column. The old
// unselected branch omitted the arrow cell entirely, so its title drifted two
// columns left.
func TestEvoMixTitlesKeepSameColumn(t *testing.T) {
	for _, artist := range []bool{true, false} {
		for _, bus := range []int{0, 1} {
			m := evoModel(t, drivers.DevEVO8, 1)
			m.evo.artistMix = artist
			m.evo.mixBus = bus
			cols := map[string]int{}
			for _, line := range strings.Split(stripANSI(m.View()), "\n") {
				rs := []rune(line)
				for _, title := range []string{"MIX 1|2", "MIX 3|4"} {
					tr := []rune(title)
					for i := 0; i+len(tr) <= len(rs); i++ {
						if string(rs[i:i+len(tr)]) == title {
							cols[title] = i
							break
						}
					}
				}
			}
			if len(cols) != 2 {
				t.Fatalf("artist=%v bus=%d: missing MIX titles: %v", artist, bus, cols)
			}
			if cols["MIX 1|2"] != cols["MIX 3|4"] {
				t.Fatalf("artist=%v bus=%d: titles misaligned: %v", artist, bus, cols)
			}
		}
	}
}

// The bus route keeps evotui's vertical drops: ╦/╧ mark the strip boundaries
// that actually feed the selected bus, while inactive strips stay a plain ═.
func TestEvoBusKeepsVerticalTicks(t *testing.T) {
	m := evoModel(t, drivers.DevEVO8, 1)
	m.evo.artistMix = true
	m.evo.mixBus = 1
	// Open one input and one playback send on bus 1: the ticks mark actual
	// sends, so a silent bus must not draw them.
	m.status.Mixer[drivers.MixerKey("input2", 1)] = drivers.MixerCell{VolumeDb: -6}
	m.status.Mixer[drivers.MixerKey("output1_2", 1)] = drivers.MixerCell{VolumeDb: -6, PanL: -100, PanR: 100}
	out := stripANSI(m.View())
	if !strings.Contains(out, "╦") || !strings.Contains(out, "╧") {
		t.Fatalf("bus route lost its vertical ticks:\n%s", out)
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

// Renaming must work from the LOAD picker too, and keep the picker open.
func TestEvoLoadPickerRename(t *testing.T) {
	m := evoModel(t, drivers.DevEVO8, 0)
	dir := m.evoConfigDir()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "gig.json"), []byte("{}"), 0o644); err != nil {
		t.Fatal(err)
	}
	m.evoKey("o")
	if m.evo.mode != 2 {
		t.Fatalf("load mode not entered: %d", m.evo.mode)
	}
	for i, f := range m.evo.fileList {
		if f == "gig.json" {
			m.evo.fileCursor = i
		}
	}
	if cmd := m.evoKey("r"); cmd != nil {
		t.Fatal("r must only enter rename mode")
	}
	if !m.evo.renaming {
		t.Fatal("rename mode not entered from LOAD")
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
	if m.evo.mode != 2 {
		t.Errorf("LOAD picker closed after rename: mode=%d", m.evo.mode)
	}
	if _, err := os.Stat(filepath.Join(dir, "live.json")); err != nil {
		t.Fatalf("rename target missing: %v", err)
	}
	if !contains(m.evo.fileList, "live.json") {
		t.Errorf("renamed file not rescanned: %v", m.evo.fileList)
	}
}

// d on the LOAD picker deletes after confirmation and refreshes the list.
func TestEvoLoadPickerDelete(t *testing.T) {
	m := evoModel(t, drivers.DevEVO8, 0)
	dir := m.evoConfigDir()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "gig.json")
	if err := os.WriteFile(path, []byte("{}"), 0o644); err != nil {
		t.Fatal(err)
	}
	m.evoKey("o")
	for i, f := range m.evo.fileList {
		if f == "gig.json" {
			m.evo.fileCursor = i
		}
	}
	if cmd := m.evoKey("d"); cmd != nil {
		t.Fatal("d must open a confirmation, not delete immediately")
	}
	if m.top() != scrConfirm {
		t.Fatalf("d should push the confirm screen, top=%v", m.top())
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatal("file deleted before confirmation")
	}
	next, cmd := m.Update(tuikit.ConfirmResultMsg{Yes: true})
	m = next.(model)
	if cmd == nil {
		t.Fatal("confirm should delete")
	}
	next, _ = m.Update(cmd())
	m = next.(model)
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("preset still present after delete: %v", err)
	}
	if contains(m.evo.fileList, "gig.json") {
		t.Errorf("deleted preset still listed: %v", m.evo.fileList)
	}
	if m.evo.mode != 2 {
		t.Errorf("delete closed the LOAD picker: mode=%d", m.evo.mode)
	}
}

func TestEvoLoadPickerCannotDeleteDefault(t *testing.T) {
	m := evoModel(t, drivers.DevEVO8, 0)
	m.evoKey("o")
	m.evo.fileCursor = 0
	if cmd := m.evoKey("d"); cmd == nil {
		t.Fatal("expected a read-only refusal")
	}
	if m.top() == scrConfirm {
		t.Fatal("default preset must not reach the delete confirmation")
	}
}

func contains(list []string, want string) bool {
	for _, v := range list {
		if v == want {
			return true
		}
	}
	return false
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
		if !strings.HasPrefix(strings.TrimSpace(stripANSI(lines0[0])), "v"+appVersion) {
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

// The devices page carries Settings then the patchbay before Close, and the
// settings page keeps only interface preferences.
func TestDevicesPageHasSettingsRow(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	m := initialModel()
	vals := map[string]bool{}
	for _, it := range m.deviceItems() {
		vals[it.Value] = true
	}
	if !vals["settings"] || !vals["patchbay"] || !vals["quit"] {
		t.Fatalf("devices page missing settings/patchbay/close rows: %v", vals)
	}
	for _, it := range m.settingsItems() {
		if it.Value == "patchbay" {
			t.Fatal("patchbay must live on the main menu, not Settings")
		}
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
		if it.Value == "settings" || it.Value == "patchbay" || it.Value == "quit" {
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

// The top separator stays glued to the cards, but the bottom one keeps one
// clear row: status notifications (Artist Mix, save errors, …) land there and
// must not overwrite the card borders.
func TestEvoBottomSpacerForNotifications(t *testing.T) {
	m := evoModel(t, drivers.DevEVO8, 0)
	lines := strings.Split(stripANSI(m.View()), "\n")
	for i, line := range lines {
		if i < 2 || !strings.Contains(line, "s save") || !strings.Contains(line, "─") {
			continue
		}
		j := i - 1
		for j >= 0 && strings.TrimSpace(lines[j]) == "" {
			j--
		}
		if j == i-1 {
			t.Fatalf("cards must not touch the bottom separator: %q", line)
		}
		if !strings.Contains(lines[j], "╯") {
			t.Fatalf("expected the card bottom above the notification spacer, got %q", lines[j])
		}
		return
	}
	t.Fatal("bottom separator not found")
}

// The modifier table is the single source of the value-editing rules.
func TestEvoAdjustKeyTable(t *testing.T) {
	cases := []struct {
		key    string
		dir    int
		coarse bool
		ok     bool
	}{
		{"ctrl+left", -1, true, true},
		{"ctrl+right", 1, true, true},
		{"ctrl+h", -1, true, true},
		{"ctrl+l", 1, true, true},
		{"ctrl+shift+left", -1, false, true},
		{"ctrl+shift+right", 1, false, true},
		{"left", 0, false, false},
		{"h", 0, false, false},
		{"ctrl+up", 0, false, false},
	}
	for _, c := range cases {
		dir, coarse, ok := evoAdjustKey(c.key)
		if dir != c.dir || coarse != c.coarse || ok != c.ok {
			t.Errorf("%q: got (%d,%v,%v), want (%d,%v,%v)", c.key, dir, coarse, ok, c.dir, c.coarse, c.ok)
		}
	}
	for _, c := range []struct {
		param  string
		coarse bool
		want   float64
	}{
		{"volume", true, evoCoarseDb},
		{"volume", false, evoFineDb},
		{"input1", true, evoCoarseDb},
		{"pan", true, evoCoarsePan},
		{"pan", false, evoFinePan},
		{"pan_l", true, evoCoarsePan},
		{"pan_r", false, evoFinePan},
	} {
		if got := evoAdjustStep(c.param, c.coarse); got != c.want {
			t.Errorf("step(%q, coarse=%v) = %v, want %v", c.param, c.coarse, got, c.want)
		}
	}
}

// Ctrl edits the selected value; Ctrl+Shift takes the fine step. Plain arrows
// keep navigating and must not change a value.
func TestEvoCtrlAdjustsSelectedValue(t *testing.T) {
	m := evoModel(t, drivers.DevEVO8, 0)
	e := m.evo.activeElements()[m.evo.cursor]
	if e.key != "input1" {
		t.Fatalf("expected IN 1 selected, got %q", e.key)
	}
	apply := func(k string) drivers.Status {
		t.Helper()
		cmd := m.evoKey(k)
		if cmd == nil {
			t.Fatalf("%q returned no command", k)
		}
		if msg, ok := cmd().(applyMsg); !ok || msg.err != nil {
			t.Fatalf("%q apply failed: %+v", k, msg)
		}
		d, _ := drivers.Open(drivers.DevEVO8)
		st, err := d.Status()
		if err != nil {
			t.Fatal(err)
		}
		m.status = st
		return st
	}
	if st := apply("ctrl+right"); st.Inputs[0].GainDb != 5 {
		t.Errorf("Ctrl+Right gain = %v, want 5", st.Inputs[0].GainDb)
	}
	if st := apply("ctrl+shift+right"); st.Inputs[0].GainDb != 6 {
		t.Errorf("Ctrl+Shift+Right gain = %v, want 6", st.Inputs[0].GainDb)
	}
	if st := apply("ctrl+left"); st.Inputs[0].GainDb != 1 {
		t.Errorf("Ctrl+Left gain = %v, want 1", st.Inputs[0].GainDb)
	}
	// A plain arrow only moves the cursor.
	before := m.status.Inputs[0].GainDb
	m.evoKey("right")
	if m.status.Inputs[0].GainDb != before {
		t.Errorf("plain arrow changed the value: %v -> %v", before, m.status.Inputs[0].GainDb)
	}
}

func TestEvoPanUsesWiderSteps(t *testing.T) {
	m := evoModel(t, drivers.DevEVO8, 1)
	m.evo.mxSection, m.evo.mxParam = 0, 0 // input1, pan
	apply := func(k string) {
		t.Helper()
		cmd := m.evoKey(k)
		if cmd == nil {
			t.Fatalf("%q returned no command", k)
		}
		if msg, ok := cmd().(applyMsg); !ok || msg.err != nil {
			t.Fatalf("%q apply failed: %+v", k, msg)
		}
		d, _ := drivers.Open(drivers.DevEVO8)
		st, _ := d.Status()
		m.status = st
	}
	apply("ctrl+right")
	if got := m.status.Mixer["input1"].Pan; got != 25 {
		t.Errorf("Ctrl+Right pan = %v, want 25", got)
	}
	apply("ctrl+shift+right")
	if got := m.status.Mixer["input1"].Pan; got != 30 {
		t.Errorf("Ctrl+Shift+Right pan = %v, want 30", got)
	}
}

func TestEvoPollGating(t *testing.T) {
	m := evoModel(t, drivers.DevEVO8, 0)
	if !m.shouldPoll() {
		t.Fatal("focused EVO controls should poll")
	}
	m.focused = false
	if m.shouldPoll() {
		t.Fatal("blurred app must not read hardware")
	}
	m.focused = true
	m.nav = []screen{scrDevices}
	if m.shouldPoll() {
		t.Fatal("devices screen must not poll")
	}
	m.nav = []screen{scrDevices, scrControls}
	m.evo.mode = 1
	if m.shouldPoll() {
		t.Fatal("open picker must not poll")
	}
}

func TestEvoPollDropsStaleStatus(t *testing.T) {
	m := evoModel(t, drivers.DevEVO8, 0)
	m.session.dataGen = 2
	stale := m.status
	stale.Note = "stale"
	mm, _ := m.update(statusMsg{dev: m.deviceID, status: stale, quiet: true, gen: 1})
	if got := mm.(model).status.Note; got == "stale" {
		t.Fatal("a poll requested before the last write must be dropped")
	}
	fresh := m.status
	fresh.Note = "fresh"
	mm, _ = m.update(statusMsg{dev: m.deviceID, status: fresh, quiet: true, gen: 2})
	if got := mm.(model).status.Note; got != "fresh" {
		t.Fatalf("current poll should apply, got note %q", got)
	}
}

// establishLive pushes a real hardware status into the session.
func establishLive(t *testing.T, m model) model {
	t.Helper()
	live := m.status
	live.Online = true
	live.Backend = drivers.BackendEvoRaw
	mm, _ := m.update(statusMsg{dev: m.deviceID, status: live, quiet: true, gen: m.session.beginRead()})
	return mm.(model)
}

// Losing the interface mid-session freezes the last known values instead of
// replacing the panel with DEMO state. A later demo refresh must not demote
// the live session either.
func TestEvoOfflineFreezesValues(t *testing.T) {
	m := establishLive(t, evoModel(t, drivers.DevEVO8, 0))
	before := m.status.Inputs[0].GainDb
	mm, _ := m.update(statusMsg{dev: m.deviceID, err: drivers.ErrOffline, quiet: true, gen: m.session.beginRead()})
	got := mm.(model)
	if got.status.Online {
		t.Fatal("status should be marked offline")
	}
	if got.status.Inputs[0].GainDb != before {
		t.Errorf("values should freeze at %v, got %v", before, got.status.Inputs[0].GainDb)
	}
	if !strings.Contains(got.status.Note, "offline") {
		t.Errorf("offline note missing: %q", got.status.Note)
	}
	demo := got.status
	demo.Backend = drivers.BackendDemo
	demo.Online = false
	demo.Note = "DEMO — should be ignored"
	demo.Inputs = append([]drivers.InputState(nil), got.status.Inputs...)
	demo.Inputs[0].GainDb = before + 10
	mm, _ = got.update(statusMsg{dev: got.deviceID, status: demo, quiet: true, gen: got.session.beginRead(), demo: true})
	got = mm.(model)
	if got.status.Note != "interface offline — last known values; retrying" {
		t.Fatalf("a demo refresh demoted the live session: %q", got.status.Note)
	}
	if got.status.Inputs[0].GainDb != before {
		t.Errorf("demo refresh changed frozen values: %v", got.status.Inputs[0].GainDb)
	}
}

func TestEvoOfflineRefusesWrites(t *testing.T) {
	m := establishLive(t, evoModel(t, drivers.DevEVO8, 0))
	mm, _ := m.update(statusMsg{dev: m.deviceID, err: drivers.ErrOffline, quiet: true, gen: m.session.beginRead()})
	m = mm.(model)
	if cmd := m.evoKey("ctrl+right"); cmd == nil {
		t.Fatal("offline adjustment should still return a status tick")
	}
	if !strings.Contains(m.evo.statusMsg, "offline") {
		t.Errorf("expected an offline refusal, got %q", m.evo.statusMsg)
	}
}

// The footer must spell out both modifier steps, on both devices and for the
// mixer's wider pan steps; a clipped line would hide the explanation.
func TestEvoLegendExplainsModifierSteps(t *testing.T) {
	for _, id := range []string{drivers.DevEVO8, drivers.DevEVO4} {
		m := evoModel(t, id, 0)
		out := stripANSI(m.View())
		want := []string{"Ctrl+←→ ±5", "Ctrl+Shift+←→ ±1", "0-9 dial", "↑↓/jk row"}
		if id == drivers.DevEVO8 {
			want = append(want, "P 48V")
		}
		for _, needle := range want {
			if !strings.Contains(out, needle) {
				t.Errorf("%s controls legend missing %q", id, needle)
			}
		}
		m = evoModel(t, id, 1)
		out = stripANSI(m.View())
		want = []string{"Ctrl+←→ ±5", "Ctrl+Shift+←→ ±1", "Space pan/vol", "0-9 dial"}
		if id == drivers.DevEVO8 {
			want = append(want, "R all")
		}
		for _, needle := range want {
			if !strings.Contains(out, needle) {
				t.Errorf("%s mixer legend missing %q", id, needle)
			}
		}
	}
	m := evoModel(t, drivers.DevEVO8, 1)
	m.evo.mxSection, m.evo.mxParam = 0, 0 // pan
	m.evo.artistMix = true
	out := stripANSI(m.View())
	for _, needle := range []string{"Ctrl+←→ ±25", "Ctrl+Shift+←→ ±5", "artist mix: on"} {
		if !strings.Contains(out, needle) {
			t.Errorf("EVO8 pan legend missing %q", needle)
		}
	}
}

// The TUI routes writes through the session: once hardware answered, the
// write uses OpenLive and fails instead of updating DEMO after an unplug.
func TestLiveApplyRefusesOffline(t *testing.T) {
	m := evoModel(t, drivers.DevEVO8, 0)
	m.session.live = true
	msg, ok := m.applyCmd(m.deviceID, func(d drivers.Driver) error {
		return d.SetVolume(0, -12)
	}, "")().(applyMsg)
	if !ok {
		t.Fatal("applyCmd did not return applyMsg")
	}
	if !errors.Is(msg.err, drivers.ErrOffline) {
		t.Fatalf("err = %v, want ErrOffline", msg.err)
	}
}

// The Levels screen is the explicit USB meter view. It must name both capture
// streams and never pretend the analog OUT controls are being measured.
func TestEvoLevelsScreenRendersUSBStreams(t *testing.T) {
	m := evoModel(t, drivers.DevEVO8, 0)
	m.meterSnap = meters.Snapshot{
		Input:    []float64{0.1, 0.2, 0.3, 0.4, 0.5, 0.6},
		Playback: []float64{0.2, 0.2, 0.4, 0.4, 0.6, 0.6},
		Peaks: map[string][]float64{
			meters.KeyInput:    {0.2, 0.3, 0.4, 0.5, 0.6, 0.7},
			meters.KeyPlayback: {0.3, 0.3, 0.5, 0.5, 0.7, 0.7},
		},
	}
	copy(m.meterPeakIn[:], m.meterSnap.Peaks[meters.KeyInput])
	copy(m.meterPeakOut[:], m.meterSnap.Peaks[meters.KeyPlayback])
	m.nav = append(m.nav, scrLevels)
	plain := stripANSI(m.View())
	for _, needle := range []string{"CAPTURE", "PLAYBACK", "PC 1|2", "LOOP 5|6", "analog OUT not metered"} {
		if !strings.Contains(plain, needle) {
			t.Errorf("levels view missing %q", needle)
		}
	}
	if strings.Contains(plain, "[M]") {
		t.Error("mute legend must be lowercase [m]")
	}
}

// Quiet hardware polls ramp the displayed value; a local write (non-quiet
// refresh) must not animate.
func TestEvoHardwareValuesRamp(t *testing.T) {
	m := evoModel(t, drivers.DevEVO8, 0)
	old := m.status
	cur, err := m.driversStatus(drivers.DevEVO8)
	if err != nil {
		t.Fatal(err)
	}
	cur.Inputs[0].GainDb = old.Inputs[0].GainDb + 20
	cur.Online = true
	m.status = cur
	if !m.startEvoRamps(old, cur) {
		t.Fatal("changed gain must start a ramp")
	}
	e := evoElement{key: "input1"}
	if got := m.evoDisplayElem(e); got != old.Inputs[0].GainDb {
		t.Fatalf("ramp starts at %v, want %v", got, old.Inputs[0].GainDb)
	}
	if m.evo.tickAnims(time.Now().Add(evoAnimDur + time.Millisecond)) {
		t.Fatal("ramp must finish")
	}
	if got := m.evoDisplayElem(e); got != cur.Inputs[0].GainDb {
		t.Fatalf("ramp ends at %v, want %v", got, cur.Inputs[0].GainDb)
	}
	m.status = old
	if m.startEvoRamps(old, old) {
		t.Fatal("unchanged status must not animate")
	}
}

func TestEvoRenameCaretMovesAndEdits(t *testing.T) {
	m := evoModel(t, drivers.DevEVO8, 0)
	m.evo.mode = 1
	m.evo.fileInput = "ac"
	m.evo.fileCursor = len(m.evo.fileList)
	m.evo.caretPos = 1
	m.evoKey("b")
	if m.evo.fileInput != "abc" || m.evo.caretPos != 2 {
		t.Fatalf("insert = %q pos %d", m.evo.fileInput, m.evo.caretPos)
	}
	m.evoKey("left")
	m.evoKey("backspace")
	if m.evo.fileInput != "bc" || m.evo.caretPos != 0 {
		t.Fatalf("left/backspace = %q pos %d", m.evo.fileInput, m.evo.caretPos)
	}
	m.evoKey("end")
	m.evoKey("delete")
	if m.evo.fileInput != "bc" || m.evo.caretPos != 2 {
		t.Fatalf("end/delete = %q pos %d", m.evo.fileInput, m.evo.caretPos)
	}
}

func TestAllowNativeVolumeSettingPersists(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	old := levelsGuardEnabled
	levelsGuardEnabled = func() bool { return true }
	t.Cleanup(func() { levelsGuardEnabled = old })
	m := initialModel()
	m.ui.ShowOnlineOnly = true
	m.push(scrSettings)
	m.syncPicker()
	m.picker = m.picker.SelectValue("allow_native")
	nm, _ := m.updateKey(tea.KeyMsg{Type: tea.KeyEnter})
	m = nm.(model)
	got := loadUIPrefs()
	if !got.AllowNativeVolume {
		t.Fatal("allow_native_volume must persist")
	}
	if !got.ShowOnlineOnly {
		t.Fatal("toggling native volume must not reset the online filter")
	}
}

func TestEvoMuteLegendIsLowercase(t *testing.T) {
	m := evoModel(t, drivers.DevEVO8, 0)
	m.status.Inputs[0].Muted = true
	plain := stripANSI(m.View())
	if strings.Contains(plain, "[M]") {
		t.Fatal("mute legend must not use uppercase [M]")
	}
	if !strings.Contains(plain, "[m]") {
		t.Fatal("mute legend [m] missing")
	}
}

func TestAllowNativeVolumeNeedsLevelsGuard(t *testing.T) {
	old := levelsGuardEnabled
	levelsGuardEnabled = func() bool { return false }
	t.Cleanup(func() { levelsGuardEnabled = old })
	m := initialModel()
	m.push(scrSettings)
	m.syncPicker()
	for _, it := range m.picker.Items() {
		if it.Value == "allow_native" {
			if !it.Disabled {
				t.Fatal("allow_native must be disabled without mosquito.levels-guard")
			}
			return
		}
	}
	t.Fatal("allow_native row missing")
}
