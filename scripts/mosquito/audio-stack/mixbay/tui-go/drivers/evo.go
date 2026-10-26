// EVO 4 / EVO 8 driver — Go port of vanzaho/audient-evo-py.
//
// Transport: USB control transfers on endpoint 0 via the evo_raw kernel
// module (/dev/evo4, /dev/evo8). The module binds the unused DFU interface
// so snd-usb-audio keeps streaming undisturbed.
//
// Protocol (entity IDs, ranges, quirks — all from audient-evo-py's
// dev/DESIGN.md, public domain):
//
//	FU10 0x0A00 CS=2 : output volume, 2B signed UAC2 (1/256 dB), [-127,0] dB
//	                   (EVO 8; the EVO 4 stops at -96 dB)
//	FU11 0x0B00 CS=2 : input gain per CN, EVO4 [-8,50], EVO8 [-8,50] wire
//	                   (the card shows the same gain on a 0..58 scale)
//	EU56 0x3800 CS=0 : monitor blend 0..127 (EVO4 ONLY — EVO8 STALLs)
//	EU58 0x3A00 CS=0 : phantom 48V per input, 4B LE bool
//	EU58 0x3A00 CS=2 : input mute (+ EVO8 output mutes), 4B LE bool
//	EU59 0x3B00 CS=1 : output mute (EVO4), 4B LE bool
//	MU60 0x3C00 CS=1 : loopback mixer, WRITE-ONLY, 2B signed dB [-128,+6]
//	CN = out_idx + in_idx * num_outputs (UAC2 standard)
//
// Quirks honoured: EU58/59 need full 4 bytes; MU60 GET_CUR always STALLs so
// the mixer is a software shadow persisted to disk; EU56 invalid CS/CN can
// lock the unit (only CS=0 CN=0 is ever used).
package drivers

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
	"unsafe"

	"golang.org/x/sys/unix"
)

// Device specs — mirrors evo/devices.py, except the EVO 8 gain scale: the
// card/app shows 0…58 dB while FU11/ALSA use the same physical gain as
// -8…50 dB. GainOffset = 8 bridges them (display 0 → wire -8, 58 → 50).
var (
	EVO8Spec = Spec{
		ID: "evo8", Display: "Audient EVO 8", Vendor: "Audient",
		USBVID: "2708", USBPID: "0007",
		NumInputs: 4, NumOutPairs: 2,
		GainMin: 0, GainMax: 58, GainOffset: 8, VolMin: -127, VolMax: 0,
		MixerInputs: 10, MixerOutputs: 4,
		HasMonitor: false, Backend: BackendEvoRaw, NeedsKmod: true,
		Caps:        Caps{Volume: true, Gain: true, Mute: true, Phantom: true, Monitor: false, Mixer: true},
		Description: "4 in / 2 out pairs + loopback matrix over 2 mix buses. Monitoring via the matrix.",
	}
	EVO4Spec = Spec{
		ID: "evo4", Display: "Audient EVO 4", Vendor: "Audient",
		USBVID: "2708", USBPID: "0006",
		NumInputs: 2, NumOutPairs: 1,
		GainMin: -8, GainMax: 50, VolMin: -96, VolMax: 0,
		MixerInputs: 6, MixerOutputs: 2,
		HasMonitor: true, Backend: BackendEvoRaw, NeedsKmod: true,
		Caps:        Caps{Volume: true, Gain: true, Mute: true, Phantom: true, Monitor: true, Mixer: true},
		Description: "2 in / 1 out pair + loopback. Direct-monitor blend knob.",
	}
)

const (
	fu10     = 0x0A00
	fu11     = 0x0B00
	eu51     = 0x3300
	eu56     = 0x3800
	eu58     = 0x3A00
	eu59     = 0x3B00
	mu60     = 0x3C00
	csVolume = 2
	csMixer  = 1
	mixDbMin = -128.0
	mixDbMax = 6.0
)

// ioctl number: _IOWR('E', 0, struct evo_ctrl_xfer), 264 bytes.
// dir=3<<30 | size<<16 | 'E'<<8 | 0 — must match evo_raw.c.
const evoXferSize = 264

func evoIoctlNr() uintptr { return uintptr((3 << 30) | (evoXferSize << 16) | (0x45 << 8) | 0) }

// captureOnce keeps the EU51 fallback to one transfer per process: the udev
// helper already enables it on connect, and polling it every 500 ms would
// hammer a write-only control.
var captureOnce sync.Once

// --- pure protocol helpers (no USB, fully unit-testable) -------------------

func dbToUSB(db float64) uint16       { return uint16(int32(math.Round(db*256)) & 0xFFFF) }
func usbToDb(raw uint16) float64      { return float64(int16(raw)) / 256.0 }
func clamp(v, lo, hi float64) float64 { return math.Max(lo, math.Min(hi, v)) }

// panToLRDb: equal-power pan law, ported from EVOController._pan_to_lr_db.
func panToLRDb(volDb, pan float64) (float64, float64) {
	pan = clamp(pan, -100, 100)
	p := (pan + 100.0) / 200.0
	angle := p * (math.Pi / 2)
	lLin, rLin := math.Cos(angle), math.Sin(angle)
	lDb, rDb := mixDbMin, mixDbMin
	if lLin > 1e-10 {
		lDb = volDb + 20*math.Log10(lLin)
	}
	if rLin > 1e-10 {
		rDb = volDb + 20*math.Log10(rLin)
	}
	return math.Max(mixDbMin, lDb), math.Max(mixDbMin, rDb)
}

