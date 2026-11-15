package drivers

import "testing"

func TestBetaDeviceRoundTrip(t *testing.T) {
	t.Setenv("HOME", t.TempDir())

	b, err := AddBetaDevice("PreSonus Quantum ES 4", "Quantum ES")
	if err != nil {
		t.Fatal(err)
	}
	var s Spec
	found := false
	for _, spec := range BetaSpecs() {
		if spec.ID == b.ID {
			s, found = spec, true
		}
	}
	if !found {
		t.Fatalf("beta spec %s missing from the store", b.ID)
	}
	if !s.Beta || s.Version != "beta" || s.Display != "PreSonus Quantum ES 4" {
		t.Fatalf("beta spec = %+v", s)
	}
	if len(s.CardMatch) != 1 || s.CardMatch[0] != "Quantum ES" {
		t.Fatalf("card match = %v", s.CardMatch)
	}
	d, err := Open(b.ID)
	if err != nil {
		t.Fatalf("open beta: %v", err)
	}
	if d.Spec().ID != b.ID || !d.Spec().Beta {
		t.Fatalf("opened %+v, want beta %s", d.Spec(), b.ID)
	}
	// Adding again must not duplicate.
	if _, err := AddBetaDevice("PreSonus Quantum ES 4", "Quantum ES"); err != nil {
		t.Fatal(err)
	}
	if got := len(BetaDevices()); got != 6 { // five seeded cards + this beta
		t.Fatalf("duplicate add: %d entries", got)
	}
	if err := RemoveBetaDevice(b.ID); err != nil {
		t.Fatal(err)
	}
	for _, spec := range BetaSpecs() {
		if spec.ID == b.ID {
			t.Fatal("beta spec survived removal")
		}
	}
}
