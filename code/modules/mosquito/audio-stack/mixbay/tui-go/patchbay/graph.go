// Package patchbay reads the PipeWire graph and applies explicit link
// presets. It is control-plane only: no audio ever passes through it, and it
// never polls in the background.
package patchbay

import (
	"encoding/json"
	"fmt"
	"os/exec"
	"sort"
	"strconv"
	"strings"
)

// Node is one PipeWire node relevant to a patchbay preset.
type Node struct {
	ID          int
	Name        string
	Description string
	Class       string
	Channels    int
	Hardware    bool
}

// Port is one node port. Direction is PipeWire's "in" or "out".
type Port struct {
	Node      string
	Name      string
	Direction string
}

// Link connects an output port to an input port, by stable node/port names.
type Link struct {
	OutNode string `json:"out_node"`
	OutPort string `json:"out_port"`
	InNode  string `json:"in_node"`
	InPort  string `json:"in_port"`
}

func (l Link) key() string {
	return l.OutNode + "\x00" + l.OutPort + "\x00" + l.InNode + "\x00" + l.InPort
}

// Graph is the subset of pw-dump the patchbay needs.
type Graph struct {
	Nodes []Node
	Ports []Port
	Links []Link
}

// Hardware returns the hardware audio nodes, in stable fingerprint order.
func (g Graph) Hardware() []Node {
	var out []Node
	for _, n := range g.Nodes {
		if n.Hardware {
			out = append(out, n)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

// Fingerprint identifies the connected hardware set. Presets only apply when
// the current interfaces match exactly; no fuzzy "close enough" matching.
func (g Graph) fingerprintFor(links []Link) []string {
	used := map[string]bool{}
	for _, l := range links {
		if g.hardwareNode(l.OutNode) {
			used[l.OutNode] = true
		}
		if g.hardwareNode(l.InNode) {
			used[l.InNode] = true
		}
	}
	var out []string
	for _, n := range g.Hardware() {
		if used[n.Name] {
			out = append(out, fmt.Sprintf("%s|%s|%d", n.Name, n.Class, n.Channels))
		}
	}
	sort.Strings(out)
	return out
}

func (g Graph) Fingerprint() []string {
	var out []string
	for _, n := range g.Hardware() {
		out = append(out, fmt.Sprintf("%s|%s|%d", n.Name, n.Class, n.Channels))
	}
	return out
}

func (g Graph) hardwareNode(name string) bool {
	for _, n := range g.Nodes {
		if n.Name == name {
			return n.Hardware
		}
	}
	return false
}

// runCommand is a variable so tests can exercise the graph without touching
// the live PipeWire daemon.
var runCommand = func(name string, args ...string) ([]byte, error) {
	return exec.Command(name, args...).Output()
}

// Available reports whether the PipeWire CLI tools are installed.
func Available() bool {
	_, dump := exec.LookPath("pw-dump")
	_, link := exec.LookPath("pw-link")
	return dump == nil && link == nil
}

// Snapshot reads the live graph with one pw-dump call. Callers decide when:
// there is no watcher and no polling in this package.
func Snapshot() (Graph, error) {
	data, err := runCommand("pw-dump")
	if err != nil {
		return Graph{}, fmt.Errorf("pw-dump: %w", err)
	}
	return Parse(data)
}

type rawObject struct {
	ID   int    `json:"id"`
	Type string `json:"type"`
	Info struct {
		Props        map[string]any `json:"props"`
		OutputNodeID int            `json:"output-node-id"`
		OutputPortID int            `json:"output-port-id"`
		InputNodeID  int            `json:"input-node-id"`
		InputPortID  int            `json:"input-port-id"`
	} `json:"info"`
}

func rawString(m map[string]any, key string) string {
	v, ok := m[key]
	if !ok {
		return ""
	}
	switch x := v.(type) {
	case string:
		return x
	case float64:
		return strconv.Itoa(int(x))
	case bool:
		return strconv.FormatBool(x)
	}
	return ""
}

func rawInt(m map[string]any, key string) int {
	v, ok := m[key]
	if !ok {
		return 0
	}
	switch x := v.(type) {
	case float64:
		return int(x)
	case string:
		n, _ := strconv.Atoi(x)
		return n
	}
	return 0
}

// Parse decodes pw-dump's JSON. Exported for tests and for callers that already
// have a snapshot.
func Parse(data []byte) (Graph, error) {
	var objs []rawObject
	if err := json.Unmarshal(data, &objs); err != nil {
		return Graph{}, fmt.Errorf("pw-dump JSON: %w", err)
	}
	g := Graph{}
	byID := map[int]Node{}
	for _, o := range objs {
		if o.Type != "PipeWire:Interface:Node" {
			continue
		}
		name := rawString(o.Info.Props, "node.name")
		if name == "" {
			continue
		}
		n := Node{
			ID:          o.ID,
			Name:        name,
			Description: rawString(o.Info.Props, "node.description"),
			Class:       rawString(o.Info.Props, "media.class"),
			Channels:    rawInt(o.Info.Props, "audio.channels"),
			Hardware:    rawString(o.Info.Props, "api.alsa.card") != "" || rawString(o.Info.Props, "device.class") == "sound",
		}
		g.Nodes = append(g.Nodes, n)
		byID[n.ID] = n
	}
	portNode := map[int]string{}
	portName := map[int]string{}
	for _, o := range objs {
		if o.Type != "PipeWire:Interface:Port" {
			continue
		}
		nid := rawInt(o.Info.Props, "node.id")
		n, ok := byID[nid]
		if !ok {
			continue
		}
		name := rawString(o.Info.Props, "port.name")
		dir := rawString(o.Info.Props, "port.direction")
		g.Ports = append(g.Ports, Port{Node: n.Name, Name: name, Direction: dir})
		portNode[o.ID] = n.Name
		portName[o.ID] = name
	}
	for _, o := range objs {
		if o.Type != "PipeWire:Interface:Link" {
			continue
		}
		l := Link{
			OutNode: portNode[o.Info.OutputPortID],
			OutPort: portName[o.Info.OutputPortID],
			InNode:  portNode[o.Info.InputPortID],
			InPort:  portName[o.Info.InputPortID],
		}
		if l.OutNode == "" || l.InNode == "" || l.OutPort == "" || l.InPort == "" {
			continue
		}
		g.Links = append(g.Links, l)
	}
	return g, nil
}

func sortedLinks(links []Link) []Link {
	out := append([]Link(nil), links...)
	sort.Slice(out, func(i, j int) bool { return out[i].key() < out[j].key() })
	return out
}

func (g Graph) hardwareLinks() []Link {
	var out []Link
	for _, l := range g.Links {
		if g.hardwareNode(l.OutNode) || g.hardwareNode(l.InNode) {
			out = append(out, l)
		}
	}
	return sortedLinks(out)
}

func (g Graph) hasPort(node, port, dir string) bool {
	for _, p := range g.Ports {
		if p.Node == node && p.Name == port && p.Direction == dir {
			return true
		}
	}
	return false
}

// endpoint is the pw-link spelling of one port.
func endpoint(node, port string) string { return strings.TrimSpace(node + ":" + port) }
