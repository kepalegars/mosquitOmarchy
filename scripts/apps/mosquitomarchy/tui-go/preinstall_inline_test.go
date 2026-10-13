package main

import (
	"testing"

	tuikit "mosquitomarchy.local/tui-kit"
)

// TestSetupPreinstallSelectionAsksRemoval: Enter with ticked preinstall rows
// in Setup asks their removal (nothing installs silently, nothing installs
// without its own confirm).
func TestSetupPreinstallSelectionAsksRemoval(t *testing.T) {
	m := flatSetup()
	m.treeMode = "install"
	m.nav = []screen{scrMain, scrSetup, scrSetupCat}
	m.w, m.h = 120, 40
	m.setupCat = "preinstalls"
	m.setupItems = append(m.setupItems, SetupItemRec{
		Folder: "preinstalls", Key: "preinstall:obsidian", Label: "Obsidian",
	})
	m.setupFolders = append(m.setupFolders, FolderRec{Folder: "preinstalls", Label: "Preinstalls"})
	m.folderOpen["preinstalls"] = true
	m.selected[setupValue("preinstalls", "preinstall:obsidian")] = true
	m.setupCatPicker = m.rebuildSetupCat()
	m, _ = m.update(tuikit.PickerResultMsg{Value: "item:preinstalls:preinstall:obsidian"})
	if m.top() != scrConfirm {
		t.Fatalf("Enter did not ask, top=%d", m.top())
	}
	if m.pendingAction != "preinstalls-remove" || len(m.pendingArgs) != 1 || m.pendingArgs[0] != "obsidian" {
		t.Fatalf("pendingAction=%q pendingArgs=%q, want preinstalls-remove [obsidian]", m.pendingAction, m.pendingArgs)
	}
	if len(m.pendingInstallPlan) != 0 {
		t.Fatalf("pure preinstall selection stashed an install plan: %q", m.pendingInstallPlan)
	}
}

// TestResumeInstallPlanShowsInstallConfirm: after a removal done, a stashed
// install plan surfaces as its own Install confirmation.
func TestResumeInstallPlanShowsInstallConfirm(t *testing.T) {
	m := initialModel()
	m.nav = []screen{scrMain, scrSetup}
	m.w, m.h = 120, 40
	m.pendingInstallPlan = []string{"apps\treaper"}
	m.setupFolders = []FolderRec{{Folder: "apps", Label: "Apps"}}
	m.setupItems = []SetupItemRec{{Folder: "apps", Key: "reaper", Label: "reaper"}}
	m.setupByValue = map[string]SetupItemRec{
		setupValue("apps", "reaper"): {Folder: "apps", Key: "reaper", Label: "reaper"},
	}
	mm, _ := m.resumeInstallPlan()
	m = mm
	if m.top() != scrConfirm {
		t.Fatalf("stashed install did not confirm, top=%d", m.top())
	}
	if m.pendingAction != "apply" {
		t.Fatalf("pendingAction = %q, want apply", m.pendingAction)
	}
	if len(m.pendingInstallPlan) != 0 {
		t.Fatalf("stash not consumed: %q", m.pendingInstallPlan)
	}
}
