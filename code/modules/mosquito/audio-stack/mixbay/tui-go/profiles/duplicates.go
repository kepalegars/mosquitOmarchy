package profiles

import (
	"sort"
	"strings"
	"unicode"
)

// Duplicate is two installed cards that look like the same interface. The
// common case: a card was added by the scan flow (local, id "beta-…") and the
// community profile for the same box was downloaded later.
type Duplicate struct {
	KeepID        string `json:"keep_id"`
	KeepDisplay   string `json:"keep_display"`
	RemoveID      string `json:"remove_id"`
	RemoveDisplay string `json:"remove_display"`
}

func sameName(s string) string {
	var b strings.Builder
	for _, r := range strings.ToLower(s) {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			b.WriteRune(r)
		}
	}
	return b.String()
}

// Duplicates groups installed cards by normalized display name. A native or
// downloaded card wins over a local scan card; a native card is never listed as
// removable. The list is stable so the UI can offer one confirmation per pair.
//
// shortcut: name comparison only; upgrade to USB VID/PID + card_match when the
// repo grows (TODO-PROFILES.md §5).
func Duplicates() []Duplicate {
	groups := map[string][]Meta{}
	for _, m := range Installed() {
		key := sameName(m.Display)
		if key == "" {
			continue
		}
		groups[key] = append(groups[key], m)
	}
	var out []Duplicate
	for _, g := range groups {
		if len(g) < 2 {
			continue
		}
		sort.Slice(g, func(i, j int) bool { return keepRank(g[i]) < keepRank(g[j]) })
		keep := g[0]
		for _, m := range g[1:] {
			if m.Native {
				continue // never propose deleting a built-in card
			}
			out = append(out, Duplicate{
				KeepID: keep.ID, KeepDisplay: keep.Display,
				RemoveID: m.ID, RemoveDisplay: m.Display,
			})
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].RemoveDisplay != out[j].RemoveDisplay {
			return out[i].RemoveDisplay < out[j].RemoveDisplay
		}
		return out[i].RemoveID < out[j].RemoveID
	})
	return out
}

// keepRank orders the group: native, then downloaded/built-in, then local scan
// cards, then the most specific id.
func keepRank(m Meta) string {
	rank := "2"
	switch {
	case m.Native:
		rank = "0"
	case m.Source == "repo" || m.Source == "built-in":
		rank = "1"
	}
	beta := "0"
	if strings.HasPrefix(m.ID, "beta-") {
		beta = "1"
	}
	return rank + beta + m.ID
}
