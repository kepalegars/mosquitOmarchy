// EVO 4 / EVO 8 driver — Go port of vanzaho/audient-evo-py.
//
// Protocol: USB control transfers on endpoint 0 via the evo_raw kernel
// module (/dev/evo4, /dev/evo8). The module binds the unused DFU interface
// so snd-usb-audio keeps streaming undisturbed. All entity IDs, ranges and
// quirks below come from audient-evo-py's dev/DESIGN.md (public domain):
//
//	FU10 0x0A00 CS=2 : output volume, 2B signed UAC2 (1/256 dB), [-96,0] dB
//	FU11 0x0B00 CS=2 : input gain per CN, EVO4 [-8,50], EVO8 [0,58] dB
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
	"fmt"
	"math"
	"os"
	"path/filepath"
	"sort"
	"unsafe"

	"golang.org/x/sys/unix"
)

// Device specs — mirrors evo/devices.py.
var (
	EVO8Spec = Spec{
		ID: "evo8", Display: "Audient EVO 8", Vendor: "Audient",
		USBVID: "2708", USBPID: "0007",
		NumInputs: 4, NumOutPairs: 2,
		GainMin: 0, GainMax: 58, VolMin: -96, VolMax: 0,
		MixerInputs: 10, MixerOutputs: 4,
		HasMonitor: false, Backend: BackendEvoRaw, NeedsKmod: true,
		Description: "4 in / 2 out pairs + loopback. Monitoring via mixer matrix.",
	}
	EVO4Spec = Spec{
		ID: "evo4", Display: "Audient EVO 4", Vendor: "Audient",
		USBVID: "2708", USBPID: "0006",
		NumInputs: 2, NumOutPairs: 1,
		GainMin: -8, GainMax: 50, VolMin: -96, VolMax: 0,
		MixerInputs: 6, MixerOutputs: 2,
		HasMonitor: true, Backend: BackendEvoRaw, NeedsKmod: true,
		Description: "2 in / 1 out pair + loopback. Direct-monitor blend knob.",
	}
)

const (
	fu10     = 0x0A00
	fu11     = 0x0B00
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

func dbToUSB(db float64) uint16 { return uint16(int32(math.Round(db * 256)) & 0xFFFF) }
func usbToDb(raw uint16) float64 { return float64(int16(raw)) / 256.0 }
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

type evoDriver struct {
	spec Spec
	demo *demoState // non-nil once demo fallback is engaged
}

func newEvo(spec Spec) *evoDriver { return &evoDriver{spec: spec} }

func (d *evoDriver) Spec() Spec { return d.spec }

func (d *evoDriver) devPath() string { return filepath.Join("/dev", d.spec.ID) }

// Probe: the kmod device node exists and opens.
func (d *evoDriver) Probe() bool {
	fd, err := unix.Open(d.devPath(), unix.O_RDONLY, 0)
	if err != nil {
		return false
	}
	unix.Close(fd)
	return true
}

func (d *evoDriver) online() bool { return d.demo == nil && d.Probe() }

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
	fd, err := unix.Open(d.devPath(), unix.O_RDONLY, 0)
	if err != nil {
		return nil, err
	}
	defer unix.Close(fd)
	buf := evoXfer(0xA1, 0x01, wValue, wIndex, uint16(length), make([]byte, 256))
	if err := ioctlCtrl(fd, buf); err != nil {
		return nil, fmt.Errorf("GET_CUR wValue=%#04x wIndex=%#04x: %w", wValue, wIndex, err)
	}
	respLen := int(binary.LittleEndian.Uint16(buf[6:]))
	if respLen > 256 {
		respLen = 256
	}
	out := make([]byte, respLen)
	copy(out, buf[8:8+respLen])
	return out, nil
}

