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

func (p navPicker) Index() int {
	return p.selectedIndex()
}

func (p navPicker) selectedIndex() int {
	v := p.SelectedValue()
	for i := range p.items {
		if p.items[i].Value == v {
			return i
		}
	}
	return 0
}