func bool4(b bool) []byte {
	var v [4]byte
	if b {
		binary.LittleEndian.PutUint32(v[:], 1)
	}
	return v[:]
}

type evoDriver struct {
	spec      Spec
	demo      *demoState // non-nil once demo fallback is engaged
	fd        int        // shared fd for the current transfer batch (-1 = closed)
	depth     int        // begin/end nesting so batches can compose
	allowDemo bool       // false = live-only writes (ErrOffline, never demo)
}

func newEvo(spec Spec) *evoDriver { return &evoDriver{spec: spec, fd: -1, allowDemo: true} }

// begin opens the device once for a whole batch of control transfers.
// Opening/closing /dev/evo* for every transfer in quick succession makes the
// device STALL (design doc: "rapid transfer storms"), which surfaces as EPIPE
// ("broken pipe") on the next transfer — e.g. when muting an output. Keeping
// one fd for the batch mirrors what the upstream controller does.
func (d *evoDriver) begin() error {
	d.depth++
	if d.depth > 1 {
		return nil
	}
	fd, err := unix.Open(d.devPath(), unix.O_RDONLY, 0)
	if err != nil {
		d.depth--
		return err
	}
	d.fd = fd
	return nil
}

func (d *evoDriver) end() {
	if d.depth == 0 {
		return
	}
	d.depth--
	if d.depth == 0 && d.fd >= 0 {
		unix.Close(d.fd)
		d.fd = -1
	}
}

// xferFD returns the fd to use for one transfer and whether it is temporary.
func (d *evoDriver) xferFD() (int, bool, error) {
	if d.fd >= 0 {
		return d.fd, false, nil
	}
	fd, err := unix.Open(d.devPath(), unix.O_RDONLY, 0)
	if err != nil {
		return -1, false, err
	}
	return fd, true, nil
}

// pace is the small gap the design doc recommends between transfers when a
// batch holds one fd, so back-to-back SET_CURs cannot trip the STALL watchdog.
func (d *evoDriver) pace() {
	if d.fd >= 0 {
		time.Sleep(time.Millisecond)
	}
}

func (d *evoDriver) Spec() Spec { return d.spec }

func (d *evoDriver) devPath() string {
	// Overridable for tests: point it at an empty dir to force demo mode
	// even on a machine with a real /dev/evo* node.
	base := os.Getenv("MOSQUITOMIXBAY_EVO_DEVDIR")
	if base == "" {
		base = "/dev"
	}
	return filepath.Join(base, d.spec.ID)
}

// Probe: the kmod device node exists and opens.
func (d *evoDriver) Probe() bool {
	fd, err := unix.Open(d.devPath(), unix.O_RDONLY, 0)
	if err != nil {
		return false
	}
	unix.Close(fd)
	return true
}

func (d *evoDriver) online() bool { return d.demo == nil && d.hasDevice() }

// hasDevice reports whether a hardware device is usable. It short-circuits
// when a batch fd is already open, so nested method calls in one batch do not
// trigger extra open/close probes (which is what caused USB STALLs).
func (d *evoDriver) hasDevice() bool {
	if d.fd >= 0 {
		return true
	}
	return d.Probe()
}

// --- raw transfers -----------------------------------------------------

// xfer builds the 264-byte struct evo_ctrl_xfer (little-endian).
func evoXfer(reqType, req byte, wValue, wIndex, wLength uint16, payload []byte) []byte {
	buf := make([]byte, evoXferSize)
	buf[0] = reqType
	buf[1] = req
	binary.LittleEndian.PutUint16(buf[2:], wValue)
	binary.LittleEndian.PutUint16(buf[4:], wIndex)
	binary.LittleEndian.PutUint16(buf[6:], wLength)
	copy(buf[8:], payload)
	return buf
}

func ioctlCtrl(fd int, buf []byte) error {
	_, _, errno := unix.Syscall(unix.SYS_IOCTL, uintptr(fd), evoIoctlNr(),
		uintptr(unsafe.Pointer(&buf[0])))
	if errno != 0 {
		return errno
	}
	return nil
}

func (d *evoDriver) getCur(wValue, wIndex uint16, length int) ([]byte, error) {
	fd, temp, err := d.xferFD()
	if err != nil {
		return nil, err
	}
	if temp {
		defer unix.Close(fd)
	}
	buf := evoXfer(0xA1, 0x01, wValue, wIndex, uint16(length), make([]byte, 256))
	if err := ioctlCtrl(fd, buf); err != nil {
		return nil, fmt.Errorf("GET_CUR wValue=%#04x wIndex=%#04x: %w", wValue, wIndex, err)
	}
	d.pace()
	respLen := int(binary.LittleEndian.Uint16(buf[6:]))
	if respLen > 256 {
		respLen = 256
	}
	out := make([]byte, respLen)
	copy(out, buf[8:8+respLen])
	return out, nil
}

