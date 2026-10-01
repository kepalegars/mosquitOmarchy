package main

import (
	"regexp"
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"
	tuikit "mosquitomarchy.local/tui-kit"
)

// This file is the end-to-end guard on the layout rule documented in
// scripts/lib/tui-kit/responsive.go. Every other test in this package checks
// behaviour at ONE size (usually 120x40). These check geometry at EVERY size,
// because the reported bug was never "the TUI is wrong" — it was "the TUI is
// wrong in a 74x18 tile, or a 100x24 one, and looks fine in the terminal I
// happened to test in".

// ansiSGR strips the colour escapes so geometry is measured on the
// visible text, not on the escape bytes.
var ansiSGR = regexp.MustCompile(`\x1b\[[0-9;]*[a-zA-Z]`)

// TestViewNeverOverflows renders every screen at every tile size and asserts
// the composed output fits the window exactly.
//
// The symptom this replaces: a screen taller than the terminal does not get
// cut off, it makes the terminal SCROLL, taking the title out of view. So
// "too many lines" and "the banner vanished" are the same bug, and only the
// line count catches it.
func TestViewNeverOverflows(t *testing.T) {
	screens := []struct {
		name string
		nav  []screen
	}{
		{"main", []screen{scrMain}},
		{"status", []screen{scrMain, scrStatus}},
		{"setup", []screen{scrMain, scrSetup}},
		{"update", []screen{scrMain, scrUpdate}},
		{"backup", []screen{scrMain, scrBackup}},
		{"settings", []screen{scrMain, scrSettings}},
		{"keybindings", []screen{scrMain, scrKB}},
		{"health", []screen{scrMain, scrHealth}},
		{"confirm", []screen{scrMain, scrConfirm}},
		{"theme-folder", []screen{scrMain, scrThemeFolder}},
		{"theme-image", []screen{scrMain, scrThemeImage}},
		{"theme-done", []screen{scrMain, scrThemeDone}},
	}
	// Tile shapes actually seen in a Hyprland tiling layout: narrow and short
	// (a quarter of a 1080p screen), a phone-ish portrait half, a wide-short
	// strip, and the comfortable fullscreen sizes.
	sizes := [][2]int{
		{74, 18}, {80, 20}, {90, 22}, {100, 24}, {110, 26},
		{120, 30}, {140, 36}, {160, 50},
		{60, 40}, {48, 60}, {200, 14}, {30, 12}, {20, 8},
	}

	for _, sc := range screens {
		for _, sz := range sizes {
			w, h := sz[0], sz[1]
			m := initialModel()
			m.w, m.h = w, h
			m.nav = sc.nav

			out := m.View()
			if out == "" {
				continue
			}
			plain := ansiSGR.ReplaceAllString(out, "")
			gotH := lipgloss.Height(plain)
			if gotH > h {
				t.Errorf("%s at %dx%d: rendered %d lines, window is %d — "+
					"the terminal scrolls and the title is lost", sc.name, w, h, gotH, h)
			}
			gotW := lipgloss.Width(plain)
			if gotW > w {
				t.Errorf("%s at %dx%d: widest line is %d columns, window is %d",
					sc.name, w, h, gotW, w)
			}
		}
	}
}

// TestHomeTitleNeverWraps is the specific regression for the shredded wordmark.
//
// BoxedMosquitOmarchy is 121 columns. It was rendered at whatever width the
// window happened to be and lipgloss hard-wrapped it, so in any tile under 121
// columns the banner showed vertical slices of glyphs instead of the word.
// A wrapped title is detected by its shape: the art's rows all start and end
// with a box-drawing character, and a wrapped one has stray fragments.
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
					t.Fatalf("%dx%d: title line %d is %d columns wide — it was wrapped, not shrunk",
						w, h, i, lw)
				}
			}
		}
	}
}

// TestHomeTitleMatchesItsReserve asserts the banner occupies exactly the rows
// the picker was laid out to leave free. These were two independent
// calculations (a hardcoded 14, chosen by a magic w<74 threshold, versus
// whatever the renderer produced), so when they disagreed the title was what
// got clipped.
func TestHomeTitleMatchesItsReserve(t *testing.T) {
	for w := 40; w <= 200; w += 7 {
		for h := 10; h <= 60; h += 5 {
			m := initialModel()
			m.w, m.h = w, h
			reserved := m.homeBannerReserve()
			drawn := lipgloss.Height(ansiSGR.ReplaceAllString(m.homeTitle(), ""))
			if reserved != drawn {
				t.Errorf("%dx%d: reserve says %d rows, title draws %d",
					w, h, reserved, drawn)
			}
		}
	}
}

// TestContentSizeFitsTheGap asserts the panel each screen is told to render
// actually fits between the title and the shortcut bar, at every size. This is
// the arithmetic that produced the +4 / +2 / +17 row overflows.
func TestContentSizeFitsTheGap(t *testing.T) {
	for w := 40; w <= 200; w += 3 {
		for h := 10; h <= 60; h += 2 {
			m := initialModel()
			m.w, m.h = w, h
			_, body := m.contentSize()
			titleRows := m.homeBannerReserve()
			if m.top() != scrMain {
				titleRows = subScreenTitleRows
			}
			gap := h - titleRows - tuikit.BarRows
			if body > gap {
				t.Errorf("%dx%d: panel is %d rows but only %d are free "+
					"(title %d + bar %d)", w, h, body, gap, titleRows, tuikit.BarRows)
			}
		}
	}
}
