package tuikit

import (
	"strings"
	"testing"
)

func TestIsAssetGateNote(t *testing.T) {
	gated := "Guitar Pro 8 — install the thing — needs guitar-pro-8-setup.exe in scripts/apps/guitarpro/"
	if !isAssetGateNote(gated) {
		t.Errorf("isAssetGateNote(%q) = false, want true", gated)
	}
	for _, tc := range []string{
		"",
		"nothing left to do here",
		"needs something", // no "in scripts/apps/" tail
		"something in scripts/apps/ without — ", // separator but no "needs " tail
		"a — b — needs x in scripts/apps/y/",    // last " — " wins: still gated
	} {
		if tc == "a — b — needs x in scripts/apps/y/" {
			if !isAssetGateNote(tc) {
				t.Errorf("isAssetGateNote(%q) = false, want true (last separator wins)", tc)
			}
			continue
		}
		if isAssetGateNote(tc) {
			t.Errorf("isAssetGateNote(%q) = true, want false", tc)
		}
	}
}

func TestBuildFolderTreeGatedRowHasNoSub(t *testing.T) {
	folders := []TreeFolder{{ID: "apps", Label: "Apps"}}
	items := map[string][]TreeItem{
		"apps": {
			{ID: "apps:guitarpro", Label: "Guitar Pro 8 - v1.0.0",
				Info:     "Guitar Pro 8 — tablature editor — needs guitar-pro-8-setup.exe in scripts/apps/guitarpro/",
				Disabled: true},
			{ID: "apps:reaper", Label: "REAPER - v1.0.0",
				Info:     "nothing left to do here",
				Disabled: true},
			{ID: "apps:zen", Label: "Zen Browser - v1.0.0"},
		},
	}
	rows := BuildFolderTree(folders, items, map[string]bool{"apps": true}, false)
	byValue := map[string]PickerItem{}
	for _, r := range rows {
		byValue[r.Value] = r
	}
	gp, ok := byValue[TreeValue(TreeItemPrefix, "apps:guitarpro")]
	if !ok {
		t.Fatal("gated row missing from tree")
	}
	if !gp.Disabled {
		t.Error("gated row is not Disabled")
	}
	if gp.Sub != "" {
		t.Errorf("gated row shows sub-line %q — want bare greyed name", gp.Sub)
	}
	if !strings.Contains(gp.Display, "Guitar Pro 8") {
		t.Errorf("gated row display lost its name: %q", gp.Display)
	}
	if strings.Contains(gp.Display, "missing installation files") {
		t.Errorf("gated row gained a label suffix: %q", gp.Display)
	}
	reaper, ok := byValue[TreeValue(TreeItemPrefix, "apps:reaper")]
	if !ok {
		t.Fatal("plain disabled row missing from tree")
	}
	if reaper.Sub == "" {
		t.Error("non-gated disabled row lost its sub-line — only asset-gate notes are dropped")
	}
}
