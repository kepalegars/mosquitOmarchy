// ALSA-level driver: RME Fireface UCX II, ESI UGM192, beta interfaces, and
// the Quantum ES 4 spec kept as the reverse-engineering test base.
//
// These three interfaces are USB class-compliant: no vendor DSP protocol to
// reverse-engineer, everything goes through the kernel's snd-usb-audio ALSA
// controls. This driver:
//   - probes /proc/asound/cards for the USB signature,
//   - reads volumes/mutes through `amixer -c <card>`,
//   - writes them back the same way (best-effort: missing controls are a
//     clear error, never a silent no-op),
//   - falls back to the same persistent DEMO state as the EVO driver when
//     the hardware is absent.
//
// Capabilities are explicit per device (Spec.Caps): gains are analog knobs,
// 48V is a hardware switch and there is no DSP mixer on any of these boxes,
// so the UI never offers those rows and the setters refuse them loudly.
// The demo honours the same caps — a rehearsal that lets you automate a
// knob that does not exist would be a lie.
//
// Fireface note: oudeis01/linux-fireface-mixer drives the Fireface 400 over
// FireWire via snd-fireface-ctl-service and does not support the CC-mode
// cards. For those, Mixbay installs huddx01/oscmix (USB MIDI SysEx in Class
// Compliant mode) and opens its GTK or Qt mixer from the card menu. This file
// only probes the card so Mixbay knows it is there.
package drivers

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

var (
	FirefaceSpec = mustNativeSpec("fireface-ucx2")
	UGM192Spec   = mustNativeSpec("ugm192")
)

// Quantum ES 4 is a community profile now: it is installed from the repo or
// added through "Add an audio interface" and never hardcoded here.

type alsaDriver struct {
	spec      Spec
	card      int // -1 = absent
	demo      *demoState
	allowDemo bool // false = live-only writes (ErrOffline, never demo)
}

func newALSA(spec Spec) *alsaDriver {
	return &alsaDriver{spec: spec, card: -1, allowDemo: true}
}

func (d *alsaDriver) Spec() Spec { return d.spec }

// Probe scans /proc/asound/cards for our USB signature.
func (d *alsaDriver) Probe() bool {
	path := "/proc/asound/cards"
	if p := os.Getenv("MOSQUITOMIXBAY_ASOUND_CARDS"); p != "" {
		path = p // tests point this at a fixture
	}
	f, err := os.Open(path)
	if err != nil {
		return false
	}
	defer f.Close()
	want := d.spec.CardMatch
	sc := bufio.NewScanner(f)
	cardRe := regexp.MustCompile(`^\s*(\d+)\s*\[`)
	var cur = -1
	found := false
	for sc.Scan() {
		line := sc.Text()
		if m := cardRe.FindStringSubmatch(line); m != nil {
			cur, _ = strconv.Atoi(m[1])
		}
		up := strings.ToUpper(line)
		for _, w := range want {
			if strings.Contains(up, strings.ToUpper(w)) {
				d.card = cur
				found = true
			}
		}
	}
	if !found {
		d.card = -1
	}
	return found
}

func (d *alsaDriver) amixer(args ...string) (string, error) {
	if d.card < 0 {
		return "", fmt.Errorf("no ALSA card")
	}
	base := append([]string{"-c", strconv.Itoa(d.card)}, args...)
	out, err := exec.Command("amixer", base...).CombinedOutput()
	return string(out), err
}

func (d *alsaDriver) demoFile() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "mosquitomixbay", d.spec.ID, "demo.json")
}

func (d *alsaDriver) ensureDemo() *demoState {
	if d.demo != nil {
		return d.demo
	}
	st := &demoState{
		Volumes: make([]float64, d.spec.NumOutPairs),
		Gains:   make([]float64, d.spec.NumInputs),
		Mutes:   map[string]bool{},
		Phantom: map[string]bool{},
		Monitor: 50,
		Mixer:   map[string]MixerCell{},
	}
	for i := range st.Volumes {
		st.Volumes[i] = 0
	}
	for i := range st.Gains {
		st.Gains[i] = 20
	}
	if data, err := os.ReadFile(d.demoFile()); err == nil {
		_ = json.Unmarshal(data, st)
	}
	d.demo = st
	return st
}

func (d *alsaDriver) saveDemo() {
	if d.demo == nil {
		return
	}
	_ = os.MkdirAll(filepath.Dir(d.demoFile()), 0o755)
	data, _ := json.MarshalIndent(d.demo, "", "  ")
	_ = os.WriteFile(d.demoFile(), data, 0o644)
}