func (d *evoDriver) setCur(wValue, wIndex uint16, data []byte) error {
	fd, err := unix.Open(d.devPath(), unix.O_RDONLY, 0)
	if err != nil {
		return err
	}
	defer unix.Close(fd)
	payload := make([]byte, 256)
	copy(payload, data)
	buf := evoXfer(0x21, 0x01, wValue, wIndex, uint16(len(data)), payload)
	if err := ioctlCtrl(fd, buf); err != nil {
		return fmt.Errorf("SET_CUR wValue=%#04x wIndex=%#04x: %w", wValue, wIndex, err)
	}
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

func bool4(b bool) []byte {
	var v [4]byte
	if b {
		binary.LittleEndian.PutUint32(v[:], 1)
	}
	return v[:]
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
	Volumes []float64          `json:"volumes"`
	Gains   []float64          `json:"gains"`
	Mutes   map[string]bool    `json:"mutes"`
	Phantom map[string]bool    `json:"phantom"`
	Monitor int                `json:"monitor"`
	Mixer   map[string]MixerCell `json:"mixer"`
}

func defaultMixerCells(spec Spec) map[string]MixerCell {
	m := map[string]MixerCell{}
	nSrc := (spec.MixerInputs - spec.NumInputs) / 2
	for i := 0; i < spec.NumInputs; i++ {
		m[fmt.Sprintf("input%d", i+1)] = MixerCell{VolumeDb: -128, Pan: 0}
	}
	for i := 0; i < nSrc; i++ {
		m[fmt.Sprintf("output%d_%d", i*2+1, i*2+2)] = MixerCell{VolumeDb: -128, Pan: 0}
	}
	// Factory default: diagonal routes open at 0 dB (as on hardware).
	m["input1"] = MixerCell{VolumeDb: 0, Pan: -100}
	if spec.NumInputs > 1 {
		m["input2"] = MixerCell{VolumeDb: 0, Pan: 100}
	}
	m["output1_2"] = MixerCell{VolumeDb: 0, Pan: 0}
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
		if d.spec.ID == "evo4" {
			st.Gains[i] = -8
		} else {
			st.Gains[i] = 25
		}
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

// --- Driver implementation ----------------------------------------------

func (d *evoDriver) Status() (Status, error) {
	st := Status{Spec: d.spec, Mixer: map[string]MixerCell{}}
	if !d.Probe() {
		demo := d.ensureDemo()
		st.Online = false
		st.Backend = BackendDemo
		st.Note = fmt.Sprintf("DEMO — %s not found (need evo_raw kmod + plugged interface). State is simulated and persistent.", d.devPath())
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
		return st, nil
	}
	d.demo = nil
	st.Online = true
	st.Backend = BackendEvoRaw
	// Volumes (CH1 of each pair; pairs are ganged on write).
	for i := 0; i < d.spec.NumOutPairs; i++ {
		raw, err := d.getFU(fu10, i*2+1)
		if err != nil {
			return st, err
		}
		name := fmt.Sprintf("output%d", i+1)
		if d.spec.NumOutPairs == 1 {
			name = "output"
		}
		muted := false
		if wV, wI, err := d.muteTarget(name); err == nil {
			if b, err := d.getCur(wV, wI, 4); err == nil && len(b) >= 4 {
				muted = binary.LittleEndian.Uint32(b) == 1
			}
		}
		st.Outputs = append(st.Outputs, OutputState{Name: name, VolumeDb: usbToDb(raw), Muted: muted})
	}
	for i := 0; i < d.spec.NumInputs; i++ {
		name := fmt.Sprintf("input%d", i+1)
		raw, err := d.getFU(fu11, i+1)
		if err != nil {
			return st, err
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
		st.Inputs = append(st.Inputs, InputState{Name: name, GainDb: math.Round(usbToDb(raw)), Muted: muted, Phantom: phantom})
	}
	if d.spec.HasMonitor {
		if b, err := d.getCur(0x0000, eu56, 2); err == nil && len(b) >= 2 {
			v := int(math.Round(float64(binary.LittleEndian.Uint16(b)) * 100 / 127))
			st.Monitor = &v
		}
	}
	// Mixer is write-only on hardware: serve the persisted shadow.
	st.Mixer = d.loadMixerShadow()
	return st, nil
}

func (d *evoDriver) SetVolume(pair int, db float64) error {
	db = clamp(db, d.spec.VolMin, d.spec.VolMax)
	if !d.Probe() {
		demo := d.ensureDemo()
		if pair < 0 {
			for i := range demo.Volumes {
				demo.Volumes[i] = db
			}
		} else {
			if pair >= len(demo.Volumes) {
				return fmt.Errorf("output pair %d out of range", pair)
			}
			demo.Volumes[pair] = db
		}
		d.saveDemo()
		return nil
	}
	raw := dbToUSB(db)
	pairs := []int{pair}
	if pair < 0 {
		pairs = pairs[:0]
		for i := 0; i < d.spec.NumOutPairs; i++ {
			pairs = append(pairs, i)
		}
	}
	for _, p := range pairs {
		base := p*2 + 1
		for _, cn := range []int{base, base + 1} {
			if err := d.setFU(fu10, cn, raw); err != nil {
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
	if !d.Probe() {
		demo := d.ensureDemo()
		demo.Gains[input-1] = math.Round(db)
		d.saveDemo()
		return nil
	}
	return d.setFU(fu11, input, dbToUSB(db))
}

func (d *evoDriver) SetMute(target string, muted bool) error {
	if !d.Probe() {
		demo := d.ensureDemo()
		demo.Mutes[target] = muted
		d.saveDemo()
		return nil
	}
	wV, wI, err := d.muteTarget(target)
	if err != nil {
		return err
	}
	return d.setCur(wV, wI, bool4(muted))
}

func (d *evoDriver) SetPhantom(input int, on bool) error {
	if input < 1 || input > d.spec.NumInputs {
		return fmt.Errorf("input must be 1..%d", d.spec.NumInputs)
	}
	name := fmt.Sprintf("input%d", input)
	if !d.Probe() {
		demo := d.ensureDemo()
		demo.Phantom[name] = on
		d.saveDemo()
		return nil
	}
	return d.setCur(uint16(input-1), eu58, bool4(on))
}

func (d *evoDriver) SetMonitor(v int) error {
	if !d.spec.HasMonitor {
		return fmt.Errorf("%s has no direct monitor control (use the mixer matrix)", d.spec.Display)
	}
	v = int(clamp(float64(v), 0, 100))
	if !d.Probe() {
		demo := d.ensureDemo()
		demo.Monitor = v
		d.saveDemo()
		return nil
	}
	raw := uint16(math.Round(float64(v) * 127 / 100))
	var b [2]byte
	binary.LittleEndian.PutUint16(b[:], raw)
	return d.setCur(0x0000, eu56, b[:])
}

// mixer CN helpers (UAC2: CN = out_idx + in_idx * num_outputs).
func (d *evoDriver) setCrosspoint(cn int, db float64) error {
	max := d.spec.MixerInputs * d.spec.MixerOutputs
	if cn < 0 || cn >= max {
		return fmt.Errorf("cross-point CN must be 0..%d", max-1)
	}
	db = clamp(db, mixDbMin, mixDbMax)
	if !d.Probe() {
		return nil // shadow updated by caller
	}
	var b [2]byte
	binary.LittleEndian.PutUint16(b[:], dbToUSB(db))
	return d.setCur(uint16(csMixer<<8|cn), mu60, b[:])
}

func (d *evoDriver) SetMixerInput(input int, volDb, pan float64, mixOut int) error {
	if input < 1 || input > d.spec.NumInputs {
		return fmt.Errorf("input must be 1..%d", d.spec.NumInputs)
	}
	if mixOut < 0 || mixOut >= d.spec.NumOutPairs {
		return fmt.Errorf("mix bus must be 0..%d", d.spec.NumOutPairs-1)
	}
	if !d.Probe() {
		demo := d.ensureDemo()
		demo.Mixer[fmt.Sprintf("input%d", input)] = MixerCell{VolumeDb: volDb, Pan: pan}
		d.saveDemo()
		return nil
	}
	lDb, rDb := panToLRDb(volDb, pan)
	base := (input-1)*d.spec.MixerOutputs + mixOut*2
	if err := d.setCrosspoint(base, lDb); err != nil {
		return err
	}
	if err := d.setCrosspoint(base+1, rDb); err != nil {
		return err
	}
	d.updateMixerShadow(fmt.Sprintf("input%d", input), MixerCell{VolumeDb: volDb, Pan: pan})
	return nil
}

func (d *evoDriver) SetMixerOutput(srcPair int, volDb, panL, panR float64, mixOut int) error {
	nSrc := (d.spec.MixerInputs - d.spec.NumInputs) / 2
	if srcPair < 0 || srcPair >= nSrc {
		return fmt.Errorf("source pair must be 0..%d", nSrc-1)
	}
	if mixOut < 0 || mixOut >= d.spec.NumOutPairs {
		return fmt.Errorf("mix bus must be 0..%d", d.spec.NumOutPairs-1)
	}
	key := fmt.Sprintf("output%d_%d", srcPair*2+1, srcPair*2+2)
	cell := MixerCell{VolumeDb: volDb, Pan: (panL + panR) / 2}
	if !d.Probe() {
		demo := d.ensureDemo()
		demo.Mixer[key] = cell
		d.saveDemo()
		return nil
	}
	inL := d.spec.NumInputs + srcPair*2
	inR := inL + 1
	lDbL, rDbL := panToLRDb(volDb, panL)
	lDbR, rDbR := panToLRDb(volDb, panR)
	off := mixOut * 2
	for cn, db := range map[int]float64{
		inL*d.spec.MixerOutputs + off:     lDbL,
		inL*d.spec.MixerOutputs + off + 1: rDbL,
		inR*d.spec.MixerOutputs + off:     lDbR,
		inR*d.spec.MixerOutputs + off + 1: rDbR,
	} {
		if err := d.setCrosspoint(cn, db); err != nil {
			return err
		}
	}
	d.updateMixerShadow(fmt.Sprintf("output%d_%d", srcPair*2+1, srcPair*2+2),
		MixerCell{VolumeDb: volDb, Pan: (panL + panR) / 2})
	return nil
}

// --- mixer shadow + save/load -------------------------------------------
// Same location as upstream (~/.config/audient-evo-py/<dev>/.mixer-state.json)
// so evoctl/evotui shadows stay interchangeable.

func (d *evoDriver) shadowDir() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "audient-evo-py", d.spec.ID)
}

func (d *evoDriver) loadMixerShadow() map[string]MixerCell {
	m := defaultMixerCells(d.spec)
	data, err := os.ReadFile(filepath.Join(d.shadowDir(), ".mixer-state.json"))
	if err != nil {
		return m
	}
	var raw map[string]map[string]float64
	if json.Unmarshal(data, &raw) == nil {
		for k, v := range raw {
			m[k] = MixerCell{VolumeDb: v["volume"], Pan: v["pan"]}
		}
		return m
	}
	var flat map[string]MixerCell
	if json.Unmarshal(data, &flat) == nil {
		for k, v := range flat {
			m[k] = v
		}
	}
	return m
}

func (d *evoDriver) updateMixerShadow(key string, cell MixerCell) {
	if d.demo != nil {
		d.demo.Mixer[key] = cell
		d.saveDemo()
		return
	}
	m := d.loadMixerShadow()
	m[key] = cell
	_ = os.MkdirAll(d.shadowDir(), 0o755)
	data, _ := json.MarshalIndent(m, "", "  ")
	_ = os.WriteFile(filepath.Join(d.shadowDir(), ".mixer-state.json"), data, 0o644)
}

// Save snapshots readable controls to config.json (upstream-compatible).
func (d *evoDriver) Save() error {
	st, err := d.Status()
	if err != nil {
		return err
	}
	cfg := map[string]any{}
	for _, o := range st.Outputs {
		cfg[o.Name] = map[string]any{"volume": o.VolumeDb, "mute": o.Muted}
	}
	for _, i := range st.Inputs {
		cfg[i.Name] = map[string]any{"gain": i.GainDb, "mute": i.Muted, "phantom": i.Phantom}
	}
	if st.Monitor != nil {
		cfg["monitor"] = *st.Monitor
	}
	_ = os.MkdirAll(d.shadowDir(), 0o755)
	data, _ := json.MarshalIndent(cfg, "", "  ")
	return os.WriteFile(filepath.Join(d.shadowDir(), "config.json"), data, 0o644)
}

// Load re-applies config.json + the mixer shadow.
func (d *evoDriver) Load() error {
	data, err := os.ReadFile(filepath.Join(d.shadowDir(), "config.json"))
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
	shadow := d.loadMixerShadow()
	var keys []string
	for k := range shadow {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		cell := shadow[k]
		var inNum int
		if _, err := fmt.Sscanf(k, "input%d", &inNum); err == nil {
			if err := d.SetMixerInput(inNum, cell.VolumeDb, cell.Pan, 0); err != nil {
				return err
			}
		}
	}
	return nil
}
