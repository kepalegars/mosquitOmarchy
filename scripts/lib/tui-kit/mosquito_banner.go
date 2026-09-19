package tuikit

import (
	"strconv"
	"strings"

	"github.com/charmbracelet/lipgloss"
)

// mosquitoBoxArt is the shared "mosquito" wordmark rendered in the ANSI
// Shadow figlet font (patorjk.com's TAAG, f=ANSI Shadow) — the title font of
// every mosquito manager (move/audio/live/jamjamjam). It is a reference value
// other scripts and the banner depend on: do NOT change it. To regenerate:
//
//	python3 -c "import pyfiglet; print(pyfiglet.figlet_format('mosquito', font='ansi_shadow'))"
var mosquitoBoxArt = strings.Join([]string{
	"███╗   ███╗ ██████╗ ███████╗ ██████╗ ██╗   ██╗██╗████████╗ ██████╗ ",
	"████╗ ████║██╔═══██╗██╔════╝██╔═══██╗██║   ██║██║╚══██╔══╝██╔═══██╗",
	"██╔████╔██║██║   ██║███████╗██║   ██║██║   ██║██║   ██║   ██║   ██║",
	"██║╚██╔╝██║██║   ██║╚════██║██║▄▄ ██║██║   ██║██║   ██║   ██║   ██║",
	"██║ ╚═╝ ██║╚██████╔╝███████║╚██████╔╝╚██████╔╝██║   ██║   ╚██████╔╝",
	"╚═╝     ╚═╝ ╚═════╝ ╚══════╝ ╚══▀▀═╝  ╚═════╝ ╚═╝   ╚═╝    ╚═════╝ ",
}, "\n")

// mosquitOmarchyBoxArt is the full "mosquitomarchy" wordmark (the whole word
// on ONE line) used ONLY by the mosquitOmarchy setup TUI's banner. Generated
// with width=300 so figlet does not wrap it at its default 80 columns:
//
//	python3 -c "import pyfiglet; print(pyfiglet.figlet_format('mosquitomarchy', font='ansi_shadow', width=300))"
var mosquitOmarchyBoxArt = strings.Join([]string{
	`███╗   ███╗ ██████╗ ███████╗ ██████╗ ██╗   ██╗██╗████████╗ ██████╗ ███╗   ███╗ █████╗ ██████╗  ██████╗██╗  ██╗██╗   ██╗`,
	`████╗ ████║██╔═══██╗██╔════╝██╔═══██╗██║   ██║██║╚══██╔══╝██╔═══██╗████╗ ████║██╔══██╗██╔══██╗██╔════╝██║  ██║╚██╗ ██╔╝`,
	`██╔████╔██║██║   ██║███████╗██║   ██║██║   ██║██║   ██║   ██║   ██║██╔████╔██║███████║██████╔╝██║     ███████║ ╚████╔╝ `,
	`██║╚██╔╝██║██║   ██║╚════██║██║▄▄ ██║██║   ██║██║   ██║   ██║   ██║██║╚██╔╝██║██╔══██║██╔══██╗██║     ██╔══██║  ╚██╔╝  `,
	`██║ ╚═╝ ██║╚██████╔╝███████║╚██████╔╝╚██████╔╝██║   ██║   ╚██████╔╝██║ ╚═╝ ██║██║  ██║██║  ██║╚██████╗██║  ██║   ██║   `,
	`╚═╝     ╚═╝ ╚═════╝ ╚══════╝ ╚══▀▀═╝  ╚═════╝ ╚═╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝   ╚═╝   `,
}, "\n")

