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

// sameCard reports two profiles for the same box. USB identity is the reliable
// signal: the display name differs between a scan card and a repo profile
// ("PreSonus Quantum ES 4" vs "Quantum ES 4"). The name stays as the fallback
// for the cards that carry no ids, and an exact shared card_match entry catches
// the rest without merging boxes that merely share a vendor.
func sameCard(a, b Card) bool {
	as, bs := a.Spec, b.Spec
	if as.USBVID != "" && as.USBVID == bs.USBVID &&
		as.USBPID != "" && as.USBPID == bs.USBPID {
		return true
	}
	if na, nb := sameName(as.Display), sameName(bs.Display); na != "" && na == nb {
		return true
	}
	for _, ma := range as.CardMatch {
		ma = sameName(ma)
		if len(ma) < 4 { // "EVO" or "UCX" alone proves nothing
			continue
		}
		for _, mb := range bs.CardMatch {
			if ma == sameName(mb) {
				return true
			}
		}
	}
	return false
}

// Duplicates groups installed cards by identity and returns one pair per card
// to remove. A native or downloaded card wins over a local scan card; a native
// card is never listed as removable. The list is stable so the UI can offer one
// confirmation per pair.
func Duplicates() []Duplicate {
	metas := Installed()
	cards := make([]Card, len(metas))
	for i, m := range metas {
		cards[i], _, _ = Effective(m.ID)
	}
	parent := make([]int, len(metas))
	for i := range parent {
		parent[i] = i
	}
	var find func(int) int
	find = func(i int) int {
		for parent[i] != i {
			parent[i] = parent[parent[i]]
			i = parent[i]
		}
		return i
	}
	for i := 0; i < len(metas); i++ {
		for j := i + 1; j < len(metas); j++ {
			if sameCard(cards[i], cards[j]) {
				if ri, rj := find(i), find(j); ri != rj {
					parent[rj] = ri
				}
			}
		}
	}
	groups := map[int][]Meta{}
	for i, m := range metas {
		root := find(i)
		groups[root] = append(groups[root], m)
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
				continue // never propose deleting a seeded snapshot
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
	case m.Source == "repo" || m.Source == "built-in" || m.Source == "preinstalled":
		rank = "1"
	}
	beta := "0"
	if strings.HasPrefix(m.ID, "beta-") {
		beta = "1"
	}
	return rank + beta + m.ID
}
