package patchbay

import (
	"strings"
	"testing"
)

// An aggregate's internal links touch hardware sinks but are not patchbay
// wiring. --replace must never remove them and they must not change a saved
// preset's fingerprint.
const aggregateFixture = `[
 {"id":10,"type":"PipeWire:Interface:Node","info":{"props":{"node.name":"alsa_output.usb-Audient_EVO8-00.pro-output-0","media.class":"Audio/Sink","audio.channels":2,"api.alsa.card":3,"device.class":"sound"}}},
 {"id":11,"type":"PipeWire:Interface:Node","info":{"props":{"node.name":"agg_studio_pair","media.class":"Audio/Sink","audio.channels":2,"node.virtual":true}}},
 {"id":100,"type":"PipeWire:Interface:Port","info":{"props":{"node.id":10,"port.name":"playback_FL","port.direction":"in"}}},
 {"id":200,"type":"PipeWire:Interface:Port","info":{"props":{"node.id":11,"port.name":"output_FL","port.direction":"out"}}},
 {"id":400,"type":"PipeWire:Interface:Link","info":{"output-port-id":200,"input-port-id":100}}
]`

func TestAggregateLinksAreNotHardwareWiring(t *testing.T) {
	g, err := Parse([]byte(aggregateFixture))
	if err != nil {
		t.Fatal(err)
	}
	if got := g.hardwareLinks(); len(got) != 0 {
		t.Fatalf("aggregate link leaked into hardwareLinks: %+v", got)
	}
	plain := Graph{Nodes: []Node{g.Nodes[0]}}
	p := Preset{Name: "plain", Fingerprint: plain.Fingerprint()}
	if !p.Applies(g) {
		t.Fatalf("fingerprint changed because of an aggregate link: %v vs %v", p.Fingerprint, g.Fingerprint())
	}
	if !g.HasLink(Link{OutNode: "agg_studio_pair", OutPort: "output_FL", InNode: "alsa_output.usb-Audient_EVO8-00.pro-output-0", InPort: "playback_FL"}) {
		t.Fatal("HasLink must still see aggregate links for repair")
	}
	if !strings.Contains(aggregateFixture, "agg_studio_pair") {
		t.Fatal("fixture must contain the aggregate node")
	}
}
