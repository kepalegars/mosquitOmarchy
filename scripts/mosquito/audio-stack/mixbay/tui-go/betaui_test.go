package main

import "testing"

func TestIsNativeCard(t *testing.T) {
	native := []string{
		"alsa_card.usb-Audient_EVO8-00",
		"Audient EVO 4",
		"Solid State Logic SSL 12",
		"RME Fireface UCX II",
		"ESI UGM192",
	}
	for _, s := range native {
		if !isNativeCard(s) {
			t.Errorf("%q should be native", s)
		}
	}
	if isNativeCard("PreSonus Quantum ES 4") {
		t.Error("Quantum ES 4 must stay available for the beta/reverse-engineering path")
	}
}
