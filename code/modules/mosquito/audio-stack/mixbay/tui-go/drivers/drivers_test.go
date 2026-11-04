package drivers

import (
	"errors"
	"math"
	"os"
	"path/filepath"
	"testing"
)

func TestDbRoundtrip(t *testing.T) {
	for _, db := range []float64{-127, -96, -20, -3.5, 0, 25, 58} {
		if got := usbToDb(dbToUSB(db)); math.Abs(got-db) > 1.0/256+1e-9 {
			t.Errorf("db %v roundtrip = %v", db, got)
		}
	}
}

func TestPanLaw(t *testing.T) {
	l, r := panToLRDb(0, 0)
	if math.Abs(l+3.0103) > 0.01 || math.Abs(r+3.0103) > 0.01 {
		t.Errorf("center pan should be -3.01dB both, got %v %v", l, r)
	}
	l, r = panToLRDb(0, -100)
	if l != 0 || r != mixDbMin {
		t.Errorf("full left: got %v %v", l, r)
	}
	l, r = panToLRDb(0, 100)
	if r != 0 || l != mixDbMin {
		t.Errorf("full right: got %v %v", l, r)
	}
}

func TestEvo8MuteTargets(t *testing.T) {
	d := newEvo(EVO8Spec)
	if _, _, err := d.muteTarget("input3"); err != nil {
		t.Errorf("evo8 input3 mute: %v", err)
	}
	if _, _, err := d.muteTarget("output2"); err != nil {
		t.Errorf("evo8 output2 mute: %v", err)
	}
	if _, _, err := d.muteTarget("output"); err == nil {
		t.Errorf("evo8 has no bare 'output' target, expected error")
	}
	d4 := newEvo(EVO4Spec)
	if _, _, err := d4.muteTarget("output"); err != nil {
		t.Errorf("evo4 output mute: %v", err)
	}
}

// The EVO 8 firmware rejects the documented EU58 CS=2 output mute, so only the
// EVO 4 (EU59) may claim a native output mute; the EVO 8 emulates it via FU10.
func TestEvoOutputMuteCapability(t *testing.T) {
	d8 := newEvo(EVO8Spec)
	if d8.supportsNativeOutputMute() {
		t.Error("EVO 8 must not claim a native output mute")
	}
	if !d8.isOutputTarget("output1") || !d8.isOutputTarget("output2") {
		t.Error("EVO 8 output1/output2 must be output targets")
	}
	if d8.isOutputTarget("output") || d8.isOutputTarget("input1") {
		t.Error("EVO 8 'output'/'input1' are not output targets")
	}
	if d8.outputName(0) != "output1" || d8.outputName(1) != "output2" {
		t.Errorf("EVO 8 output names: %q %q", d8.outputName(0), d8.outputName(1))
	}
	d4 := newEvo(EVO4Spec)
	if !d4.supportsNativeOutputMute() {
		t.Error("EVO 4 has a native output mute (EU59)")
	}
	if !d4.isOutputTarget("output") || d4.outputName(0) != "output" {
		t.Error("EVO 4 bare output target")
	}
}

// The emulated-mute level memory must round-trip through disk.
func TestEvoOutputMuteMemory(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	d := newEvo(EVO8Spec)
	if err := d.saveOutputMutes(map[string]float64{"output1": -12}); err != nil {
		t.Fatal(err)
	}
	got := d.loadOutputMutes()
	if got["output1"] != -12 {
		t.Errorf("output mute memory = %v, want -12", got["output1"])
	}
}

func TestDemoStatus(t *testing.T) {
	// No hardware on CI: every driver must serve a demo status, never fail.
	for _, spec := range Registry() {
		drv, err := Open(spec.ID)
		if err != nil {
			t.Fatalf("open %s: %v", spec.ID, err)
		}
		t.Setenv("HOME", t.TempDir())
		drv2, _ := Open(spec.ID) // fresh driver, fresh HOME
		_ = drv
		st, err := drv2.Status()
		if err != nil {
			t.Errorf("%s status: %v", spec.ID, err)
			continue
		}
		if st.Online {
			t.Logf("%s: hardware online, skipping demo assertions", spec.ID)
			continue
		}
		if len(st.Inputs) != spec.NumInputs {
			t.Errorf("%s: %d inputs, want %d", spec.ID, len(st.Inputs), spec.NumInputs)
		}
		if len(st.Outputs) != spec.NumOutPairs {
			t.Errorf("%s: %d outputs, want %d", spec.ID, len(st.Outputs), spec.NumOutPairs)
		}
		// Demo writes persist.
		if err := drv2.SetVolume(0, -10); err != nil {
			t.Errorf("%s demo set volume: %v", spec.ID, err)
		}
		st2, _ := drv2.Status()
		if st2.Outputs[0].VolumeDb != -10 {
			t.Errorf("%s demo volume not persisted: %v", spec.ID, st2.Outputs[0].VolumeDb)
		}
	}
}

