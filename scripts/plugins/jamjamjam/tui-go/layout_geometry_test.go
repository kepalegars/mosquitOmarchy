package main

import (
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"
)

// Geometry guard for the splash and the panels: see the rule in
// scripts/lib/tui-kit/responsive.go. The splash in particular was 13 rows at
// every size — it concatenated the boxed mosquito and the subtitle wordmark
// unconditionally — so in a short tile it overflowed the window and the
// terminal scrolled it away on the one screen the user is guaranteed to see.

func TestSplashFitsTheWindow(t *testing.T) {
	for w := 20; w <= 200; w += 3 {
		for h := 6; h <= 60; h += 2 {
			m := initialModel()
			m.w, m.h = w, h
			out := m.splashTitle()
			if out == "" {
				t.Fatalf("empty splash title at %dx%d", w, h)
			}
			for i, line := range strings.Split(out, "\n") {
				if lw := lipgloss.Width(line); lw > w {
					t.Fatalf("%dx%d: splash line %d is %d columns — wrapped, not shrunk", w, h, i, lw)
				}
			}
			if oh := lipgloss.Height(out); oh > h {
				t.Fatalf("%dx%d: splash is %d rows", w, h, oh)
			}
		}
	}
}
