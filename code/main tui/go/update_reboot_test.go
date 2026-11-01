package main

import (
	"testing"

	tuikit "mosquitomarchy.local/tui-kit"
)

// TestWantsSelfRebuild: only a modules update that included the manager
// leads to the quit-to-new-version confirm.
func TestWantsSelfRebuild(t *testing.T) {
	if !wantsSelfRebuild("update-modules", []string{"reaper", "mosquitomarchy"}) {
		t.Fatalf("modules update with the manager should offer reboot")
	}
	if wantsSelfRebuild("update-modules", []string{"reaper"}) {
		t.Fatalf("modules update without the manager should not offer reboot")
	}
	if wantsSelfRebuild("update-repo", nil) {
		t.Fatalf("repo update is matched by action, not by helper")
	}
}

// TestUpdateRebootConfirm: answering the post-update confirm restarts
// through the dispatcher on Restart, shows the log on See log, and goes
// back on Esc. There is no plain quit: Restart quits AND relaunches.
func TestUpdateRebootConfirm(t *testing.T) {
	newConfirm := func() model {
		m := initialModel()
		m.nav = []screen{scrMain, scrUpdate, scrConfirm}
		m.w, m.h = 100, 34
		m.pendingAction = "update-reboot"
		m.lastOutput = "some log"
		return m
	}
	m := newConfirm()
	mm, cmd := m.update(tuikit.ConfirmResultMsg{Yes: true})
	_ = cmd
	if !mm.quit || !mm.restart {
		t.Fatalf("Restart did not ask for a relaunching quit, quit=%v restart=%v", mm.quit, mm.restart)
	}
	m = newConfirm()
	mm, _ = m.update(tuikit.ConfirmResultMsg{Yes: false})
	if mm.quit || mm.restart {
		t.Fatalf("See log must not quit, quit=%v restart=%v", mm.quit, mm.restart)
	}
	if mm.top() != scrInfo {
		t.Fatalf("See log did not open the log, top=%v", mm.top())
	}
	m = newConfirm()
	mm, _ = m.update(tuikit.ConfirmResultMsg{Canceled: true})
	if mm.quit || mm.restart || mm.top() != scrUpdate {
		t.Fatalf("Esc must go back to Update, quit=%v restart=%v top=%v", mm.quit, mm.restart, mm.top())
	}
}

// TestUpdateModuleLabel: the Update screen rows are bare "id - vX.Y.Z",
// never the catalog descriptions.
func TestUpdateModuleLabel(t *testing.T) {
	m := initialModel()
	m.updateRec.RepoVersion = "1.0.0"
	it := ItemRec{Key: "reaper", Label: "REAPER + Hyprland/Wayland integration, and its UI scale is set"}
	if got := updateModuleLabel(m, it); got != "reaper - v1.0.0" {
		t.Fatalf("row = %q, want %q", got, "reaper - v1.0.0")
	}
	m.updateRec.RepoVersion = ""
	if got := updateModuleLabel(m, it); got != "reaper" {
		t.Fatalf("row without version = %q, want %q", got, "reaper")
	}
}
