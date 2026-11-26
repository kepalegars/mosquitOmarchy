package main

import (
	"strings"
	"testing"
)

// TestGreyedAssetGatedRowShowsShortLabel: an asset-gated (installer missing)
// app row carries "(missing installation files)" in its own label and no
// long catalog description underneath — the backend joins both with " — "
// and the row must only keep the note's meaning, not its paragraph.
func TestGreyedAssetGatedRowShowsShortLabel(t *testing.T) {
	folders := []FolderRec{{Folder: "apps", Label: "Apps"}}
	items := []SetupItemRec{{
		Folder:   "apps",
		Key:      "ableton-wine",
		Label:    "ableton - v1.0.0",
		Info:     "Ableton Live 12 via Wine (shibco/ableton-linux) — needs a Live zip in code/modules/Apps/ableton/wine/",
		Disabled: true,
	}}
	rows := pickerTreeItems(folders, items, map[string]bool{}, map[string]bool{"apps": true}, false, "install", false)
	found := false
	for _, r := range rows {
		if !strings.Contains(r.Display, "ableton - v1.0.0") {
			continue
		}
		found = true
		if !strings.HasSuffix(r.Display, "(missing installation files)") {
			t.Fatalf("row label missing short note: %q", r.Display)
		}
		if strings.Contains(r.Sub, "Native Linux Ableton") {
			t.Fatalf("long catalog description leaked into sub-line: %q", r.Sub)
		}
	}
	if !found {
		t.Fatalf("ableton row not found among %d rows", len(rows))
	}
}
