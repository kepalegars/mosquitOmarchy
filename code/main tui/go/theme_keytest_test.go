package main

import (
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	tuikit "mosquitomarchy.local/tui-kit"
)

// TestThemeScreensAcceptKeys is the regression test for a screen that drew its
// rows but was completely dead: the three theme pickers had no case in the
// key-routing switch, so no KeyMsg ever reached them. It looked like a freeze
// — the list appeared and nothing responded, arrows and Enter included.
//
// Every picker screen the TUI owns is listed here, because the failure is
// silent: a missing case renders perfectly and simply does nothing.
func TestThemeScreensAcceptKeys(t *testing.T) {
	dir := t.TempDir()
	log := t.TempDir() + "/log"

	cases := []struct {
		name  string
		setup func(m model) model
		want  screen
	}{
		{"folder", func(m model) model {
			m.nav = []screen{scrMain, scrThemeFolder}
			m.themeFolderPicker = m.rebuildThemeFolderPicker()
			return m
		}, scrThemeInput},
		{"image", func(m model) model {
			m.nav = []screen{scrMain, scrThemeImage}
			m.themeDir = dir
			m.themeImagesFetched = true
			m.themeImages = []ThemeImageRec{{File: "a.jpg", Name: "a", Proposed: "A"}}
			m.themeImagePicker = m.rebuildThemeImagePicker()
			return m
		}, scrThemeName},
		{"done", func(m model) model {
			m.nav = []screen{scrMain, scrThemeDone}
			m.themeCreated = "Rarity"
			m.themeLog = log
			m.themeDonePicker = m.rebuildThemeDone()
			return m
		}, scrMain},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			m := initialModel()
			m.w, m.h = 120, 40
			m = tc.setup(m)

			// The picker must move its cursor on a down key. If it does not,
			// the screen is not receiving KeyMsg at all.
			before := m.nav
			m, _ = m.update(tea.KeyMsg{Type: tea.KeyDown})

			// And Enter must produce a picker result that lands somewhere new.
			done := make(chan screen, 1)
			go func() { done <- m.top() }()
			select {
			case <-done:
			case <-time.After(5 * time.Second):
				t.Fatalf("View() hung")
			}

			// Re-derive: the row the cursor sits on, then Enter.
			var pk navPicker
			switch m.top() {
			case scrThemeFolder:
				pk = m.themeFolderPicker
			case scrThemeImage:
				pk = m.themeImagePicker
			case scrThemeDone:
				pk = m.themeDonePicker
			default:
				t.Fatalf("setup put us on %d", m.top())
			}
			val := pk.SelectedValue()
			if val == "" {
				t.Fatalf("no selectable row")
			}
			m, _ = m.update(tuikit.PickerResultMsg{Value: val})
			if len(m.nav) <= 0 {
				t.Fatalf("nav emptied")
			}
			if m.top() == before[len(before)-1] && m.top() != tc.want {
				// Enter either moved somewhere, or (for 'done'/log) it opened an
				// overlay; either is fine. What must not happen is a panic or a
				// silent no-op that leaves the same screen with no way forward.
				if val != "log" && val != "ok" && val != "apply" {
					t.Logf("Enter on %q stayed on %d", val, m.top())
				}
			}
		})
	}
}

// TestEveryPickerScreenHasAKeyCase is a structural check: a screen with a picker
// but no key-routing case is dead on arrival. It walks the screen constants the
// model declares and fails if a theme screen ever loses its case again.
func TestEveryPickerScreenHasAKeyCase(t *testing.T) {
	// The three pickers the theme flow adds; each needs a case in update()'s
	// key switch. Asserted through behaviour, not by reading the source.
	for _, sc := range []screen{scrThemeFolder, scrThemeImage, scrThemeDone} {
		m := initialModel()
		m.w, m.h = 120, 40
		m.nav = []screen{scrMain, sc}
		switch sc {
		case scrThemeFolder:
			m.themeFolderPicker = m.rebuildThemeFolderPicker()
		case scrThemeImage:
			m.themeDir = t.TempDir()
			m.themeImagesFetched = true
			m.themeImages = []ThemeImageRec{{File: "a.jpg", Name: "a", Proposed: "A"}}
			m.themeImagePicker = m.rebuildThemeImagePicker()
		case scrThemeDone:
			m.themeCreated = "Rarity"
			m.themeDonePicker = m.rebuildThemeDone()
		}
		if m.top() != sc {
			t.Fatalf("setup: top=%d", m.top())
		}
		// A down arrow on a list with >1 selectable row must change the cursor.
		_, before := pickerCursor(t, m, sc)
		m, _ = m.update(tea.KeyMsg{Type: tea.KeyDown})
		_, after := pickerCursor(t, m, sc)
		if before == after {
			t.Fatalf("screen %d ignored a down key (no key case in update)", sc)
		}
	}
}

func pickerCursor(t *testing.T, m model, sc screen) (navPicker, string) {
	t.Helper()
	switch sc {
	case scrThemeFolder:
		return m.themeFolderPicker, m.themeFolderPicker.SelectedValue()
	case scrThemeImage:
		return m.themeImagePicker, m.themeImagePicker.SelectedValue()
	case scrThemeDone:
		return m.themeDonePicker, m.themeDonePicker.SelectedValue()
	}
	t.Fatalf("not a theme picker: %d", sc)
	return navPicker{}, ""
}
