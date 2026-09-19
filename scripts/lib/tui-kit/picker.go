package tuikit

import (
	"fmt"
	"io"
	"strings"

	"github.com/charmbracelet/bubbles/key"
	"github.com/charmbracelet/bubbles/list"
	tea "github.com/charmbracelet/bubbletea"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

// PickerResultMsg is sent when the user makes a choice or cancels — the
// replacement for ui_select's "echo the chosen value, 0/1/2/3 exit code"
// bash contract. A host model's Update() type-switches on this.
type PickerResultMsg struct {
	Value    string
	Canceled bool
}

// PickerToggleMsg is sent on Tab — a distinct, non-destructive "mark this
// row" action alongside Enter's "act on it now", for screens that need
// multi-select (batch uninstall, or checking/unchecking rows before an
// explicit save). The host owns the actual checked-state and Display
// string (e.g. a leading ✓/○), same convention as the existing manual
// toggle-list screens (execItemsToPicker) — Picker itself stays state-free.
type PickerToggleMsg struct{ Value string }

// PickerActionMsg is the reserved single-key shortcut channel (the kit
// emits it with Key "x"; the host decides what "x" means per screen —
// the audio manager's plugin list uses it to flip the plugin window
// handler classic ⇄ hyprland).
type PickerActionMsg struct{ Key string }

// PickerSortMsg is sent on Left/Right — cycle the active sort live without
// leaving the list (btop's own column-cycle convention). Dir is -1 (left)
// or +1 (right); the host owns what "sort mode" even means and rebuilds
// the item list in response.
type PickerSortMsg struct{ Dir int }

// PickerItem is one option — the Go equivalent of ui_select's
// "display<TAB>value" pairs, minus the ad-hoc tab-encoding.
type PickerItem struct {
	Display  string
	Sub      string // optional grey subtext line, e.g. the native overlay's value hint
	Value    string
	Disabled bool // rendered greyed out, skipped by navigation, inert on enter
	// Badge is an optional short marker (a single glyph like "●") rendered
	// in the theme accent on a fixed leading slot, for a row that needs a
	// state cue the plain Display can't carry. When ANY row in a picker
	// sets Badge, every row reserves the same slot, so the shared text
	// column stays aligned. Leading badges are reserved for compact state
	// marks (e.g. the ○/● checkbox); a badge that should read as a suffix
	// to the row's own label belongs in TrailingBadge instead.
	Badge string
	// TrailingBadge is an optional short marker rendered in the theme accent
	// at the END of the row's title ("name  ■") rather than in the leading
	// slot. It is for markers the user explicitly wants after the label
	// (e.g. "this plugin already has an applied fix"), so a row's own text
	// stays in the leading column. When ANY row sets it, every row reserves
	// the same trailing width so the shared column stays aligned.
	TrailingBadge string
	// Accent renders the row's TITLE in a solid theme-accent block even when
	// it is not the focused row — for a row the host wants to stand out (e.g.
	// the "mosquito" setup category). Hosts can toggle it on a timer to make
	// the row blink. Purely additive: untouched rows render exactly as
	// before. Only Display is accented; Suffix is rendered in the ordinary
	// row style, so a trailing count does not blink with it.
	Accent bool
	// Suffix is optional text appended right after the title in the row's
	// ordinary style (not the Accent block), e.g. a "  (6)" count that must
	// stay in the normal colour next to an accented title.
	Suffix string
}

// trailingBadgeGap is the number of spaces placed between a row's title and
// its TrailingBadge, so the marker reads as a suffix ("name  ■") rather than
// as part of the label.
const trailingBadgeGap = 2

// terminalPickerValues are the picker Values that mean "leave this screen":
// the universal navigation/exit rows every TUI shares. Such rows are drawn
// inside an accent-filled box so "the way out" is always visually obvious,
// regardless of which manager's screen they sit on.
var terminalPickerValues = map[string]bool{
	"quit":   true,
	"close":  true,
	"back":   true,
	"return": true,
	"menu":   true,
	"main":   true,
	"cancel": true,
}

// terminalBoxPad is the number of columns a terminal row's accent box adds
// to its label (Padding(0,1) — one column on each side). It is folded into
// the row-width math so a boxed terminal row can never break the shared
// maxRowW column alignment.
const terminalBoxPad = 2

// isTerminalValue reports whether a picker Value is one of the universal
// terminal/exit rows (case-insensitive, whitespace-tolerant).
func isTerminalValue(v string) bool {
	return terminalPickerValues[strings.ToLower(strings.TrimSpace(v))]
}

// terminalRowStyle renders a terminal row's label inside a solid box filled
// with the theme accent. The text colour is the strongest-contrast
// black/white against that accent — exactly the rule the boxed mosquito
// banner uses (accentForeground) — so the box stays readable on both dark
// and light accent themes. When SELECTED the colours INVERT (box takes the
// text colour, label takes the accent) so the focused exit row is obvious.
// disabled drops the bold weight so an inert terminal row still reads as
// inert while keeping the box shape.
func terminalRowStyle(disabled, selected bool) lipgloss.Style {
	bg, fg := ColorAccent, accentForeground()
	if selected {
		bg, fg = fg, bg
	}
	s := lipgloss.NewStyle().
		Background(bg).
		Foreground(fg).
		Padding(0, 1)
	if disabled {
		return s.Bold(false)
	}
	return s.Bold(true)
}

func (i PickerItem) Title() string       { return i.Display }
func (i PickerItem) Description() string { return i.Sub }
func (i PickerItem) FilterValue() string { return i.Display }

// pickerDelegate renders PickerItems, greyed out and never selected-highlighted
// when Disabled is set, and otherwise exactly like list.DefaultDelegate.
type pickerDelegate struct {
	list.DefaultDelegate
	// maxRowW is the widest visible row across every item in the picker
	// that owns this delegate (indicator + space + max(title,sub)). Set
	// once in NewPicker so renderCentered can pad every shorter row to
	// this width before centering — keeps every item's visual centre on
	// the same column instead of stair-stepping left/right with each
	// item's natural width.
	maxRowW int
	// badgeSlot is the fixed leading column width reserved for an item's
	// Badge (0 when no item in the picker sets one). It is part of every
	// row's composed width so badged and unbadged rows keep the same text
	// column.
	badgeSlot int
	// trailSlot is the fixed trailing column width reserved for an item's
	// TrailingBadge (0 when no item in the picker sets one). It is folded
	// into every row's maxRowW so a trailing badge can never overflow the
	// shared, centered row block.
	trailSlot int
}

// badgeCell renders a row's badge on its fixed leading slot: the accent
// glyph followed by enough spaces to fill badgeSlot, or plain spaces when
// the row has no badge. Returns "" when the picker reserved no slot.
func (d pickerDelegate) badgeCell(pi PickerItem) string {
	if d.badgeSlot <= 0 {
		return ""
	}
	if pi.Badge == "" {
		return strings.Repeat(" ", d.badgeSlot)
	}
	badge := ansi.Truncate(pi.Badge, d.badgeSlot, "")
	pad := d.badgeSlot - lipgloss.Width(badge)
	if pad < 0 {
		pad = 0
	}
	return StyleAccent.Render(badge) + strings.Repeat(" ", pad)
}

// trailingCell renders a row's TrailingBadge: two spaces then the accent
// glyph, appended AFTER the title so it reads as a suffix ("name  ■"). It is
// never a leading slot — the title keeps its normal column. Returns "" when
// the picker reserved no trailing slot or the row has no badge.
func (d pickerDelegate) trailingCell(pi PickerItem) string {
	if d.trailSlot <= 0 || pi.TrailingBadge == "" {
		return ""
	}
	return strings.Repeat(" ", trailingBadgeGap) + StyleAccent.Render(pi.TrailingBadge)
}

// titleStyleFor picks the terminal accent box for an exit row and the
// ordinary per-row title style otherwise, so the box treatment applies in
// both the normal and the disabled renderer.
func (d pickerDelegate) titleStyleFor(pi PickerItem, index, selected int) lipgloss.Style {
	if isTerminalValue(pi.Value) {
		return terminalRowStyle(false, index == selected)
	}
	if pi.Accent {
		// A solid accent block, applied regardless of focus, so a host can
		// blink the row (toggle Accent on a timer) and the blink is visible
		// even when the cursor sits on it.
		return lipgloss.NewStyle().Padding(0).
			Background(ColorAccent).
			Foreground(accentForeground()).
			Bold(true)
	}
	return d.titleStyle(index, selected)
}

func (d pickerDelegate) Render(w io.Writer, m list.Model, index int, item list.Item) {
	pi, ok := item.(PickerItem)
	if ok && pi.Disabled {
		d.renderDisabled(w, m, pi)
		return
	}
	d.renderCentered(w, m, index, item)
}

// renderCentered renders one picker row with the text perfectly centered
// horizontally in the list's full width. The selection indicator ("▶ ")
// sits immediately to the left of the text and moves with the text — the
// whole row (indicator + text) is rendered as one line and then centered
// in the row width, so short and long options read as one aligned column
// and nothing is ever left-aligned. The DefaultDelegate's left-border
// highlight is stripped (see titleStyle) so the centered text doesn't get a
// stray "│" next to the cursor.
func (d pickerDelegate) renderCentered(w io.Writer, m list.Model, index int, item list.Item) {
	if m.Width() <= 0 {
		return
	}
	pi, _ := item.(PickerItem)
	desc := pi.Sub

	textWidth := m.Width()
	if textWidth <= 0 {
		textWidth = 1
	}
	avail := textWidth
	if isTerminalValue(pi.Value) {
		avail -= terminalBoxPad
		if avail < 1 {
			avail = 1
		}
	}
	suffixW := lipgloss.Width(pi.Suffix)
	titleAvail := avail - suffixW
	if titleAvail < 1 {
		titleAvail = 1
	}
	title := ansi.Truncate(pi.Display, titleAvail, "…")
	suffix := ""
	if pi.Suffix != "" {
		// The suffix keeps the row's ordinary style even when the title is an
		// Accent block, so only the title blinks.
		suffix = d.titleStyle(index, m.Index()).Render(pi.Suffix)
	}
	titleStyled := d.badgeCell(pi) + d.titleStyleFor(pi, index, m.Index()).Render(title) + suffix + d.trailingCell(pi)
	// Fixed 3-column slot before the title: three spaces when unselected,
	// one space + "▶ " (styled) when selected — *exactly* three visible
	// columns in both cases, so the title always starts on the same
	// offset and the ▶ glyph's East-Asian-Ambiguous width quirk can't
	// shift anything for either row of a pair.
	indicator := "   "
	if index == m.Index() {
		indicator = " " + lipgloss.NewStyle().Foreground(ColorAccent).Bold(true).Render("▶ ")
	}
	// Compose the row (3-col indicator slot + styled title), then snap
	// every row to the uniform width right-padded inside a
	// Width(maxRowW) block, and center that block in the list width:
	// every occupied column is identical across rows — one shared
	// text column, no stair-stepping, never left-anchored.
	row := indicator + titleStyled
	if d.ShowDescription && desc != "" {
		descAvail := avail - d.badgeSlot
		if descAvail < 1 {
			descAvail = 1
		}
		desc = ansi.Truncate(desc, descAvail, "…")
		descStyled := d.descStyle(index, m.Index()).Render(desc)
		row += "\n" + indicator + d.badgeCell(pi) + descStyled
	}
	if d.maxRowW > 0 {
		row = lipgloss.NewStyle().Width(d.maxRowW).Align(lipgloss.Left).Render(row)
	}
	fmt.Fprint(w, lipgloss.NewStyle().Width(m.Width()).Align(lipgloss.Center).Render(row)) //nolint: errcheck
}

// titleStyle builds the per-row title style AT RENDER TIME so the colors
// always come from the live theme vars (ApplyTheme recolors open pickers
// on the next frame). The bubbles SelectedTitle's left border is NOT
// inherited — this picker draws its own "▶ " indicator in a fixed left
// slot, so a border would only add a stray "│".
func (d pickerDelegate) titleStyle(index, selected int) lipgloss.Style {
	if index == selected {
		return lipgloss.NewStyle().Padding(0).Foreground(ColorAccent).Bold(true)
	}
	return lipgloss.NewStyle().Padding(0).Foreground(lipgloss.AdaptiveColor{
		Light: "#1a1a1a", Dark: "#dddddd",
	})
}

func (d pickerDelegate) descStyle(index, selected int) lipgloss.Style {
	if index == selected {
		return lipgloss.NewStyle().Padding(0).Foreground(ColorAccent)
	}
	return lipgloss.NewStyle().Padding(0).Foreground(lipgloss.AdaptiveColor{
		Light: "#A49FA5", Dark: "#777777",
	})
}

func (d pickerDelegate) renderDisabled(w io.Writer, m list.Model, pi PickerItem) {
	if m.Width() <= 0 {
		return
	}
	textWidth := m.Width()
	if textWidth <= 0 {
		textWidth = 1
	}
	// Compose disabled rows EXACTLY like renderCentered (same fixed 3-col
	// indicator slot, same badge slot, same maxRowW padding, same
	// full-width centering) so a greyed row shares the same visual column
	// as the enabled ones — the previous width-based centering put disabled
	// rows on a different column (the user's "Schwung / Move as Bitwig
	// controller aren't aligned like the other options").
	avail := textWidth
	if isTerminalValue(pi.Value) {
		avail -= terminalBoxPad
		if avail < 1 {
			avail = 1
		}
	}
	title := ansi.Truncate(pi.Display, avail, "…")
	var titleStyled string
	if isTerminalValue(pi.Value) {
		// A terminal row keeps its accent box even while disabled: the box
		// is what marks it as the way out, and the disabled cue is carried
		// by the dropped bold weight (see terminalRowStyle).
		titleStyled = terminalRowStyle(true, false).Render(title)
	} else {
		titleStyled = StyleDisabled.Render(title)
	}
	row := "   " + d.badgeCell(pi) + titleStyled + d.trailingCell(pi)
	if d.ShowDescription && pi.Sub != "" {
		descAvail := avail - d.badgeSlot
		if descAvail < 1 {
			descAvail = 1
		}
		desc := ansi.Truncate(pi.Sub, descAvail, "…")
		row += "\n" + "   " + d.badgeCell(pi) + StyleDisabled.Render(desc)
	}
	if d.maxRowW > 0 {
		row = lipgloss.NewStyle().Width(d.maxRowW).Align(lipgloss.Left).Render(row)
	}
	fmt.Fprint(w, lipgloss.NewStyle().Width(m.Width()).Align(lipgloss.Center).Render(row)) //nolint: errcheck
}

// newPickerDelegate builds a fresh delegate at call time (inside NewPicker,
// never as a package-level var).
//
// The base bubbles item styles originally baked the accent/selection colors
// in at NewPicker time — which broke live theme following: once a TUI was
// running, an Omarchy theme switch never reached rows that the picker had
// already styled. Accent (and selection bolding) is now applied AT RENDER
// TIME in titleStyle/descStyle from the live package vars, so ApplyTheme()
// recolors every open picker on the next frame. Both NormalTitle's
// built-in `Padding(0,0,0,2)` and SelectedTitle's `Padding(0,0,0,1)` are
// bypassed entirely: the delegate builds styles from scratch instead of
// inheriting them, so the centering math in renderCentered operates on the
// actual title text only.
func newPickerDelegate(maxRowW, badgeSlot, trailSlot int) pickerDelegate {
	d := list.NewDefaultDelegate()
	return pickerDelegate{DefaultDelegate: d, maxRowW: maxRowW, badgeSlot: badgeSlot, trailSlot: trailSlot}
}

// Picker wraps bubbles/list as a full-screen option picker.
type Picker struct {
	list     list.Model
	ready    bool
	helpOpen bool
	// extraHints are the human-readable hint strings of any custom keys
	// registered through SetHelpKeys, kept here so ShortcutsHint() can
	// produce a single-line "↑/k up · ↓/j down · enter select · esc back ·
	// ? more · tab select · ←/→ sort" string without re-implementing
	// bubbles' help renderer.
	extraHints []string
}

func NewPicker(header string, items []PickerItem) Picker {
	litems := make([]list.Item, len(items))
	hasSub := false
	maxRowW := 0
	// Reserve one fixed leading slot for badges when any row sets one, so a
	// badged row and an unbadged row still share the same title column.
	badgeSlot := 0
	trailSlot := 0
	for _, it := range items {
		if it.Badge != "" {
			if bw := lipgloss.Width(it.Badge) + 1; bw > badgeSlot {
				badgeSlot = bw
			}
		}
		if it.TrailingBadge != "" {
			if tw := lipgloss.Width(it.TrailingBadge) + trailingBadgeGap; tw > trailSlot {
				trailSlot = tw
			}
		}
	}
	for _, it := range items {
		if it.Sub != "" {
			hasSub = true
		}
		// Measure through lipgloss.Width on the EXACT composition the
		// delegate draws ("  " indicator slot + single space + text),
		// not through a separate width function — the ▶ glyph is
		// East-Asian-Ambiguous and ansi.StringWidth/lipgloss.Width can
		// disagree by one column on it, which left the row blocks
		// different widths and the shared column misaligned. +2 keeps
		// one spare column so no composed row can ever exceed the
		// uniform width. The badge slot and (for an exit row) the accent
		// box padding are part of what the delegate actually draws.
		w := lipgloss.Width("  "+" "+it.Display) + 1 + badgeSlot + trailSlot + lipgloss.Width(it.Suffix)
		if isTerminalValue(it.Value) {
			w += terminalBoxPad
		}
		if it.Sub != "" {
			if ws := lipgloss.Width("  "+" "+it.Sub) + 1 + badgeSlot + trailSlot; ws > w {
				w = ws
			}
		}
		if w > maxRowW {
			maxRowW = w
		}
	}
	delegate := newPickerDelegate(maxRowW, badgeSlot, trailSlot)
	if !hasSub {
		delegate.ShowDescription = false
		delegate.SetHeight(1)
		// With descriptions hidden the delegate renders one row per item;
		// kill the built-in inter-item spacer so a compact picker shows all
		// its options contiguously (spacing=1 otherwise reserves two rows per
		// item → only half the list fits → bogus pagination dots + blank
		// rows between options).
		delegate.SetSpacing(0)
	}
	for i, it := range items {
		litems[i] = it
	}
	l := list.New(litems, delegate, 0, 0)
	l.Title = header
	l.Styles.Title = StyleHeader
	// The bubbles title row is NEVER rendered: every screen's label is
	// owned by the universal layout's accent title (screenTitle), so a
	// header string like "Settings" would print TWICE — once colored in
	// the title bar and once inside the picker frame (the user's report:
	// "dans les sous menus tu as mis deux fois les titres").
	l.SetShowTitle(false)
	l.SetShowStatusBar(false)
	l.SetFilteringEnabled(false)
	// Disable bubbles' built-in help line: hosts render the shortcut hint
	// separately (the universal layout pins it to the bottom of the screen,
	// not in the centred body).
	l.SetShowHelp(false)
	p := Picker{list: l, ready: true}
	p = p.clampDisabled(1)
	return p
}

func (p Picker) SetSize(w, h int) Picker {
	if !p.ready {
		// A zero Picker has no delegate; resizing one would nil-deref inside
		// bubbles' updatePagination and crash the whole TUI on the first
		// WindowSizeMsg (see live-mode's launch bug). Treat it as inert.
		return p
	}
	// bubbles' updatePagination() computes the new PerPage from the
	// PREVIOUS page count's pagination-view height (it subtracts the
	// current pagination dots, then sets TotalPages). That leaves TWO
	// self-consistent fixed points for the same (w,h) depending on the
	// picker's history: a fresh list starts with TotalPages=9 (built at
	// height 0) and gets stuck reserving two pagination rows, while a list
	// last laid out tall — all rows on one page, TotalPages=1, no dots
	// reserved — converges the other way. The boxed exit row then flickers
	// in for one frame on a pop and vanishes on the next rebuild. Seed
	// TotalPages=1 so the first pass measures with no pagination row, then
	// iterate until PerPage/TotalPages stabilize: the result depends only
	// on (w,h) and the item count, never on the previous size.
	p.list.Paginator.TotalPages = 1
	for i := 0; i < 4; i++ {
		perPage, total := p.list.Paginator.PerPage, p.list.Paginator.TotalPages
		p.list.SetSize(w, h)
		if p.list.Paginator.PerPage == perPage && p.list.Paginator.TotalPages == total {
			break
		}
	}
	return p
}

// SetHelpKeys adds extra shortcut hints to the picker's own help bar
// (alongside the built-in up/down/quit/?), for a screen-specific key like
// Tab or Left/Right whose meaning the host owns (see PickerToggleMsg/
// PickerSortMsg) -- purely cosmetic, every shortcut belongs in the help bar
// rather than hand-written into a header/title string.
//
// SetHelpKeys also accumulates the additional keys' human-readable hints
// into a single line returned by ShortcutsHint() — hosts render this at
// the bottom of the screen (the universal layout pins it to the very last
// row, not in the centred body), so every screen's shortcut bar is
// identical for every picker that didn't add custom keys.
func (p Picker) SetHelpKeys(keys ...key.Binding) Picker {
	p.list.AdditionalShortHelpKeys = func() []key.Binding { return keys }
	p.list.AdditionalFullHelpKeys = func() []key.Binding { return keys }
	p.extraHints = nil
	for _, k := range keys {
		if h := k.Help(); h.Key != "" {
			p.extraHints = append(p.extraHints, h.Key+" "+h.Desc)
		}
	}
	return p
}

// ShortcutsHint returns the canonical single-line shortcut bar for this
// picker: the four built-in keys ("↑/k up · ↓/j down · enter select · esc
// back · ? more") plus, on the right, any custom hints registered through
// SetHelpKeys ("tab select", "←/→ sort", …). Style with StyleHelp.Render
// to render it. Empty for a zero Picker.
func (p Picker) ShortcutsHint() string {
	if !p.ready {
		return ""
	}
	// When the host registered its own "enter …" hint, drop the generic
	// "enter select" so the bar doesn't advertise two meanings for enter.
	hasEnterHint := false
	for _, h := range p.extraHints {
		if strings.HasPrefix(h, "enter ") {
			hasEnterHint = true
			break
		}
	}
	base := "↑/k up · ↓/j down · esc back · ? help"
	if !hasEnterHint {
		base = "↑/k up · ↓/j down · enter select · esc back · ? help"
	}
	if len(p.extraHints) == 0 {
		return StyleHelp.Render(base)
	}
	parts := append([]string{base}, p.extraHints...)
	return StyleHelp.Render(strings.Join(parts, " · "))
}

func (p Picker) Init() tea.Cmd { return nil }

func (p Picker) Update(msg tea.Msg) (Picker, tea.Cmd) {
	if !p.ready {
		return p, nil // zero Picker: inert (see SetSize)
	}
	switch m := msg.(type) {
	case tea.KeyMsg:
		switch {
		case key.Matches(m, key.NewBinding(key.WithKeys("ctrl+c", "esc"))):
			return p, func() tea.Msg { return PickerResultMsg{Canceled: true} }
		case key.Matches(m, key.NewBinding(key.WithKeys("enter"))):
			if it, ok := p.list.SelectedItem().(PickerItem); ok {
				if it.Disabled {
					return p, nil // inert: never choose an unavailable option
				}
				return p, func() tea.Msg { return PickerResultMsg{Value: it.Value} }
			}
			return p, nil
		case key.Matches(m, key.NewBinding(key.WithKeys("tab"))):
			if it, ok := p.list.SelectedItem().(PickerItem); ok {
				if it.Disabled {
					return p, nil
				}
				// Tab toggles the CURRENT item only — the cursor stays
				// exactly where it is (the user's rule: multi-selecting
				// with Tab must not move the selection; Down/Up navigate).
				return p, func() tea.Msg { return PickerToggleMsg{Value: it.Value} }
			}
			return p, nil
		case key.Matches(m, key.NewBinding(key.WithKeys("x"))):
			// Reserved host-side shortcut channel: the host decides what
			// "x" means per screen (the audio manager's plugin list uses
			// it to flip the plugin window handler). A plain single key
			// is safe — the picker has no text filter.
			return p, func() tea.Msg { return PickerActionMsg{Key: "x"} }
		case key.Matches(m, key.NewBinding(key.WithKeys("?"))):
			// "?" opens/closes the picker's own shortcut-overlay (the
			// old bubbles "?" toggled nothing visible once the built-in
			// help line was disabled — the user reported "?" as buggy).
			// Overlay replace-IN-PLACE: no host wiring needed, no other
			// screen moves, the picker keeps its size.
			p.helpOpen = !p.helpOpen
			return p, nil
		case key.Matches(m, key.NewBinding(key.WithKeys("down", "j"))):
			// Down arrow moves down within the current page only — it
			// never crosses a page boundary, so the cursor can never
			// jump from the bottom of the list to the top. Multi-page
			// lists require an explicit NextPage action (pgdown/right/l)
			// to advance pages. This matches the multi-select Tab
			// no-wrap rule: once a user has scrolled to the bottom of
			// the visible list, additional Down presses are no-ops
			// rather than wrap-and-then-have-to-scroll-back.
			out, moved := p.advanceDown()
			if !moved {
				return p, nil
			}
			return out, nil
		case key.Matches(m, key.NewBinding(key.WithKeys("up", "k"))):
			out, moved := p.advanceUp()
			if !moved {
				return p, nil
			}
			return out, nil
		case key.Matches(m, key.NewBinding(key.WithKeys("left"))):
			return p, func() tea.Msg { return PickerSortMsg{Dir: -1} }
		case key.Matches(m, key.NewBinding(key.WithKeys("right"))):
			return p, func() tea.Msg { return PickerSortMsg{Dir: 1} }
		}
	}
	var cmd tea.Cmd
	p.list, cmd = p.list.Update(msg)
	if km, ok := msg.(tea.KeyMsg); ok {
		if dir, isNav := navDirection(km, &p.list); isNav {
			p = p.clampDisabled(dir)
		}
	}
	return p, cmd
}

// advanceDown moves the cursor to the next SELECTABLE row, crossing page
// boundaries (so the pagination dots are actually reachable with ↓/j). It
// skips greyed/Disabled rows and never wraps: at the last selectable row it
// returns false. list.Select also updates the paginator page.
func (p Picker) advanceDown() (Picker, bool) {
	if !p.ready {
		return p, false
	}
	items := p.list.Items()
	n := len(items)
	start := p.list.Index()
	for i := start + 1; i < n; i++ {
		if it, ok := items[i].(PickerItem); ok && it.Disabled {
			continue
		}
		p.list.Select(i)
		return p, true
	}
	return p, false // already at the last selectable row
}

// advanceUp moves the cursor to the previous SELECTABLE row, crossing page
// boundaries (the pagination dots are reachable with ↑/k). Skips Disabled
// rows, never wraps.
func (p Picker) advanceUp() (Picker, bool) {
	if !p.ready {
		return p, false
	}
	items := p.list.Items()
	start := p.list.Index()
	for i := start - 1; i >= 0; i-- {
		if it, ok := items[i].(PickerItem); ok && it.Disabled {
			continue
		}
		p.list.Select(i)
		return p, true
	}
	return p, false // already at the first selectable row
}

// navDirection reports whether the key moves the cursor, and in which
// direction, so disabled items can be skipped during navigation.
func navDirection(m tea.KeyMsg, l *list.Model) (int, bool) {
	switch {
	case key.Matches(m, l.KeyMap.CursorDown),
		key.Matches(m, l.KeyMap.NextPage),
		key.Matches(m, l.KeyMap.GoToEnd):
		return 1, true
	case key.Matches(m, l.KeyMap.CursorUp),
		key.Matches(m, l.KeyMap.PrevPage),
		key.Matches(m, l.KeyMap.GoToStart):
		return -1, true
	}
	return 0, false
}

// clampDisabled nudges the cursor off a disabled item in the given direction,
// sweeping back the other way if it ran into the end of the list (e.g. the
// last item is disabled and the user pressed "down").
func (p Picker) clampDisabled(dir int) Picker {
	total := len(p.list.Items())
	if total == 0 {
		return p
	}
	move := func(d int) {
		if d > 0 {
			p.list.CursorDown()
		} else {
			p.list.CursorUp()
		}
	}
	onDisabled := func() bool {
		it, ok := p.list.SelectedItem().(PickerItem)
		return !ok || it.Disabled
	}
	for step := 0; step < total && onDisabled(); step++ {
		move(dir)
	}
	if !onDisabled() {
		return p
	}
	for step := 0; step < total && onDisabled(); step++ {
		move(-dir)
	}
	return p
}

func (p Picker) View() string {
	if !p.ready {
		return "" // zero Picker: nothing to draw (see SetSize)
	}
	if p.helpOpen {
		// "?" opened the shortcut overlay: replace the list body with
		// the complete shortcut list in-place (same size modal), any
		// other key press goes through Update and toggles it off first
		// — so no host wiring is needed anywhere.
		return StyleModal.Render(p.FullHelpText())
	}
	// Re-stamp the bubbles title style from the live package var on every
	// render so a theme switch mid-flight reaches an already-built picker,
	// and re-stamp the delegate's per-row styles the same way (rows are
	// styled at render time — see titleStyle/descStyle — but the TITLE
	// style is stored on the bubbles model itself and would otherwise
	// keep the accent captured when NewPicker ran).
	p.list.Styles.Title = StyleHeader
	// Each row is centered inside the picker's own width by renderCentered
	// (which pads every row to maxRowW first so widths match and centers
	// are aligned across items). bubbles composes those rows vertically;
	// StyleFrame wraps the whole panel with Padding(1, 2).
	body := p.list.View()
	return StyleFrame.Render(body)
}

// FullHelpText renders the picker's complete shortcut list as a centered
// modal body for the "?" overlay: the base keys first, then every custom
// hint registered via SetHelpKeys, then a close hint.
func (p Picker) FullHelpText() string {
	base := []string{
		"↑/k · ↓/j      move (no wrap)",
		"enter          select the highlighted row",
		"esc · ctrl+c   cancel / back",
		"?              close this help",
	}
	all := append(base, p.extraHints...)
	lines := []string{
		StyleHeader.Render("Shortcuts"),
		"",
		StyleHelp.Render(strings.Join(all, "\n")),
		"",
		StyleHelp.Render("press ? or any other key to close"),
	}
	return lipgloss.JoinVertical(lipgloss.Center, lines...)
}

// Index returns the cursor 0-based ABSOLUTE row position across the whole
// (paginated) item list — bubbles's Cursor() is page-local, which made
// page-crossing and selection-preservation wrong. Hosts use it to preserve
// the selection across a screen rebuild (the Live
// Mode Manager re-creates its picker after every settings change —
// without re-selecting, Enter-on-a-row sent the cursor flying back to
// the top of the list on every save).
func (p Picker) Index() int {
	if !p.ready {
		return 0
	}
	return p.list.Index()
}

// SelectIndex moves the cursor to the given 0-based row. The index is
// CLAMPED to the real range: bubbles' list.Select does not clamp, so a
// rebuild that shortens the list (e.g. collapsing a folder removes its
// children) used to leave the cursor past the end and panic on the next
// render/selection. No-op on a zero Picker.
func (p Picker) SelectIndex(i int) Picker {
	if !p.ready {
		return p
	}
	n := len(p.list.Items())
	if n == 0 {
		return p
	}
	if i < 0 {
		i = 0
	}
	if i >= n {
		i = n - 1
	}
	p.list.Select(i)
	return p
}

// SelectedValue returns the Value of the row the cursor is on, "", empty.
// Host models use it to key screen-wide shortcuts (e.g. Left/Right adjusting
// only the thermal-limit row) off the current selection.
func (p Picker) SelectedValue() string {
	if it, ok := p.list.SelectedItem().(PickerItem); ok {
		return it.Value
	}
	return ""
}
