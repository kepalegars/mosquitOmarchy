package main

import (
	"strings"
	"testing"
)

func TestLogoHoldBox(t *testing.T) {
	m := model{hold: true, w: 90, h: 30}
	out := m.logoWordmark()
	if !strings.Contains(out, "╭") || !strings.Contains(out, "╰") {
		t.Fatalf("hold draw should frame the logo with a rounded box, got:\n%s", out)
	}
	t.Log("framed art:\n" + m.logoWordmark())
}

func TestTunerGaugeSpan(t *testing.T) {
	m := model{}
	// Rune layout: ♭ (0) + 17 cells (1..17) + ♯ (18); needle cell pos p
	// lands at rune index 1+p. cents 0 → p=8 → idx 9; +50 → p=16 → idx 17;
	// -50 → p=0 → idx 1.
	idx := func(s string) int {
		for i, r := range []rune(s) {
			if r == '●' {
				return i
			}
		}
		return -1
	}
	if g := m.tunerGauge(0, true); idx(g) != 9 {
		t.Fatalf("gauge@0 needle should sit on the center marker, got %q (idx %d)", g, idx(g))
	}
	if g := m.tunerGauge(50, true); idx(g) != 17 {
		t.Fatalf("gauge@+50 needle should sit at the sharp end, got %q (idx %d)", g, idx(g))
	}
	if g := m.tunerGauge(-50, true); idx(g) != 1 {
		t.Fatalf("gauge@-50 needle should sit at the flat end, got %q (idx %d)", g, idx(g))
	}
	if g := m.tunerGauge(32, true); idx(g) < 9 || idx(g) > 17 {
		t.Fatalf("gauge@+32 needle should be right of center, got %q (idx %d)", g, idx(g))
	}
	if g := m.tunerGauge(0, false); idx(g) != -1 {
		t.Fatalf("idle gauge should have no needle, got %q", g)
	}
	t.Log("gauge(+32):", m.tunerGauge(32, true))
}