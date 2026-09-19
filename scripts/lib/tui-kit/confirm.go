package tuikit

import (
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// ConfirmResultMsg replaces ui_confirm's "0 = yes, 1 = no/cancel" contract
// — but unlike that bash contract, Esc/Ctrl+C (Canceled) is kept distinct
// from an explicit "No" answer (Yes:false, Canceled:false). They read the
// same for a plain yes/no question, but not every confirm here is a plain
// yes/no question: some (e.g. "Install into the default wine prefix?")
// use the No button for a real, deliberate alternative path, not "abort".
// Esc must always mean "back out of this screen", never "press the button
// on the left" — a host's Update() should check Canceled before Yes.
//
// Extra carries an optional third button's choice (see Confirm.WithExtra):
// it is only ever true for a Confirm built with an ExtraLabel. Hosts that
// don't use it can keep checking only Canceled/Yes.
type ConfirmResultMsg struct {
	Yes      bool
	Canceled bool
	Extra    bool
}

// Confirm is a modal yes/no dialog. Left/Right or Tab cycles the focused
// button, Enter submits, y/n are direct shortcuts for an explicit yes/no
// answer, ctrl+c/esc always cancel (back out, matching Picker's and
// TextInput's own ctrl+c/esc convention — never conflated with the No
// button, see ConfirmResultMsg's own doc comment).
//
// A Confirm may optionally carry a third button (WithExtra), rendered
// between No and Yes: e.g. "No / Re-check / Yes". It is purely additive —
// with no extra label the dialog is exactly the classic two-button one.
type Confirm struct {
	Message  string
	NoLabel  string
	YesLabel string

	// ExtraLabel, when non-empty, adds a third button between No and Yes.
	// ExtraKey, when non-empty, is a single-character shortcut for it (e.g.
	// "r" for "Re-check"), like y/n for Yes/No.
	ExtraLabel string
	ExtraKey   string

	// focus is the index of the focused button over the active button list
	// ([No, Extra?, Yes]).
	focus int
}

func NewConfirm(message, noLabel, yesLabel string) Confirm {
	if noLabel == "" {
		noLabel = "No"
	}
	if yesLabel == "" {
		yesLabel = "Yes"
	}
	return Confirm{Message: message, NoLabel: noLabel, YesLabel: yesLabel}
}

// WithExtra returns a copy of the Confirm with an optional third button,
// rendered between No and Yes and reported via ConfirmResultMsg.Extra.
// An empty label leaves the Confirm unchanged (classic two-button dialog).
// extraKey is an optional single-character shortcut (empty = none).
func (c Confirm) WithExtra(label, extraKey string) Confirm {
	c.ExtraLabel = label
	c.ExtraKey = extraKey
	return c
}

func (c Confirm) hasExtra() bool { return c.ExtraLabel != "" }

func (c Confirm) buttonCount() int {
	if c.hasExtra() {
		return 3
	}
	return 2
}

func (c Confirm) Init() tea.Cmd { return nil }

func (c Confirm) Update(msg tea.Msg) (Confirm, tea.Cmd) {
	km, ok := msg.(tea.KeyMsg)
	if !ok {
		return c, nil
	}
	if c.hasExtra() && c.ExtraKey != "" && km.String() == c.ExtraKey {
		return c, func() tea.Msg { return ConfirmResultMsg{Extra: true} }
	}
	switch km.String() {
	case "ctrl+c", "esc":
		return c, func() tea.Msg { return ConfirmResultMsg{Canceled: true} }
	case "n", "N":
		return c, func() tea.Msg { return ConfirmResultMsg{Yes: false} }
	case "y", "Y":
		return c, func() tea.Msg { return ConfirmResultMsg{Yes: true} }
	case "left", "shift+tab", "h":
		c.focus = (c.focus - 1 + c.buttonCount()) % c.buttonCount()
		return c, nil
	case "right", "tab", "l":
		c.focus = (c.focus + 1) % c.buttonCount()
		return c, nil
	case "enter":
		switch {
		case c.focus == 0:
			return c, func() tea.Msg { return ConfirmResultMsg{Yes: false} }
		case c.hasExtra() && c.focus == 1:
			return c, func() tea.Msg { return ConfirmResultMsg{Extra: true} }
		default:
			return c, func() tea.Msg { return ConfirmResultMsg{Yes: true} }
		}
	}
	return c, nil
}

func (c Confirm) View() string {
	btn := func(label string, focused bool) string {
		s := lipgloss.NewStyle().Padding(0, 2)
		if focused {
			s = s.Background(ColorAccent).Foreground(lipgloss.Color("0")).Bold(true)
		} else {
			s = s.Foreground(ColorMuted)
		}
		return s.Render(label)
	}
	// Focus index maps over the rendered order [No, Extra?, Yes]; the No
	// button is focus 0, so `!yesFocus` becomes `focus == 0`, and the rest
	// follows.
	parts := []string{btn(c.NoLabel, c.focus == 0)}
	if c.hasExtra() {
		parts = append(parts, btn(c.ExtraLabel, c.focus == 1))
	}
	yesFocus := c.focus == c.buttonCount()-1
	parts = append(parts, btn(c.YesLabel, yesFocus))
	buttons := lipgloss.JoinHorizontal(lipgloss.Top, intersperse(parts, "  ")...)
	body := lipgloss.JoinVertical(lipgloss.Left,
		c.Message, "", buttons)
	return StyleModal.Render(body)
}

// intersperse joins parts with sep between each pair (the old View used
// JoinHorizontal(..., a, "  ", b); this keeps the same layout for any
// number of buttons).
func intersperse(parts []string, sep string) []string {
	if len(parts) <= 1 {
		return parts
	}
	out := make([]string, 0, len(parts)*2-1)
	for i, p := range parts {
		if i > 0 {
			out = append(out, sep)
		}
		out = append(out, p)
	}
	return out
}

// ShortcutsHint returns the bottom-row shortcut hint for a Confirm:
// "←/→ choose · enter submit · esc back" — matches every Confirm's
// controls (Left/Right or Tab to move focus, Enter to submit, Esc/Ctrl+C
// to cancel).
func (c Confirm) ShortcutsHint() string {
	return StyleHelp.Render("←/→ choose · enter submit · esc back")
}
