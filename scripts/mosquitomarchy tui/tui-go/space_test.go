package main

import (
	"strings"
	"testing"

	tuikit "mosquitomarchy.local/tui-kit"
)

func TestSpaceLineInstallKnown(t *testing.T) {
	line := spaceLine("install", DiskRec{FreeKB: 10 * 1024 * 1024, NeedKB: 2 * 1024 * 1024})
	for _, want := range []string{"10.0 GiB free", "needs ~2.0 GiB"} {
		if !strings.Contains(line, want) {
			t.Fatalf("line %q missing %q", line, want)
		}
	}
	if strings.Contains(line, "after") {
		t.Fatalf("line %q should not show a post-install estimate", line)
	}
}

func TestSpaceLineUninstallKnown(t *testing.T) {
	line := spaceLine("uninstall", DiskRec{FreeKB: 2048, FreedKB: 1024})
	if line != "Disk: frees ~1 MiB" {
		t.Fatalf("line = %q, want only the freed size", line)
	}
}

func TestSpaceLineInstallNotEnough(t *testing.T) {
	r := DiskRec{FreeKB: 1024, NeedKB: 2 * 1024 * 1024}
	if !spaceWarning(r) {
		t.Fatal("shortfall not detected")
	}
	if !strings.Contains(warningText(true), notEnough) || !strings.Contains(warningText(false), notEnough) {
		t.Fatal("the warning must stay red/readable in both blink phases")
	}
}

func TestSpaceLineUnknownParts(t *testing.T) {
	line := spaceLine("uninstall", DiskRec{FreeKB: 2048, FreedUnknown: true})
	if line != "Disk: frees a bunch of bananas" {
		t.Fatalf("line = %q, want no free-space half and a bananas freed size", line)
	}
}

func TestSpaceLineShowsPartialEstimate(t *testing.T) {
	line := spaceLine("install", DiskRec{FreeKB: 10 * 1024 * 1024, NeedKB: 1024 * 1024, NeedUnknown: true})
	if !strings.Contains(line, "needs ~1.0 GiB and some bananas") {
		t.Fatalf("line %q should show the known part and some bananas", line)
	}
	if strings.Contains(line, "needs a bunch of bananas") {
		t.Fatalf("line %q threw away the known part", line)
	}
	line = spaceLine("uninstall", DiskRec{FreeKB: 2048, FreedKB: 1024, FreedUnknown: true})
	if line != "Disk: frees ~1 MiB and some bananas" {
		t.Fatalf("line %q should show the known freed part and some bananas, with no free half", line)
	}
}

func TestApplySpaceMsgIgnoresStaleAnswer(t *testing.T) {
	m := model{nav: []screen{scrConfirm}}
	m.spaceSeq = 2
	m.spaceOp = "install"
	m.spaceBase = "Install x?"
	m.pendingMsg = "Install x?" + diskChecking
	m.confirm.Message = m.pendingMsg
	m.applySpaceMsg(spaceMsg{seq: 1, rec: DiskRec{FreeKB: 1024}})
	if !strings.Contains(m.confirm.Message, diskChecking) {
		t.Fatal("a stale answer rewrote the prompt")
	}
	m.applySpaceMsg(spaceMsg{seq: 2, rec: DiskRec{FreeKB: 1024}})
	if strings.Contains(m.confirm.Message, diskChecking) || !strings.Contains(m.confirm.Message, "1 MiB free") {
		t.Fatalf("current answer not applied: %q", m.confirm.Message)
	}
}

func TestSpaceWarningWithPartialNeed(t *testing.T) {
	if !spaceWarning(DiskRec{FreeKB: 1024, NeedKB: 2048, NeedUnknown: true}) {
		t.Fatal("a known need already over free must warn even with unknown extra")
	}
	if spaceWarning(DiskRec{FreeKB: 4096, NeedKB: 2048, NeedUnknown: true}) {
		t.Fatal("unknown extra alone is not proof of a shortfall")
	}
	if !spaceWarning(DiskRec{FreeKB: 4096, NeedKB: 2048, TempShort: true}) {
		t.Fatal("an install that lacks scratch space must warn even when the final payload fits")
	}
	if spaceWarning(DiskRec{FreeKB: 1024, FreeUnknown: true, NeedKB: 2048, TempShort: true}) {
		t.Fatal("without a free-space answer neither half can be proven short")
	}
}

func TestWithSpaceThenPushKeepsWarningBase(t *testing.T) {
	m := model{nav: []screen{scrSetup}}
	m.pendingMsg, _ = m.withSpace("Install x?", "install", []string{"x"})
	m.push(scrConfirm)
	m.applySpaceMsg(spaceMsg{seq: m.spaceSeq, rec: DiskRec{FreeKB: 1024, NeedKB: 2048}})
	if !m.spaceShort || !strings.Contains(m.confirm.Message, notEnough) {
		t.Fatalf("warning lost after push: short=%v msg=%q", m.spaceShort, m.confirm.Message)
	}
}

func TestSpaceWarningSetsBlink(t *testing.T) {
	m := model{nav: []screen{scrConfirm}}
	m.spaceSeq = 1
	m.spaceOp = "install"
	m.spaceBase = "Install x?"
	m.applySpaceMsg(spaceMsg{seq: 1, rec: DiskRec{FreeKB: 1024, NeedKB: 2048}})
	if !m.spaceShort {
		t.Fatal("shortfall did not arm the warning")
	}
	if !strings.Contains(m.confirm.Message, notEnough) {
		t.Fatalf("message %q missing the warning", m.confirm.Message)
	}
	on := m.spaceBlinkOn
	m, _ = m.update(blinkMsg{})
	if m.spaceBlinkOn == on {
		t.Fatal("blink did not toggle the warning")
	}
}

// The warning must always sit on its own line: glued to the disk estimate it
// could be wrapped in half, so the phrase flickered across two rows.
func TestSpaceWarningGetsItsOwnLine(t *testing.T) {
	m := model{nav: []screen{scrConfirm}}
	m.spaceSeq = 1
	m.spaceOp = "install"
	m.spaceBase = "Install x?"
	m.applySpaceMsg(spaceMsg{seq: 1, rec: DiskRec{FreeKB: 1024, NeedKB: 2048}})
	if !strings.Contains(m.pendingMsg, "\n\n"+warningText(m.spaceBlinkOn)) {
		t.Fatalf("warning is not on its own line: %q", m.pendingMsg)
	}
	if strings.Contains(m.pendingMsg, " · "+warningText(m.spaceBlinkOn)) {
		t.Fatalf("warning is still glued to the disk line: %q", m.pendingMsg)
	}
}

func TestSpaceWarningRendersInConfirm(t *testing.T) {
	m := model{nav: []screen{scrConfirm}}
	m.spaceSeq = 1
	m.spaceOp = "install"
	m.spaceBase = "Install x?"
	m.applySpaceMsg(spaceMsg{seq: 1, rec: DiskRec{FreeKB: 1024, NeedKB: 2048}})
	m.confirm = tuikit.NewConfirm(m.pendingMsg, "Cancel", "Install")
	if !strings.Contains(m.confirm.View(), notEnough) {
		t.Fatalf("confirm view dropped the warning: %q", m.confirm.View())
	}
}
