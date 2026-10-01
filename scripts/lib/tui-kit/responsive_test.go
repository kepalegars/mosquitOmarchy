package tuikit

import (
	"os"
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"
)

// TestKitUsesNoNerdFontGlyphs locks the decision documented in responsive.go:
// the kit renders with stock monospace fonts only, so there is nothing to
// install and nothing that can be missing on the machine it runs on.
//
// The rule is stated as ranges rather than a hand-kept list of codepoints,
// because the previous list was itself a maintenance trap: adding U+2510 to
// CompactTitle failed a test that claimed U+2510 was exotic.
//
// FORBIDDEN, always: the Private Use Areas (U+E000..U+F8FF, U+F0000..U+FFFFD,
// U+100000..U+10FFFD). That is where Nerd Fonts and fontawesome put their icons,
// and it is exactly where a terminal without the font renders tofu.
//
// ALLOWED: Unicode box drawing (U+2500..U+257F), geometric shapes
// (U+25A0..U+25FF), the two dingbats the kit uses for ok/error, and the arrows
// it uses as key affordances. All are in every monospace font shipped by
// Omarchy and in the terminal fallback chain.
func TestKitUsesNoNerdFontGlyphs(t *testing.T) {
	const (
		boxStart, boxEnd   = 0x2500, 0x257F // ─ │ ┌ ┐ └ ┘ ├ ┤ ┬ ┴ ┼ ═ ║ ╔ ╗ ╚ ╝ ╭ ╮ ╰ ╯
		geomStart, geomEnd = 0x25A0, 0x25FF // ■ ▢ ▣ ▲ ▶ ▸ ▼ ▾ ○ ●
		dings              = 0x2713         // ✓
		dingErr            = 0x2717         // ✗
	)
	allowedDing := map[rune]bool{dings: true, dingErr: true}
	allowedArrow := map[rune]bool{0x2190: true, 0x2191: true, 0x2192: true, 0x2193: true, 0x21C4: true}

	sources := []string{
		"picker.go", "layout.go", "theme.go", "confirm.go", "info.go",
		"input.go", "toast.go", "runner.go", "foldertree.go",
		"mosquito_banner.go", "contrast.go", "responsive.go",
	}
	for _, name := range sources {
		src := readKitSource(t, name)
		for _, r := range src {
			switch {
			case boxStart <= r && r <= boxEnd,
				geomStart <= r && r <= geomEnd,
				allowedDing[r], allowedArrow[r]:
				continue
			}
			// Private Use Area: the exact failure this test exists for.
			if 0xE000 <= r && r <= 0xF8FF {
				t.Errorf("%s uses U+%04X, a Private Use Area codepoint: that is a Nerd Font icon, "+
					"and it renders as tofu without one", name, r)
				continue
			}
			if r > 0xFFFF {
				t.Errorf("%s uses U+%04X, a supplementary-plane codepoint: that is a "+
					"supplementary-plane font icon or an emoji, neither of which is guaranteed "+
					"to render in a terminal", name, r)
				continue
			}
			// Deliberately NOT a generic "is this a symbol" check. Go classifies
			// the backtick, '^' and '°' as Sk/So, and the kit's own source is
			// full of them inside Go string literals and comments — flagging
			// those produced a wall of false positives and taught nothing. The
			// two checks above (Private Use Area, supplementary plane) are the
			// actual, unambiguous signature of a font-icon dependency, and they
			// cannot be satisfied by ordinary punctuation.
		}
	}
}

// TestTitleLadderNeverWraps is the regression test for shredded box art. The
// wordmark was rendered unconditionally at 121 columns and lipgloss hard-wrapped
// it at the window width, so any tile under 121 columns showed fragments of
// glyphs instead of the word.
func TestTitleLadderNeverWraps(t *testing.T) {
	ladder := MosquitOmarchyTitleLadder()
	for w := 8; w <= 160; w++ {
		for h := 1; h <= 40; h++ {
			got := ladder.Render(w, h)
			if got == "" {
				t.Fatalf("empty title at %dx%d", w, h)
			}
			if gotWidth := lipgloss.Width(got); gotWidth > w {
				t.Fatalf("title wider than the window at %dx%d: %d > %d", w, h, gotWidth, w)
			}
			// The killer assertion: no line may exceed the window, i.e. nothing
			// was wrapped to make it fit.
			for i, line := range strings.Split(got, "\n") {
				if lw := lipgloss.Width(line); lw > w {
					t.Fatalf("line %d wraps at %dx%d: width %d > %d", i, w, h, lw, w)
				}
			}
			if rows := ladder.Rows(w, h); rows != lipgloss.Height(got) {
				t.Fatalf("Rows(%d,%d)=%d but Render is %d rows — the budget and the draw disagree",
					w, h, rows, lipgloss.Height(got))
			}
		}
	}
}

