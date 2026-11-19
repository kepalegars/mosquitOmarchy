package profiles

import "testing"

const meterCardJSON = `{
  "schema_version": 1,
  "spec": {
    "id": "lab",
    "display": "Acme Lab",
    "vendor": "Acme",
    "num_inputs": 2,
    "num_output_pairs": 1,
    "backend": "alsa",
    "version": "v0.1.0",
    "caps": {"volume": true, "mute": true}
  },
  "ui": {"preset": "single-pair"},
  "hardware": {
    "meters": {
      "node": "Acme Lab",
      "capture": ["IN 1", "IN 2"],
      "playback": ["OUT L", "OUT R"],
      "floor_db": -48
    }
  }
}`

func TestParseAcceptsMeterBinding(t *testing.T) {
	card, issues, err := Parse([]byte(meterCardJSON))
	if err != nil {
		t.Fatal(err)
	}
	if errs := Errors(issues); len(errs) > 0 {
		t.Fatalf("valid card rejected: %v", errs)
	}
	if card.Hardware == nil || card.Hardware.Meters == nil {
		t.Fatal("hardware.meters was not parsed")
	}
	m := card.Hardware.Meters
	if m.Node != "Acme Lab" || len(m.Capture) != 2 || len(m.Playback) != 2 || m.FloorDb != -48 {
		t.Fatalf("binding = %+v", m)
	}
}

func TestParseRejectsMeterBindingTypos(t *testing.T) {
	cases := map[string]string{
		"hardware.metre":      `{"metre":{}}`,
		"hardware.meters.nod": `{"meters":{"nod":"x","capture":["IN1"]}}`,
	}
	for field, hw := range cases {
		raw := `{"schema_version":1,"spec":{"id":"lab","display":"Lab","vendor":"Acme","num_inputs":1,"num_output_pairs":1,"backend":"alsa","version":"v1","caps":{"volume":true}},"ui":{"preset":"auto"},"hardware":` + hw + `}`
		_, issues, err := Parse([]byte(raw))
		if err != nil {
			t.Fatal(err)
		}
		found := false
		for _, i := range issues {
			if i.Field == field {
				found = true
			}
		}
		if !found {
			t.Errorf("%s not reported in %+v", field, issues)
		}
	}
}

func TestValidateMeterBindingEdges(t *testing.T) {
	base := func(m *Meters) []Issue {
		c := Card{
			SchemaVersion: SchemaVersion,
			Spec: Spec{
				ID: "lab", Display: "Lab", Vendor: "Acme",
				NumInputs: 1, NumOutPairs: 1,
				Backend: BackendALSA, Version: "v1",
				Caps: Caps{Volume: true},
			},
			UI:       map[string]any{"preset": "auto"},
			Hardware: &Hardware{Meters: m},
		}
		return Errors(Validate(c))
	}
	if errs := base(&Meters{Node: "Acme", Capture: []string{"IN1"}}); len(errs) > 0 {
		t.Fatalf("single direction rejected: %v", errs)
	}
	if errs := base(&Meters{Node: " ", Capture: []string{"IN1"}}); len(errs) == 0 {
		t.Fatal("empty node accepted")
	}
	if errs := base(&Meters{Node: "Acme"}); len(errs) == 0 {
		t.Fatal("binding without channels accepted")
	}
	if errs := base(&Meters{Node: "Acme", Capture: []string{"IN1", "IN1"}}); len(errs) == 0 {
		t.Fatal("duplicate labels accepted")
	}
	many := make([]string, MaxMeterChannels+1)
	for i := range many {
		many[i] = string(rune('A' + i))
	}
	if errs := base(&Meters{Node: "Acme", Capture: many}); len(errs) == 0 {
		t.Fatal("oversized channel map accepted")
	}
	if errs := base(&Meters{Node: "Acme", Capture: []string{"IN1"}, FloorDb: 1}); len(errs) == 0 {
		t.Fatal("positive floor accepted")
	}
}

// spec.upstream is part of the format (direct RME updates); it must survive
// the strict key check like any other field.
func TestParseAcceptsUpstream(t *testing.T) {
	raw := `{"schema_version":1,"spec":{"id":"lab","display":"Lab","vendor":"Acme","num_inputs":1,"num_output_pairs":1,"backend":"alsa","version":"v1","caps":{"volume":true},"upstream":"https://raw.githubusercontent.com/kepalegars/mosquito-mixbay-profiles/main/cards/lab/card.json"},"ui":{"preset":"auto"}}`
	if _, issues, err := Parse([]byte(raw)); err != nil {
		t.Fatal(err)
	} else if errs := Errors(issues); len(errs) > 0 {
		t.Fatalf("spec.upstream rejected: %v", errs)
	}
}
