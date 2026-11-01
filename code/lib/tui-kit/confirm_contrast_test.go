package tuikit

import (
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"
	"github.com/muesli/termenv"
)

// The focused answer is painted on the theme's accent fill. With a bright
// accent — the active theme's is #b5e61d, a lime — the old hardcoded cream
// (#f7f1e8) was almost unreadable, which is what the user reported on
// "close mosquitomarchy" / "see log".
//
// These tests pin the RULE (the text beats the fill, by WCAG contrast ratio)
// rather than one theme's answer, because the accent changes with the theme and
// a test frozen on today's colour would keep passing while the next theme is
// unreadable.
func TestConfirmFocusedAnswerBeatsTheAccentFill(t *testing.T) {
	for _, accent := range []string{
		"#b5e61d", // the active theme: bright lime
		"#ffb454", // catppuccin-ish amber
		"#89b4fa", // pastel blue
		"#1e1e2e", // dark base
		"212",     // bare ANSI index — used to defeat every hex parser
		"231",     // bare ANSI index, near-white
	} {
		saved := ColorAccent
		ColorAccent = lipgloss.Color(accent)

		fg := BestContrastOn(ColorAccent)
		ar, ag, ab, ok := colorRGB(ColorAccent)
		if !ok {
			ColorAccent = saved
			t.Fatalf("accent %s did not resolve to RGB", accent)
		}
		won := contrastRatio(ar, ag, ab, mustRGB(t, fg, 0), mustRGB(t, fg, 1), mustRGB(t, fg, 2))
		alt := lipgloss.Color("15")
		if string(fg) == "15" {
			alt = lipgloss.Color("0")
		}
		other := contrastRatio(ar, ag, ab, mustRGB(t, alt, 0), mustRGB(t, alt, 1), mustRGB(t, alt, 2))
		if won <= other {
			t.Errorf("accent %s: chosen text %s scores %.2f, not better than %s (%.2f)", accent, fg, won, alt, other)
		}
		ColorAccent = saved
	}
}

// The render must actually CARRY the computed colour, not merely compute it: a
// test that only checked the arithmetic would still pass with the hardcoded
// cream left in place.
func TestConfirmFocusedAnswerUsesTheComputedColour(t *testing.T) {
	// Under `go test` there is no TTY, so lipgloss picks the Ascii profile and
	// emits no colour at all — the run under test would be invisible. Force the
	// 256-colour profile a real terminal has.
	old := lipgloss.ColorProfile()
	lipgloss.SetColorProfile(termenv.ANSI256)
	defer lipgloss.SetColorProfile(old)

	for _, accent := range []string{"#b5e61d", "#1e1e2e", "212", "231"} {
		saved := ColorAccent
		ColorAccent = lipgloss.Color(accent)
		want := BestContrastOn(ColorAccent)

		// Both focus positions, not just the default: "Close" and "See log" are
		// reached by tabbing, and whichever answer is focused has to stay
		// readable on the same fill.
		for _, focused := range []string{"Cancel", "Close"} {
			c := NewConfirm("Close mosquitomarchy?", "Cancel", "Close")
			if focused == "Close" {
				c = c.SetFocus(1)
			}
			raw := c.View()

			// Compare against the render lipgloss produces for the computed
			// colour. Deriving the expected SGR by hand is not viable: lipgloss
			// DOWNSAMPLES a hex fill to the nearest 256-colour index
			// (#b5e61d -> 48;5;148), so the bytes depend on the profile and the
			// palette. Rendering the style and looking for it tests the same
			// thing without re-deriving the encoding.
			expected := lipgloss.NewStyle().
				Padding(0, 2).
				Background(ColorAccent).
				Foreground(want).
				Bold(true).
				Render(focused)
			if !strings.Contains(raw, expected) {
				t.Errorf("accent %s, focused %q: not painted in the computed colour %s\n want run: %q\n got render: %q",
					accent, focused, want, expected, raw)
			}

			// The old hardcoded cream must be gone: on a bright fill it is
			// effectively invisible, which is the reported bug.
			cream := lipgloss.NewStyle().
				Padding(0, 2).
				Background(ColorAccent).
				Foreground(ColorOnSurface).
				Bold(true).
				Render(focused)
			if strings.Contains(raw, cream) {
				t.Errorf("accent %s, focused %q: still painted in ColorOnSurface (%s) on the accent fill",
					accent, focused, ColorOnSurface)
			}
		}
		ColorAccent = saved
	}
}

// The same rule governs the picker's highlighted row and the banner, which sit
// on the accent fill too. They used to route through a hex-only luminance guess.
func TestAccentForegroundTracksTheComputedContrast(t *testing.T) {
	for _, accent := range []string{"#b5e61d", "#1e1e2e", "212", "231", "17"} {
		saved := ColorAccent
		ColorAccent = lipgloss.Color(accent)
		if got, want := accentForeground(), BestContrastOn(ColorAccent); got != want {
			t.Errorf("accent %s: accentForeground() = %s, want %s", accent, got, want)
		}
		ColorAccent = saved
	}
}
