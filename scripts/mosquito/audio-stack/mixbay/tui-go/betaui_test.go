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

// Add an audio interface lists the name only: the PipeWire profile string
// ("output:analog-surround-40+input:analog-surround-71") is noise there.
func TestAddInterfaceShowsNameOnly(t *testing.T) {
	m := initialModel()
	m.scanCards = []scanCard{{Name: "PreSonus Quantum ES 4", Match: "Quantum ES 4"}}
	items := m.addInterfaceItems()
	if len(items) < 2 {
		t.Fatalf("add-interface items = %+v", items)
	}
	if got := items[1].Display; got != "  PreSonus Quantum ES 4" {
		t.Fatalf("row = %q, want name only", got)
	}
}
