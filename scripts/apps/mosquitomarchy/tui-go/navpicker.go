package main

import (
	"github.com/charmbracelet/bubbles/key"
	tea "github.com/charmbracelet/bubbletea"
	tuikit "mosquitomarchy.local/tui-kit"
)

// navPicker wraps tuikit.Picker with an app-side guarantee that vertical
// navigation stops dead at the first/last selectable row — it can never
// wrap (same wrapper as the move-manager TUI; see its navpicker.go for the
// full rationale around page-local cursors). Enter on a non-control row
// still routes through the kit, so every multi-select screen in this app
// rebuilds its picker with the new "✓"/"·" badges on each toggle.
type navPicker struct {
	tuikit.Picker
	items []tuikit.PickerItem
}

func newNavPicker(header string, items []tuikit.PickerItem) navPicker {
	return navPicker{Picker: tuikit.NewPicker(header, items), items: items}
}

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

func (p navPicker) step(dir int) navPicker {
	cur := p.selectedIndex()
	// Land on the next SELECTABLE row in one go.
	//
	// It used to select the neighbouring index and let the kit's clamp push off
	// an inert row, but the clamp always steps in ONE fixed direction: aiming
	// up at a section heading (which is inert) had it step back DOWN onto the
	// row we came from, so the cursor never moved — going up was stuck at the
	// last row of a folder. Resolving the target here makes the direction the
	// one the user asked for.
	for i := cur + dir; i >= 0 && i < len(p.items); i += dir {
		if p.items[i].Disabled || p.items[i].Heading {
			continue
		}
		p.Picker = p.Picker.SelectIndex(i)
		return p
	}
	return p
}

func (p navPicker) selectFirst() navPicker {
	for i := 0; i < len(p.items); i++ {
		if !p.items[i].Disabled && !p.items[i].Heading {
			p.Picker = p.Picker.SelectIndex(i)
			return p
		}
	}
	return p
}

func (p navPicker) selectLast() navPicker {
	for i := len(p.items) - 1; i >= 0; i-- {
		if !p.items[i].Disabled && !p.items[i].Heading {
			p.Picker = p.Picker.SelectIndex(i)
			return p
		}
	}
	return p
}

func (p navPicker) Index() int {
	return p.selectedIndex()
}

func (p navPicker) selectedIndex() int {
	return p.IndexOf(p.SelectedValue())
}

// IndexOf returns the position of a row value, or -1 when the value is not in
// the list. Needed to carry the cursor across a REBUILD: a filtered list is a
// different set in a different order, so a saved row NUMBER means something
// else afterwards, while the value still identifies the row.
// Len reports the number of rows, so callers can tell an unbuilt picker
// (no rows yet) from a legitimately empty one.
func (p navPicker) Len() int { return len(p.items) }

func (p navPicker) IndexOf(v string) int {
	for i := range p.items {
		if p.items[i].Value == v {
			return i
		}
	}
	return -1
}

// KeepCursor rebuilds a picker and restores the row the user was on, matching
// by value. Without it every periodic rebuild (the blink, the update poll)
// dropped the cursor back to the first row, so moving down a filtered list was
// undone a second later.
func (p navPicker) KeepCursor(prev string) navPicker {
	if i := p.IndexOf(prev); i >= 0 {
		return p.SelectIndex(i)
	}
	return p
}
