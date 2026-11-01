// douze backend — Solid State Logic SSL 12 control through the douze daemon.
//
// douze (https://github.com/xenicle/douze) owns the card's vendor-specific
// USB control interface and exposes a local HTTP API on 127.0.0.1:1212:
//
//	GET  /state   → full mixer/state snapshot
//	POST /api     → one command, returns {ok, state}
//
// Mixbay never talks USB for this card. It maps the generic Driver interface
// onto douze's command vocabulary (fader/pan/mute/solo, route, master, bus,
// mon, preamp, ...). The SSL 12's preamps/48V are intentionally not exposed
// yet: `Caps.Gain/Phantom` stay false until the mapping is verified against a
// real card. The Omarchy360 overlay (douze's native front end) remains the
// complete control surface; Mixbay gives it a native entry, setup and a
// generic mixer/volume view.
package drivers

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const douzeBase = "http://127.0.0.1:1212"

var SSL12Spec = Spec{
	ID: DevSSL12, Display: "Solid State Logic SSL 12", Vendor: "SSL",
	USBVID: "31e9", USBPID: "0005",
	NumInputs: 4, NumOutPairs: 4,
	GainMin: 0, GainMax: 70, VolMin: -96, VolMax: 12,
	MixerInputs: 12, MixerOutputs: 8, // 4 analog + 4 playback pairs; 4 buses
	HasMonitor: false, Backend: BackendDouze, NeedsKmod: false,
	Version:     "v0.1.0",
	BusNames:    []string{"MONITOR", "LINE 3-4", "HP A", "HP B"},
	Caps:        Caps{Volume: true, Gain: false, Mute: true, Phantom: false, Monitor: false, Mixer: true},
	Description: "douze backend: master volumes, mutes and mixer sends. Preamps/48V and the full SSL 360 surface stay in Omarchy360.",
}

type douzeDriver struct {
	spec      Spec
	demo      *demoState
	allowDemo bool
}

func newDouze(spec Spec) *douzeDriver {
	return &douzeDriver{spec: spec, allowDemo: true}
}

func (d *douzeDriver) demoFile() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "mosquitomixbay", d.spec.ID, "demo.json")
}

func (d *douzeDriver) ensureDemo() *demoState {
	if d.demo != nil {
		return d.demo
	}
	st := &demoState{
		Volumes: make([]float64, d.spec.NumOutPairs),
		Gains:   make([]float64, d.spec.NumInputs),
		Mutes:   map[string]bool{},
		Phantom: map[string]bool{},
		Mixer:   defaultMixerCells(d.spec),
	}
	if data, err := os.ReadFile(d.demoFile()); err == nil {
		_ = json.Unmarshal(data, st)
	}
	d.demo = st
	return st
}

func (d *douzeDriver) saveDemo() {
	if d.demo == nil {
		return
	}
	_ = os.MkdirAll(filepath.Dir(d.demoFile()), 0o755)
	data, _ := json.MarshalIndent(d.demo, "", "  ")
	_ = os.WriteFile(d.demoFile(), data, 0o644)
}

func (d *douzeDriver) demoStatus(note string) Status {
	demo := d.ensureDemo()
	out := Status{Spec: d.spec, Backend: BackendDemo, Note: note, Mixer: map[string]MixerCell{}}
	for i := 0; i < d.spec.NumInputs; i++ {
		name := fmt.Sprintf("input%d", i+1)
		out.Inputs = append(out.Inputs, InputState{Name: name, GainDb: demo.Gains[i], Muted: demo.Mutes[name]})
	}
	for i := 0; i < d.spec.NumOutPairs; i++ {
		out.Outputs = append(out.Outputs, OutputState{
			Name:     douzeBusLabels[i],
			VolumeDb: demo.Volumes[i],
			Muted:    demo.Mutes[fmt.Sprintf("output%d", i+1)],
		})
	}
	for k, v := range demo.Mixer {
		out.Mixer[k] = v
	}
	return out
}

func (d *douzeDriver) Spec() Spec { return d.spec }