func (d *evoDriver) setCur(wValue, wIndex uint16, data []byte) error {
	fd, temp, err := d.xferFD()
	if err != nil {
		return err
	}
	if temp {
		defer unix.Close(fd)
	}
	payload := make([]byte, 256)
	copy(payload, data)
	buf := evoXfer(0x21, 0x01, wValue, wIndex, uint16(len(data)), payload)
	if err := ioctlCtrl(fd, buf); err != nil {
		return fmt.Errorf("SET_CUR wValue=%#04x wIndex=%#04x: %w", wValue, wIndex, err)
	}
	d.pace()
	return nil
}

func (d *evoDriver) getFU(unit uint16, cn int) (uint16, error) {
	raw, err := d.getCur(uint16(csVolume<<8|cn), unit, 2)
	if err != nil {
		return 0, err
	}
	if len(raw) < 2 {
		return 0, fmt.Errorf("short read (%d bytes)", len(raw))
	}
	return binary.LittleEndian.Uint16(raw), nil
}

func (d *evoDriver) setFU(unit uint16, cn int, raw uint16) error {
	var b [2]byte
	binary.LittleEndian.PutUint16(b[:], raw)
	return d.setCur(uint16(csVolume<<8|cn), unit, b[:])
}

// enableCapture opens the EVO 8's 6-channel USB capture selector (EU51).
// The firmware may leave it disabled after power-on, which silences every
// capture channel even when gain, mute and 48V are correct. Best-effort:
// the controls still work if the device STALLs this vendor unit, and EU51's
// Enable selector is write-only on this unit.
func (d *evoDriver) enableCapture() {
	if d.spec.ID != DevEVO8 {
		return
	}
	captureOnce.Do(func() { _ = d.setCur(0x0000, eu51, []byte{1}) })
}

// muteTarget maps a UI target to (wValue, wIndex), mirroring controller.py.
func (d *evoDriver) muteTarget(target string) (uint16, uint16, error) {
	for i := 0; i < d.spec.NumInputs; i++ {
		if target == fmt.Sprintf("input%d", i+1) {
			return uint16(0x0200 + i), eu58, nil
		}
	}
	if d.spec.NumOutPairs == 1 {
		if target == "output" {
			return 0x0100, eu59, nil
		}
	} else {
		for i := 0; i < d.spec.NumOutPairs; i++ {
			if target == fmt.Sprintf("output%d", i+1) {
				return uint16(0x0200 + d.spec.NumInputs + i), eu58, nil
			}
		}
	}
	return 0, 0, fmt.Errorf("unknown mute target %q", target)
}

// --- demo fallback ------------------------------------------------------
// No hardware (or no kmod) → persistent simulated state so the TUI, the CLI
// and live-mode rehearsals work without the interface plugged in.

type demoState struct {
	Volumes []float64            `json:"volumes"`
	Gains   []float64            `json:"gains"`
	Mutes   map[string]bool      `json:"mutes"`
	Phantom map[string]bool      `json:"phantom"`
	Monitor int                  `json:"monitor"`
	Mixer   map[string]MixerCell `json:"mixer"`
}

func defaultMixerCells(spec Spec) map[string]MixerCell {
	m := map[string]MixerCell{}
	for bus := 0; bus < MixBuses(spec); bus++ {
		for _, src := range MixerSources(spec, bus) {
			if strings.HasPrefix(src, "output") {
				// Stereo loopback sources carry pan_l/pan_r, as upstream does.
				m[src] = MixerCell{VolumeDb: -128, Pan: 0, PanL: -100, PanR: 100}
			} else {
				m[src] = MixerCell{VolumeDb: -128, Pan: 0}
			}
		}
	}
	return m
}

func (d *evoDriver) demoFile() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "mosquitomixbay", d.spec.ID, "demo.json")
}

func (d *evoDriver) ensureDemo() *demoState {
	if d.demo != nil {
		return d.demo
	}
	st := &demoState{
		Volumes: make([]float64, d.spec.NumOutPairs),
		Gains:   make([]float64, d.spec.NumInputs),
		Mutes:   map[string]bool{},
		Phantom: map[string]bool{},
		Monitor: 50,
		Mixer:   defaultMixerCells(d.spec),
	}
	for i := range st.Volumes {
		st.Volumes[i] = 0
	}
	for i := range st.Gains {
		// Neutral unity default (not GainMin, which confused users).
		st.Gains[i] = 0
	}
	if data, err := os.ReadFile(d.demoFile()); err == nil {
		_ = json.Unmarshal(data, st)
	}
	d.demo = st
	return st
}

func (d *evoDriver) saveDemo() {
	if d.demo == nil {
		return
	}
	_ = os.MkdirAll(filepath.Dir(d.demoFile()), 0o755)
	data, _ := json.MarshalIndent(d.demo, "", "  ")
	_ = os.WriteFile(d.demoFile(), data, 0o644)
}

// --- readable state -----------------------------------------------------

// Read reads the hardware only. A missing interface is ErrOffline, never a
// fabricated DEMO status: the live session freezes its last real values.
func (d *evoDriver) Read() (Status, error) {
	if !d.hasDevice() {
		return Status{Spec: d.spec}, ErrOffline
	}
	return d.readHardware()
}