func TestEvo8SpecMatchesHardware(t *testing.T) {
	// The card/app displays 0…58 dB; FU11/ALSA carry the same gain as
	// -8…50 dB, hence the 8 dB display offset.
	if EVO8Spec.NumInputs != 4 || EVO8Spec.NumOutPairs != 2 {
		t.Errorf("evo8 io: %+v", EVO8Spec)
	}
	if EVO8Spec.GainMin != 0 || EVO8Spec.GainMax != 58 || EVO8Spec.GainOffset != 8 {
		t.Errorf("evo8 gain range: %+v", EVO8Spec)
	}
	if EVO8Spec.GainMin-EVO8Spec.GainOffset != -8 || EVO8Spec.GainMax-EVO8Spec.GainOffset != 50 {
		t.Errorf("evo8 wire gain range: %+v", EVO8Spec)
	}
	if EVO8Spec.VolMin != -127 {
		t.Errorf("evo8 volume floor = %v dB, want -127", EVO8Spec.VolMin)
	}
	if EVO8Spec.MixerInputs*EVO8Spec.MixerOutputs != 40 {
		t.Errorf("evo8 mixer should be 40 cross-points")
	}
	if EVO4Spec.MixerInputs*EVO4Spec.MixerOutputs != 12 {
		t.Errorf("evo4 mixer should be 12 cross-points")
	}
}

func TestMixerBusKeys(t *testing.T) {
	if got := MixerKey("input1", 0); got != "input1" {
		t.Errorf("bus 0 keeps the bare key, got %q", got)
	}
	if got := MixerKey("input1", 1); got != "input1@1" {
		t.Errorf("bus 1 suffix, got %q", got)
	}
	if got := MixBuses(EVO8Spec); got != 2 {
		t.Errorf("evo8 has 2 mix buses, got %d", got)
	}
	if got := MixBuses(EVO4Spec); got != 1 {
		t.Errorf("evo4 has 1 mix bus, got %d", got)
	}
	if got := BusLabel(1); got != "MIX 3|4" {
		t.Errorf("bus 1 label = %q, want MIX 3|4", got)
	}
}

func TestAlsaCapsRefuseUnsupported(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	d, _ := Open(DevUGM192)
	if err := d.SetGain(1, 20); err == nil {
		t.Errorf("ALSA gain should fail (analog knob)")
	}
	if err := d.SetPhantom(1, true); err == nil {
		t.Errorf("ALSA 48V should fail (hardware switch)")
	}
	if err := d.SetMonitor(50); err == nil {
		t.Errorf("ALSA monitor should fail")
	}
	if err := d.SetMixerInput(1, -6, 0, 0); err == nil {
		t.Errorf("ALSA mixer should fail (no DSP)")
	}
	if err := d.SetVolume(0, -10); err != nil {
		t.Errorf("ALSA volume should work in demo: %v", err)
	}
}

func TestEvoLoadRestoresEveryMixerRoute(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	// Force demo mode even where a real /dev/evo* node exists.
	t.Setenv("MOSQUITOMIXBAY_EVO_DEVDIR", t.TempDir())
	d, _ := Open(DevEVO8)
	if err := d.SetMixerInput(1, -6, -20, 0); err != nil {
		t.Fatalf("set mixer input: %v", err)
	}
	if err := d.SetMixerOutput(0, -3, 0, 0, 0); err != nil {
		t.Fatalf("set mixer output: %v", err)
	}
	if err := d.Save(); err != nil {
		t.Fatalf("save: %v", err)
	}
	// A fresh driver (as after a reboot): demo state is factory, but the
	// shadow files Save() wrote are still on disk.
	home, _ := os.UserHomeDir()
	_ = os.Remove(filepath.Join(home, ".config", "mosquitomixbay", DevEVO8, "demo.json"))
	d2, _ := Open(DevEVO8)
	st0, _ := d2.Status()
	if c := st0.Mixer["input1"]; c.VolumeDb != -128 || c.Pan != 0 {
		t.Fatalf("fresh demo should be neutral {-128 0}, got %+v", c)
	}
	if err := d2.Load(); err != nil {
		t.Fatalf("load: %v", err)
	}
	st, _ := d2.Status()
	if c := st.Mixer["input1"]; c.VolumeDb != -6 || c.Pan != -20 {
		t.Errorf("input1 not restored: %+v", c)
	}
	// The old Load silently dropped outputX_Y keys; both must come back.
	if c := st.Mixer["output1_2"]; c.VolumeDb != -3 {
		t.Errorf("output1_2 not restored: %+v", c)
	}
}