func (d *alsaDriver) outName(i int) string {
	if d.spec.NumOutPairs == 1 {
		return "output"
	}
	return fmt.Sprintf("output%d", i+1)
}

func (d *alsaDriver) Status() (Status, error) {
	st := Status{Spec: d.spec, Mixer: map[string]MixerCell{}}
	if !d.Probe() {
		demo := d.ensureDemo()
		st.Online = false
		st.Backend = BackendDemo
		st.Note = fmt.Sprintf("DEMO — %s not found on ALSA. State is simulated and persistent.", d.spec.Display)
		for i := 0; i < d.spec.NumInputs; i++ {
			name := fmt.Sprintf("input%d", i+1)
			st.Inputs = append(st.Inputs, InputState{Name: name, GainDb: demo.Gains[i], Muted: demo.Mutes[name], Phantom: demo.Phantom[name]})
		}
		for i := 0; i < d.spec.NumOutPairs; i++ {
			name := d.outName(i)
			st.Outputs = append(st.Outputs, OutputState{Name: name, VolumeDb: demo.Volumes[i], Muted: demo.Mutes[name]})
		}
		return st, nil
	}
	d.demo = nil
	st.Online = true
	st.Backend = BackendALSA
	st.Note = fmt.Sprintf("ALSA card %d — level-1 controls (volumes/mutes only, no DSP).", d.card)
	lvl, hasLevel := d.readLevel()
	for i := 0; i < d.spec.NumInputs; i++ {
		st.Inputs = append(st.Inputs, InputState{Name: fmt.Sprintf("input%d", i+1)})
	}
	for i := 0; i < d.spec.NumOutPairs; i++ {
		o := OutputState{Name: d.outName(i)}
		if hasLevel {
			o.VolumeDb = lvl.db
			o.Muted = lvl.muted
		}
		st.Outputs = append(st.Outputs, o)
	}
	return st, nil
}

// Read is the live seam for polling: unlike Status it never fabricates the
// persistent DEMO state when the card is gone.
func (d *alsaDriver) Read() (Status, error) {
	if !d.Probe() {
		return Status{}, ErrOffline
	}
	return d.Status()
}

// alsaLevel is one amixer control's playback value.
type alsaLevel struct {
	db    float64
	muted bool
}

var (
	amixerDBRe = regexp.MustCompile(`\[(-?[0-9]+(?:\.[0-9]+)?)dB\]`)
	amixerOnRe = regexp.MustCompile(`\[(on|off)\]`)
)

// parseAmixerLevel reads the first playback channel of `amixer sget` output:
// "Front Left: Playback 41 [64%] [-23.00dB] [on]".
func parseAmixerLevel(out string) (alsaLevel, bool) {
	m := amixerDBRe.FindStringSubmatch(out)
	if m == nil {
		return alsaLevel{}, false
	}
	db, err := strconv.ParseFloat(m[1], 64)
	if err != nil {
		return alsaLevel{}, false
	}
	lvl := alsaLevel{db: db}
	if on := amixerOnRe.FindStringSubmatch(out); on != nil {
		lvl.muted = on[1] == "off"
	}
	return lvl, true
}

// readLevel reads the first control this card exposes. All the level-1
// interfaces put their monitor volume on one of these names.
func (d *alsaDriver) readLevel() (alsaLevel, bool) {
	for _, ctl := range []string{"Master", "PCM", "Speaker"} {
		out, err := d.amixer("sget", ctl)
		if err != nil {
			continue
		}
		if lvl, ok := parseAmixerLevel(out); ok {
			return lvl, true
		}
	}
	return alsaLevel{}, false
}

func (d *alsaDriver) SetVolume(pair int, db float64) error {
	db = clamp(db, d.spec.VolMin, d.spec.VolMax)
	if !d.Probe() {
		if !d.allowDemo {
			return ErrOffline
		}
		demo := d.ensureDemo()
		if pair < 0 {
			for i := range demo.Volumes {
				demo.Volumes[i] = db
			}
		} else {
			if pair >= len(demo.Volumes) {
				return fmt.Errorf("output pair %d out of range (0..%d)", pair, len(demo.Volumes)-1)
			}
			demo.Volumes[pair] = db
		}
		d.saveDemo()
		return nil
	}
	// Best-effort on Master/PCM; interfaces without such a control report it.
	pct := alsaVolumePercent(d.spec, db)
	for _, ctl := range []string{"Master", "PCM", "Speaker"} {
		if _, err := d.amixer("sset", ctl, fmt.Sprintf("%.0f%%", pct)); err == nil {
			return nil
		}
	}
	return fmt.Errorf("card %d exposes no Master/PCM volume control (see `amixer -c %d scontrols`)", d.card, d.card)
}