// Status keeps the historical demo fallback for the CLI and deliberate demo
// mode. The live UI uses Read() so a lost interface cannot look like data.
func (d *evoDriver) Status() (Status, error) {
	st, err := d.Read()
	if errors.Is(err, ErrOffline) {
		return d.demoStatus(), nil
	}
	return st, err
}

func (d *evoDriver) demoStatus() Status {
	st := Status{Spec: d.spec, Mixer: map[string]MixerCell{}}
	demo := d.ensureDemo()
	st.Online = false
	st.Backend = BackendDemo
	st.Note = fmt.Sprintf("DEMO — %s not found. State is simulated and persistent.", d.spec.Display)
	for i := 0; i < d.spec.NumInputs; i++ {
		name := fmt.Sprintf("input%d", i+1)
		st.Inputs = append(st.Inputs, InputState{Name: name, GainDb: demo.Gains[i], Muted: demo.Mutes[name], Phantom: demo.Phantom[name]})
	}
	for i := 0; i < d.spec.NumOutPairs; i++ {
		name := fmt.Sprintf("output%d", i+1)
		if d.spec.NumOutPairs == 1 {
			name = "output"
		}
		st.Outputs = append(st.Outputs, OutputState{Name: name, VolumeDb: demo.Volumes[i], Muted: demo.Mutes[name]})
	}
	if d.spec.HasMonitor {
		m := demo.Monitor
		st.Monitor = &m
	}
	for k, v := range demo.Mixer {
		st.Mixer[k] = v
	}
	return st
}

func (d *evoDriver) readHardware() (Status, error) {
	st := Status{Spec: d.spec, Mixer: map[string]MixerCell{}}
	d.demo = nil
	st.Online = true
	st.Backend = BackendEvoRaw
	if err := d.begin(); err != nil {
		// The node can vanish between the probe and the transfer.
		return st, fmt.Errorf("%w: %v", ErrOffline, err)
	}
	defer d.end()
	d.enableCapture()
	// Volumes (CH1 of each pair; pairs are ganged on write).
	var outMutes map[string]float64
	if !d.supportsNativeOutputMute() {
		outMutes = d.loadOutputMutes()
	}
	for i := 0; i < d.spec.NumOutPairs; i++ {
		raw, err := d.getFU(fu10, i*2+1)
		if err != nil {
			return st, fmt.Errorf("volume output%d: %w", i+1, err)
		}
		name := d.outputName(i)
		vol := usbToDb(raw)
		muted := false
		if outMutes != nil {
			if saved, ok := outMutes[name]; ok {
				muted, vol = true, saved
			}
		} else if wV, wI, err := d.muteTarget(name); err == nil {
			if b, err := d.getCur(wV, wI, 4); err == nil && len(b) >= 4 {
				muted = binary.LittleEndian.Uint32(b) == 1
			}
		}
		st.Outputs = append(st.Outputs, OutputState{Name: name, VolumeDb: vol, Muted: muted})
	}
	for i := 0; i < d.spec.NumInputs; i++ {
		name := fmt.Sprintf("input%d", i+1)
		raw, err := d.getFU(fu11, i+1)
		if err != nil {
			return st, fmt.Errorf("gain %s: %w", name, err)
		}
		muted := false
		if wV, wI, err := d.muteTarget(name); err == nil {
			if b, err := d.getCur(wV, wI, 4); err == nil && len(b) >= 4 {
				muted = binary.LittleEndian.Uint32(b) == 1
			}
		}
		phantom := false
		if b, err := d.getCur(uint16(i), eu58, 4); err == nil && len(b) >= 4 {
			phantom = binary.LittleEndian.Uint32(b) == 1
		}
		gain := math.Round(usbToDb(raw) + d.spec.GainOffset)
		st.Inputs = append(st.Inputs, InputState{Name: name, GainDb: gain, Muted: muted, Phantom: phantom})
	}
	if d.spec.HasMonitor {
		if b, err := d.getCur(0x0000, eu56, 2); err == nil && len(b) >= 2 {
			v := int(math.Round(float64(binary.LittleEndian.Uint16(b)) * 100 / 127))
			st.Monitor = &v
		}
	}
	// Mixer is write-only on hardware: serve the persisted shadow.
	st.Mixer = d.loadShadow()
	return st, nil
}

// --- writes -------------------------------------------------------------

