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

// TestUpdateRebootConfirm: answering the post-update confirm quits to the
// new version on Quit, and shows the log on See log.
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
	if mm.top() != scrInfo {
		t.Fatalf("See log did not open the log, top=%v", mm.top())
	}
	m = newConfirm()
	mm, _ = m.update(tuikit.ConfirmResultMsg{Yes: false})
	if !mm.quit {
		t.Fatalf("Quit did not quit")
	}
}
