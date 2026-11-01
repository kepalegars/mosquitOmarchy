package tuikit

import (
	"fmt"
	"testing"

	"github.com/charmbracelet/lipgloss"
)

// The point of computing this: the accent is the ACTIVE THEME's accent, so no
// fixed answer is right for every user. Each pair below is (fill, better text)
// taken from real Omarchy themes.
func TestBestContrastOn(t *testing.T) {
	cases := []struct {
		bg   lipgloss.Color
		want string
		why  string
	}{
		{lipgloss.Color("#ffb454"), "0", "pale amber — dark text is the only readable option"},
		{lipgloss.Color("#f9fafb"), "0", "near-white fill"},
		{lipgloss.Color("#89b4fa"), "0", "pastel blue"},
		{lipgloss.Color("#1e1e2e"), "15", "catppuccin base — dark fill"},
		{lipgloss.Color("#458588"), "0", "muted teal: black 4.96 beats white 4.23 — a mid-tone fill favours neither, and dark still wins"},
		{lipgloss.Color("212"), "0", "ANSI-256 pink (the kit's default accent): black 9.70 beats white 2.17"},
		{lipgloss.Color("231"), "0", "ANSI-256 near-white"},
		{lipgloss.Color("17"), "15", "ANSI-256 dark blue"},
	}
	for _, c := range cases {
		if got := BestContrastOn(c.bg); string(got) != c.want {
			t.Errorf("BestContrastOn(%s) = %s, want %s — %s", c.bg, got, c.want, c.why)
		}
	}
}

// Whatever the theme, the chosen text must actually beat the other option —
// otherwise "best contrast" is a claim the code does not back up.
func TestBestContrastOnBeatsTheAlternative(t *testing.T) {
	for _, bg := range []lipgloss.Color{
		"#ffb454", "#f9fafb", "#89b4fa", "#458588", "#1e1e2e", "#ed1c24",
		"212", "231", "17", "0", "7", "15", "99",
	} {
		chosen := BestContrastOn(bg)
		other := lipgloss.Color("0")
		if string(chosen) == "0" {
			other = lipgloss.Color("15")
		}
		cr, cg, cb, ok := colorRGB(bg)
		if !ok {
			t.Fatalf("could not resolve %s to RGB", bg)
		}
		got := contrastRatio(cr, cg, cb, mustRGB(t, chosen, 0), mustRGB(t, chosen, 1), mustRGB(t, chosen, 2))
		alt := contrastRatio(cr, cg, cb, mustRGB(t, other, 0), mustRGB(t, other, 1), mustRGB(t, other, 2))
		if got < alt {
			t.Errorf("on %s chose %s (ratio %.2f) but %s scores higher (%.2f)", bg, chosen, got, other, alt)
		}
		fmt.Printf("  %-10s -> %s  (%.2f vs %.2f)\n", bg, chosen, got, alt)
	}
}

func mustRGB(t *testing.T, c lipgloss.Color, i int) float64 {
	t.Helper()
	r, g, b, ok := colorRGB(c)
	if !ok {
		t.Fatalf("cannot resolve %s", c)
	}
	return []float64{r, g, b}[i]
}
