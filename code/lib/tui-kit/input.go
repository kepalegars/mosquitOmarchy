package tuikit

import (
	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// InputResultMsg replaces ui_input's "echo the entered text, empty allowed,
// return 1 on cancel" contract.
type InputResultMsg struct {
	Value    string
	Canceled bool
}

// TextInput is a single-line prompt.
type TextInput struct {
	Prompt string
	model  textinput.Model
}

func NewTextInput(prompt, def string) TextInput {
	ti := textinput.New()
	ti.Prompt = "> "
	ti.SetValue(def)
	ti.CursorEnd()
	ti.Focus()
	return TextInput{Prompt: prompt, model: ti}
}

// NewPasswordInput is NewTextInput with the typed value masked ("•"), for a
// passphrase/password that must not be shown on screen. Everything else
// (enter submit, esc cancel, ShortcutsHint) is identical.
func NewPasswordInput(prompt, def string) TextInput {
	t := NewTextInput(prompt, def)
	t.model.EchoMode = textinput.EchoPassword
	t.model.EchoCharacter = '•'
	return t
}

func (t TextInput) Init() tea.Cmd { return textinput.Blink }

func (t TextInput) Update(msg tea.Msg) (TextInput, tea.Cmd) {
	if km, ok := msg.(tea.KeyMsg); ok {
		switch km.String() {
		case "ctrl+c", "esc":
			return t, func() tea.Msg { return InputResultMsg{Canceled: true} }
		case "enter":
			return t, func() tea.Msg { return InputResultMsg{Value: t.model.Value()} }
		}
	}
	var cmd tea.Cmd
	t.model, cmd = t.model.Update(msg)
	return t, cmd
}

func (t TextInput) View() string {
	body := lipgloss.JoinVertical(lipgloss.Left,
		StyleHeader.Render(t.Prompt), "", t.model.View())
	return StyleModal.Render(body)
}

// ShortcutsHint returns the bottom-row shortcut hint for a TextInput:
// "enter submit · esc cancel" — Enter to submit, Esc/Ctrl+C to cancel.
func (t TextInput) ShortcutsHint() string {
	return StyleHelp.Render("enter submit · esc cancel")
}
