package main

import (
	"github.com/charmbracelet/bubbles/key"
	tea "github.com/charmbracelet/bubbletea"
	tuikit "mosquitomarchy.local/tui-kit"
)

// navPicker wraps tuikit.Picker with an app-side guarantee that vertical
// navigation stops dead at the first/last selectable row — it can never
// wrap. This is deliberately owned here, not in the shared kit: the kit's
// advanceDown/advanceUp start from list.Cursor(), which bubbles defines as
// the *page-local* cursor position, while they then scan the whole
// (absolute) item slice. As soon as a list paginates (more rows than fit,
// e.g. the 9-row main menu with its banner budget leaving room for 8), a
// down-step that crosses into page 2 leaves Cursor() back at a small
// page-local value, so the next step re-enters page 1 near the top — the
// reported "scroll past Close and land back on the first". Handling the
// navigation keys here and selecting by ABSOLUTE index through
// Picker.SelectIndex sidesteps that entirely, for every picker in the TUI.
//
// All non-navigation keys (enter/esc/tab/x/?/left/right, …) still go
// through the wrapped kit picker unchanged, so the kit's result/toggle/
// sort messages and help overlay behave exactly as before.
type navPicker struct {
	tuikit.Picker
	items []tuikit.PickerItem
}

func newNavPicker(header string, items []tuikit.PickerItem) navPicker {
	return navPicker{Picker: tuikit.NewPicker(header, items), items: items}
}

// SetSize/SetHelpKeys/SelectIndex shadow the promoted kit methods so the
// fluent call sites keep returning the wrapper instead of a bare Picker.
func (p navPicker) SetSize(w, h int) navPicker {
	p.Picker = p.Picker.SetSize(w, h)
	return p
}

func (p navPicker) SetHelpKeys(keys ...key.Binding) navPicker {
	p.Picker = p.Picker.SetHelpKeys(keys...)
	return p
}

func (p navPicker) SelectIndex(i int) navPicker {
	p.Picker = p.Picker.SelectIndex(i)
	return p
}

func (p navPicker) Update(msg tea.Msg) (navPicker, tea.Cmd) {
	if km, ok := msg.(tea.KeyMsg); ok {
		switch km.String() {
		case "down", "j", "pgdown", "l", "f", "d":
			return p.step(1), nil
		case "up", "k", "pgup", "h", "b", "u":
			return p.step(-1), nil
		case "home", "g":
			return p.selectFirst(), nil
		case "end", "G":
			return p.selectLast(), nil
		}
	}
	var cmd tea.Cmd
	p.Picker, cmd = p.Picker.Update(msg)
	return p, cmd
}

// step moves one selectable row in dir (-1 up, +1 down), scanning across
// page boundaries by absolute index and never wrapping: at the boundary it
// returns the picker unchanged, so the key is a genuine no-op.
func (p navPicker) step(dir int) navPicker {
	cur := p.selectedIndex()
	for i := cur + dir; i >= 0 && i < len(p.items); i += dir {
		if p.items[i].Disabled {
			continue
		}
		p.Picker = p.Picker.SelectIndex(i)
		return p
	}
	return p
}

func (p navPicker) selectFirst() navPicker {
	for i := 0; i < len(p.items); i++ {
		if !p.items[i].Disabled {
			p.Picker = p.Picker.SelectIndex(i)
			return p
		}
	}
	return p
}

func (p navPicker) selectLast() navPicker {
	for i := len(p.items) - 1; i >= 0; i-- {
		if !p.items[i].Disabled {
			p.Picker = p.Picker.SelectIndex(i)
			return p
		}
	}
	return p
}

// Index returns the row's ABSOLUTE position. The kit's Index() is
// bubbles' page-local cursor, so a rebuild that preserves it (status
// refresh, settings re-create) would misplace the cursor once a list
// paginates — resolve through the item values instead.
func (p navPicker) Index() int {
	return p.selectedIndex()
}

// selectedIndex resolves the current row through its Value, which our
// pickers always set uniquely. This avoids relying on the kit's page-local
// Index() (see the type comment).
func (p navPicker) selectedIndex() int {
	v := p.SelectedValue()
	for i := range p.items {
		if p.items[i].Value == v {
			return i
		}
	}
	return 0
}
