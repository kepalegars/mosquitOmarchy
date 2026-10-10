package main

import (
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

// themeUninstallOnBack builds the remove-themes screen over the folder screen,
// with the cursor parked on the Back row.
func themeUninstallOnBack(themes []ThemeRec) model {
	m := initialModel()
	m.nav = []screen{scrMain, scrThemeFolder, scrThemeUninstall}
	m.w, m.h = 100, 34
	m.themeList = themes
	m.themeChecked = map[string]bool{}
	m.themeUninstallPicker = m.rebuildThemeUninstall()
	m.themeUninstallPicker = m.themeUninstallPicker.SelectValue("back")
	return m
}

// pressThemeKey feeds one key to the theme-uninstall picker and resolves the
// single command it returns, mirroring pressKey for the Setup tree.
func pressThemeKey(m model, k tea.KeyMsg) model {
	var cmd tea.Cmd
	m.themeUninstallPicker, cmd = m.themeUninstallPicker.Update(k)
	if cmd == nil {
		return m
	}
	m, _ = m.update(cmd())
	return m
}

// TestThemeUninstallBackPops: Enter on Back leaves the remove-themes screen,
// whether or not any theme is listed. Regression test: Back was reported as
// doing nothing on a clean machine (empty list).
func TestThemeUninstallBackPops(t *testing.T) {
	for _, themes := range [][]ThemeRec{
		{{Name: "sometheme"}},
		{},
	} {
		m := themeUninstallOnBack(themes)
		if m.top() != scrThemeUninstall {
			t.Fatalf("setup: not on the uninstall screen")
		}
		m = pressThemeKey(m, tea.KeyMsg{Type: tea.KeyEnter})
		if m.top() != scrThemeFolder {
			t.Fatalf("Enter on Back with %d theme(s) left top=%v, want scrThemeFolder", len(themes), m.top())
		}
	}
}
