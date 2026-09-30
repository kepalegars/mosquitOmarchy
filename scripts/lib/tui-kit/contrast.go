package tuikit

import (
	"math"
	"strconv"
	"strings"

	"github.com/charmbracelet/lipgloss"
	"github.com/lucasb-eyer/go-colorful"
)

// BestContrastOn returns the text color — black or white — that reads best on
// top of bg.
//
// The app paints selected rows and confirmation choices on the theme's accent
// fill, and that accent comes from whichever Omarchy theme is active. A hardcoded
// choice cannot work: the same code is unreadable on a light theme (dark text on
// pale yellow) and glaring on a dark one. So the choice is computed from the
// fill's own luminance, using the WCAG contrast ratio, and whichever of black or
// white scores higher wins.
//
// Ties, and anything that cannot be resolved to RGB, fall back to white: on a
// terminal the background is almost always darker than the text.
func BestContrastOn(bg lipgloss.Color) lipgloss.Color {
	r, g, b, ok := colorRGB(bg)
	if !ok {
		return lipgloss.Color("15") // bright white
	}
	whiteContrast := contrastRatio(r, g, b, 1, 1, 1)
	blackContrast := contrastRatio(r, g, b, 0, 0, 0)
	if blackContrast > whiteContrast {
		return lipgloss.Color("0") // true black, ANSI 0
	}
	return lipgloss.Color("15")
}

// contrastRatio is the WCAG 2.1 ratio between two sRGB colors, in [1,21].
// 1 means indistinguishable, 21 means maximum contrast.
func contrastRatio(r1, g1, b1, r2, g2, b2 float64) float64 {
	l1 := relativeLuminance(r1, g1, b1)
	l2 := relativeLuminance(r2, g2, b2)
	if l1 < l2 {
		l1, l2 = l2, l1
	}
	return (l1 + 0.05) / (l2 + 0.05)
}

// relativeLuminance is the WCAG definition: channels are linearised first, then
// weighted by how much the eye notices them. The sRGB gamma curve is why this is
// not a plain average — a mid-grey has to be linearised or dark accents look
// lighter than they are and the text choice comes out backwards.
func relativeLuminance(r, g, b float64) float64 {
	lin := func(c float64) float64 {
		if c <= 0.03928 {
			return c / 12.92
		}
		return math.Pow((c+0.055)/1.055, 2.4)
	}
	return 0.2126*lin(r) + 0.7152*lin(g) + 0.0722*lin(b)
}

// colorRGB resolves a lipgloss colour spec to sRGB in [0,1]. It understands the
// three forms the app actually uses: #rrggbb / #rgb hex, the "#rrggbbaa" alpha
// form, and a bare ANSI palette index ("212", "0".."255").
func colorRGB(c lipgloss.Color) (r, g, b float64, ok bool) {
	s := strings.TrimSpace(string(c))
	if s == "" {
		return 0, 0, 0, false
	}
	if strings.HasPrefix(s, "#") {
		// colorful.Hex wants the leading '#' kept (it dispatches on the 7/9
		// character "#rrggbb"/"#rrggbbaa" forms), so hand it s untouched.
		col, err := colorful.Hex(s)
		if err != nil {
			return 0, 0, 0, false
		}
		r, g, b = col.R, col.G, col.B
		return r, g, b, true
	}
	n, err := strconv.Atoi(s)
	if err != nil {
		return 0, 0, 0, false
	}
	cr, cg, cb, ok := ansi256RGB(n)
	return cr, cg, cb, ok
}

// ansi256RGB maps an xterm-256 palette index to sRGB in [0,1]: 0-15 are the
// sixteen theme colours (approximated by the standard cube/greyscale values),
// 16-231 are the 6x6x6 colour cube, 232-255 the 24-step greyscale ramp.
func ansi256RGB(n int) (r, g, b float64, ok bool) {
	base := [16][3]float64{
		{0, 0, 0}, {128, 0, 0}, {0, 128, 0}, {128, 128, 0},
		{0, 0, 128}, {128, 0, 128}, {0, 128, 128}, {192, 192, 192},
		{128, 128, 128}, {255, 0, 0}, {0, 255, 0}, {255, 255, 0},
		{0, 0, 255}, {255, 0, 255}, {0, 255, 255}, {255, 255, 255},
	}
	switch {
	case n < 0 || n > 255:
		return 0, 0, 0, false
	case n < 16:
		p := base[n]
		return p[0] / 255, p[1] / 255, p[2] / 255, true
	case n < 232:
		n -= 16
		steps := []float64{0, 95, 135, 175, 215, 255}
		return steps[n/36] / 255, steps[(n/6)%6] / 255, steps[n%6] / 255, true
	default:
		v := float64(8+(n-232)*10) / 255
		return v, v, v, true
	}
}
