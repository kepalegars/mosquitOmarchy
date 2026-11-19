package drivers

import (
	"testing"

	"mosquitomarchy.local/mosquitomixbay-tui/profiles"
)

// A card's meter binding is data: the runtime spec must carry it, and the
// slices must not alias the card's.
func TestSpecFromProfileCarriesMeters(t *testing.T) {
	card := profiles.Card{
		Spec: profiles.Spec{
			ID: "lab", Display: "Lab", Vendor: "Acme",
			NumInputs: 2, NumOutPairs: 1, Backend: profiles.BackendALSA,
			Version: "v1", Caps: profiles.Caps{Volume: true},
		},
		Hardware: &profiles.Hardware{Meters: &profiles.Meters{
			Node:     "Acme Lab",
			Capture:  []string{"IN1", "IN2"},
			Playback: []string{"OUT1", "OUT2"},
			FloorDb:  -48,
		}},
	}
	spec := specFromProfile(card)
	if spec.Meters == nil {
		t.Fatal("meters dropped in conversion")
	}
	if spec.Meters.Node != "Acme Lab" || len(spec.Meters.Capture) != 2 || spec.Meters.FloorDb != -48 {
		t.Fatalf("binding = %+v", spec.Meters)
	}
	card.Hardware.Meters.Capture[0] = "CHANGED"
	if spec.Meters.Capture[0] != "IN1" {
		t.Fatal("capture labels alias the card")
	}
}