// TestTitleLadderPicksTheBiggestThatFits checks the ladder is not merely safe,
// but actually uses the room it has.
func TestTitleLadderPicksTheBiggestThatFits(t *testing.T) {
	ladder := MosquitOmarchyTitleLadder()
	if got := lipgloss.Height(ladder.Render(140, 40)); got != 9 {
		t.Errorf("a 140x40 window should show the full wordmark (9 rows), got %d", got)
	}
	if got := lipgloss.Height(ladder.Render(80, 40)); got == 9 {
		t.Errorf("an 80-column window must NOT show the 121-column wordmark")
	}
	// And the small rung must fit where the big one cannot.
	small := ladder.Render(60, 40)
	if lipgloss.Width(small) > 60 {
		t.Errorf("small rung still too wide: %d", lipgloss.Width(small))
	}
	if !strings.Contains(strings.ToLower(stripANSI(small)), "mosquitomarchy") {
		t.Errorf("the title must still say mosquitomarchy, got %q", stripANSI(small))
	}
}

// TestLayoutBudgetNeverForgetsChrome is the rule in executable form: BarRows and
// FrameRows are always accounted for, at every size, and BodyRows is never
// negative or zero.
func TestLayoutBudgetNeverForgetsChrome(t *testing.T) {
	for h := 4; h <= 60; h++ {
		for _, titleRows := range []int{0, 1, 3, 9, 13} {
			l := NewLayout(100, h, titleRows)
			if l.BodyRows() < 1 {
				t.Fatalf("h=%d title=%d: BodyRows=%d", h, titleRows, l.BodyRows())
			}
			// What fits must actually fit the gap. A title that does not leave
			// room for a bar and a body row is only reachable through the raw
			// constructor; LayoutForLadder is the guarded entry point.
			gap := h - titleRows - l.BarRows
			if gap < 1 {
				continue
			}
			if l.BodyRows() > gap {
				t.Fatalf("h=%d title=%d: BodyRows=%d exceeds the gap %d", h, titleRows, l.BodyRows(), gap)
			}
			w, bh := l.ContentSize()
			if w < 8 {
				t.Fatalf("h=%d title=%d: content width %d too small", h, titleRows, w)
			}
			if bh != l.BodyRows() {
				t.Fatalf("ContentSize height %d != BodyRows %d", bh, l.BodyRows())
			}
		}
	}
}

// TestFrameScreenProtectsChrome proves the safety net: an over-tall body loses
// its tail, and the title and shortcut bar survive.
func TestFrameScreenProtectsChrome(t *testing.T) {
	tall := strings.Repeat("body line\n", 40)
	title := "TITLE"
	bar := "shortcut hint"
	out := FrameScreen(40, 12, title, tall, bar)

	if h := lipgloss.Height(out); h > 12 {
		t.Errorf("render is %d rows in a 12-row window", h)
	}
	if !strings.Contains(out, title) {
		t.Errorf("title lost to an over-tall body")
	}
	if !strings.Contains(out, bar) {
		t.Errorf("shortcut bar lost to an over-tall body")
	}
}

// TestFrameScreenKeepsTheBarOnItsOwnLine guards the case where the body exactly
// fills the gap: without an explicit newline the bar concatenates onto the
// body's last row and becomes unreadable.
func TestFrameScreenKeepsTheBarOnItsOwnLine(t *testing.T) {
	body := strings.Repeat("x\n", 8) // 8 rows
	out := FrameScreen(20, 11, "T", body, "BAR")
	lines := strings.Split(strings.TrimRight(out, "\n"), "\n")
	last := lines[len(lines)-1]
	if !strings.Contains(stripANSI(last), "BAR") {
		t.Errorf("bar is concatenated onto another row: %q", stripANSI(last))
	}
	if strings.Contains(stripANSI(last), "x") {
		t.Errorf("bar shares its row with body content: %q", stripANSI(last))
	}
}

func readKitSource(t *testing.T, name string) string {
	t.Helper()
	b, err := readFileLocal(name)
	if err != nil {
		t.Fatalf("read %s: %v", name, err)
	}
	return string(b)
}

func readFileLocal(name string) ([]byte, error) {
	return os.ReadFile(name)
}

// TestLayoutForLadderAlwaysFits is the end-to-end rule: for every window, the
// title it chooses, the height it budgets and the height it draws agree, and
// title+bar+body fill the window without spilling. This is the test that would
// have caught the +4 / +2 / +17 row overflows.
func TestLayoutForLadderAlwaysFits(t *testing.T) {
	for _, ladder := range []TitleLadder{MosquitOmarchyTitleLadder(), MosquitoTitleLadder()} {
		for h := 6; h <= 60; h++ {
			for w := 40; w <= 200; w++ {
				l := LayoutForLadder(w, h, ladder)
				title := l.RenderLadder(w, ladder)

				if lipgloss.Height(title) != l.TitleRows {
					t.Fatalf("%dx%d: drew a %d-row title but budgeted %d",
						w, h, lipgloss.Height(title), l.TitleRows)
				}
				if gap := h - l.TitleRows - l.BarRows; l.BodyRows() > gap {
					t.Fatalf("%dx%d: BodyRows=%d exceeds the gap %d", w, h, l.BodyRows(), gap)
				}
				// No line of the title may be wider than the window.
				for i, line := range strings.Split(title, "\n") {
					if lw := lipgloss.Width(line); lw > w {
						t.Fatalf("%dx%d: title line %d is %d wide", w, h, i, lw)
					}
				}
				// And the composed screen must fit the window exactly.
				body := strings.Repeat("row\n", l.BodyRows())
				out := FrameScreen(w, h, title, body, "hint")
				if got := lipgloss.Height(out); got > h {
					t.Fatalf("%dx%d: screen is %d rows", w, h, got)
				}
			}
		}
	}
}
