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
	SetupOscmix = "oscmix"  // RME CC-mode cards: huddx01/oscmix (GTK + Qt)
	SetupDouze  = "douze"   // Solid State Logic SSL 12 control
	SetupEvoRaw = "evo-raw" // Audient EVO: evo_raw kmod + capture helper
	SetupMove   = "move"    // Ableton Move: the 44.1 kHz audio switch helper
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
	// Upstream is an optional direct card URL (same schema) used by cards whose
	// vendor integration moves faster than the published index, currently the
	// RME/oscmix cards. Only the official profiles repo is accepted.
	Upstream string `json:"upstream,omitempty"`
}

// Credits says who made a card: "mosquito" for the built-in integrations,
// plus any outside contributors. Shown in the info popup, never executed.
type Credits struct {
	Author       string   `json:"author,omitempty"`
	Contributors []string `json:"contributors,omitempty"`
}

// Capture references a distilled capture inside the card folder. Raw capture
// bundles live in release artifacts and are referenced by sha256 only.
type Capture struct {
	File   string `json:"file"`
	SHA256 string `json:"sha256"`
	Label  string `json:"label,omitempty"`
}

// MaxMeterChannels is the widest meter binding the TUI can hold (its peak
// arrays are fixed). Mirrored by drivers.MaxMeterChannels.
const MaxMeterChannels = 8

// Meters is the declarative USB meter binding. The build turns it into the
// two pw-record captures; a card never names a command or a path.
type Meters struct {
	// Node is a fragment of the PipeWire node name (vendor/model). A declared
	// binding is authoritative: when the node is absent, the card gets no
	// meters instead of another card's channels.
	Node string `json:"node"`
	// Capture and Playback are the channel labels in USB stream order; their
	// length is the channel count. Empty means that direction has no meters.
	Capture  []string `json:"capture,omitempty"`
	Playback []string `json:"playback,omitempty"`
	// FloorDb is the bottom of the meter scale in dB. Zero means the default
	// (-60), which is what the EVO capture path has always used.
	FloorDb float64 `json:"floor_db,omitempty"`
}

// Hardware is the optional transport binding section. It is data only: the
// build interprets the fields it knows and validation rejects the rest.
type Hardware struct {
	Meters *Meters `json:"meters,omitempty"`
}

