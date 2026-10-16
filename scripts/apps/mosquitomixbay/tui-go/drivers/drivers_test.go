package drivers

import (
	"math"
	"os"
	"path/filepath"
	"testing"
)

func TestDbRoundtrip(t *testing.T) {
	for _, db := range []float64{-96, -20, -3.5, 0, 25, 58} {
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

func TestEvo8SpecMatchesUpstream(t *testing.T) {
	// Values cross-checked against audient-evo-py evo/devices.py.
	if EVO8Spec.NumInputs != 4 || EVO8Spec.NumOutPairs != 2 {
		t.Errorf("evo8 io: %+v", EVO8Spec)
	}
	if EVO8Spec.GainMin != 0 || EVO8Spec.GainMax != 58 {
		t.Errorf("evo8 gain range: %+v", EVO8Spec)
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
	if c := st0.Mixer["input1"]; c.VolumeDb != 0 || c.Pan != -100 {
		t.Fatalf("fresh demo should be factory {0 -100}, got %+v", c)
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
