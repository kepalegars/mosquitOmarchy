package aggregate

import (
	"strings"
	"testing"

	"mosquitomarchy.local/mosquitomixbay-tui/patchbay"
)

func testGraph() patchbay.Graph {
	return patchbay.Graph{Nodes: []patchbay.Node{
		{Name: "alsa_output.usb-Audient_EVO8-00.pro-output-0", Class: "Audio/Sink", Channels: 2, Hardware: true, Profile: "pro-audio", Card: "EVO8", Device: "alsa_card.usb-Audient_EVO8-00"},
		{Name: "alsa_output.usb-ESI_UGM192-00.analog-stereo", Class: "Audio/Sink", Channels: 2, Hardware: true},
		{Name: "alsa_input.usb-Audient_EVO8-00.pro-input-0", Class: "Audio/Source", Channels: 2, Hardware: true},
	}}
}

func TestPresetNamesAlwaysUseAggPrefix(t *testing.T) {
	p := Preset{Name: "Studio pair"}
	if p.SinkName() != "agg_studio_pair" || p.SourceName() != "agg_studio_pair_in" {
		t.Fatalf("names = %q / %q", p.SinkName(), p.SourceName())
	}
}

func TestValidateRejectsUnsafeMembers(t *testing.T) {
	cases := []Preset{
		{Name: "ok", Outputs: []Member{{Node: "agg_self"}}},
		{Name: "ok", Inputs: []Member{{Node: "agg_studio_pair:monitor"}}},
		{Name: "ok", Outputs: []Member{{Node: "card"}, {Node: "card"}}},
		{Name: "agg_prefix", Outputs: []Member{{Node: "card"}}},
		{Name: "ok"},
	}
	for _, p := range cases {
		if err := p.Validate(); err == nil {
			t.Errorf("%+v should be rejected", p)
		}
	}
}

func TestMakePresetKeepsSelectorKeys(t *testing.T) {
	p, err := MakePreset("Studio pair", "Studio", testGraph(),
		[]string{"alsa_output.usb-Audient_EVO8-00.pro-output-0"},
		[]string{"alsa_input.usb-Audient_EVO8-00.pro-input-0"})
	if err != nil {
		t.Fatal(err)
	}
	if len(p.Outputs) != 1 || !p.Outputs[0].Drift {
		t.Fatalf("outputs = %+v", p.Outputs)
	}
	if p.Outputs[0].Profile != "pro-audio" || p.Outputs[0].Card != "EVO8" {
		t.Fatalf("selector lost: %+v", p.Outputs[0])
	}
	if p.DisplayName != "Studio" || !p.Applies() {
		t.Fatalf("unexpected preset: %+v", p)
	}
	if _, err := MakePreset("bad", "", testGraph(), []string{"missing"}, nil); err == nil {
		t.Fatal("unknown node must be refused")
	}
}

func TestModuleArgsCarriesDriftAndSelector(t *testing.T) {
	p := Preset{Name: "Studio pair", DisplayName: "Studio"}
	out := moduleArgs(p, p.SinkName(), "Studio", "sink", []Member{
		{Node: "card_a", Class: "Audio/Sink", Profile: "pro", Drift: true, Quality: 6, Latency: 1024},
		{Node: "card_b", Class: "Audio/Sink", Drift: false},
	}, 48000)
	for _, want := range []string{
		`combine.mode = sink`,
		`node.name = "agg_studio_pair"`,
		`device.profile.name = "pro"`,
		`node.name = "card_a"`,
		`resample.quality = 6`,
		`node.latency = 1024/48000`,
		`resample.disable = true`,
	} {
		if !strings.Contains(out, want) {
			t.Errorf("args missing %q:\n%s", want, out)
		}
	}
	src := moduleArgs(p, p.SourceName(), "Studio in", "source", []Member{{Node: "mic", Class: "Audio/Source", Drift: true}}, 48000)
	if !strings.Contains(src, `combine.mode = source`) || !strings.Contains(src, `media.class = "Audio/Source"`) {
		t.Fatalf("source args wrong:\n%s", src)
	}
}
