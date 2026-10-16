// ALSA-level driver: RME Fireface UCX II, ESI UGM192, PreSonus Quantum ES 4.
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
// FireWire via snd-fireface-ctl-service. The UCX II is a USB interface and
// that service does not expose it today, so the full TotalMix crosspoint
// matrix is out of reach for now. Level 1 (this file: ALSA volumes and
// mutes) covers daily use; the matrix arrives when the kernel/ctl service
// exposes UCX II routing.
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
	FirefaceSpec = Spec{
		ID: "fireface-ucx2", Display: "RME Fireface UCX II", Vendor: "RME",
		USBVID: "0422", USBPID: "3xxx",
		NumInputs: 8, NumOutPairs: 3,
		GainMin: 0, GainMax: 65, VolMin: -96, VolMax: 0,
		MixerInputs: 8, MixerOutputs: 2,
		HasMonitor: false, Backend: BackendALSA, NeedsKmod: false,
		Caps:        Caps{Volume: true, Gain: false, Mute: true, Phantom: false, Monitor: false, Mixer: false},
		Description: "ALSA level 1 (volumes/mutes). TotalMix matrix pending kernel support.",
	}
	UGM192Spec = Spec{
		ID: "ugm192", Display: "ESI UGM192", Vendor: "ESI",
		USBVID: "0a51", USBPID: "0019",
		NumInputs: 2, NumOutPairs: 1,
		GainMin: 0, GainMax: 40, VolMin: -96, VolMax: 0,
		MixerInputs: 2, MixerOutputs: 2,
		HasMonitor: false, Backend: BackendALSA, NeedsKmod: false,
		Caps:        Caps{Volume: true, Gain: false, Mute: true, Phantom: false, Monitor: false, Mixer: false},
		Description: "Class-compliant USB. ALSA volumes only, no DSP.",
	}
	QuantumES4Spec = Spec{
		ID: "quantum-es4", Display: "PreSonus Quantum ES 4", Vendor: "PreSonus",
		USBVID: "194f", USBPID: "010d",
		NumInputs: 4, NumOutPairs: 2,
		GainMin: 0, GainMax: 60, VolMin: -96, VolMax: 0,
		MixerInputs: 4, MixerOutputs: 2,
		HasMonitor: false, Backend: BackendALSA, NeedsKmod: false,
		Caps:        Caps{Volume: true, Gain: false, Mute: true, Phantom: false, Monitor: false, Mixer: false},
		Description: "Class-compliant USB. ALSA volumes only, no DSP.",
	}
)

// alsaMatch maps a device to the card-name fragments seen in
// /proc/asound/cards and `aplay -l`.
var alsaMatch = map[string][]string{
	"fireface-ucx2": {"UCX II", "UCXII", "Fireface"},
	"ugm192":        {"UGM192", "UGM 192"},
	"quantum-es4":   {"Quantum ES", "QuantumES"},
}

type alsaDriver struct {
	spec Spec
	card int // -1 = absent
	demo *demoState
}

func newALSA(spec Spec) *alsaDriver { return &alsaDriver{spec: spec, card: -1} }

func (d *alsaDriver) Spec() Spec { return d.spec }

// Probe scans /proc/asound/cards for our USB signature.
func (d *alsaDriver) Probe() bool {
	f, err := os.Open("/proc/asound/cards")
	if err != nil {
		return false
	}
	defer f.Close()
	want := alsaMatch[d.spec.ID]
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
	for i := 0; i < d.spec.NumInputs; i++ {
		st.Inputs = append(st.Inputs, InputState{Name: fmt.Sprintf("input%d", i+1)})
	}
	for i := 0; i < d.spec.NumOutPairs; i++ {
		st.Outputs = append(st.Outputs, OutputState{Name: d.outName(i)})
	}
	return st, nil
}

func (d *alsaDriver) SetVolume(pair int, db float64) error {
	db = clamp(db, d.spec.VolMin, d.spec.VolMax)
	if !d.Probe() {
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
	for _, ctl := range []string{"Master", "PCM", "Speaker"} {
		if _, err := d.amixer("sset", ctl, fmt.Sprintf("%.0f%%", (db+96)/96*100)); err == nil {
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
