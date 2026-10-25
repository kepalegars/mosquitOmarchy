// Package drivers is the hardware abstraction of mosquitomixbay.
//
// One Driver per supported interface. The TUI and the CLI actions both talk
// to this interface only, so adding a device means adding one file here,
// never touching the UI.
//
// Device roadmap:
//   - evo8 / evo4  : full control via evo_raw kmod (/dev/evo* ioctl).
//     Protocol reverse-engineered by vanzaho/audient-evo-py (public domain).
//     EVO 8 is the reference device: 4 inputs (gain 0..58 dB card scale;
//     FU11 wire is -8..50 dB), 2 output
//     pairs (-96..0 dB), 10x4 loopback matrix over 2 mix buses, no monitor
//     blend knob (monitoring goes through the matrix).
//   - fireface-ucx2: RME Fireface UCX II. Level 1 = ALSA volumes + mutes
//     (works today, class-compliant). Level 2 = full TotalMix matrix once
//     snd-fireface-ctl-services supports the UCX II over USB.
//   - ugm192       : ESI UGM192, class-compliant, no vendor DSP → ALSA only.
//   - quantum-es4  : PreSonus Quantum ES 4, class-compliant → ALSA only.
//
// With no hardware connected every driver reports Online=false and serves a
// persistent DEMO state (same JSON shape), so the TUI is fully usable for
// development and for live-mode rehearsals without the interface plugged in.
package drivers

import (
	"errors"
	"fmt"
)

// ErrOffline says the hardware is not reachable. Status() keeps its DEMO
// fallback for the CLI and deliberate demo mode; Read() returns this instead.
var ErrOffline = errors.New("device offline")

// Device IDs. Stable: used in config paths, CLI flags and live-mode hooks.
const (
	DevEVO8       = "evo8"
	DevEVO4       = "evo4"
	DevFireface   = "fireface-ucx2"
	DevUGM192     = "ugm192"
	DevQuantumES4 = "quantum-es4"
)

// Backend names a control transport.
type Backend string

const (
	BackendEvoRaw Backend = "evo-raw" // /dev/evo* ioctl (kmod)
	BackendALSA   Backend = "alsa"    // amixer / ALSA controls
	BackendDemo   Backend = "demo"    // simulated, persistent
)

// Caps advertises what a device can actually do. The UI only offers capped
// rows and the drivers refuse the rest with a clear error — an ALSA box must
// never show a gain slider for an analog knob, and a demo must behave like
// the hardware it stands in for.
type Caps struct {
	Volume  bool `json:"volume"`
	Gain    bool `json:"gain"`
	Mute    bool `json:"mute"`
	Phantom bool `json:"phantom_48v"`
	Monitor bool `json:"monitor_blend"`
	Mixer   bool `json:"mixer"`
}

// Spec describes one supported interface.
type Spec struct {
	ID           string  `json:"id"`
	Display      string  `json:"display"`
	Vendor       string  `json:"vendor"`
	USBVID       string  `json:"usb_vid"`
	USBPID       string  `json:"usb_pid"`
	NumInputs    int     `json:"num_inputs"`
	NumOutPairs  int     `json:"num_output_pairs"`
	GainMin      float64 `json:"gain_min_db"`
	GainMax      float64 `json:"gain_max_db"`
	GainOffset   float64 `json:"gain_offset_db"`
	VolMin       float64 `json:"vol_min_db"`
	VolMax       float64 `json:"vol_max_db"`
	MixerInputs  int     `json:"mixer_inputs"`
	MixerOutputs int     `json:"mixer_outputs"`
	HasMonitor   bool    `json:"has_monitor"`
	Backend      Backend `json:"backend"`
	NeedsKmod    bool    `json:"needs_kmod"`
	Description  string  `json:"description"`
	Caps         Caps    `json:"caps"`
}

// InputState is one mic/line input.
type InputState struct {
	Name    string  `json:"name"`
	GainDb  float64 `json:"gain_db"`
	Muted   bool    `json:"muted"`
	Phantom bool    `json:"phantom_48v"`
}

// OutputState is one stereo output pair.
type OutputState struct {
	Name     string  `json:"name"`
	VolumeDb float64 `json:"volume_db"`
	Muted    bool    `json:"muted"`
}

