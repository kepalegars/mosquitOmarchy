// Package profiles owns the community interface profiles: the on-disk card
// format, the local card store, repo download/import, and PR-ready export.
//
// A card is DATA. It never carries executable code, udev rules, PipeWire
// configuration or USB replay. The drivers package converts a Card into its
// runtime Spec; this package deliberately does not import drivers so the
// format stays independent from the renderer.
package profiles

import (
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
)

// SchemaVersion is the only card format this build understands.
const SchemaVersion = 1

// Backends name a control transport. Mirrors drivers.Backend without the
// import cycle.
const (
	BackendEvoRaw = "evo-raw"
	BackendALSA   = "alsa"
	BackendDouze  = "douze"
	BackendDemo   = "demo"
)

// Setup names are the closed set of card-specific integrations a downloaded
// card may ask for. A card never carries a command or URL: the build knows
// these, so a repo entry cannot run arbitrary code.
const (
	SetupOscmix = "oscmix" // RME Fireface UCX II control (oscmix-desk)
	SetupDouze  = "douze"  // Solid State Logic SSL 12 control
)

// Foundation is the optional per-card part of the audio foundation. Absent
// means the default (match the card in the connection log and use that name
// for the default sink/source).
type Foundation struct {
	Sink   string `json:"sink,omitempty"`
	Source string `json:"source,omitempty"`
}

// Caps advertises what a card can actually do.
type Caps struct {
	Volume  bool `json:"volume"`
	Gain    bool `json:"gain"`
	Mute    bool `json:"mute"`
	Phantom bool `json:"phantom_48v"`
	Monitor bool `json:"monitor_blend"`
	Mixer   bool `json:"mixer"`
}

// Spec is the hardware description of a card. Field names and JSON shape match
// drivers.Spec so status-json and local data stay interchangeable.
type Spec struct {
	ID           string      `json:"id"`
	Display      string      `json:"display"`
	Vendor       string      `json:"vendor"`
	USBVID       string      `json:"usb_vid"`
	USBPID       string      `json:"usb_pid"`
	NumInputs    int         `json:"num_inputs"`
	NumOutPairs  int         `json:"num_output_pairs"`
	GainMin      float64     `json:"gain_min_db"`
	GainMax      float64     `json:"gain_max_db"`
	GainOffset   float64     `json:"gain_offset_db"`
	VolMin       float64     `json:"vol_min_db"`
	VolMax       float64     `json:"vol_max_db"`
	MixerInputs  int         `json:"mixer_inputs"`
	MixerOutputs int         `json:"mixer_outputs"`
	HasMonitor   bool        `json:"has_monitor"`
	Backend      string      `json:"backend"`
	NeedsKmod    bool        `json:"needs_kmod"`
	Description  string      `json:"description"`
	Version      string      `json:"version"`
	Beta         bool        `json:"beta,omitempty"`
	CardMatch    []string    `json:"card_match,omitempty"`
	BusNames     []string    `json:"bus_names,omitempty"`
	Caps         Caps        `json:"caps"`
	Setup        string      `json:"setup,omitempty"`
	Foundation   *Foundation `json:"foundation,omitempty"`
}

// Capture references a distilled capture inside the card folder. Raw capture
// bundles live in release artifacts and are referenced by sha256 only.
type Capture struct {
	File   string `json:"file"`
	SHA256 string `json:"sha256"`
	Label  string `json:"label,omitempty"`
}

// Card is one interface profile. UI stays generic on purpose: a future Mixbay
// may add blocks without invalidating older cards, and local overrides merge
// into it sparsely.
type Card struct {
	SchemaVersion int            `json:"schema_version"`
	Spec          Spec           `json:"spec"`
	UI            map[string]any `json:"ui,omitempty"`
	Captures      []Capture      `json:"captures,omitempty"`
}

// Preset returns the UI preset name ("evo8", "auto"…).
func (c Card) Preset() string {
	s, _ := c.UI["preset"].(string)
	if s == "" {
		return "auto"
	}
	return s
}

