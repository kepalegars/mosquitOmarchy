package main

import (
	"testing"

	tuikit "mosquitomarchy.local/tui-kit"
)

// Esc on the archive prompt used to return before pop(), leaving "Checking
// required archives…" on screen for good.
func TestDownloadPromptEscPops(t *testing.T) {
	m := initialModel()
	m.push(scrConfirm)
	m.pendingAction = "download-assets-prompt"
	m.pendingArgs = []string{"ableton-wires"}
	m.pendingMsg = "Checking required archives…"
	m.confirm = tuikit.NewConfirm(m.pendingMsg, "Cancel", "Download")

	m2, _ := m.update(tuikit.ConfirmResultMsg{Canceled: true})
	if m2.top() == scrConfirm {
		t.Fatalf("Esc left the prompt up")
	}
	if m2.pendingAction != "" || len(m2.pendingArgs) != 0 {
		t.Fatalf("Esc kept the pending state: action=%q args=%v", m2.pendingAction, m2.pendingArgs)
	}
}

// A fetch that lands after the prompt is gone must not repaint anything.
func TestLateAssetMissingIsIgnored(t *testing.T) {
	m := initialModel()
	m.pendingAction = "download-assets-prompt"
	m.pendingArgs = []string{"davinci-resolve"}
	m.pendingMsg = "Checking required archives…"

	m2, _ := m.update(assetMissingMsg{key: "davinci-resolve", items: []AssetMissing{{Name: "x"}}})
	if m2.pendingMsg != "Checking required archives…" {
		t.Fatalf("late result repainted the message: %q", m2.pendingMsg)
	}
}

// With no direct URL the only button is the page, so Yes must open the browser
// (and return to the tree), never start a download.
func TestPageOnlyPromptOpensPage(t *testing.T) {
	m := initialModel()
	m.push(scrConfirm)
	m.pendingAction = "download-assets-prompt"
	m.pendingArgs = []string{"davinci-resolve"}
	m.pendingMsg = "Checking required archives…"
	m.confirm = tuikit.NewConfirm(m.pendingMsg, "Cancel", "Download")

	m2, _ := m.update(assetMissingMsg{key: "davinci-resolve", items: []AssetMissing{{
		Name: "DaVinci_Resolve.zip", Path: "/tmp/x", Page: "https://example.com/download",
	}}})
	if len(m2.pendingArgs) != 2 || m2.pendingArgs[1] != "page" {
		t.Fatalf("page-only prompt not marked: %v", m2.pendingArgs)
	}
	m3, cmd := m2.update(tuikit.ConfirmResultMsg{Yes: true})
	if m3.top() == scrWorking || m3.top() == scrConfirm {
		t.Fatalf("Yes on a page-only prompt left the tree: top=%v", m3.top())
	}
	if cmd == nil {
		t.Fatalf("Yes on a page-only prompt did not launch the opener")
	}
}
