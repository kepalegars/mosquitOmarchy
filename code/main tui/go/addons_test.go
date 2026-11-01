package main

import (
	"strings"
	"testing"
)

func addonTestModel() model {
	m := model{
		nav:          []screen{scrMain, scrSettings, scrAddons},
		w:            100,
		h:            40,
		addonsLoaded: true,
		addonsSel:    map[string]bool{"emoticon": true},
		addons: []addonRec{
			{Name: "emoticon", Category: "Themes", Installed: true},
			{Name: "backup-helper", Category: "System", Installed: false},
		},
	}
	return m
}

func TestAddonsAreGroupedAndEmptyCategoriesHidden(t *testing.T) {
	p := addonTestModel().rebuildAddons()
	var headings, themes, system int
	for _, it := range p.items {
		if it.Heading {
			headings++
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
	if headings != 2 || themes != 1 || system != 1 {
		t.Fatalf("headings=%d themes=%d system=%d", headings, themes, system)
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