// Blocks returns the declared UI block list, if any.
func (c Card) Blocks() []string {
	raw, ok := c.UI["blocks"].([]any)
	if !ok {
		return nil
	}
	out := make([]string, 0, len(raw))
	for _, v := range raw {
		if s, ok := v.(string); ok {
			out = append(out, s)
		}
	}
	return out
}

var idPattern = regexp.MustCompile(`^[a-z0-9][a-z0-9-]*$`)

// foundationNamePattern keeps a card from injecting a jq/wpctl expression into
// the generated default-sink picker. Real node fragments look like
// "HiFi__Line5__sink" or "Fireface".
var foundationNamePattern = regexp.MustCompile(`^[A-Za-z0-9_.:-]+$`)

// ValidID reports whether id is safe as a folder/file name. Import paths and
// local folders both go through it, so a crafted index cannot escape the store.
func ValidID(id string) bool { return idPattern.MatchString(id) }

// Presets is the closed set of UI block compositions this build renders.
var Presets = []string{"evo8", "evo4", "ugm192", "single-pair", "auto"}

// Blocks is the closed set of reusable mixbay UI blocks a card may compose.
// A preset chooses a default composition; ui.blocks documents the card's
// intent and is validated so a typo can never silently render a blank panel.
var Blocks = []string{
	"tabBar", "controlsGrid", "controlsSingle", "mixerGrid",
	"levelsColumns", "statusBar", "help",
}

func validPreset(p string) bool {
	for _, v := range Presets {
		if v == p {
			return true
		}
	}
	return false
}

func validBlock(b string) bool {
	for _, v := range Blocks {
		if v == b {
			return true
		}
	}
	return false
}

// Setups is the closed set of card-specific integrations this build can run
// after a download. Empty means the card needs none.
var Setups = []string{"", SetupOscmix, SetupDouze}

func validSetup(s string) bool {
	for _, v := range Setups {
		if v == s {
			return true
		}
	}
	return false
}

// Issue is one validation finding. Level "error" blocks an import.
type Issue struct {
	Level  string `json:"level"`
	Field  string `json:"field,omitempty"`
	Detail string `json:"detail"`
}

func (i Issue) String() string {
	if i.Field != "" {
		return i.Level + ": " + i.Field + ": " + i.Detail
	}
	return i.Level + ": " + i.Detail
}