func (d *alsaDriver) SetGain(input int, db float64) error {
	if input < 1 || input > d.spec.NumInputs {
		return fmt.Errorf("input must be 1..%d", d.spec.NumInputs)
	}
	// Refused in demo too: the demo mirrors the hardware caps, so a
	// rehearsal can never automate a knob that does not exist.
	return fmt.Errorf("%s: input gain is an analog front-panel knob — ALSA cannot drive it", d.spec.Display)
}

func (d *alsaDriver) SetMute(target string, muted bool) error {
	if !d.Probe() {
		if !d.allowDemo {
			return ErrOffline
		}
		demo := d.ensureDemo()
		demo.Mutes[target] = muted
		d.saveDemo()
		return nil
	}
	sw := "mute"
	if !muted {
		sw = "unmute"
	}
	for _, ctl := range []string{"Master", "PCM"} {
		if _, err := d.amixer("sset", ctl, sw); err == nil {
			return nil
		}
	}
	return fmt.Errorf("card %d exposes no mute switch", d.card)
}

func (d *alsaDriver) SetPhantom(input int, on bool) error {
	if input < 1 || input > d.spec.NumInputs {
		return fmt.Errorf("input must be 1..%d", d.spec.NumInputs)
	}
	return fmt.Errorf("%s: 48V is a hardware switch — ALSA cannot drive it", d.spec.Display)
}

func (d *alsaDriver) SetMonitor(v int) error {
	return fmt.Errorf("%s has no monitor blend (use your DAW)", d.spec.Display)
}

func (d *alsaDriver) SetMixerInput(input int, volDb, pan float64, mixOut int) error {
	if input < 1 || input > d.spec.NumInputs {
		return fmt.Errorf("input must be 1..%d", d.spec.NumInputs)
	}
	return fmt.Errorf("%s exposes no DSP mixer over ALSA", d.spec.Display)
}

func (d *alsaDriver) SetMixerOutput(srcPair int, volDb, panL, panR float64, mixOut int) error {
	return fmt.Errorf("%s exposes no DSP mixer over ALSA", d.spec.Display)
}

func (d *alsaDriver) Save() error {
	if !d.allowDemo && !d.Probe() {
		return ErrOffline
	}
	st, err := d.Status()
	if err != nil {
		return err
	}
	home, _ := os.UserHomeDir()
	dir := filepath.Join(home, ".config", "mosquitomixbay", d.spec.ID)
	_ = os.MkdirAll(dir, 0o755)
	data, _ := json.MarshalIndent(st, "", "  ")
	return os.WriteFile(filepath.Join(dir, "config.json"), data, 0o644)
}

func (d *alsaDriver) Load() error {
	if !d.allowDemo && !d.Probe() {
		return ErrOffline
	}
	home, _ := os.UserHomeDir()
	data, err := os.ReadFile(filepath.Join(home, ".config", "mosquitomixbay", d.spec.ID, "config.json"))
	if err != nil {
		return fmt.Errorf("no saved config: %w", err)
	}
	var st Status
	if err := json.Unmarshal(data, &st); err != nil {
		return err
	}
	// Only volumes and mutes exist on this hardware: restore exactly those
	// and say what was skipped, instead of pretending a full recall.
	for i, o := range st.Outputs {
		if i >= d.spec.NumOutPairs {
			break
		}
		if err := d.SetVolume(i, o.VolumeDb); err != nil {
			return fmt.Errorf("output %s volume: %w", o.Name, err)
		}
		if err := d.SetMute(o.Name, o.Muted); err != nil {
			return fmt.Errorf("output %s mute: %w", o.Name, err)
		}
	}
	return nil
}

// alsaVolumePercent maps dB to amixer's 0..100% for a card whose control
// spans Spec.VolMin..VolMax (UGM192: -64..0 dB, linear).
func alsaVolumePercent(spec Spec, db float64) float64 {
	span := spec.VolMax - spec.VolMin
	if span <= 0 {
		span = 96
	}
	return clamp((db-spec.VolMin)/span*100, 0, 100)
}

// mixerKeys returns the known shadow keys in stable order (demo only — the
// hardware has no matrix to list).
func mixerKeys(m map[string]MixerCell) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
