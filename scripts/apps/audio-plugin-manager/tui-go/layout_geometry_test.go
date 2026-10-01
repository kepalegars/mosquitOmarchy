package main

import (
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"
	tuikit "mosquitomarchy.local/tui-kit"
)

// Geometry guard for the layout rule in scripts/lib/tui-kit/responsive.go.
//
// Behaviour tests here all render at one comfortable size. These render at
// every tile size, because the reported failure was never "the TUI is wrong"
// — it was "the TUI is wrong in a 74x18 tile and looks fine in the terminal I
// happened to test in".

// tiles are the shapes a Hyprland tiling layout actually produces: a quarter
// pane, a portrait half, a wide short strip, and comfortable fullscreen.
var tiles = [][2]int{
	{74, 18}, {80, 20}, {90, 22}, {100, 24}, {110, 26},
	{120, 30}, {140, 36}, {160, 50},
	{60, 40}, {48, 60}, {200, 14}, {30, 12}, {20, 8},
}

// TestViewNeverOverflows asserts the composed screen fits its window.
//
// A screen taller than the terminal does not get cut off, it makes the
// terminal SCROLL — taking the title out of view. So "too many lines" and "the
// banner vanished" are one bug, and only the line count catches it.
func TestViewNeverOverflows(t *testing.T) {
	for _, sz := range tiles {
		w, h := sz[0], sz[1]
		m := initialModel()
		m.w, m.h = w, h
		out := m.View()
		if out == "" {
			continue
		}
		plain := ansiSGR.ReplaceAllString(out, "")
		if gotH := lipgloss.Height(plain); gotH > h {
			t.Errorf("%dx%d: rendered %d lines in a %d-row window — the terminal "+
				"scrolls and the title is lost", w, h, gotH, h)
		}
		if gotW := lipgloss.Width(plain); gotW > w {
			t.Errorf("%dx%d: widest line is %d columns in a %d-column window", w, h, gotW, w)
		}
	}
}

// TestHomeTitleNeverWraps is the regression for a shredded banner. The boxed
// art is wide, and rendering it at whatever width the window happened to be
// let lipgloss hard-wrap it — turning the word into vertical slices of glyphs.
// A wrapped title is caught by its geometry: no line may exceed the window.
func TestHomeTitleNeverWraps(t *testing.T) {
	for w := 30; w <= 200; w++ {
		for _, h := range []int{10, 18, 24, 40, 60} {
			m := initialModel()
			m.w, m.h = w, h
			title := ansiSGR.ReplaceAllString(m.homeTitle(), "")
			if title == "" {
				t.Fatalf("empty home title at %dx%d", w, h)
			}
			for i, line := range strings.Split(title, "\n") {
				if lw := lipgloss.Width(line); lw > w {
					t.Fatalf("%dx%d: title line %d is %d columns — it was wrapped, not shrunk",
						w, h, i, lw)
				}
			}
		}
	}
}

// TestHomeTitleMatchesItsReserve asserts the banner occupies exactly the rows
// the picker was laid out to leave free. These were two independent numbers —
// a hardcoded reserve versus whatever the renderer produced — so when they
// disagreed, the title was what got clipped.
func TestHomeTitleMatchesItsReserve(t *testing.T) {
	for w := 40; w <= 200; w += 7 {
		for h := 10; h <= 60; h += 5 {
			m := initialModel()
			m.w, m.h = w, h
			reserved := m.homeBannerReserve()
			drawn := lipgloss.Height(ansiSGR.ReplaceAllString(m.homeTitle(), ""))
			if reserved != drawn {
				t.Errorf("%dx%d: reserve says %d rows, title draws %d", w, h, reserved, drawn)
			}
		}
	}
}

// TestContentSizeFitsTheGap asserts the panel each screen is told to render
// actually fits between the title and the shortcut bar, at every size. This is
// the arithmetic that produced the row overflows.
func TestContentSizeFitsTheGap(t *testing.T) {
	for w := 40; w <= 200; w += 3 {
		for h := 10; h <= 60; h += 2 {
			m := initialModel()
			m.w, m.h = w, h
			_, body := m.contentSize()
			gap := h - m.homeBannerReserve() - tuikit.BarRows
			if body > gap {
				t.Errorf("%dx%d: panel is %d rows but only %d are free", w, h, body, gap)
			}
		}
	}
}
