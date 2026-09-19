// Package tuikit provides the shared Bubble Tea components used by both
// mosquito-move-manager-tui and mosquito-audio-plugin-manager-tui: a list picker, a
// confirm dialog, a text input, a transient toast, and a runner for
// streaming long external commands. Every component follows one shared key
// convention -- ctrl+c and esc always mean "cancel/back", handled by
// returning a Msg the host model interprets, never a special case that
// could leave a second render pass behind.
package tuikit

import (
	"bufio"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

var (
	ColorAccent   lipgloss.Color
	ColorMuted    lipgloss.Color
	ColorDisabled lipgloss.Color
	ColorHeader   lipgloss.Color
	ColorOK       lipgloss.Color
	ColorWarn     lipgloss.Color
	ColorErr      lipgloss.Color
	ColorRed      lipgloss.Color
	ColorBorder   lipgloss.Color

	StyleHeader   lipgloss.Style
	StyleMuted    lipgloss.Style
	StyleDisabled lipgloss.Style
	StyleAccent   lipgloss.Style
	StyleOK       lipgloss.Style
	StyleWarn     lipgloss.Style
	StyleErr      lipgloss.Style
	StyleHelp     lipgloss.Style
	StyleModal    lipgloss.Style
	StyleFrame    lipgloss.Style
)

func init() {
	applyPalette(loadOmarchyPalette())
}

// omarchyThemeColorsPath is where Omarchy always symlinks the CURRENTLY
// active theme's colors, regardless of which theme is selected --
// confirmed present on this machine as
// ~/.local/state/omarchy/current/theme/colors.toml (mode/accent/selection/
// muted/backgrounds/foregrounds/16 ANSI names, flat quoted-string
// assignments). Re-read on every process start, so a theme switched
// between two launches of a TUI is picked up automatically -- this is not
// a live-reload of an already-running TUI (both TUIs here are short-lived,
// launched fresh each time, same as every other themed app on the system).
const omarchyThemeColorsPath = ".local/state/omarchy/current/theme/colors.toml"

// omarchyColorLine matches one "key = "value"" line of that file --
// deliberately not a real TOML parser, since this file's shape is a flat
// list of quoted string assignments with no nested tables.
var omarchyColorLine = regexp.MustCompile(`^([a-z_]+)\s*=\s*"([^"]*)"$`)

// loadOmarchyPalette reads the current Omarchy theme's colors. Returns nil
// when Omarchy isn't present, the theme file is missing, or nothing
// parses -- applyPalette then falls back to this package's own built-in
// defaults, so a non-Omarchy system (or Omarchy without an active theme
// symlink yet) renders exactly as before this change.
func loadOmarchyPalette() map[string]string {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil
	}
	f, err := os.Open(filepath.Join(home, omarchyThemeColorsPath))
	if err != nil {
		return nil
	}
	defer f.Close()
	out := map[string]string{}
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if m := omarchyColorLine.FindStringSubmatch(line); m != nil {
			out[m[1]] = m[2]
		}
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

// applyPalette sets every Color*/Style* var, preferring the Omarchy
// palette's keys and falling back to this package's own long-standing
// defaults (the original hardcoded ANSI-256 values) for anything missing
// -- p may be nil entirely (indexing a nil map is safe, always misses).
// Header text uses bright_foreground rather than accent, so it stays
// legible/distinct from the accent-colored selection highlight regardless
// of which single accent color a given Omarchy theme picks.
func applyPalette(p map[string]string) {
	pick := func(key, fallback string) lipgloss.Color {
		if v, ok := p[key]; ok && v != "" {
			return lipgloss.Color(v)
		}
		return lipgloss.Color(fallback)
	}
	ColorAccent = pick("accent", "212")
	ColorMuted = pick("muted", "240")
	ColorDisabled = pick("dark_foreground", "238")
	ColorHeader = pick("bright_foreground", "99")
	ColorOK = pick("green", "42")
	ColorWarn = pick("yellow", "214")
	// Errors render in the theme's warm orange rather than its pure red --
	// the same choice soundcloud2000 and Typeinc make: on a dark terminal a
	// neon red (e.g. this theme's "#ed1c24") is harsh and clashing, while a
	// warm amber-orange keeps full legibility and a composed palette. The
	// warning (yellow) and error (orange) tones stay ordered warm-soft.
	ColorErr = pick("orange", "167")
	// ColorRed is the theme's true red, kept separate from ColorErr (which is
	// the warm orange) for highlights that must read as unmistakably red --
	// e.g. the jamjamjam "recording" box around the wordmark.
	ColorRed = pick("red", "196")
	ColorBorder = pick("muted", "240")

	StyleHeader = lipgloss.NewStyle().Foreground(ColorHeader).Bold(true)
	StyleMuted = lipgloss.NewStyle().Foreground(ColorMuted)
	StyleDisabled = lipgloss.NewStyle().Foreground(ColorDisabled)
	StyleAccent = lipgloss.NewStyle().Foreground(ColorAccent).Bold(true)
	StyleOK = lipgloss.NewStyle().Foreground(ColorOK)
	StyleWarn = lipgloss.NewStyle().Foreground(ColorWarn)
	StyleErr = lipgloss.NewStyle().Foreground(ColorErr)
	StyleHelp = lipgloss.NewStyle().Foreground(ColorMuted)
	StyleModal = lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(ColorAccent).Padding(1, 2)
	StyleFrame = lipgloss.NewStyle().Padding(1, 2)
}

// ---------------------------------------------------------------------------
// Live theme following
//
// Every manager re-reads the ACTIVE Omarchy theme while it's running: a
// ThemeTickMsg arrives every themePollInterval, the host calls ApplyTheme(),
// and every package-level Color*/Style* var is re-stamped to the freshly
// loaded palette. Because all components render THROUGH those vars (or
// resolve accent colors at render time — see pickerDelegate.titleStyle),
// a theme switched while a TUI is open takes effect on the next frame
// without any restart. Hosts wire one case in Update:
//
//	case tuikit.ThemeTickMsg:
//	    tuikit.ApplyTheme()
//	    return m, tuikit.ThemeWatchCmd()
//
// and start the loop with tuikit.ThemeWatchCmd() returned from Init().
// ---------------------------------------------------------------------------

type ThemeTickMsg time.Time

const themePollInterval = 2 * time.Second

// ThemeWatchCmd schedules the next theme poll. Feed the ThemeTickMsg it
// produces into ApplyTheme() + ThemeWatchCmd() re-issue (see above).
func ThemeWatchCmd() tea.Cmd {
	return tea.Tick(themePollInterval, func(t time.Time) tea.Msg {
		return ThemeTickMsg(t)
	})
}

// ApplyTheme re-reads the active Omarchy palette and re-assigns every
// package-level Color*/Style* var. Safe to call repeatedly, cheap enough
// to call on every tick (a tiny toml scan every 2 s is nothing).
func ApplyTheme() {
	applyPalette(loadOmarchyPalette())
}