// Card is one interface profile. UI stays generic on purpose: a future Mixbay
// may add blocks without invalidating older cards, and local overrides merge
// into it sparsely.
type Card struct {
	SchemaVersion int            `json:"schema_version"`
	Spec          Spec           `json:"spec"`
	Credits       Credits        `json:"credits,omitempty"`
	UI            map[string]any `json:"ui,omitempty"`
	Hardware      *Hardware      `json:"hardware,omitempty"`
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

// Opener is one way to open a card's UI. A profile only names an opener id
// from the build's closed set (web, gtk, qt) and its label; the launcher
// itself lives in Mixbay, so a repo card still cannot carry a command.
type Opener struct {
	ID    string `json:"id"`
	Label string `json:"label,omitempty"`
}

// Openers returns the UIs a card offers, in profile order.
func (c Card) Openers() []Opener {
	raw, ok := c.UI["openers"]
	if !ok {
		return nil
	}
	b, err := json.Marshal(raw)
	if err != nil {
		return nil
	}
	var out []Opener
	if json.Unmarshal(b, &out) != nil {
		return nil
	}
	return out
}

var idPattern = regexp.MustCompile(`^[a-z0-9][a-z0-9-]*$`)

// foundationNamePattern keeps a card from injecting a jq/wpctl expression into
// the generated default-sink picker. Real node fragments look like
// "HiFi__Line5__sink" or "Fireface".
var foundationNamePattern = regexp.MustCompile(`^[A-Za-z0-9_.:-]+$`)

// meterNodePattern is narrower than a node name on purpose: the fragment is
// only used for a case-folded substring match, never as a command.
var meterNodePattern = regexp.MustCompile(`^[A-Za-z0-9_.: -]+$`)

// ValidID reports whether id is safe as a folder/file name. Import paths and
// local folders both go through it, so a crafted index cannot escape the store.
func ValidID(id string) bool { return idPattern.MatchString(id) }

// Presets is the closed set of UI block compositions this build renders.
var Presets = []string{"evo8", "evo4", "ugm192", "single-pair", "move", "auto"}

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
var Setups = []string{"", SetupOscmix, SetupDouze, SetupEvoRaw, SetupMove}

func validSetup(s string) bool {
	for _, v := range Setups {
		if v == s {
			return true
		}
	}
	return false
}

// ValidUpstreamURL accepts only a raw card URL from the official profiles
// repository. Cards are data, but this URL is fetched by Mixbay itself, so the
// host and owner are pinned instead of trusting whatever the card says.
func ValidUpstreamURL(u string) bool {
	const prefix = "https://raw.githubusercontent.com/kepalegars/mosquito-mixbay-profiles/"
	if !strings.HasPrefix(u, prefix) || strings.Contains(u, "..") {
		return false
	}
	rest := strings.TrimPrefix(u, prefix)
	return strings.HasSuffix(rest, ".json") && len(rest) > len(".json")
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
		add("error", "spec.setup", "unknown setup %q (known: oscmix, douze, evo-raw)", s.Setup)
	}
	if s.Upstream != "" && !ValidUpstreamURL(s.Upstream) {
		add("error", "spec.upstream", "%q is not a card URL from the profiles repository", s.Upstream)
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
	if h := c.Hardware; h != nil {
		if m := h.Meters; m != nil {
			if !meterNodePattern.MatchString(m.Node) || strings.TrimSpace(m.Node) == "" {
				add("error", "hardware.meters.node", "%q is not a PipeWire node fragment", m.Node)
			}
			if len(m.Capture) == 0 && len(m.Playback) == 0 {
				add("error", "hardware.meters", "needs a capture or playback channel map")
			}
			for _, dir := range []struct {
				field  string
				labels []string
			}{{"capture", m.Capture}, {"playback", m.Playback}} {
				if len(dir.labels) > MaxMeterChannels {
					add("error", "hardware.meters."+dir.field, "%d channels, at most %d", len(dir.labels), MaxMeterChannels)
				}
				seen := map[string]bool{}
				for i, label := range dir.labels {
					label = strings.TrimSpace(label)
					if label == "" {
						add("error", fmt.Sprintf("hardware.meters.%s[%d]", dir.field, i), "must not be empty")
					} else if seen[label] {
						add("error", fmt.Sprintf("hardware.meters.%s[%d]", dir.field, i), "duplicate label %q", label)
					}
					seen[label] = true
				}
			}
			if m.FloorDb > 0 || m.FloorDb < -120 {
				add("error", "hardware.meters.floor_db", "%v is outside -120..0 dB", m.FloorDb)
			}
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
	allowed := map[string]bool{"schema_version": true, "spec": true, "credits": true, "ui": true, "hardware": true, "captures": true}
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
		"setup": true, "foundation": true, "upstream": true,
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
	// Hardware carries bindings the build interprets; strict like spec so a
	// typo cannot silently disable them.
	if hwRaw, ok := raw["hardware"]; ok {
		var keys map[string]json.RawMessage
		if json.Unmarshal(hwRaw, &keys) == nil {
			for k := range keys {
				if k != "meters" {
					issues = append(issues, Issue{Level: "error", Field: "hardware." + k, Detail: "unknown key"})
				}
			}
			if mRaw, ok := keys["meters"]; ok {
				var mkeys map[string]json.RawMessage
				if json.Unmarshal(mRaw, &mkeys) == nil {
					for k := range mkeys {
						switch k {
						case "node", "capture", "playback", "floor_db":
						default:
							issues = append(issues, Issue{Level: "error", Field: "hardware.meters." + k, Detail: "unknown key"})
						}
					}
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