// The built-in "default" preset must leave the outputs at the minimum so
// loading it never blasts the monitors. Inputs stay at unity.
func TestEvoDefaultPresetOutputsAtMin(t *testing.T) {
	for _, id := range []string{EVO8Spec.ID, EVO4Spec.ID} {
		t.Setenv("HOME", t.TempDir())
		drv, err := Open(id)
		if err != nil {
			t.Fatal(err)
		}
		// Never reset real hardware from a test.
		pre, err := drv.Status()
		if err != nil {
			t.Fatal(err)
		}
		if pre.Online {
			t.Logf("%s: hardware online, skipping demo assertion", id)
			continue
		}
		r, ok := drv.(interface{ ResetToDefaults() error })
		if !ok {
			t.Fatalf("%s: ResetToDefaults missing", id)
		}
		if err := r.ResetToDefaults(); err != nil {
			t.Fatal(err)
		}
		st, err := drv.Status()
		if err != nil {
			t.Fatal(err)
		}
		for i, out := range st.Outputs {
			if out.VolumeDb != st.Spec.VolMin {
				t.Errorf("%s output %d = %v dB, want VolMin %v dB",
					id, i, out.VolumeDb, st.Spec.VolMin)
			}
		}
		for i, in := range st.Inputs {
			if in.GainDb != 0 {
				t.Errorf("%s input %d gain = %v dB, want 0", id, i, in.GainDb)
			}
		}
	}
}

// Read() is the explicit live seam: no interface means ErrOffline, while
// Status() keeps the historical DEMO fallback for the CLI and demo mode.
func TestEvoReadRequiresHardware(t *testing.T) {
	t.Setenv("MOSQUITOMIXBAY_EVO_DEVDIR", t.TempDir())
	d := newEvo(EVO8Spec)
	lr, ok := any(d).(LiveReader)
	if !ok {
		t.Fatal("*evoDriver must implement LiveReader")
	}
	st, err := lr.Read()
	if !errors.Is(err, ErrOffline) {
		t.Fatalf("Read() error = %v, want ErrOffline", err)
	}
	if st.Online {
		t.Fatal("Read() must not report online without hardware")
	}
	st, err = d.Status()
	if err != nil {
		t.Fatalf("Status() error = %v, want demo fallback", err)
	}
	if st.Online || st.Backend != BackendDemo {
		t.Fatalf("Status() = online=%v backend=%v, want demo", st.Online, st.Backend)
	}
	if st.Mixer["input1"].VolumeDb != -128 {
		t.Errorf("demo mixer default = %v, want -128", st.Mixer["input1"].VolumeDb)
	}
}

// Every bus must default to silence except the factory PC 1|2 → OUT 1|2
// route, which is open at 0 dB. Otherwise an untouched second bus renders
// as 0 dB and a pan tweak opens crosspoints at unity.
func TestEvoDefaultMixerCoversEveryBus(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("MOSQUITOMIXBAY_EVO_DEVDIR", t.TempDir())
	d := newEvo(EVO8Spec)
	st := d.demoStatus()
	for bus := 0; bus < MixBuses(EVO8Spec); bus++ {
		for _, src := range MixerSources(EVO8Spec, bus) {
			c, ok := st.Mixer[src]
			if !ok {
				t.Fatalf("missing default cell %q (bus %d)", src, bus)
			}
			want := -128.0
			if bus == 0 && src == "output1_2" {
				want = 0
			}
			if c.VolumeDb != want {
				t.Errorf("%q default volume = %v, want %v", src, c.VolumeDb, want)
			}
		}
	}
	if c := st.Mixer["output1_2"]; c.PanL != -100 || c.PanR != 100 {
		t.Errorf("factory route lost stereo width: %+v", c)
	}
}

