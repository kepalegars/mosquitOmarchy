package patchbay

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// ErrNoPresets is the empty state, not a failure.
var ErrNoPresets = errors.New("no patchbay presets")

// Preset records the hardware set it was saved on and the links to restore.
// Links are stored by node/port name, not PipeWire IDs (IDs are per-boot).
type Preset struct {
	Name        string   `json:"name"`
	Fingerprint []string `json:"fingerprint"`
	Links       []Link   `json:"links"`
}

// Dir is the patchbay preset directory.
func Dir() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "mosquitomixbay", "pipewire")
}

func presetPath(name string) string { return filepath.Join(Dir(), name+".json") }

func validName(name string) error {
	if name == "" || name == "." || name == ".." || strings.ContainsAny(name, `/\`) {
		return fmt.Errorf("invalid preset name")
	}
	return nil
}

// List returns the presets sorted by name. A malformed preset fails loudly:
// silently ignoring it would make an explicit apply look available.
func List() ([]Preset, error) {
	entries, err := os.ReadDir(Dir())
	if os.IsNotExist(err) {
		return nil, ErrNoPresets
	}
	if err != nil {
		return nil, err
	}
	var out []Preset
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".json") {
			continue
		}
		p, err := loadFrom(filepath.Join(Dir(), e.Name()))
		if err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	if len(out) == 0 {
		return nil, ErrNoPresets
	}
	return out, nil
}

func loadFrom(path string) (Preset, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return Preset{}, err
	}
	var p Preset
	if err := json.Unmarshal(data, &p); err != nil {
		return Preset{}, fmt.Errorf("%s: %w", filepath.Base(path), err)
	}
	if p.Name == "" {
		p.Name = strings.TrimSuffix(filepath.Base(path), ".json")
	}
	return p, nil
}

// LoadPreset reads one named preset.
func LoadPreset(name string) (Preset, error) {
	if err := validName(name); err != nil {
		return Preset{}, err
	}
	return loadFrom(presetPath(name))
}

// SavePreset snapshots the current hardware links as a named preset,
// replacing an existing file (the CLI keeps its historical overwrite).
func SavePreset(name string, g Graph) error {
	return writePreset(name, g, true)
}

// CreatePreset saves a new preset and refuses to overwrite an existing one.
// The TUI uses it so a typo cannot silently destroy a working routing.
func CreatePreset(name string, g Graph) error {
	return writePreset(name, g, false)
}

func writePreset(name string, g Graph, overwrite bool) error {
	if err := validName(name); err != nil {
		return err
	}
	p := Preset{Name: name, Links: g.hardwareLinks()}
	p.Fingerprint = g.fingerprintFor(p.Links)
	if len(p.Fingerprint) == 0 {
		return fmt.Errorf("no hardware links to save")
	}
	if _, err := os.Stat(presetPath(name)); err == nil && !overwrite {
		return fmt.Errorf("preset %q already exists", name)
	}
	if err := os.MkdirAll(Dir(), 0o755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(p, "", "  ")
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(Dir(), "."+name+".*.json")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), presetPath(name))
}

func sameFingerprint(a, b []string) bool {
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

// Applies reports whether the preset's interface set matches this graph.
func (p Preset) Applies(g Graph) bool { return sameFingerprint(p.Fingerprint, g.Fingerprint()) }

// ApplyResult summarises one explicit apply.
type ApplyResult struct {
	Added   int
	Present int
	Removed int
	Missing []string
}

// Apply ensures every preset link exists. With replace, it first removes
// hardware-touching links that are not in the preset. Links unrelated to
// hardware are never touched.
func Apply(p Preset, g Graph, replace bool) (ApplyResult, error) {
	var res ApplyResult
	if !p.Applies(g) {
		return res, fmt.Errorf("interfaces changed — preset saved for %s, current %s", describe(p.Fingerprint), describe(g.Fingerprint()))
	}
	want := map[string]bool{}
	for _, l := range p.Links {
		want[l.key()] = true
	}
	have := map[string]bool{}
	for _, l := range g.Links {
		have[l.key()] = true
	}
	if replace {
		for _, l := range g.hardwareLinks() {
			if want[l.key()] {
				continue
			}
			if _, err := runCommand("pw-link", "-d", endpoint(l.OutNode, l.OutPort), endpoint(l.InNode, l.InPort)); err != nil {
				return res, fmt.Errorf("remove %s -> %s: %w", endpoint(l.OutNode, l.OutPort), endpoint(l.InNode, l.InPort), err)
			}
			res.Removed++
			delete(have, l.key())
		}
	}
	for _, l := range p.Links {
		if have[l.key()] {
			res.Present++
			continue
		}
		if !g.hasPort(l.OutNode, l.OutPort, "out") || !g.hasPort(l.InNode, l.InPort, "in") {
			res.Missing = append(res.Missing, endpoint(l.OutNode, l.OutPort)+" -> "+endpoint(l.InNode, l.InPort))
			continue
		}
		if _, err := runCommand("pw-link", endpoint(l.OutNode, l.OutPort), endpoint(l.InNode, l.InPort)); err != nil {
			return res, fmt.Errorf("link %s -> %s: %w", endpoint(l.OutNode, l.OutPort), endpoint(l.InNode, l.InPort), err)
		}
		res.Added++
		have[l.key()] = true
	}
	return res, nil
}

func describe(fp []string) string {
	if len(fp) == 0 {
		return "none"
	}
	return strings.Join(fp, ", ")
}

// State is one preset's status for the UI/JSON.
type State struct {
	Preset
	Applies bool   `json:"applies"`
	Reason  string `json:"reason,omitempty"`
}

// States lists presets with their live applicability.
func States(g Graph) ([]State, error) {
	presets, err := List()
	if err != nil {
		if errors.Is(err, ErrNoPresets) {
			return nil, nil
		}
		return nil, err
	}
	out := make([]State, 0, len(presets))
	for _, p := range presets {
		st := State{Preset: p, Applies: p.Applies(g)}
		if !st.Applies {
			st.Reason = "interfaces differ"
		}
		out = append(out, st)
	}
	return out, nil
}
