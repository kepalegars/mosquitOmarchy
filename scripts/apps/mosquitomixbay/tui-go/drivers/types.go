// Package drivers is the hardware abstraction of mosquitomixbay.
//
// One Driver per supported interface. The TUI and the CLI actions both talk
// to this interface only, so adding a device (UGM192, Quantum ES 4, …) means
// adding one file here, never touching the UI.
//
// Device roadmap:
//   - evo8 / evo4  : full control via evo_raw kmod (/dev/evo* ioctl).
//     Protocol reverse-engineered by vanzaho/audient-evo-py (public domain),
//     which this file ports to Go. See evo.go.
//   - fireface-ucx2: RME Fireface UCX II. Level 1 = ALSA volumes + PipeWire
//     profile (works today, class-compliant). Level 2 = full TotalMix matrix
//     once snd-fireface-ctl-services supports the UCX II over USB
//     (today it only drives the Fireface 400 over FireWire — see
//     oudeis01/linux-fireface-mixer). See alsa.go.
//   - ugm192       : ESI UGM192, class-compliant, no vendor DSP → ALSA only.
//   - quantum-es4  : PreSonus Quantum ES 4, class-compliant → ALSA only.
//
// With no hardware connected every driver reports Online=false and serves a
// persistent DEMO state (same JSON shape), so the TUI is fully usable for
// development and for live-mode rehearsals without the interface plugged in.
package drivers

import "fmt"

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

// Spec describes one supported interface.
type Spec struct {
	ID            string  `json:"id"`
	Display       string  `json:"display"`
	Vendor        string  `json:"vendor"`
	USBVID        string  `json:"usb_vid"`
	USBPID        string  `json:"usb_pid"`
	NumInputs     int     `json:"num_inputs"`
	NumOutPairs   int     `json:"num_output_pairs"`
	GainMin       float64 `json:"gain_min_db"`
	GainMax       float64 `json:"gain_max_db"`
	VolMin        float64 `json:"vol_min_db"`
	VolMax        float64 `json:"vol_max_db"`
	MixerInputs   int     `json:"mixer_inputs"`
	MixerOutputs  int     `json:"mixer_outputs"`
	HasMonitor    bool    `json:"has_monitor"`
	Backend       Backend `json:"backend"`
	NeedsKmod     bool    `json:"needs_kmod"`
	Description   string  `json:"description"`
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
// hardware, shadowed in software — same as audient-evo-py).
type MixerCell struct {
	VolumeDb float64 `json:"volume_db"`
	Pan      float64 `json:"pan"` // -100..+100
}

// Status is the full readable state of one device.
type Status struct {
	Spec      Spec               `json:"spec"`
	Online    bool               `json:"online"`
	Backend   Backend            `json:"backend_in_use"`
	Inputs    []InputState       `json:"inputs"`
	Outputs   []OutputState      `json:"outputs"`
	Monitor   *int               `json:"monitor,omitempty"` // EVO4 blend 0..100
	Mixer     map[string]MixerCell `json:"mixer"`
	Note      string             `json:"note,omitempty"`
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
