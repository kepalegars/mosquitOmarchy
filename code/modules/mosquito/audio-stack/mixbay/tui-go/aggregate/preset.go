// Package aggregate turns a small list of sound cards into one named virtual
// output (and optionally input) using PipeWire's combine-stream module.
//
// It is control-plane only: no audio is handled in Go, no clock property is
// written globally, and nothing is ever applied without an explicit action.
package aggregate

import (
	"errors"
	"fmt"
	"sort"
	"strings"

	"mosquitomarchy.local/mosquitomixbay-tui/patchbay"
)

// ErrNoPresets is the empty state, not a failure.
var ErrNoPresets = errors.New("no aggregate presets")

// Member is one card taking part in an aggregate. Node is the PipeWire node
// name it was found under; the remaining selector keys are kept so a reload
// can match the card even if the exact node name changed.
type Member struct {
	Node     string   `json:"node"`
	Class    string   `json:"class,omitempty"`
	Profile  string   `json:"profile,omitempty"`
	Card     string   `json:"card,omitempty"`
	Device   string   `json:"device,omitempty"`
	Channels []string `json:"channels,omitempty"`
	Drift    bool     `json:"drift"`
	Quality  int      `json:"quality,omitempty"`
	Latency  int      `json:"latency,omitempty"`
}

// Preset is the whole recipe for one aggregate: an output sink, optionally an
// input source, and the members of each. IDs are never stored.
type Preset struct {
	SchemaVersion int      `json:"schema_version"`
	Name          string   `json:"name"`
	DisplayName   string   `json:"display_name,omitempty"`
	Rate          int      `json:"rate,omitempty"`
	Master        string   `json:"master,omitempty"`
	Outputs       []Member `json:"outputs,omitempty"`
	Inputs        []Member `json:"inputs,omitempty"`
	Fingerprint   []string `json:"fingerprint,omitempty"`
}

// SinkName and SourceName are the stable node names derived from a preset.
// agg_ is also the marker patchbay uses to leave aggregate links alone.
func (p Preset) SinkName() string   { return "agg_" + slug(p.Name) }
func (p Preset) SourceName() string { return "agg_" + slug(p.Name) + "_in" }

func slug(name string) string {
	var b strings.Builder
	prevDash := false
	for _, r := range strings.ToLower(name) {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9':
			b.WriteRune(r)
			prevDash = false
		default:
			if !prevDash && b.Len() > 0 {
				b.WriteByte('_')
				prevDash = true
			}
		}
	}
	s := strings.Trim(b.String(), "_")
	if s == "" {
		return "device"
	}
	return s
}

func validName(name string) error {
	if name == "" || name == "." || name == ".." || strings.ContainsAny(name, `/\`) {
		return fmt.Errorf("invalid aggregate name")
	}
	if strings.HasPrefix(strings.ToLower(name), "agg_") {
		return fmt.Errorf("aggregate name must not start with agg_")
	}
	return nil
}

// Validate rejects an impossible or dangerous recipe before it reaches
// PipeWire. Self-monitor members would feed an aggregate into itself.
func (p Preset) Validate() error {
	if err := validName(p.Name); err != nil {
		return err
	}
	if len(p.Outputs) == 0 && len(p.Inputs) == 0 {
		return fmt.Errorf("no members")
	}
	seen := map[string]bool{}
	for _, group := range [][]Member{p.Outputs, p.Inputs} {
		for _, m := range group {
			if m.Node == "" {
				return fmt.Errorf("member without a node name")
			}
			if strings.HasPrefix(m.Node, "agg_") || strings.Contains(m.Node, ":monitor") {
				return fmt.Errorf("an aggregate cannot contain its own monitor or another aggregate: %s", m.Node)
			}
			key := strings.ToLower(m.Node)
			if seen[key] {
				return fmt.Errorf("member listed twice: %s", m.Node)
			}
			seen[key] = true
		}
	}
	return nil
}

// MakePreset builds a preset from the current graph and the chosen node names.
// Drift is on for every member; input aggregation uses the same rule.
func MakePreset(name, display string, g patchbay.Graph, outputNodes, inputNodes []string) (Preset, error) {
	p := Preset{SchemaVersion: 1, Name: name, DisplayName: display}
	if p.DisplayName == "" {
		p.DisplayName = name
	}
	if err := validName(name); err != nil {
		return p, err
	}
	for _, n := range outputNodes {
		m, ok := memberFor(g, n, "Audio/Sink")
		if !ok {
			return p, fmt.Errorf("output %q is not in the PipeWire graph", n)
		}
		p.Outputs = append(p.Outputs, m)
	}
	for _, n := range inputNodes {
		m, ok := memberFor(g, n, "Audio/Source")
		if !ok {
			return p, fmt.Errorf("input %q is not in the PipeWire graph", n)
		}
		p.Inputs = append(p.Inputs, m)
	}
	if err := p.Validate(); err != nil {
		return p, err
	}
	p.Fingerprint = fingerprint(p.Outputs, p.Inputs)
	return p, nil
}

func memberFor(g patchbay.Graph, node, wantClass string) (Member, bool) {
	for _, n := range g.Nodes {
		if n.Name != node {
			continue
		}
		if wantClass != "" && n.Class != wantClass {
			return Member{}, false
		}
		ch := make([]string, 0, n.Channels)
		for i := 0; i < n.Channels && i < 2; i++ {
			ch = append(ch, channelName(i, n.Channels))
		}
		return Member{
			Node:     n.Name,
			Class:    n.Class,
			Profile:  n.Profile,
			Card:     n.Card,
			Device:   n.Device,
			Channels: ch,
			Drift:    true,
			Quality:  4,
		}, true
	}
	return Member{}, false
}

func channelName(i, _ int) string { return []string{"FL", "FR"}[i%2] }

func fingerprint(outputs, inputs []Member) []string {
	var out []string
	for _, group := range [][]Member{outputs, inputs} {
		for _, m := range group {
			out = append(out, strings.Join([]string{m.Node, m.Class, fmt.Sprint(len(m.Channels))}, "|"))
		}
	}
	sort.Strings(out)
	return out
}

// Applies reports whether the cards the preset was built from are still there.
func (p Preset) Applies() bool {
	return sameList(p.Fingerprint, fingerprint(p.Outputs, p.Inputs))
}

func sameList(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
