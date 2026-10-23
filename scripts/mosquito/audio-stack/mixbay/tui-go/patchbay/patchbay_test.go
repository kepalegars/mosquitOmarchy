package patchbay

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const fixture = `[
 {"id":10,"type":"PipeWire:Interface:Node","info":{"props":{"node.name":"alsa_output.usb-Audient_EVO8-00.pro-output-0","node.description":"EVO8 Pro","media.class":"Audio/Sink","audio.channels":6,"api.alsa.card":3,"device.class":"sound"}}},
 {"id":20,"type":"PipeWire:Interface:Node","info":{"props":{"node.name":"alsa_input.usb-Audient_EVO8-00.pro-input-0","node.description":"EVO8 Pro","media.class":"Audio/Source","audio.channels":6,"api.alsa.card":3,"device.class":"sound"}}},
 {"id":30,"type":"PipeWire:Interface:Node","info":{"props":{"node.name":"ardour","media.class":"Stream/Output/Audio","audio.channels":2}}},
 {"id":100,"type":"PipeWire:Interface:Port","info":{"props":{"node.id":10,"port.name":"playback_AUX0","port.direction":"in"}}},
 {"id":101,"type":"PipeWire:Interface:Port","info":{"props":{"node.id":10,"port.name":"playback_AUX1","port.direction":"in"}}},
 {"id":200,"type":"PipeWire:Interface:Port","info":{"props":{"node.id":20,"port.name":"capture_AUX0","port.direction":"out"}}},
 {"id":300,"type":"PipeWire:Interface:Port","info":{"props":{"node.id":30,"port.name":"out_1","port.direction":"out"}}},
 {"id":301,"type":"PipeWire:Interface:Port","info":{"props":{"node.id":30,"port.name":"in_1","port.direction":"in"}}},
 {"id":400,"type":"PipeWire:Interface:Link","info":{"output-port-id":300,"input-port-id":100}},
 {"id":401,"type":"PipeWire:Interface:Link","info":{"output-port-id":200,"input-port-id":301}},
 {"id":402,"type":"PipeWire:Interface:Link","info":{"output-port-id":300,"input-port-id":301}}
]`

func testGraph(t *testing.T) Graph {
	t.Helper()
	g, err := Parse([]byte(fixture))
	if err != nil {
		t.Fatal(err)
	}
	return g
}

func TestParseHardwareAndLinks(t *testing.T) {
	g := testGraph(t)
	if got := len(g.Hardware()); got != 2 {
		t.Fatalf("hardware nodes = %d, want 2", got)
	}
	fp := g.Fingerprint()
	if len(fp) != 2 || !strings.Contains(fp[0], "pro-input-0") {
		t.Fatalf("fingerprint = %v", fp)
	}
	if got := len(g.hardwareLinks()); got != 2 {
		t.Fatalf("hardware links = %d, want 2", got)
	}
}

func TestSaveAndApply(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	g := testGraph(t)
	if err := SavePreset("studio", g); err != nil {
		t.Fatal(err)
	}
	p, err := LoadPreset("studio")
	if err != nil {
		t.Fatal(err)
	}
	if len(p.Links) != 2 || !p.Applies(g) {
		t.Fatalf("preset = %+v", p)
	}

	var cmds [][]string
	old := runCommand
	runCommand = func(name string, args ...string) ([]byte, error) {
		cmds = append(cmds, append([]string{name}, args...))
		return nil, nil
	}
	defer func() { runCommand = old }()

	// Pretend nothing is linked yet, but the hardware/ports are present.
	empty := g
	empty.Links = nil
	res, err := Apply(p, empty, false)
	if err != nil {
		t.Fatal(err)
	}
	if res.Added != 2 || len(cmds) != 2 {
		t.Fatalf("added=%d cmds=%v", res.Added, cmds)
	}
	got := map[string]bool{}
	for _, c := range cmds {
		got[strings.Join(c, " ")] = true
	}
	for _, want := range []string{
		"pw-link ardour:out_1 alsa_output.usb-Audient_EVO8-00.pro-output-0:playback_AUX0",
		"pw-link alsa_input.usb-Audient_EVO8-00.pro-input-0:capture_AUX0 ardour:in_1",
	} {
		if !got[want] {
			t.Fatalf("missing command %q in %v", want, cmds)
		}
	}

	cmds = nil
	res, err = Apply(p, g, false)
	if err != nil {
		t.Fatal(err)
	}
	if res.Present != 2 || len(cmds) != 0 {
		t.Fatalf("idempotent apply = %+v cmds=%v", res, cmds)
	}
}

func TestApplyReplaceOnlyTouchesHardware(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	g := testGraph(t)
	if err := SavePreset("studio", g); err != nil {
		t.Fatal(err)
	}
	p, _ := LoadPreset("studio")
	withExtra := g
	withExtra.Links = append(append([]Link(nil), g.Links...),
		Link{OutNode: "ardour", OutPort: "out_1", InNode: "alsa_output.usb-Audient_EVO8-00.pro-output-0", InPort: "playback_AUX1"},
		Link{OutNode: "ardour", OutPort: "out_1", InNode: "ardour", InPort: "in_1"},
	)
	var cmds [][]string
	old := runCommand
	runCommand = func(name string, args ...string) ([]byte, error) {
		cmds = append(cmds, append([]string{name}, args...))
		return nil, nil
	}
	defer func() { runCommand = old }()

	res, err := Apply(p, withExtra, true)
	if err != nil {
		t.Fatal(err)
	}
	if res.Removed != 1 || res.Present != 2 || len(cmds) != 1 {
		t.Fatalf("replace = %+v cmds=%v", res, cmds)
	}
	if cmds[0][1] != "-d" {
		t.Fatalf("expected a delete, got %v", cmds[0])
	}
	if strings.Contains(strings.Join(cmds[0], " "), "ardour:in_1") {
		t.Fatal("a software-only link must never be removed")
	}
}

func TestApplyRefusesChangedInterfaces(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	g := testGraph(t)
	if err := SavePreset("studio", g); err != nil {
		t.Fatal(err)
	}
	p, _ := LoadPreset("studio")
	other := g
	for i := range other.Nodes {
		if other.Nodes[i].Hardware {
			other.Nodes[i].Channels = 4
		}
	}
	if _, err := Apply(p, other, false); err == nil {
		t.Fatal("apply must refuse a different interface set")
	}
}

func TestCreatePresetRefusesOverwrite(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	g := testGraph(t)
	if err := CreatePreset("studio", g); err != nil {
		t.Fatal(err)
	}
	if err := CreatePreset("studio", g); err == nil {
		t.Fatal("CreatePreset must not overwrite")
	}
	if err := SavePreset("studio", g); err != nil {
		t.Fatalf("SavePreset keeps the CLI overwrite contract: %v", err)
	}
}

func TestSaveRefusesNoHardwareLinks(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	g := testGraph(t)
	g.Links = nil
	if err := SavePreset("empty", g); err == nil {
		t.Fatal("an empty preset must be refused")
	}
}

func TestListEmpty(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if _, err := List(); !errors.Is(err, ErrNoPresets) {
		t.Fatalf("err = %v, want ErrNoPresets", err)
	}
	if err := os.MkdirAll(Dir(), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(Dir(), "bad.json"), []byte("{"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := List(); err == nil {
		t.Fatal("malformed preset must fail loudly")
	}
}