// douzeState is the subset of /state Mixbay needs. Unknown fields are ignored
// so a douze update cannot break the driver.
type douzeState struct {
	Channels map[string]struct {
		Fader any     `json:"fader"`
		Pan   float64 `json:"pan"`
		Mute  bool    `json:"mute"`
		Solo  bool    `json:"solo"`
	} `json:"channels"`
	Sends    map[string]map[string]any     `json:"sends"`
	SendPans map[string]map[string]float64 `json:"send_pans"`
	Masters  map[string]float64            `json:"masters"`
	BusModes map[string]map[string]bool    `json:"bus_modes"`
	Monitor  map[string]bool               `json:"monitoring"`
	Clock    []int                         `json:"_clock"`
	Device   bool                          `json:"_device"`
	Features []string                      `json:"_features"`
}

func douzeGet() (douzeState, error) {
	var st douzeState
	// Local daemon: 500 ms is plenty. A dead daemon must not freeze the TUI
	// device list, which probes every native card on selection.
	c := &http.Client{Timeout: 500 * time.Millisecond}
	r, err := c.Get(douzeBase + "/state")
	if err != nil {
		return st, err
	}
	defer r.Body.Close()
	if r.StatusCode != 200 {
		return st, fmt.Errorf("douze HTTP %d", r.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	if err != nil {
		return st, err
	}
	if err := json.Unmarshal(body, &st); err != nil {
		return st, err
	}
	return st, nil
}

func douzePost(cmd map[string]any) error {
	body, _ := json.Marshal(cmd)
	c := &http.Client{Timeout: 4 * time.Second}
	r, err := c.Post(douzeBase+"/api", "application/json", bytes.NewReader(body))
	if err != nil {
		return err
	}
	defer r.Body.Close()
	var out struct {
		OK    bool   `json:"ok"`
		Error string `json:"error"`
	}
	_ = json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&out)
	if r.StatusCode != 200 || !out.OK {
		if out.Error != "" {
			return errors.New(out.Error)
		}
		return fmt.Errorf("douze refused %v (HTTP %d)", cmd["cmd"], r.StatusCode)
	}
	return nil
}

func (d *douzeDriver) Probe() bool {
	st, err := douzeGet()
	return err == nil && st.Device
}

func faderDB(v any) float64 {
	switch x := v.(type) {
	case float64:
		return x
	case string:
		if x == "off" || x == "" {
			return -120
		}
		if f, err := strconv.ParseFloat(x, 64); err == nil {
			return f
		}
	}
	return 0
}

var douzeBuses = []string{"monitor", "line34", "hp-a", "hp-b"}
var douzeBusLabels = []string{"MONITOR", "LINE 3-4", "HP A", "HP B"}

func (d *douzeDriver) Status() (Status, error) {
	st, err := douzeGet()
	if err != nil {
		if d.allowDemo {
			return d.demoStatus("DEMO — douze offline. Set up SSL 12 from this screen, then open Omarchy360."), nil
		}
		out := Status{Spec: d.spec, Backend: BackendDouze, Mixer: map[string]MixerCell{}}
		out.Note = "douze offline."
		return out, nil
	}
	if !st.Device {
		if d.allowDemo {
			return d.demoStatus("DEMO — douze is running but the SSL 12 is not connected."), nil
		}
		out := Status{Spec: d.spec, Backend: BackendDouze, Mixer: map[string]MixerCell{}}
		out.Note = "SSL 12 not connected (douze is running)."
		return out, nil
	}
	out := Status{Spec: d.spec, Backend: BackendDouze, Mixer: map[string]MixerCell{}}
	out.Online = true
	out.Note = "douze backend — master volumes/mutes/mixer. Preamps, 48V and full SSL 360 via Omarchy360."
	if len(st.Clock) > 0 {
		out.Note += fmt.Sprintf(" Device clock %d Hz.", st.Clock[0])
	}
	for i := 0; i < d.spec.NumInputs; i++ {
		name := fmt.Sprintf("input%d", i+1)
		out.Inputs = append(out.Inputs, InputState{Name: name})
	}
	for i, bus := range douzeBuses {
		muted := false
		if bus == "monitor" {
			muted = st.Monitor["cut"]
		} else if modes, ok := st.BusModes[bus]; ok {
			muted = modes["cut"]
		}
		out.Outputs = append(out.Outputs, OutputState{
			Name:     douzeBusLabels[i],
			VolumeDb: st.Masters[bus],
			Muted:    muted,
		})
	}
	fill := func(key string, level float64, pan float64, muted bool) {
		if muted {
			level = -120
		}
		out.Mixer[key] = MixerCell{VolumeDb: level, Pan: pan}
	}
	for bus := 0; bus < len(douzeBuses); bus++ {
		for i := 0; i < d.spec.NumInputs; i++ {
			ch := strconv.Itoa(i + 1)
			key := MixerKey(fmt.Sprintf("input%d", i+1), bus)
			if bus == 0 {
				c := st.Channels[ch]
				fill(key, faderDB(c.Fader), c.Pan, c.Mute)
			} else {
				lvl := faderDB(st.Sends[ch][douzeBuses[bus]])
				pan := 0.0
				if p, ok := st.SendPans[ch][douzeBuses[bus]]; ok {
					pan = p
				}
				fill(key, lvl, pan, lvl <= -119)
			}
		}
		for pair := 0; pair < (d.spec.MixerInputs-d.spec.NumInputs)/2; pair++ {
			ch := fmt.Sprintf("pb%d%d", pair*2+1, pair*2+2)
			key := MixerKey(fmt.Sprintf("output%d_%d", pair*2+1, pair*2+2), bus)
			if bus == 0 {
				c := st.Channels[ch]
				fill(key, faderDB(c.Fader), c.Pan, c.Mute)
			} else {
				lvl := faderDB(st.Sends[ch][douzeBuses[bus]])
				pan := 0.0
				if p, ok := st.SendPans[ch][douzeBuses[bus]]; ok {
					pan = p
				}
				fill(key, lvl, pan, lvl <= -119)
			}
		}
	}
	return out, nil
}

func (d *douzeDriver) requireOnline() error {
	if !d.Probe() {
		return ErrOffline
	}
	return nil
}

func (d *douzeDriver) offlineDemo() bool {
	return !d.Probe() && d.allowDemo
}

func douzeBus(pair int) (string, error) {
	if pair < 0 || pair >= len(douzeBuses) {
		return "", fmt.Errorf("SSL 12 has no output pair %d", pair)
	}
	return douzeBuses[pair], nil
}

func (d *douzeDriver) SetVolume(pair int, db float64) error {
	if err := douzeBusCheck(pair); err != nil {
		return err
	}
	if d.offlineDemo() {
		demo := d.ensureDemo()
		demo.Volumes[pair] = db
		d.saveDemo()
		return nil
	}
	if err := d.requireOnline(); err != nil {
		return err
	}
	bus, _ := douzeBus(pair)
	return douzePost(map[string]any{"cmd": "master", "bus": bus, "db": db})
}

func douzeBusCheck(pair int) error {
	_, err := douzeBus(pair)
	return err
}

func (d *douzeDriver) SetMute(target string, muted bool) error {
	if d.offlineDemo() {
		key := target
		switch strings.ToUpper(target) {
		case "MONITOR", "OUTPUT1":
			key = "output1"
		case "LINE 3-4", "OUTPUT2":
			key = "output2"
		case "HP A", "OUTPUT3":
			key = "output3"
		case "HP B", "OUTPUT4":
			key = "output4"
		}
		d.ensureDemo().Mutes[key] = muted
		d.saveDemo()
		return nil
	}
	if err := d.requireOnline(); err != nil {
		return err
	}
	switch strings.ToUpper(target) {
	case "MONITOR", "OUTPUT1":
		return douzePost(map[string]any{"cmd": "mon", "name": "cut", "on": muted})
	case "LINE 3-4", "OUTPUT2":
		return douzePost(map[string]any{"cmd": "bus", "bus": "line34", "mode": "cut", "on": muted})
	case "HP A", "OUTPUT3":
		return douzePost(map[string]any{"cmd": "bus", "bus": "hp-a", "mode": "cut", "on": muted})
	case "HP B", "OUTPUT4":
		return douzePost(map[string]any{"cmd": "bus", "bus": "hp-b", "mode": "cut", "on": muted})
	}
	return fmt.Errorf("SSL 12: unknown mute target %q", target)
}

func (d *douzeDriver) SetGain(input int, db float64) error {
	return fmt.Errorf("SSL 12 preamp gain is not mapped in Mixbay yet — use Omarchy360")
}

func (d *douzeDriver) SetPhantom(input int, on bool) error {
	return fmt.Errorf("SSL 12 48V is not mapped in Mixbay yet — use Omarchy360")
}

func (d *douzeDriver) SetMonitor(v int) error {
	return fmt.Errorf("SSL 12 has no monitor blend")
}

func douzeSource(bus int) (string, bool) {
	// 0 = main mix (channel faders), 1..3 = aux buses.
	if bus == 0 {
		return "", true
	}
	if bus >= 1 && bus < len(douzeBuses) {
		return douzeBuses[bus], false
	}
	return "", false
}

func (d *douzeDriver) SetMixerInput(input int, volDb, pan float64, mixOut int) error {
	if input < 1 || input > d.spec.NumInputs {
		return fmt.Errorf("SSL 12 has no input %d", input)
	}
	if d.offlineDemo() {
		d.ensureDemo().Mixer[MixerKey(fmt.Sprintf("input%d", input), mixOut)] = MixerCell{VolumeDb: volDb, Pan: pan}
		d.saveDemo()
		return nil
	}
	if err := d.requireOnline(); err != nil {
		return err
	}
	ch := strconv.Itoa(input)
	bus, main := douzeSource(mixOut)
	if main {
		if err := douzePost(map[string]any{"cmd": "fader", "ch": ch, "db": volDb}); err != nil {
			return err
		}
		return douzePost(map[string]any{"cmd": "pan", "ch": ch, "pos": pan})
	}
	return douzePost(map[string]any{"cmd": "route", "ch": ch, "bus": bus, "level": volDb, "pan": pan})
}

func (d *douzeDriver) SetMixerOutput(srcPair int, volDb, panL, panR float64, mixOut int) error {
	if srcPair < 0 || srcPair >= (d.spec.MixerInputs-d.spec.NumInputs)/2 {
		return fmt.Errorf("SSL 12 has no playback pair %d", srcPair)
	}
	if d.offlineDemo() {
		key := MixerKey(fmt.Sprintf("output%d_%d", srcPair*2+1, srcPair*2+2), mixOut)
		d.ensureDemo().Mixer[key] = MixerCell{VolumeDb: volDb, Pan: (panL + panR) / 2, PanL: panL, PanR: panR}
		d.saveDemo()
		return nil
	}
	if err := d.requireOnline(); err != nil {
		return err
	}
	ch := fmt.Sprintf("pb%d%d", srcPair*2+1, srcPair*2+2)
	pan := (panL + panR) / 2
	bus, main := douzeSource(mixOut)
	if main {
		if err := douzePost(map[string]any{"cmd": "fader", "ch": ch, "db": volDb}); err != nil {
			return err
		}
		return douzePost(map[string]any{"cmd": "pan", "ch": ch, "pos": pan})
	}
	return douzePost(map[string]any{"cmd": "route", "ch": ch, "bus": bus, "level": volDb, "pan": pan})
}

func (d *douzeDriver) Save() error {
	if d.offlineDemo() {
		d.ensureDemo()
		d.saveDemo()
		return nil
	}
	if err := d.requireOnline(); err != nil {
		return err
	}
	return douzePost(map[string]any{"cmd": "profile-save", "name": "mixbay"})
}

func (d *douzeDriver) Load() error {
	if d.offlineDemo() {
		d.demo = nil
		d.ensureDemo()
		return nil
	}
	if err := d.requireOnline(); err != nil {
		return err
	}
	return douzePost(map[string]any{"cmd": "profile-load", "name": "mixbay"})
}
