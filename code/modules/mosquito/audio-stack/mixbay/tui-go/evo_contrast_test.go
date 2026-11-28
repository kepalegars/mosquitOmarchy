package main

import (
	"testing"

	"github.com/charmbracelet/lipgloss"
	tuikit "mosquitomarchy.local/tui-kit"
)

// A light accent (kanagawa and similar) used to get theme-foreground text on
// top of it, which is effectively white on white. The palette must choose the
// text colour from the accent itself, like the shared confirm buttons do.
func TestEVOPaletteContrastOnAccent(t *testing.T) {
	saved := tuikit.ColorAccent
	defer func() { tuikit.ColorAccent = saved }()

	for _, tc := range []struct {
		accent string
		want   lipgloss.Color
	}{
		{"#f8f8f2", lipgloss.Color("0")},  // near-white: dark text
		{"#1e1e2e", lipgloss.Color("15")}, // dark: light text
	} {
		tuikit.ColorAccent = lipgloss.Color(tc.accent)
		pal := evoPalette()
		if pal[cOnAccent] != tc.want {
			t.Errorf("accent %s: on-accent text = %s, want %s", tc.accent, pal[cOnAccent], tc.want)
		}
		if pal[cWhite] != tuikit.ColorOnSurface {
			t.Errorf("accent %s: body text changed to %s", tc.accent, pal[cWhite])
		}
	}
}
