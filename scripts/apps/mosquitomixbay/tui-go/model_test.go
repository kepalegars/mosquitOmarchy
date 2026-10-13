package main

import (
	"strings"
	"testing"

	"mosquitomarchy.local/mosquitomixbay-tui/drivers"
)

func demoStatus(t *testing.T, id string) drivers.Status {
	t.Helper()
	d, err := drivers.Open(id)
	if err != nil {
		t.Fatalf("open %s: %v", id, err)
	}
	st, err := d.Status()
	if err != nil {
		t.Fatalf("status %s: %v", id, err)
	}
	if st.Online {
		t.Skipf("%s hardware online, demo assertions skipped", id)
	}
	return st
}

func TestControlItemsEVO8(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	st := demoStatus(t, drivers.DevEVO8)
	items := controlItems(st)
	// 2 out pairs x (vol+mute) + 4 inputs x (gain+mute+48V) + mixer + save + load + back
	want := 2*2 + 4*3 + 4
	if len(items) != want {
		t.Errorf("evo8 control rows = %d, want %d", len(items), want)
	}
	joined := ""
	for _, it := range items {
		joined += it.Display + "\n"
	}
	for _, needle := range []string{"input3", "output2", "48V", "Loopback mixer"} {
		if !strings.Contains(joined, needle) {
			t.Errorf("control list missing %q", needle)
		}
	}
}

func TestControlItemsEVO4HasMonitor(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	st := demoStatus(t, drivers.DevEVO4)
	found := false
	for _, it := range controlItems(st) {
		if strings.HasPrefix(it.Display, "monitor") {
			found = true
		}
	}
	if !found {
		t.Errorf("evo4 controls should include the monitor blend row")
	}
}

func TestMixerItemsStableOrder(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	st := demoStatus(t, drivers.DevEVO8)
	a := mixerKeys(st)
	b := mixerKeys(st)
	if len(a) != len(b) {
		t.Fatalf("mixer key count unstable")
	}
	for i := range a {
		if a[i] != b[i] {
			t.Fatalf("mixer order unstable at %d: %q vs %q", i, a[i], b[i])
		}
	}
	if !strings.HasPrefix(a[0], "input") {
		t.Errorf("inputs should sort before usb playback sources, got %q first", a[0])
	}
}

func TestSetMixerSourceParsing(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	d, _ := drivers.Open(drivers.DevEVO8)
	if err := setMixerSource(d, "input2", -10, 20); err != nil {
		t.Errorf("input2: %v", err)
	}
	if err := setMixerSource(d, "output3_4", -3, 0); err != nil {
		t.Errorf("output3_4: %v", err)
	}
	if err := setMixerSource(d, "bogus", 0, 0); err == nil {
		t.Errorf("bogus source should fail")
	}
}

func TestDbFmt(t *testing.T) {
	if dbFmt(-128) != "-inf" {
		t.Errorf("mixer silence should render -inf, got %q", dbFmt(-128))
	}
	if !strings.Contains(dbFmt(-20), "20") {
		t.Errorf("dbFmt(-20) = %q", dbFmt(-20))
	}
}
