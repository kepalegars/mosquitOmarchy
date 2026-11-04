package main

import (
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"
	tuikit "mosquitomarchy.local/tui-kit"
)

// TestDownloadBarGrowsWithPercent pins the streamed download bar: one row as
// wide as the window, centred, with the accent fill strictly growing from 0
// to 100 and no empty track left at 100.
func TestDownloadBarGrowsWithPercent(t *testing.T) {
	m := model{}
	m.w = 80
	inner := m.contentSizeW()

	empty, half, full := m.downloadBar(0), m.downloadBar(50), m.downloadBar(100)
	for _, bar := range []string{empty, half, full} {
		if got := lipgloss.Width(bar); got != m.w {
			t.Fatalf("bar width = %d, want %d (%q)", got, m.w, bar)
		}
	}
	if strings.ContainsAny(empty, "[]") {
		t.Fatalf("bar should not draw side brackets: %q", empty)
	}

	e, h, f := strings.Count(empty, "█"), strings.Count(half, "█"), strings.Count(full, "█")
	if !(e < h && h < f) {
		t.Fatalf("fill does not grow monotonically: %d, %d, %d", e, h, f)
	}
	if e != 0 || f != inner {
		t.Fatalf("fill at 0/100 = %d/%d, want 0/%d", e, f, inner)
	}
	if strings.Count(half, "█")+strings.Count(half, "░") != inner {
		t.Fatalf("half bar is not %d columns: %q", inner, half)
	}
	if got := strings.Count(m.downloadBar(100), "░"); got != 0 {
		t.Fatalf("full bar has %d empty cells left", got)
	}
}

// TestDownloadBarFitsTheWindow pins the layout contract: with a download in
// flight the frame plus the bar still occupy exactly the window's rows, never
// one more (a terminal would scroll the title off the top).
func TestDownloadBarFitsTheWindow(t *testing.T) {
	m := initialModel()
	m.nav = []screen{scrWorking}
	m.w, m.h = 80, 24
	m.runner = tuikit.NewRunner()
	m.runner, _ = m.runner.Update(tuikit.RunnerLineMsg{Text: "\x01progress 30"})
	if got := strings.Count(m.View(), "\n") + 1; got != m.h {
		t.Fatalf("view has %d rows, want %d", got, m.h)
	}
	lines := strings.Split(m.View(), "\n")
	if !strings.Contains(lines[len(lines)-1], "esc cancel") {
		t.Fatalf("last row is not the shortcut legend: %q", lines[len(lines)-1])
	}
	foundBar := false
	for i := 0; i < len(lines)-1; i++ {
		if strings.ContainsAny(lines[i], "█░") {
			foundBar = true
			break
		}
	}
	if !foundBar {
		t.Fatalf("progress bar not rendered inside the frame")
	}
}

// TestDownloadPercentOnlyWhileWorking pins that the bar is a Working-screen
// affordance: it must not appear over another screen or after the run ended.
func TestDownloadPercentOnlyWhileWorking(t *testing.T) {
	m := initialModel()
	m.nav = []screen{scrSetup}
	m.runner = tuikit.NewRunner()
	m.runner, _ = m.runner.Update(tuikit.RunnerLineMsg{Text: "\x01progress 50"})
	if _, ok := m.downloadPercent(); ok {
		t.Fatal("progress bar showed outside the Working screen")
	}

	m.nav = []screen{scrWorking}
	m.runner, _ = m.runner.Update(tuikit.RunnerDoneMsg{})
	if _, ok := m.downloadPercent(); ok {
		t.Fatal("progress bar survived the end of the run")
	}
}
