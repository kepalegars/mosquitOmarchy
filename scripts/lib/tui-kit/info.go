package tuikit

import (
	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// InfoDismissedMsg is sent when the user dismisses an Info screen —
// replacement for ui_info's single-OK-button notice.
type InfoDismissedMsg struct{}

// Info is a single, dismissable notice — width/height-bounded and
// scrollable via a viewport, so a long body (e.g. a Readme) wraps to fit
// the terminal and scrolls instead of rendering an oversized, unbounded
// box (StyleModal has no width/height of its own — that's what used to
// make a long Info balloon past the terminal's actual size).
type Info struct {
	text     string
	w, h     int
	viewport viewport.Model
}

func NewInfo(text string) Info {
	return Info{text: text, viewport: viewport.New(0, 0)}
}

// SetSize bounds the modal to fit within a w x h terminal, matching the
// Picker/Runner convention (SetSize(m.contentSize())).
//
// The current scroll offset is PRESERVED across the resize: hosts re-size
// their Info defensively on every render (a value-copy View), and creating a
// fresh viewport each time reset YOffset to 0, which made the status screen
// impossible to scroll (each keypress scrolled, the next frame snapped back).
func (i Info) SetSize(w, h int) Info {
	i.w, i.h = w, h
	// Reserve room for the border+padding (StyleModal: 1 rounded border +
	// 2h/1v padding = 4 cols, 4 rows) and the trailing help line.
	vpW := w - 6
	if vpW < 10 {
		vpW = 10
	}
	vpH := h - 6
	if vpH < 3 {
		vpH = 3
	}
	off := i.viewport.YOffset
	i.viewport = viewport.New(vpW, vpH)
	i.viewport.SetContent(lipgloss.NewStyle().Width(vpW).Render(i.text))
	i.viewport.SetYOffset(off)
	return i
}

func (i Info) Init() tea.Cmd { return nil }

func (i Info) Update(msg tea.Msg) (Info, tea.Cmd) {
	if km, ok := msg.(tea.KeyMsg); ok {
		switch km.String() {
		case "esc", "enter", "q", "ctrl+c":
			return i, func() tea.Msg { return InfoDismissedMsg{} }
		}
		var cmd tea.Cmd
		i.viewport, cmd = i.viewport.Update(msg)
		return i, cmd
	}
	return i, nil
}

func (i Info) View() string {
	body := i.viewport.View()
	return StyleModal.Render(body)
}

// ShortcutsHint returns the bottom-row shortcut hint for this Info:
// "↑/↓ scroll · esc/enter to continue" when the body is long enough to
// scroll, "esc/enter to continue" otherwise (nothing to scroll → no scroll
// hint, which used to show even when the log fit entirely on the page).
func (i Info) ShortcutsHint() string {
	scrollable := i.viewport.Height > 0 && i.viewport.TotalLineCount() > i.viewport.Height
	if scrollable {
		return StyleHelp.Render("↑/↓ scroll · esc/enter to continue")
	}
	return StyleHelp.Render("esc/enter to continue")
}
