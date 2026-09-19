package tuikit

import (
	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// InfoConfirm is a yes/no dialog whose message is rendered through the SAME
// bounded, wrapping, scrollable, StyleModal-framed body the Info (Readme)
// screen uses — instead of a raw Confirm, whose long unwrapped paragraph
// overflows the terminal. Semantics are identical to Confirm: a Yes result
// means "apply", No and Esc both mean "drop" (ConfirmResultMsg keeps
// Canceled distinct so hosts can tell them apart, but both read as no).
type InfoConfirm struct {
	Message  string
	NoLabel  string
	YesLabel string
	yesFocus bool
	w, h     int
	viewport viewport.Model
}

// NewInfoConfirm builds a framed confirm. Empty button labels fall back to
// No/Yes, matching NewConfirm.
func NewInfoConfirm(message, noLabel, yesLabel string) InfoConfirm {
	if noLabel == "" {
		noLabel = "No"
	}
	if yesLabel == "" {
		yesLabel = "Yes"
	}
	return InfoConfirm{
		Message:  message,
		NoLabel:  noLabel,
		YesLabel: yesLabel,
		viewport: viewport.New(0, 0),
	}
}

// SetSize bounds the modal to fit within a w x h terminal area, using the
// same border/padding reserve as Info.SetSize and leaving two rows for the
// button line.
func (c InfoConfirm) SetSize(w, h int) InfoConfirm {
	c.w, c.h = w, h
	vpW := w - 6
	if vpW < 10 {
		vpW = 10
	}
	vpH := h - 8
	if vpH < 3 {
		vpH = 3
	}
	c.viewport = viewport.New(vpW, vpH)
	c.viewport.SetContent(lipgloss.NewStyle().Width(vpW).Render(c.Message))
	return c
}

func (c InfoConfirm) Init() tea.Cmd { return nil }

func (c InfoConfirm) Update(msg tea.Msg) (InfoConfirm, tea.Cmd) {
	km, ok := msg.(tea.KeyMsg)
	if !ok {
		var cmd tea.Cmd
		c.viewport, cmd = c.viewport.Update(msg)
		return c, cmd
	}
	switch km.String() {
	case "ctrl+c", "esc":
		return c, func() tea.Msg { return ConfirmResultMsg{Canceled: true} }
	case "n", "N":
		return c, func() tea.Msg { return ConfirmResultMsg{Yes: false} }
	case "y", "Y":
		return c, func() tea.Msg { return ConfirmResultMsg{Yes: true} }
	case "left", "right", "tab", "shift+tab", "h", "l":
		c.yesFocus = !c.yesFocus
		return c, nil
	case "enter":
		return c, func() tea.Msg { return ConfirmResultMsg{Yes: c.yesFocus} }
	}
	// Anything else (arrows/page keys) scrolls a long message.
	var cmd tea.Cmd
	c.viewport, cmd = c.viewport.Update(msg)
	return c, cmd
}

func (c InfoConfirm) View() string {
	btn := func(label string, focused bool) string {
		s := lipgloss.NewStyle().Padding(0, 2)
		if focused {
			s = s.Background(ColorAccent).Foreground(accentForeground()).Bold(true)
		} else {
			s = s.Foreground(ColorMuted)
		}
		return s.Render(label)
	}
	buttons := lipgloss.JoinHorizontal(lipgloss.Top,
		btn(c.NoLabel, !c.yesFocus), "  ", btn(c.YesLabel, c.yesFocus))
	body := c.viewport.View() + "\n\n" + buttons
	return StyleModal.Render(body)
}

// ShortcutsHint is the same hint line a Confirm shows.
func (c InfoConfirm) ShortcutsHint() string {
	return StyleHelp.Render("←/→ choose · enter submit · esc back")
}