// A live-only driver must never touch the persistent demo state when the
// interface disappears. This closes the sub-second window before the next
// poll notices the unplug.
func TestEvoLiveOnlyWritesRefuseOffline(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("MOSQUITOMIXBAY_EVO_DEVDIR", t.TempDir())
	d := newEvo(EVO8Spec)
	d.allowDemo = false

	writes := []struct {
		name string
		fn   func() error
	}{
		{"volume", func() error { return d.SetVolume(0, -12) }},
		{"gain", func() error { return d.SetGain(1, 12) }},
		{"mute", func() error { return d.SetMute("input1", true) }},
		{"phantom", func() error { return d.SetPhantom(1, true) }},
		{"mixer input", func() error { return d.SetMixerInput(1, -6, 0, 0) }},
		{"mixer output", func() error { return d.SetMixerOutput(0, -6, -100, 100, 0) }},
		{"save", d.Save},
		{"load", d.Load},
		{"reset", d.ResetToDefaults},
	}
	for _, w := range writes {
		if err := w.fn(); !errors.Is(err, ErrOffline) {
			t.Errorf("%s: err = %v, want ErrOffline", w.name, err)
		}
	}
	if _, err := os.Stat(d.demoFile()); !os.IsNotExist(err) {
		t.Fatalf("strict write created demo state: %v", err)
	}
	if _, err := OpenLive(DevEVO8); !errors.Is(err, ErrOffline) {
		t.Fatalf("OpenLive offline = %v, want ErrOffline", err)
	}
}

func TestALSALiveOnlyWritesRefuseOffline(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	d := newALSA(UGM192Spec)
	d.allowDemo = false
	if err := d.SetVolume(0, -12); !errors.Is(err, ErrOffline) {
		t.Fatalf("volume err = %v, want ErrOffline", err)
	}
	if err := d.SetMute("output", true); !errors.Is(err, ErrOffline) {
		t.Fatalf("mute err = %v, want ErrOffline", err)
	}
	if _, err := os.Stat(d.demoFile()); !os.IsNotExist(err) {
		t.Fatalf("strict ALSA write created demo state: %v", err)
	}
}

// A stereo loopback source must keep its channels apart: pan_l = -100 and
// pan_r = +100 send source L only to bus L and source R only to bus R. The
// old code folded both into both sides (the "everything is mono" bug).
func TestStereoSourceKeepsChannelsSeparate(t *testing.T) {
	ll, lr, rl, rr := stereoSourceGains(0, -100, 100)
	if ll != 0 || rr != 0 {
		t.Errorf("direct channels = %v/%v, want 0/0", ll, rr)
	}
	if lr != mixDbMin || rl != mixDbMin {
		t.Errorf("cross channels = %v/%v, want silence", lr, rl)
	}
	// Centred pans keep both source channels on both sides, each at -3 dB.
	ll, lr, rl, rr = stereoSourceGains(0, 0, 0)
	for _, db := range []float64{ll, lr, rl, rr} {
		if math.Abs(db+3.0103) > 0.01 {
			t.Errorf("centred stereo gain = %v, want -3.01", db)
		}
	}
}

// An old shadow without pan_l/pan_r must not collapse the stereo source to
// mono: the factory spread is kept for the missing fields.
func TestEvoShadowKeepsStereoPans(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("MOSQUITOMIXBAY_EVO_DEVDIR", t.TempDir())
	d := newEvo(EVO8Spec)
	if err := os.MkdirAll(d.shadowDir(), 0o755); err != nil {
		t.Fatal(err)
	}
	old := `{"output1_2":{"volume_db":-6,"pan":0}}`
	if err := os.WriteFile(d.shadowFile(), []byte(old), 0o644); err != nil {
		t.Fatal(err)
	}
	c := d.loadShadow()["output1_2"]
	if c.VolumeDb != -6 || c.PanL != -100 || c.PanR != 100 {
		t.Errorf("old shadow folded to mono: %+v", c)
	}
}

func TestEvoResetMixerBusDefaultsOnlyThatBus(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("MOSQUITOMIXBAY_EVO_DEVDIR", t.TempDir())
	d := newEvo(EVO8Spec)
	if err := d.SetMixerOutput(0, -20, 0, 0, 0); err != nil {
		t.Fatal(err)
	}
	if err := d.SetMixerInput(1, -6, 0, 1); err != nil {
		t.Fatal(err)
	}
	if err := d.ResetMixerBus(1); err != nil {
		t.Fatal(err)
	}
	st := d.demoStatus()
	if c := st.Mixer["output1_2"]; c.VolumeDb != -20 {
		t.Errorf("bus 0 was touched: %+v", c)
	}
	if c := st.Mixer["input1@1"]; c.VolumeDb != -128 {
		t.Errorf("bus 1 input not cleared: %+v", c)
	}
	if c := st.Mixer["output1_2@1"]; c.VolumeDb != -128 {
		t.Errorf("bus 1 default route = %+v, want silence at -128 dB", c)
	}
	if c := st.Mixer["output3_4@1"]; c.VolumeDb != -128 {
		t.Errorf("other source not cleared: %+v", c)
	}
}

