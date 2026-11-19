// Beta interfaces — cards Mixbay discovered itself and has no native profile
// for yet.
//
// "Add an audio interface" writes a local card under
// ~/.config/mosquitomixbay/cards/<id>/ (source=local). It is the same format as
// a downloaded community profile, so exporting it for a PR and later replacing
// it with an upstream card need no special path. The pre-profile
// beta-devices.json is migrated once on first read.
package drivers

import (
	"strings"

	"mosquitomarchy.local/mosquitomixbay-tui/profiles"
)

// BetaDevice is the on-disk shape exposed to the TUI's Add interface flow.
type BetaDevice struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Match string `json:"match"`
	// Controls the installed card declares. The guided harness uses them so
	// it never proposes a control this driver cannot set.
	Inputs  int `json:"inputs,omitempty"`
	Outputs int `json:"outputs,omitempty"`
}

// BetaDevices lists locally installed non-native cards.
func BetaDevices() []BetaDevice {
	_ = profiles.MigrateLegacyBeta()
	var out []BetaDevice
	for _, c := range profiles.LocalCards() {
		match := ""
		if len(c.Spec.CardMatch) > 0 {
			match = c.Spec.CardMatch[0]
		}
		out = append(out, BetaDevice{
			ID: c.Spec.ID, Name: c.Spec.Display, Match: match,
			Inputs: c.Spec.NumInputs, Outputs: c.Spec.NumOutPairs,
		})
	}
	return out
}

// BetaSpecs maps installed local cards to their runtime specs. The name is
// kept for callers; downloaded community profiles are included too.
func BetaSpecs() []Spec { return localSpecs() }

// AddBetaDevice stores a card once. The id is derived from the name so the
// same card cannot be added twice under different spellings.
func AddBetaDevice(name, match string) (BetaDevice, error) {
	if match == "" {
		match = name
	}
	id := slug(name)
	for _, b := range BetaDevices() {
		if b.ID == id || strings.EqualFold(b.Name, name) {
			return b, nil
		}
	}
	card, err := profiles.InstallLocalCard(id, name, match)
	if err != nil {
		return BetaDevice{}, err
	}
	return BetaDevice{
		ID: card.Spec.ID, Name: card.Spec.Display, Match: match,
		Inputs: card.Spec.NumInputs, Outputs: card.Spec.NumOutPairs,
	}, nil
}

// RemoveBetaDevice drops a local card (used when the user removes the card).
func RemoveBetaDevice(id string) error {
	return profiles.Remove(id)
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
