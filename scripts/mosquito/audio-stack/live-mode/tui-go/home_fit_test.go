package main

import (
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

// The home screen must fit the terminal, at every size.
//
// It did not. The banner was drawn from a constant (15 rows) while the layout
// budget measured the real header (13) and the "is there room?" threshold was a
// height of its own, so the two disagreed; the home screen came out TALLER than
// the window, and bubbletea clips from the TOP — the framed mosquito and the
// "live mode manager" subtitle simply disappeared. The user reported exactly
// that. The banner is now chosen from the arithmetic, so the draw and the
// budget cannot disagree.
func TestTheHomeScreenFitsTheTerminal(t *testing.T) {
	// From 74 columns up, which is the width the kit itself treats as the floor
	// for the framed banner (narrower than that and it drops to the subtitle).
	//
	// BELOW 74 this test does not run, and the reason is worth stating: the
	// picker WRAPS a row that is wider than its box, so a list of
	// "Block package installation during the session: Off" takes two lines at
	// 60 columns and the screen grows by one row per wrapped row. That is a
	// property of the shared picker, it affects every one of the six managers in
	// the same way, and it is not what was reported here. Fixing it means the
	// picker either truncating or the hosts measuring their widest row — a
	// kit-wide change, not a live-mode one.
	for _, h := range []int{18, 20, 22, 24, 26, 28, 30, 32, 34, 40, 50} {
		for _, w := range []int{74, 80, 100, 120, 160} {
			m := initialModel()
			mm, _ := m.Update(tea.WindowSizeMsg{Width: w, Height: h})
			got := mm.(model)
			rows := strings.Count(got.View(), "\n") + 1
			if rows > h {
				t.Errorf("%dx%d renders %d rows — bubbletea will clip the top", w, h, rows)
			}
		}
	}
}

// The banner must be PRESENT at every size, in whichever of its two renderings
// fits: the framed wordmark when there is room, the subtitle when there is not.
// Losing it entirely is the reported bug, and it is the thing this file exists
// to prevent — so the check is that SOMETHING of it is there, not which form.
func TestTheBannerIsNeverLost(t *testing.T) {
	for _, s := range []struct{ w, h int }{{100, 24}, {100, 30}, {100, 20}, {100, 18}, {80, 26}} {
		m := initialModel()
		mm, _ := m.Update(tea.WindowSizeMsg{Width: s.w, Height: s.h})
		got := mm.(model).View()
		// The boxed mosquito is block-drawing art; the subtitle is the ASCII
		// "live mode" wordmark. Either one proves the banner rendered.
		boxed := strings.Contains(got, "█")
		wordmark := strings.Contains(got, "(_)_") || strings.Contains(got, "l i v e")
		if !boxed && !wordmark {
			t.Errorf("%dx%d: the home screen has no banner at all", s.w, s.h)
		}
	}
}