func (d *evoDriver) SetVolume(pair int, db float64) error {
	db = clamp(db, d.spec.VolMin, d.spec.VolMax)
	if !d.hasDevice() {
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
	if err := d.begin(); err != nil {
		return err
	}
	defer d.end()
	pairs := []int{pair}
	if pair < 0 {
		pairs = pairs[:0]
		for i := 0; i < d.spec.NumOutPairs; i++ {
			pairs = append(pairs, i)
		}
	}
	// A level set on an emulated-muted pair updates the remembered level but
	// leaves the output silent, so unmuting restores the new level.
	var mutes map[string]float64
	if !d.supportsNativeOutputMute() {
		mutes = d.loadOutputMutes()
	}
	for _, p := range pairs {
		if p < 0 || p >= d.spec.NumOutPairs {
			return fmt.Errorf("output pair %d out of range (0..%d)", p, d.spec.NumOutPairs-1)
		}
		writeDb := db
		if mutes != nil {
			name := d.outputName(p)
			if _, ok := mutes[name]; ok {
				mutes[name] = db
				if err := d.saveOutputMutes(mutes); err != nil {
					return err
				}
				writeDb = d.spec.VolMin
			}
		}
		base := p*2 + 1
		for _, cn := range []int{base, base + 1} {
			if err := d.setFU(fu10, cn, dbToUSB(writeDb)); err != nil {
				return err
			}
		}
	}
	return nil
}

func (d *evoDriver) SetGain(input int, db float64) error {
	if input < 1 || input > d.spec.NumInputs {
		return fmt.Errorf("input must be 1..%d", d.spec.NumInputs)
	}
	db = clamp(db, d.spec.GainMin, d.spec.GainMax)
	if !d.hasDevice() {
		if !d.allowDemo {
			return ErrOffline
		}
		demo := d.ensureDemo()
		demo.Gains[input-1] = math.Round(db)
		d.saveDemo()
		return nil
	}
	if err := d.begin(); err != nil {
		return err
	}
	defer d.end()
	return d.setFU(fu11, input, dbToUSB(db-d.spec.GainOffset))
}

func (d *evoDriver) SetMute(target string, muted bool) error {
	if !d.hasDevice() {
		if !d.allowDemo {
			return ErrOffline
		}
		demo := d.ensureDemo()
		demo.Mutes[target] = muted
		d.saveDemo()
		return nil
	}
	// The EVO 8 firmware STALLs the documented EU58 CS=2 output-mute selector
	// (SET_CUR wValue=0x0204 wIndex=0x3a00 → EPIPE / "broken pipe"). Rather
	// than leave the key dead, emulate the mute through the one output control
	// that always answers, FU10: drop the pair to VolMin and remember the
	// previous level so unmuting restores it. The EVO 4 has a real output mute
	// (EU59) and keeps using it.
	if d.isOutputTarget(target) && !d.supportsNativeOutputMute() {
		return d.setOutputMuteEmulated(target, muted)
	}
	wValue, unit, err := d.muteTarget(target)
	if err != nil {
		return err
	}
	if err := d.begin(); err != nil {
		return err
	}
	defer d.end()
	return d.setCur(wValue, unit, bool4(muted))
}

// supportsNativeOutputMute reports whether the device exposes a working
// hardware output mute. Only the single-pair EVO 4 (EU59) does; the EVO 8's
// EU58 CS=2 selector is rejected by the firmware.
func (d *evoDriver) supportsNativeOutputMute() bool {
	return d.spec.NumOutPairs == 1
}

func (d *evoDriver) isOutputTarget(target string) bool {
	if d.spec.NumOutPairs == 1 {
		return target == "output"
	}
	for i := 0; i < d.spec.NumOutPairs; i++ {
		if target == d.outputName(i) {
			return true
		}
	}
	return false
}

func (d *evoDriver) outputName(pair int) string {
	if d.spec.NumOutPairs == 1 {
		return "output"
	}
	return fmt.Sprintf("output%d", pair+1)
}

// outputMuteFile persists the pre-mute level of each emulated output mute so
// the state survives a restart (the hardware mute flag cannot be read back).
func (d *evoDriver) outputMuteFile() string {
	return filepath.Join(d.shadowDir(), ".output-mute.json")
}

func (d *evoDriver) loadOutputMutes() map[string]float64 {
	m := map[string]float64{}
	if data, err := os.ReadFile(d.outputMuteFile()); err == nil {
		_ = json.Unmarshal(data, &m)
	}
	return m
}

func (d *evoDriver) saveOutputMutes(m map[string]float64) error {
	_ = os.MkdirAll(d.shadowDir(), 0o755)
	data, _ := json.MarshalIndent(m, "", "  ")
	return os.WriteFile(d.outputMuteFile(), data, 0o644)
}

func (d *evoDriver) setOutputMuteEmulated(target string, muted bool) error {
	pair := -1
	for i := 0; i < d.spec.NumOutPairs; i++ {
		if target == d.outputName(i) {
			pair = i
		}
	}
	if pair < 0 {
		return fmt.Errorf("unknown mute target %q", target)
	}
	mutes := d.loadOutputMutes()
	if !muted {
		db, ok := mutes[target]
		if !ok {
			return nil
		}
		delete(mutes, target)
		if err := d.saveOutputMutes(mutes); err != nil {
			return err
		}
		return d.SetVolume(pair, db)
	}
	if _, ok := mutes[target]; ok {
		return nil
	}
	if err := d.begin(); err != nil {
		return err
	}
	raw, err := d.getFU(fu10, pair*2+1)
	d.end()
	if err != nil {
		return err
	}
	mutes[target] = usbToDb(raw)
	if err := d.saveOutputMutes(mutes); err != nil {
		return err
	}
	return d.SetVolume(pair, d.spec.VolMin)
}

func (d *evoDriver) SetPhantom(input int, on bool) error {
	if input < 1 || input > d.spec.NumInputs {
		return fmt.Errorf("input must be 1..%d", d.spec.NumInputs)
	}
	if !d.hasDevice() {
		if !d.allowDemo {
			return ErrOffline
		}
		demo := d.ensureDemo()
		demo.Phantom[fmt.Sprintf("input%d", input)] = on
		d.saveDemo()
		return nil
	}
	if err := d.begin(); err != nil {
		return err
	}
	defer d.end()
	return d.setCur(uint16(input-1), eu58, bool4(on))
}

func (d *evoDriver) SetMonitor(v int) error {
	if !d.spec.HasMonitor {
		return fmt.Errorf("%s has no monitor blend knob — route through the loopback mixer instead", d.spec.Display)
	}
	v = int(clamp(float64(v), 0, 100))
	if !d.hasDevice() {
		if !d.allowDemo {
			return ErrOffline
		}
		demo := d.ensureDemo()
		demo.Monitor = v
		d.saveDemo()
		return nil
	}
	if err := d.begin(); err != nil {
		return err
	}
	defer d.end()
	raw := byte(math.Round(float64(v) / 100 * 127))
	return d.setCur(0, eu56, []byte{raw})
}

// mixer CN helpers (UAC2: CN = out_idx + in_idx * num_outputs, where the
// "outputs" here are the loopback mixer's bus channels).
func (d *evoDriver) setCrosspoint(cn int, db float64) error {
	max := d.spec.MixerInputs * d.spec.MixerOutputs
	if cn < 0 || cn >= max {
		return fmt.Errorf("cross-point CN must be 0..%d", max-1)
	}
	db = clamp(db, mixDbMin, mixDbMax)
	var b [2]byte
	binary.LittleEndian.PutUint16(b[:], dbToUSB(db))
	return d.setCur(uint16(csMixer<<8|cn), mu60, b[:])
}

// writeMixerCell pushes one shadow cell to the hardware: the cell's volume
// and pan expand to L/R crosspoint writes on the selected mix bus.
func (d *evoDriver) writeMixerCell(src string, c MixerCell, bus int) error {
	if err := d.begin(); err != nil {
		return err
	}
	defer d.end()
	lDb, rDb := panToLRDb(c.VolumeDb, c.Pan)
	off := bus * 2
	var in int
	if _, err := fmt.Sscanf(src, "input%d", &in); err == nil {
		base := (in-1)*d.spec.MixerOutputs + off
		if err := d.setCrosspoint(base, lDb); err != nil {
			return err
		}
		return d.setCrosspoint(base+1, rDb)
	}
	var l, r int
	if _, err := fmt.Sscanf(src, "output%d_%d", &l, &r); err != nil || r != l+1 || l%2 != 1 {
		return fmt.Errorf("unknown mixer source %q", src)
	}
	// A loopback pair fans out to both channels of the mix bus.
	inL := d.spec.NumInputs + (l-1)/2*2
	inR := inL + 1
	for cn, db := range map[int]float64{
		inL*d.spec.MixerOutputs + off:     lDb,
		inL*d.spec.MixerOutputs + off + 1: rDb,
		inR*d.spec.MixerOutputs + off:     lDb,
		inR*d.spec.MixerOutputs + off + 1: rDb,
	} {
		if err := d.setCrosspoint(cn, db); err != nil {
			return err
		}
	}
	return nil
}

func (d *evoDriver) SetMixerInput(input int, volDb, pan float64, mixOut int) error {
	if input < 1 || input > d.spec.NumInputs {
		return fmt.Errorf("input must be 1..%d", d.spec.NumInputs)
	}
	if mixOut < 0 || mixOut >= MixBuses(d.spec) {
		return fmt.Errorf("mix bus must be 0..%d", MixBuses(d.spec)-1)
	}
	cell := MixerCell{VolumeDb: clamp(volDb, mixDbMin, mixDbMax), Pan: clamp(pan, -100, 100)}
	key := MixerKey(fmt.Sprintf("input%d", input), mixOut)
	if !d.hasDevice() {
		if !d.allowDemo {
			return ErrOffline
		}
		demo := d.ensureDemo()
		demo.Mixer[key] = cell
		d.saveDemo()
		// The shadow is the hardware truth even in demo: Load() reads it.
		sh := d.loadShadow()
		sh[key] = cell
		return d.saveShadow(sh)
	}
	if err := d.writeMixerCell(fmt.Sprintf("input%d", input), cell, mixOut); err != nil {
		return err
	}
	sh := d.loadShadow()
	sh[key] = cell
	return d.saveShadow(sh)
}

func (d *evoDriver) SetMixerOutput(srcPair int, volDb, panL, panR float64, mixOut int) error {
	if srcPair < 0 || srcPair >= (d.spec.MixerInputs-d.spec.NumInputs)/2 {
		return fmt.Errorf("loopback pair %d out of range", srcPair)
	}
	if mixOut < 0 || mixOut >= MixBuses(d.spec) {
		return fmt.Errorf("mix bus must be 0..%d", MixBuses(d.spec)-1)
	}
	cell := MixerCell{
		VolumeDb: clamp(volDb, mixDbMin, mixDbMax),
		Pan:      clamp((panL+panR)/2, -100, 100),
		PanL:     clamp(panL, -100, 100),
		PanR:     clamp(panR, -100, 100),
	}
	key := MixerKey(fmt.Sprintf("output%d_%d", srcPair*2+1, srcPair*2+2), mixOut)
	if !d.hasDevice() {
		if !d.allowDemo {
			return ErrOffline
		}
		demo := d.ensureDemo()
		demo.Mixer[key] = cell
		d.saveDemo()
		sh := d.loadShadow()
		sh[key] = cell
		return d.saveShadow(sh)
	}
	if err := d.writeMixerCell(fmt.Sprintf("output%d_%d", srcPair*2+1, srcPair*2+2), cell, mixOut); err != nil {
		return err
	}
	sh := d.loadShadow()
	sh[key] = cell
	return d.saveShadow(sh)
}

// --- shadow + snapshots -------------------------------------------------

// Same location as upstream (~/.config/audient-evo-py/<dev>/.mixer-state.json)
// so evoctl and this bay share one shadow.
func (d *evoDriver) shadowDir() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "audient-evo-py", d.spec.ID)
}