// MixerCell is one source → mix-bus route (loopback mixer, write-only on
// hardware, shadowed in software — same as audient-evo-py). Inputs carry a
// mono Pan; stereo loopback sources carry separate PanL/PanR (as upstream's
// pan_l/pan_r do), with Pan kept as their mean for the CLI and old shadows.
type MixerCell struct {
	VolumeDb float64 `json:"volume_db"`
	Pan      float64 `json:"pan"` // -100..+100
	PanL     float64 `json:"pan_l,omitempty"`
	PanR     float64 `json:"pan_r,omitempty"`
}

// Status is the full readable state of one device.
type Status struct {
	Spec    Spec                 `json:"spec"`
	Online  bool                 `json:"online"`
	Backend Backend              `json:"backend_in_use"`
	Inputs  []InputState         `json:"inputs"`
	Outputs []OutputState        `json:"outputs"`
	Monitor *int                 `json:"monitor,omitempty"` // EVO4 blend 0..100
	Mixer   map[string]MixerCell `json:"mixer"`
	Note    string               `json:"note,omitempty"`
}

// Driver is the single interface the UI and CLI use.
type Driver interface {
	Spec() Spec
	// Probe reports whether real hardware is reachable right now.
	Probe() bool
	// Status reads the full state (real or demo).
	Status() (Status, error)
	SetVolume(pair int, db float64) error
	SetGain(input int, db float64) error
	SetMute(target string, muted bool) error
	SetPhantom(input int, on bool) error
	SetMonitor(v int) error
	SetMixerInput(input int, volDb, pan float64, mixOut int) error
	SetMixerOutput(srcPair int, volDb, panL, panR float64, mixOut int) error
	Save() error
	Load() error
}

// LiveReader is a driver that can separate a real hardware read from the DEMO
// fallback. Read() never fabricates state: it returns ErrOffline when the
// interface is gone, so the caller can freeze the last real values.
type LiveReader interface {
	Read() (Status, error)
}

// Registry lists every supported device, EVO 8 first (the owner's hardware).
func Registry() []Spec {
	return []Spec{EVO8Spec, EVO4Spec, FirefaceSpec, UGM192Spec, QuantumES4Spec}
}

// Open returns the driver for id. Unknown ids are an error (fail loud, the
// TUI device list only ever offers Registry ids).
func Open(id string) (Driver, error) {
	switch id {
	case DevEVO8:
		return newEvo(EVO8Spec), nil
	case DevEVO4:
		return newEvo(EVO4Spec), nil
	case DevFireface:
		return newALSA(FirefaceSpec), nil
	case DevUGM192:
		return newALSA(UGM192Spec), nil
	case DevQuantumES4:
		return newALSA(QuantumES4Spec), nil
	}
	return nil, fmt.Errorf("unknown device %q", id)
}

// OpenLive opens the driver for a control write that must reach real
// hardware. DEMO fallback is disabled: a vanished interface returns
// ErrOffline instead of silently updating the persistent demo state.
func OpenLive(id string) (Driver, error) {
	d, err := Open(id)
	if err != nil {
		return nil, err
	}
	switch v := d.(type) {
	case *evoDriver:
		v.allowDemo = false
	case *alsaDriver:
		v.allowDemo = false
	}
	if !d.Probe() {
		return nil, ErrOffline
	}
	return d, nil
}

// MixerKey names one shadow cell: "inputN" or "outputX_Y" on bus 0, with an
// "@bus" suffix for the other buses. Bus 0 keeps the historical bare key so
// existing shadows keep working.
func MixerKey(src string, bus int) string {
	if bus <= 0 {
		return src
	}
	return fmt.Sprintf("%s@%d", src, bus)
}

// MixBuses counts the stereo mix buses of a device (MIX 1|2, MIX 3|4…).
func MixBuses(spec Spec) int {
	if n := spec.MixerOutputs / 2; n >= 1 {
		return n
	}
	return 1
}

// BusLabel names a mix bus the way the hardware prints it.
func BusLabel(bus int) string {
	return fmt.Sprintf("MIX %d|%d", bus*2+1, bus*2+2)
}

// MixerSources lists every loopback source key for one bus, in stable order:
// hardware inputs first, then loopback playback pairs — the evotui order.
func MixerSources(spec Spec, bus int) []string {
	var out []string
	for i := 0; i < spec.NumInputs; i++ {
		out = append(out, MixerKey(fmt.Sprintf("input%d", i+1), bus))
	}
	for i := 0; i < (spec.MixerInputs-spec.NumInputs)/2; i++ {
		out = append(out, MixerKey(fmt.Sprintf("output%d_%d", i*2+1, i*2+2), bus))
	}
	return out
}
