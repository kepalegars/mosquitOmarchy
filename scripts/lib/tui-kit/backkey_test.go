package tuikit

import (
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

// TestBackspaceLeavesPicker: Backspace is a second "back" key on every picker.
// Text-input and live-filter screens handle Backspace themselves before the
// picker sees it, so a plain list must leave on it just like Esc.
func TestBackspaceLeavesPicker(t *testing.T) {
	p := newTestPicker(t, PickerItem{Display: "Back", Value: "back"})
	_, cmd := p.Update(tea.KeyMsg{Type: tea.KeyBackspace})
	if cmd == nil {
		t.Fatal("backspace produced no command")
	}
	msg, ok := cmd().(PickerResultMsg)
	if !ok || !msg.Canceled {
		t.Fatalf("backspace = %#v, want a canceled PickerResultMsg", msg)
	}
}

func TestBackspaceDismissesModals(t *testing.T) {
	for name, update := range map[string]func() tea.Msg{
		"info": func() tea.Msg {
			_, cmd := NewInfo("details").Update(tea.KeyMsg{Type: tea.KeyBackspace})
			return cmd()
		},
		"confirm": func() tea.Msg {
			_, cmd := NewConfirm("Continue?", "No", "Yes").Update(tea.KeyMsg{Type: tea.KeyBackspace})
			return cmd()
		},
	} {
		t.Run(name, func(t *testing.T) {
			msg := update()
			switch result := msg.(type) {
			case InfoDismissedMsg:
				if name != "info" {
					t.Fatalf("unexpected info dismissal: %#v", result)
				}
			case ConfirmResultMsg:
				if name != "confirm" || !result.Canceled {
					t.Fatalf("confirm result = %#v, want canceled", result)
				}
			default:
				t.Fatalf("backspace result = %#v, want modal dismissal", msg)
			}
		})
	}
}
