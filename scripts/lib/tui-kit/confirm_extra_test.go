package tuikit

import (
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

func kmsg(s string) tea.KeyMsg {
	switch s {
	case "enter":
		return tea.KeyMsg{Type: tea.KeyEnter}
	case "esc":
		return tea.KeyMsg{Type: tea.KeyEsc}
	case "right":
		return tea.KeyMsg{Type: tea.KeyRight}
	case "left":
		return tea.KeyMsg{Type: tea.KeyLeft}
	case "tab":
		return tea.KeyMsg{Type: tea.KeyTab}
	default:
		return tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(s)}
	}
}

func press(t *testing.T, c Confirm, keys ...string) ConfirmResultMsg {
	t.Helper()
	for _, k := range keys {
		var cmd tea.Cmd
		c, cmd = c.Update(kmsg(k))
		if cmd != nil {
			if res, ok := cmd().(ConfirmResultMsg); ok {
				return res
			}
		}
	}
	t.Fatalf("no ConfirmResultMsg produced by %v", keys)
	return ConfirmResultMsg{}
}

// TestConfirmTwoButtonUnchanged guards the classic two-button contract the
// 30+ existing NewConfirm call sites rely on.
func TestConfirmTwoButtonUnchanged(t *testing.T) {
	if res := press(t, NewConfirm("q", "No", "Yes"), "enter"); res.Yes || res.Canceled || res.Extra {
		t.Fatalf("default enter should answer No: %+v", res)
	}
	if res := press(t, NewConfirm("q", "No", "Yes"), "right", "enter"); !res.Yes {
		t.Fatalf("right+enter should answer Yes: %+v", res)
	}
	if res := press(t, NewConfirm("q", "No", "Yes"), "y"); !res.Yes {
		t.Fatalf("y should answer Yes: %+v", res)
	}
	if res := press(t, NewConfirm("q", "No", "Yes"), "n"); res.Yes || res.Canceled {
		t.Fatalf("n should answer No (not canceled): %+v", res)
	}
	if res := press(t, NewConfirm("q", "No", "Yes"), "esc"); !res.Canceled {
		t.Fatalf("esc should cancel: %+v", res)
	}
}

// TestConfirmExtra covers the optional third button: focus order No ->
// Extra -> Yes, the Extra result, the optional shortcut, and the fact that
// an empty label is a no-op.
func TestConfirmExtra(t *testing.T) {
	c := NewConfirm("q", "No", "Yes").WithExtra("Re-check", "r")

	if res := press(t, c, "right", "enter"); !res.Extra || res.Yes || res.Canceled {
		t.Fatalf("right+enter should pick Extra: %+v", res)
	}
	if res := press(t, c, "right", "right", "enter"); !res.Yes {
		t.Fatalf("right,right+enter should pick Yes: %+v", res)
	}
	if res := press(t, c, "right", "right", "right", "enter"); res.Yes || res.Extra || res.Canceled {
		t.Fatalf("focus should wrap back to No: %+v", res)
	}
	if res := press(t, c, "r"); !res.Extra {
		t.Fatalf("shortcut r should pick Extra: %+v", res)
	}
	if res := press(t, c, "esc"); !res.Canceled {
		t.Fatalf("esc should still cancel: %+v", res)
	}

	if res := press(t, c.WithExtra("", ""), "right", "enter"); !res.Yes {
		t.Fatalf("empty extra label must behave like two-button: %+v", res)
	}
}