// Bus 0 keeps the factory playback route on reset; the Artist Mix bus stays
// silent so a reset cannot leak PC 1|2 into OUT 3|4.
func TestEvoResetMixerBus0KeepsFactoryRoute(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("MOSQUITOMIXBAY_EVO_DEVDIR", t.TempDir())
	d := newEvo(EVO8Spec)
	if err := d.SetMixerOutput(0, -20, 0, 0, 0); err != nil {
		t.Fatal(err)
	}
	if err := d.ResetMixerBus(0); err != nil {
		t.Fatal(err)
	}
	st := d.demoStatus()
	if c := st.Mixer["output1_2"]; c.VolumeDb != 0 || c.PanL != -100 || c.PanR != 100 {
		t.Errorf("bus 0 route = %+v, want PC 1|2 at 0 dB full width", c)
	}
	if c := st.Mixer["output3_4"]; c.VolumeDb != -128 {
		t.Errorf("bus 0 non-factory source = %+v, want -128", c)
	}
}

// Mono channel levels become a ganged FU10 base plus a ≤ 0 dB PipeWire trim,
// so moving OUT 1 never moves OUT 2.
func TestEvoOutputPairSplit(t *testing.T) {
	base, trims := outputPairSplit(-6, -20)
	if base != -6 {
		t.Errorf("base = %v, want -6 (louder channel)", base)
	}
	if trims[0] != 0 || trims[1] != -14 {
		t.Errorf("trims = %v, want [0 -14]", trims)
	}

	applied := outputPairApplied(0, trims, map[string]float64{"ch2": -20})
	if applied[0] != 0 || applied[1] != mixDbMin {
		t.Errorf("muted trims = %v, want [0 -128]", applied)
	}

	// The louder channel moving below the other swaps the base and keeps the
	// quieter one at its level.
	base, trims = outputPairSplit(-110, -107)
	if base != -107 || trims[0] != -3 || trims[1] != 0 {
		t.Errorf("swap = %v %v, want -107 [-3 0]", base, trims)
	}
}

func TestDbToPactl(t *testing.T) {
	cases := map[float64]int{0: 65536, -6: 32846, -128: 0}
	for db, want := range cases {
		if got := dbToPactl(db); got != want {
			t.Errorf("dbToPactl(%v) = %d, want %d", db, got, want)
		}
	}
}

// ResetControls must leave the loopback matrix exactly as it was.
func TestEvoResetControlsLeavesMixer(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("MOSQUITOMIXBAY_EVO_DEVDIR", t.TempDir())
	d := newEvo(EVO8Spec)
	if err := d.SetMixerOutput(0, -12, 25, -25, 0); err != nil {
		t.Fatal(err)
	}
	before := d.demoStatus().Mixer["output1_2"]
	if err := d.ResetControls(); err != nil {
		t.Fatal(err)
	}
	if after := d.demoStatus().Mixer["output1_2"]; after != before {
		t.Errorf("controls reset changed the mixer: %+v -> %+v", before, after)
	}
}

// The page reset zeroes the input gains, floors the output volumes and leaves
// the outputs in stereo.
func TestEvoResetControlsFloorsOutputs(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("MOSQUITOMIXBAY_EVO_DEVDIR", t.TempDir())
	d := newEvo(EVO8Spec)
	if err := d.SetVolume(0, -40); err != nil {
		t.Fatal(err)
	}
	if err := d.SetGain(1, 20); err != nil {
		t.Fatal(err)
	}
	if err := d.SetPhantom(1, true); err != nil {
		t.Fatal(err)
	}
	if err := d.ResetControls(); err != nil {
		t.Fatal(err)
	}
	st := d.demoStatus()
	for i, out := range st.Outputs {
		if out.VolumeDb != st.Spec.VolMin || out.Muted {
			t.Errorf("output %d = %v dB muted=%v, want %v dB unmuted",
				i+1, out.VolumeDb, out.Muted, st.Spec.VolMin)
		}
	}
	for i, in := range st.Inputs {
		if in.GainDb != 0 || in.Muted || in.Phantom {
			t.Errorf("input %d = %v dB muted=%v 48V=%v, want 0/unmuted/off", i+1, in.GainDb, in.Muted, in.Phantom)
		}
	}
}
