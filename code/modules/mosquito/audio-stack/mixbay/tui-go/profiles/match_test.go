package profiles

import "testing"

// The seven RME displays nest ("Fireface UFX" ⊂ "Fireface UFX II" ⊂ "…III"),
// so a connected card must resolve to its own row, not the shortest match.
func TestMatchEntryRME(t *testing.T) {
	ix := Index{SchemaVersion: SchemaVersion}
	for _, d := range []string{
		"RME Fireface 802", "RME Fireface UCX", "RME Fireface UCX II",
		"RME Fireface UFX", "RME Fireface UFX II", "RME Fireface UFX III",
		"RME Fireface UFX+",
	} {
		ix.Cards = append(ix.Cards, IndexCard{ID: "id-" + d, Display: d})
	}
	cases := []struct{ name, match, want string }{
		{"RME Fireface UFX III", "Fireface UFX III", "RME Fireface UFX III"},
		{"RME Fireface UFX II", "Fireface UFX II", "RME Fireface UFX II"},
		{"RME Fireface UFX", "Fireface UFX", "RME Fireface UFX"},
		{"RME Fireface UFX+", "Fireface UFX+", "RME Fireface UFX+"},
		{"RME Fireface UCX II", "Fireface UCX II", "RME Fireface UCX II"},
		{"RME Fireface UCX", "Fireface UCX", "RME Fireface UCX"},
		{"RME Fireface 802", "Fireface 802", "RME Fireface 802"},
	}
	for _, c := range cases {
		ic, ok := matchEntry(ix, ConnEntry{Name: c.name, Match: c.match})
		if !ok || ic.Display != c.want {
			t.Errorf("%s matched %q (ok=%v), want %q", c.name, ic.Display, ok, c.want)
		}
	}
}
