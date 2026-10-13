package drivers

import (
	"math"
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