// subtitleArt maps the three module subtitles (e.g. "vst manager") to
// their Small-font figlet render — the SAME shadow-family as the boxed
// "mosquito" label above (so the whole title reads as one cohesive block)
// in the patorjk "Small" font (TAAG: f=Small, the compact outlined style
// the user picked). Subtitles that wouldn't fit the available panel width
// fall back to subtitleArtTiny (a one-line smaller variant), then to a
// plain accent one-liner so the subtitle is always legible and never
// clipped.
var subtitleArt = map[string]string{
	"audio plugin manager": strings.Join([]string{
		"              _ _            _           _                                          ",
		" __ _ _  _ __| (_)___   _ __| |_  _ __ _(_)_ _    _ __  __ _ _ _  __ _ __ _ ___ _ _ ",
		`/ _` + "`" + ` | || / _` + "`" + ` | / _ \ | '_ \ | || / _` + "`" + ` | | ' \  | '  \/ _` + "`" + ` | ' \/ _` + "`" + ` / _` + "`" + ` / -_) '_|`,
		`\__,_|\_,_\__,_|_\___/ | .__/_|\_,_\__, |_|_||_| |_|_|_\__,_|_||_\__,_\__, \___|_|  `,
		"                       |_|         |___/                              |___/         ",
	}, "\n"),
	"vst manager": strings.Join([]string{
		"        _                                       ",
		"__ ____| |_   _ __  __ _ _ _  __ _ __ _ ___ _ _ ",
		`\ V (_-<  _| | '  \/ _` + "`" + ` | ' \/ _` + "`" + ` / _` + "`" + ` / -_) '_|`,
		` \_//__/\__| |_|_|_\__,_|_||_\__,_\__, \___|_|  `,
		"                                  |___/         ",
	}, "\n"),
	"move manager": strings.Join([]string{
		"                                                       ",
		" _ __  _____ _____   _ __  __ _ _ _  __ _ __ _ ___ _ _ ",
		`| '  \/ _ \ V / -_) | '  \/ _` + "`" + ` | ' \/ _` + "`" + ` / _` + "`" + ` / -_) '_|`,
		"|_|_|_\\___/\\_/\\___| |_|_|_\\__,_|_||_\\__,_\\__, |\\___|_|  ",
		"                                         |___/         ",
	}, "\n"),
	"live mode manager": strings.Join([]string{
		" _ _                         _                                         ",
		"| (_)_ _____   _ __  ___  __| |___   _ __  __ _ _ _  __ _ __ _ ___ _ _ ",
		`| | \ V / -_) | '  \/ _ \/ _` + "`" + ` / -_) | '  \/ _` + "`" + ` | ' \/ _` + "`" + ` / _` + "`" + ` / -_) '_|`,
		"|_|_|\\_/\\___| |_|_|_\\___/\\__,_\\___| |_|_|_\\__,_|_||_\\__,_\\__, |\\___|_|  ",
		"                                                         |___/         ",
	}, "\n"),
	"jamjamjam": strings.Join([]string{
		"   _             _             _            ",
		"  (_)__ _ _ __  (_)__ _ _ __  (_)__ _ _ __  ",
		`  | / _` + "`" + ` | '  \ | / _` + "`" + ` | '  \ | / _` + "`" + ` | '  \ `,
		" _/ \\__,_|_|_|_|/ \\__,_|_|_|_|/ \\__,_|_|_|_|",
		"|__/          |__/          |__/             ",
	}, "\n"),
	"marchy": strings.Join([]string{
		"                   _        ",
		" _ __  __ _ _ _ __| |_ _  _ ",
		`| '  \/ _` + "`" + ` | '_/ _| ' \ || |`,
		"|_|_|_\\__,_|_| \\__|_||_\\_, |",
		"                       |__/ ",
	}, "\n"),
	"setup": strings.Join([]string{
		`         _             `,
		` ___ ___| |_ _  _ _ __ `,
		`(_-</ -_)  _| || | '_ \`,
		`/__/\___|\__|\_,_| .__/`,
		`                 |_|   `,
	}, "\n"),
}

// subtitleArtTiny is the final fallback for the subtitles when both the
// ansi_shadow (subtitleArt) and Small (subtitleArtSmall below) art would
// overflow the panel. Rendered in the smallest practical variant — a
// single one-line label — so the subtitle is never clipped even on
// extremely narrow terminals.
var subtitleArtTiny = map[string]string{
	"audio plugin manager": "a u d i o   p l u g i n   m a n a g e r",
	"vst manager":          "v s t   m a n a g e r",
	"move manager":         "m o v e   m a n a g e r",
	"live mode manager":    "l i v e   m o d e   m a n a g e r",
	"jamjamjam":            "j a m j a m j a m",
	"marchy":               "m a r c h y",
	"setup":                "s e t u p",
}

// accentForeground returns "white" when the current accent is dark and
// "black" when it is light, so the boxed "mosquito" label always has the
// strongest possible contrast. ColorAccent is a lipgloss.Color parsed from
// the active Omarchy theme (init() in theme.go).
func accentForeground() lipgloss.Color {
	c := string(ColorAccent)
	r, g, b, ok := parseHexColor(c)
	if !ok {
		return lipgloss.Color("#ffffff")
	}
	// Relative luminance (BT.601 weights — good enough for picking
	// black/white text against a solid background).
	lum := 0.299*float64(r) + 0.587*float64(g) + 0.114*float64(b)
	if lum < 128 {
		return lipgloss.Color("#ffffff")
	}
	return lipgloss.Color("#000000")
}

// parseHexColor accepts #RGB, #RRGGBB, or 0xRRGGBB and returns (r,g,b,ok).
func parseHexColor(s string) (int, int, int, bool) {
	s = strings.TrimSpace(s)
	if strings.HasPrefix(s, "#") {
		s = s[1:]
	} else if strings.HasPrefix(strings.ToLower(s), "0x") {
		s = s[2:]
	}
	switch len(s) {
	case 3:
		v, err1 := strconv.ParseUint(s, 16, 64)
		if err1 != nil {
			return 0, 0, 0, false
		}
		return int((v>>8)&0xF) * 17, int((v>>4)&0xF) * 17, int(v&0xF) * 17, true
	case 6:
		v, err1 := strconv.ParseUint(s, 16, 64)
		if err1 != nil {
			return 0, 0, 0, false
		}
		return int((v >> 16) & 0xFF), int((v >> 8) & 0xFF), int(v & 0xFF), true
	}
	return 0, 0, 0, false
}

// BoxedMosquito renders the "mosquito" label in the active theme's accent
// color. The label text is black or white depending on what gives the
// strongest contrast against the accent background (so the same banner
// reads correctly on a dark accent AND a light accent theme). A solid
// accent-colored strip is added above and below the art so the framed
// title block reads as a clear, slightly taller visual anchor at the top
// of every manager. The strip width matches the rendered art's total width
// (art + horizontal padding) so the framing is a clean rectangle.
//
// The box ends with a single trailing newline (so callers can append the
// subtitle directly below the bottom strip with no blank gap between
// them — universal layout rule: title and subtitle read as one block).
func BoxedMosquito() string {
	return boxedArt(mosquitoBoxArt)
}

// BoxedMosquitOmarchy renders the full "mosquitomarchy" wordmark box — a NEW
// value reserved for the mosquitOmarchy setup TUI. Every other manager keeps
// the shared BoxedMosquito() ("mosquito") unchanged.
func BoxedMosquitOmarchy() string {
	return boxedArt(mosquitOmarchyBoxArt)
}

func boxedArt(wordArt string) string {
	fg := accentForeground()
	artLines := strings.Split(wordArt, "\n")
	artW := 0
	for _, l := range artLines {
		if w := lipgloss.Width(l); w > artW {
			artW = w
		}
	}
	// Total rendered width of the framed art, accounting for the 1-space
	// horizontal padding on each side.
	frameW := artW + 2
	strip := strings.Repeat(" ", frameW)
	stripStyle := lipgloss.NewStyle().Bold(true).Foreground(fg).Background(ColorAccent)
	stripLine := stripStyle.Render(strip) + "\n"
	art := lipgloss.NewStyle().
		Bold(true).
		Foreground(fg).
		Background(ColorAccent).
		Padding(0, 1).
		Render(wordArt)
	// Top strip + art + bottom strip, no extra trailing blank. Callers
	// that want a blank gap append "\n" themselves (header() does this so
	// the subtitle still has visual breathing room).
	return stripLine + art + "\n" + stripLine
}

// MosquitoSubtitle renders the module subtitle ("vst manager",
// "move manager", "live mode manager") below the boxed "mosquito" label.
// The subtitle tries the "Small" figlet font (patorjk TAAG: f=Small,
// same shadow family as the boxed mosquito label so the title reads as
// one cohesive block) first; if that art would overflow the available
// panel width it falls back to subtitleArtTiny (a one-line label, the
// smallest practical variant), then to a plain accent-color label so
// the subtitle is always legible and never clipped. maxWidth <= 0 skips
// the fit check (art is rendered as-is, callers control the width).
func MosquitoSubtitle(s string, maxW int) string {
	if art, ok := subtitleArt[s]; ok && (maxW <= 0 || artWidth(art) <= maxW) {
		return lipgloss.NewStyle().
			Bold(true).
			Foreground(ColorAccent).
			Render(art)
	}
	if art, ok := subtitleArtTiny[s]; ok && (maxW <= 0 || lipgloss.Width(art) <= maxW) {
		return lipgloss.NewStyle().
			Bold(true).
			Foreground(ColorAccent).
			Render(art)
	}
	return lipgloss.NewStyle().
		Bold(true).
		Foreground(ColorAccent).
		Render(s)
}

// artWidth returns the widest visible line of the given art, used to decide
// whether a small_shadow subtitle still fits the picker's content width.
func artWidth(art string) int {
	w := 0
	for _, l := range strings.Split(art, "\n") {
		if lw := lipgloss.Width(l); lw > w {
			w = lw
		}
	}
	return w
}

// padBlockLines pads every line of an art block to `w` columns so a host
// that centers per line renders the whole block centered (art lines usually
// have unequal natural widths — a figlet word, for instance).
func padBlockLines(block string, w int) string {
	lines := strings.Split(strings.TrimSuffix(block, "\n"), "\n")
	for i, l := range lines {
		if pad := w - lipgloss.Width(l); pad > 0 {
			lines[i] = l + strings.Repeat(" ", pad)
		}
	}
	return strings.Join(lines, "\n")
}

// MosquitoStackedHeader is the stacked-header rule every mosquito TUI uses
// for a boxed SHORT label ("mosquito") plus its own subtitle: the subtitle
// is padded to its own width so the host's per-line centering centers the
// box as ONE block and the subtitle as ONE block — coherent margins at
// every window size, exactly like MosquitOmarchyTitle. No side-by-side
// variant: it could never center coherently.
func MosquitoStackedHeader(box, subText string, maxW int) string {
	sub := MosquitoSubtitle(subText, maxW)
	return box + padBlockLines(sub, artWidth(sub))
}

// MosquitOmarchyTitle renders the mosquitOmarchy banner: the boxed
// "mosquitomarchy" wordmark (ANSI Shadow, the whole word on one line) with
// the "setup" subtitle centered UNDER it. The layout is ALWAYS stacked — a
// side-by-side variant existed for very wide panels but its composed block
// could never be centered coherently (unequal line widths made the host's
// per-line centering drift), so it is gone: the wordmark + subtitle keep
// their relative layout at EVERY window size, centered with coherent
// margins.
func MosquitOmarchyTitle(maxW int) string {
	box := BoxedMosquitOmarchy()
	sub := MosquitoSubtitle("setup", maxW)
	subW := artWidth(sub)
	// Stacked: the boxed wordmark first, the subtitle centered UNDER it.
	// Each block is padded to its own width first, so the host's per-line
	// centering centers the box as ONE block and the subtitle as ONE
	// block — coherent margins, no per-row drift.
	return box + padBlockLines(sub, subW)
}