func (d *evoDriver) shadowFile() string {
	return filepath.Join(d.shadowDir(), ".mixer-state.json")
}

func (d *evoDriver) loadShadow() map[string]MixerCell {
	m := defaultMixerCells(d.spec)
	if data, err := os.ReadFile(d.shadowFile()); err == nil {
		_ = json.Unmarshal(data, &m)
	}
	return m
}

func (d *evoDriver) saveShadow(m map[string]MixerCell) error {
	_ = os.MkdirAll(filepath.Dir(d.shadowFile()), 0o755)
	data, _ := json.MarshalIndent(m, "", "  ")
	return os.WriteFile(d.shadowFile(), data, 0o644)
}

func (d *evoDriver) Save() error {
	if !d.allowDemo && !d.hasDevice() {
		return ErrOffline
	}
	return d.SaveTo(filepath.Join(d.shadowDir(), "config.json"))
}

// SaveTo writes the snapshot to an arbitrary path (the evotui config picker).
func (d *evoDriver) SaveTo(path string) error {
	if !d.allowDemo && !d.hasDevice() {
		return ErrOffline
	}
	st, err := d.Status()
	if err != nil {
		return err
	}
	cfg := map[string]any{}
	for _, i := range st.Inputs {
		cfg[i.Name] = map[string]any{"gain": i.GainDb, "mute": i.Muted, "phantom": i.Phantom}
	}
	for _, o := range st.Outputs {
		cfg[o.Name] = map[string]any{"volume": o.VolumeDb, "mute": o.Muted}
	}
	if st.Monitor != nil {
		cfg["monitor"] = *st.Monitor
	}
	// Full named snapshots include the loopback mixer (all buses), so several
	// configs can carry distinct routings.
	shadow := map[string]MixerCell{}
	for k, c := range st.Mixer {
		shadow[k] = c
	}
	for bus := 0; bus < MixBuses(d.spec); bus++ {
		for _, src := range MixerSources(d.spec, bus) {
			if _, ok := shadow[src]; ok {
				continue
			}
			if strings.HasPrefix(src, "output") {
				shadow[src] = MixerCell{VolumeDb: mixDbMin, PanL: -100, PanR: 100}
			} else {
				shadow[src] = MixerCell{VolumeDb: mixDbMin}
			}
		}
	}
	mixer := map[string]any{}
	for k, c := range shadow {
		mixer[k] = map[string]any{"volume": c.VolumeDb, "pan": c.Pan, "pan_l": c.PanL, "pan_r": c.PanR}
	}
	if len(mixer) > 0 {
		cfg["mixer"] = mixer
	}
	_ = os.MkdirAll(filepath.Dir(path), 0o755)
	data, _ := json.MarshalIndent(cfg, "", "  ")
	return os.WriteFile(path, data, 0o644)
}

