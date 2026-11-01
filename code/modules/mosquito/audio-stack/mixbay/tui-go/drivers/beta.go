// Beta interfaces — user-added cards Mixbay does not support natively yet.
//
// "Add an audio interface" writes ~/.config/mosquitomixbay/beta-devices.json.
// Each entry becomes an ALSA level-1 Spec (volume/mute only) carrying the
// "beta" version. The reverse-engineering process will promote an entry to a
// native spec once its controls are mapped; until then the generic UI is
// intentionally honest about the limits.
package drivers

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
)

// BetaDevice is the on-disk shape written by the TUI's Add interface flow.
type BetaDevice struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Match string `json:"match"`
}

func betaFile() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "mosquitomixbay", "beta-devices.json")
}

// BetaDevices reads the beta list. A missing/corrupt file is empty, never an
// error: the TUI must still open on a fresh machine.
func BetaDevices() []BetaDevice {
	data, err := os.ReadFile(betaFile())
	if err != nil {
		return nil
	}
	var out []BetaDevice
	if json.Unmarshal(data, &out) != nil {
		return nil
	}
	return out
}

func SaveBetaDevices(list []BetaDevice) error {
	path := betaFile()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	data, _ := json.MarshalIndent(list, "", "  ")
	return os.WriteFile(path, data, 0o644)
}

// BetaSpecs maps the stored devices to generic ALSA level-1 specs.
func BetaSpecs() []Spec {
	var out []Spec
	for _, b := range BetaDevices() {
		out = append(out, Spec{
			ID: b.ID, Display: b.Name, Vendor: "beta",
			NumInputs: 2, NumOutPairs: 1,
			GainMin: 0, GainMax: 60, VolMin: -96, VolMax: 0,
			MixerInputs: 2, MixerOutputs: 2,
			Backend: BackendALSA, NeedsKmod: false,
			Version: "beta", Beta: true, CardMatch: []string{b.Match},
			Caps:        Caps{Volume: true, Gain: false, Mute: true, Phantom: false, Monitor: false, Mixer: false},
			Description: "Beta: ALSA level 1 (volume/mute only). Native controls and routing are not mapped yet.",
		})
	}
	return out
}

func betaSpec(id string) (Spec, bool) {
	for _, s := range BetaSpecs() {
		if s.ID == id {
			return s, true
		}
	}
	return Spec{}, false
}

// AddBetaDevice stores a card once. The id is derived from the name so the
// same card cannot be added twice under different spellings.
func AddBetaDevice(name, match string) (BetaDevice, error) {
	list := BetaDevices()
	id := slug(name)
	for _, b := range list {
		if b.ID == id || strings.EqualFold(b.Name, name) {
			return b, nil
		}
	}
	b := BetaDevice{ID: id, Name: name, Match: match}
	list = append(list, b)
	return b, SaveBetaDevices(list)
}

// RemoveBetaDevice drops a beta entry (used when the user removes the card).
func RemoveBetaDevice(id string) error {
	list := BetaDevices()
	kept := list[:0]
	for _, b := range list {
		if b.ID != id {
			kept = append(kept, b)
		}
	}
	return SaveBetaDevices(kept)
}

func slug(s string) string {
	var b strings.Builder
	for _, r := range strings.ToLower(s) {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9':
			b.WriteRune(r)
		case r == ' ' || r == '-' || r == '_' || r == '/':
			b.WriteByte('-')
		}
	}
	out := strings.Trim(b.String(), "-")
	for strings.Contains(out, "--") {
		out = strings.ReplaceAll(out, "--", "-")
	}
	if out == "" {
		out = "beta-card"
	}
	return "beta-" + out
}
