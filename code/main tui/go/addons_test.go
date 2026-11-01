package main

import (
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"

	tuikit "mosquitomarchy.local/tui-kit"
)

func addonTestModel() model {
	m := model{
		nav:          []screen{scrMain, scrSettings, scrAddons},
		w:            100,
		h:            40,
		addonsLoaded: true,
		addonsSel:    map[string]bool{"emoticon": true},
		addonsOpen:   map[string]bool{"Themes": true, "System": true},
		addons: []addonRec{
			{Name: "emoticon", Category: "Themes", Installed: true},
			{Name: "backup-helper", Category: "System", Installed: false},
		},
	}
	return m
}

func TestAddonsAreGroupedAndEmptyCategoriesHidden(t *testing.T) {
	p := addonTestModel().rebuildAddons()
	var folders, themes, system int
	for _, it := range p.items {
		if it.Folder {
			folders++
			switch it.Display {
			case "Themes":
				themes++
			case "System":
				system++
			case "Other":
				t.Fatal("empty Other category was rendered")
			}
		}
	}
	if folders != 2 || themes != 1 || system != 1 {
		t.Fatalf("folders=%d themes=%d system=%d", folders, themes, system)
	}
	for _, it := range p.items {
		if it.Value == "apply" {
			t.Fatal("an Apply changes row is still rendered")
		}
	}
}

func TestAddonChangesTrackInstalledState(t *testing.T) {
	m := addonTestModel()
	m.addonsSel["backup-helper"] = true
	m.addonsSel["emoticon"] = false
	added, removed := m.addonChanges()
	if len(added) != 1 || added[0] != "backup-helper" {
		t.Fatalf("added=%v", added)
	}
	if len(removed) != 1 || removed[0] != "emoticon" {
		t.Fatalf("removed=%v", removed)
	}
	text := addonChangesText(added, removed)
	if !strings.Contains(text, "+ backup-helper") || !strings.Contains(text, "- emoticon") {
		t.Fatalf("confirmation does not list both changes:\n%s", text)
	}
}

func TestExtrasOffersBlinkingAddonsRow(t *testing.T) {
	for _, it := range addonTestModel().settingsItems2() {
		if it.Value == "addons" {
			if !it.Engage {
				t.Fatal("Addons row is not an engagement row")
			}
			return
		}
	}
	t.Fatal("Extras has no Addons row")
}

func TestSearchMatchesHyphenAsSpace(t *testing.T) {
	if !searchMatch("hyprland-autofocus", "hyprland autofocus") {
		t.Fatal("the Setup search does not find a hyphenated row from two words")
	}
	if !searchMatch("Focus options", "focus") {
		t.Fatal("plain search no longer works")
	}
}

func TestAddonsSearchShortcutAndFilter(t *testing.T) {
	m := addonTestModel()
	m.addonsPicker = m.rebuildAddons()
	next, _ := m.update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'F'}})
	m = next
	if !m.filterOpen {
		t.Fatal("shift+F did not open the addon filter")
	}
	next, _ = m.update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'e'}})
	m = next
	if m.filterText != "e" {
		t.Fatalf("filter text = %q", m.filterText)
	}
	if len(m.addonsPicker.items) == 0 {
		t.Fatal("filtered addon list is empty")
	}
}

func TestAddonsFoldWithLeftArrow(t *testing.T) {
	m := addonTestModel()
	m.addonsPicker = m.rebuildAddons()
	m.addonsPicker = m.addonsPicker.SelectValue(tuikit.TreeValue(tuikit.TreeFolderPrefix, "Themes"))
	next, _ := m.update(tuikit.PickerSortMsg{Dir: -1})
	m = next
	if m.addonsOpen["Themes"] {
		t.Fatal("left arrow did not collapse the Themes folder")
	}
}

func TestSetupSearchFindsQuickFixes(t *testing.T) {
	m := model{
		nav:          []screen{scrMain, scrSetup},
		w:            100,
		h:            40,
		filterText:   "hyprland autofocus",
		selected:     map[string]bool{},
		setupFolders: []FolderRec{{Folder: "fixes", Label: "fixes"}},
		setupItems: []SetupItemRec{{
			Folder: "fixes", Key: "hyprland-autofocus", Label: "hyprland-autofocus",
		}},
	}
	p := m.rebuildFilteredSetup()
	if len(p.items) != 1 || p.items[0].Value != setupValue("fixes", "hyprland-autofocus") {
		t.Fatalf("quick fix missing from search: %#v", p.items)
	}
}

func TestAddonShortcutsFit(t *testing.T) {
	m := addonTestModel()
	m.w, m.h = 100, 40
	hint := m.rebuildAddons().ShortcutsHint()
	for _, want := range []string{"tab", "search", "fold", "apply"} {
		if !strings.Contains(hint, want) {
			t.Fatalf("shortcut %q missing from %q", want, hint)
		}
	}
}