// ProtectedConfigName is the built-in preset that cannot be overwritten.
const ProtectedConfigName = "default"

// ResetToDefaults restores the neutral factory default: unity input gains,
// output volume at the minimum (so loading the default never blasts the
// monitors), nothing muted, phantom off, centred input pans, full-width
// stereo sources and a silent loopback matrix (no route open).
func (d *evoDriver) ResetToDefaults() error {
	if !d.allowDemo && !d.hasDevice() {
		return ErrOffline
	}
	if d.hasDevice() {
		if err := d.begin(); err != nil {
			return err
		}
		defer d.end()
	}
	// Clear output mutes first: an emulated unmute restores the remembered
	// level, which the volume reset below must then overwrite.
	for i := 0; i < d.spec.NumOutPairs; i++ {
		if err := d.SetMute(d.outputName(i), false); err != nil {
			return err
		}
	}
	if err := d.SetVolume(-1, d.spec.VolMin); err != nil {
		return err
	}
	for i := 0; i < d.spec.NumInputs; i++ {
		name := fmt.Sprintf("input%d", i+1)
		if err := d.SetGain(i+1, 0); err != nil {
			return err
		}
		if err := d.SetMute(name, false); err != nil {
			return err
		}
		if err := d.SetPhantom(i+1, false); err != nil {
			return err
		}
	}
	if d.spec.HasMonitor {
		if err := d.SetMonitor(50); err != nil {
			return err
		}
	}
	return d.ResetMixer()
}

// Load re-applies config.json + every mixer shadow route (inputs and
// loopback pairs alike, on every bus).
func (d *evoDriver) Load() error {
	return d.LoadFrom(filepath.Join(d.shadowDir(), "config.json"))
}