// Validate checks structural invariants. Unknown UI keys are allowed (forward
// compatibility); an unknown preset is an error because it would render as a
// blank panel rather than a usable card.
func Validate(c Card) []Issue {
	var out []Issue
	add := func(level, field, format string, args ...any) {
		out = append(out, Issue{Level: level, Field: field, Detail: fmt.Sprintf(format, args...)})
	}
	if c.SchemaVersion != SchemaVersion {
		add("error", "schema_version", "want %d, got %d", SchemaVersion, c.SchemaVersion)
	}
	s := c.Spec
	if !ValidID(s.ID) {
		add("error", "spec.id", "%q is not a lowercase slug", s.ID)
	}
	if strings.TrimSpace(s.Display) == "" {
		add("error", "spec.display", "must not be empty")
	}
	if strings.TrimSpace(s.Vendor) == "" {
		add("error", "spec.vendor", "must not be empty")
	}
	if strings.TrimSpace(s.Version) == "" {
		add("error", "spec.version", "must not be empty")
	}
	if s.NumInputs < 1 {
		add("error", "spec.num_inputs", "must be >= 1")
	}
	if s.NumOutPairs < 1 {
		add("error", "spec.num_output_pairs", "must be >= 1")
	}
	switch s.Backend {
	case BackendEvoRaw, BackendALSA, BackendDouze, BackendDemo:
	default:
		add("error", "spec.backend", "unknown backend %q", s.Backend)
	}
	if s.GainMax < s.GainMin {
		add("error", "spec.gain", "max %v below min %v", s.GainMax, s.GainMin)
	}
	if s.VolMax < s.VolMin {
		add("error", "spec.volume", "max %v below min %v", s.VolMax, s.VolMin)
	}
	if s.Caps.Mixer && (s.MixerInputs < s.NumInputs || s.MixerOutputs < 2) {
		add("error", "spec.caps.mixer", "mixer caps need %d+ inputs and 2+ outputs (got %d/%d)", s.NumInputs, s.MixerInputs, s.MixerOutputs)
	}
	if !validSetup(s.Setup) {
		add("error", "spec.setup", "unknown setup %q (known: oscmix, douze)", s.Setup)
	}
	if f := s.Foundation; f != nil {
		if f.Sink == "" && f.Source == "" {
			add("error", "spec.foundation", "needs a sink or a source")
		}
		for field, v := range map[string]string{"sink": f.Sink, "source": f.Source} {
			if v != "" && !foundationNamePattern.MatchString(v) {
				add("error", "spec.foundation."+field, "%q is not a PipeWire node name fragment", v)
			}
		}
	}
	if s.Caps.Phantom && s.NumInputs < 1 {
		add("error", "spec.caps.phantom_48v", "phantom power needs at least one input")
	}
	if c.UI == nil {
		add("error", "ui", "must be an object with a preset")
	} else if p := c.Preset(); !validPreset(p) {
		add("error", "ui.preset", "unknown preset %q (known: %s)", p, strings.Join(Presets, ", "))
	}
	for i, b := range c.Blocks() {
		if !validBlock(b) {
			add("error", fmt.Sprintf("ui.blocks[%d]", i), "unknown block %q (known: %s)", b, strings.Join(Blocks, ", "))
		}
	}
	for i, cap := range c.Captures {
		if !strings.HasPrefix(cap.File, "captures/") || !strings.HasSuffix(cap.File, ".jsonl") {
			add("error", fmt.Sprintf("captures[%d].file", i), "must be captures/<name>.jsonl")
		}
		if len(cap.SHA256) != 64 || strings.Trim(cap.SHA256, "0123456789abcdef") != "" {
			add("error", fmt.Sprintf("captures[%d].sha256", i), "must be a lowercase sha256")
		}
	}
	return out
}

// Errors filters the blocking issues.
func Errors(issues []Issue) []Issue {
	var out []Issue
	for _, i := range issues {
		if i.Level == "error" {
			out = append(out, i)
		}
	}
	return out
}

// Parse validates JSON and returns the card. Unknown top-level keys are an
// error: a typo like "spce" must not silently import a useless card.
func Parse(data []byte) (Card, []Issue, error) {
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {
		return Card{}, nil, fmt.Errorf("card is not JSON: %w", err)
	}
	allowed := map[string]bool{"schema_version": true, "spec": true, "ui": true, "captures": true}
	var issues []Issue
	for k := range raw {
		if !allowed[k] {
			issues = append(issues, Issue{Level: "error", Field: k, Detail: "unknown top-level key"})
		}
	}
	// The spec names hardware drivers rely on: a typo there silently changes
	// I/O, so it is strict. UI stays open for forward-compatible keys.
	specKeys := map[string]bool{
		"id": true, "display": true, "vendor": true, "usb_vid": true, "usb_pid": true,
		"num_inputs": true, "num_output_pairs": true,
		"gain_min_db": true, "gain_max_db": true, "gain_offset_db": true,
		"vol_min_db": true, "vol_max_db": true,
		"mixer_inputs": true, "mixer_outputs": true, "has_monitor": true,
		"backend": true, "needs_kmod": true, "description": true, "version": true,
		"beta": true, "card_match": true, "bus_names": true, "caps": true,
		"setup": true, "foundation": true,
	}
	if specRaw, ok := raw["spec"]; ok {
		var keys map[string]json.RawMessage
		if json.Unmarshal(specRaw, &keys) == nil {
			for k := range keys {
				if !specKeys[k] {
					issues = append(issues, Issue{Level: "error", Field: "spec." + k, Detail: "unknown key"})
				}
			}
		}
	}
	var c Card
	if err := json.Unmarshal(data, &c); err != nil {
		return Card{}, issues, fmt.Errorf("card shape: %w", err)
	}
	issues = append(issues, Validate(c)...)
	return c, issues, nil
}