// LoadFrom re-applies a snapshot from an arbitrary path (the evotui config
// picker).
func (d *evoDriver) LoadFrom(path string) error {
	if !d.allowDemo && !d.hasDevice() {
		return ErrOffline
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("no saved config: %w", err)
	}
	var cfg map[string]map[string]any
	if err := json.Unmarshal(data, &cfg); err != nil {
		return err
	}
	num := func(m map[string]any, k string) (float64, bool) {
		v, ok := m[k].(float64)
		return v, ok
	}
	boolean := func(m map[string]any, k string) bool {
		v, _ := m[k].(bool)
		return v
	}
	// Hold one fd for the whole restore so the burst of SET_CURs doesn't
	// STALL the device (see begin/end).
	if d.hasDevice() {
		if err := d.begin(); err != nil {
			return err
		}
		defer d.end()
	}
	// Deterministic order: outputs, inputs, monitor, mixer.
	var outNames []string
	for i := 0; i < d.spec.NumOutPairs; i++ {
		if d.spec.NumOutPairs == 1 {
			outNames = append(outNames, "output")
		} else {
			outNames = append(outNames, fmt.Sprintf("output%d", i+1))
		}
	}
	for idx, name := range outNames {
		if m, ok := cfg[name]; ok {
			if v, ok := num(m, "volume"); ok {
				if err := d.SetVolume(idx, v); err != nil {
					return err
				}
			}
			if err := d.SetMute(name, boolean(m, "mute")); err != nil {
				return err
			}
		}
	}
	for i := 0; i < d.spec.NumInputs; i++ {
		name := fmt.Sprintf("input%d", i+1)
		if m, ok := cfg[name]; ok {
			if v, ok := num(m, "gain"); ok {
				if err := d.SetGain(i+1, v); err != nil {
					return err
				}
			}
			if err := d.SetMute(name, boolean(m, "mute")); err != nil {
				return err
			}
			if err := d.SetPhantom(i+1, boolean(m, "phantom")); err != nil {
				return err
			}
		}
	}
	// monitor may be stored as a bare number.
	var monMap map[string]any
	_ = json.Unmarshal(data, &monMap)
	if mv, ok := monMap["monitor"].(float64); ok && d.spec.HasMonitor {
		if err := d.SetMonitor(int(math.Round(mv))); err != nil {
			return err
		}
	}
	shadow := d.loadShadow()
	if rawMixer, ok := cfg["mixer"]; ok && len(rawMixer) > 0 {
		// Named snapshot carries its own mixer state.
		shadow = map[string]MixerCell{}
		for k, v := range rawMixer {
			cell := MixerCell{}
			if m, ok := v.(map[string]any); ok {
				if f, ok := num(m, "volume"); ok {
					cell.VolumeDb = f
				}
				if f, ok := num(m, "pan"); ok {
					cell.Pan = f
				}
				if f, ok := num(m, "pan_l"); ok {
					cell.PanL = f
				}
				if f, ok := num(m, "pan_r"); ok {
					cell.PanR = f
				}
			}
			shadow[k] = cell
		}
	}
	keys := make([]string, 0, len(shadow))
	for k := range shadow {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		if err := d.SetMixerKey(k, shadow[k]); err != nil {
			return fmt.Errorf("mixer %s: %w", k, err)
		}
	}
	return nil
}

// ResetMixer clears the loopback matrix on every bus (silent, centred).
func (d *evoDriver) ResetMixer() error {
	if d.hasDevice() {
		if err := d.begin(); err != nil {
			return err
		}
		defer d.end()
	}
	sources := (d.spec.MixerInputs - d.spec.NumInputs) / 2
	for bus := 0; bus < MixBuses(d.spec); bus++ {
		for i := 0; i < d.spec.NumInputs; i++ {
			if err := d.SetMixerInput(i+1, mixDbMin, 0, bus); err != nil {
				return err
			}
		}
		for i := 0; i < sources; i++ {
			if err := d.SetMixerOutput(i, mixDbMin, -100, 100, bus); err != nil {
				return err
			}
		}
	}
	return nil
}

// SetMixerKey restores one shadow cell by key ("inputN[@bus]",
// "outputX_Y[@bus]"), preserving a stereo source's separate pan_l/pan_r.
func (d *evoDriver) SetMixerKey(key string, cell MixerCell) error {
	base, bus := splitMixerKey(key)
	var n int
	if _, err := fmt.Sscanf(base, "input%d", &n); err == nil {
		return d.SetMixerInput(n, cell.VolumeDb, cell.Pan, bus)
	}
	var l, r int
	if _, err := fmt.Sscanf(base, "output%d_%d", &l, &r); err == nil && r == l+1 && l%2 == 1 {
		pl, pr := cell.PanL, cell.PanR
		if pl == 0 && pr == 0 && cell.Pan != 0 {
			pl, pr = cell.Pan, cell.Pan
		}
		return d.SetMixerOutput((l-1)/2, cell.VolumeDb, pl, pr, bus)
	}
	return fmt.Errorf("unknown mixer source %q", key)
}

func splitMixerKey(key string) (string, int) {
	base := key
	bus := 0
	if i := len(key) - 2; i > 0 && key[i] == '@' {
		var b int
		if _, err := fmt.Sscanf(key[i+1:], "%d", &b); err == nil {
			base, bus = key[:i], b
		}
	}
	return base, bus
}
