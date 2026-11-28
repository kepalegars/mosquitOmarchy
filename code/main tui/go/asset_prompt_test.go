package main

import (
	"os"
	"path/filepath"
	"strings"
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

// A ready archive clears the greyed row and its stale "needs …" info.
func TestAssetReadyUngreysRow(t *testing.T) {
	m := initialModel()
	m.setupItems = []SetupItemRec{{
		Folder: "apps", Key: "davinci-resolve", Disabled: true,
		Needs: "davinci-resolve", Info: "DaVinci Resolve — needs DaVinci_Resolve_*.zip in code/modules/Apps/davinci/",
	}}
	m.setupByValue = map[string]SetupItemRec{
		setupValue("apps", "davinci-resolve"): m.setupItems[0],
	}

	m2, _ := m.update(assetReadyMsg{keys: []string{"davinci-resolve"}})
	it := m2.setupItems[0]
	if it.Needs != "" || it.Disabled {
		t.Fatalf("row still gated: needs=%q disabled=%v", it.Needs, it.Disabled)
	}
	if strings.Contains(it.Info, "needs DaVinci") {
		t.Fatalf("stale archive note kept: %q", it.Info)
	}
	if got := m2.setupByValue[setupValue("apps", "davinci-resolve")]; got.Needs != "" || got.Disabled {
		t.Fatalf("setupByValue still gated: %+v", got)
	}
}

// The watcher sees a file appear, asks for verification once its size+mtime
// are stable, and reports it gone when the file is removed.
func TestScanAssetsAppearAndDisappear(t *testing.T) {
	dir := t.TempDir()
	globs := map[string][]string{"k": {filepath.Join(dir, "*.zip")}}

	empty := scanAssetsCmd(globs, map[string]string{}, map[string]int{}, map[string]string{})().(assetScanMsg)
	if len(empty.verify) != 0 || len(empty.gone) != 0 {
		t.Fatalf("empty dir: verify=%v gone=%v", empty.verify, empty.gone)
	}

	p := filepath.Join(dir, "archive.zip")
	if err := os.WriteFile(p, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	first := scanAssetsCmd(globs, empty.sig, empty.stable, empty.checked)().(assetScanMsg)
	if len(first.verify) != 0 {
		t.Fatalf("verified on the first sighting: %v", first.verify)
	}
	second := scanAssetsCmd(globs, first.sig, first.stable, first.checked)().(assetScanMsg)
	if len(second.verify) != 0 {
		t.Fatalf("verified after one quiet tick: %v", second.verify)
	}
	third := scanAssetsCmd(globs, second.sig, second.stable, second.checked)().(assetScanMsg)
	if len(third.verify) != 1 || third.verify[0] != "k" {
		t.Fatalf("stable file not verified: %v", third.verify)
	}

	if err := os.Remove(p); err != nil {
		t.Fatal(err)
	}
	gone := scanAssetsCmd(globs, third.sig, third.stable, third.checked)().(assetScanMsg)
	if len(gone.gone) != 1 || gone.gone[0] != "k" {
		t.Fatalf("removal not noticed: %v", gone.gone)
	}
}

// A disappeared archive greys the row again, note included.
func TestAssetGoneRegreysRow(t *testing.T) {
	m := initialModel()
	m.setupItems = []SetupItemRec{{Folder: "apps", Key: "k", Info: "desc"}}
	m.setupByValue = map[string]SetupItemRec{setupValue("apps", "k"): m.setupItems[0]}
	m.asset.ready["k"] = true
	m.asset.notes["k"] = "needs X in code/modules/Apps/k/"

	m.setAssetGated("k")
	it := m.setupItems[0]
	if it.Needs != "k" || !it.Disabled {
		t.Fatalf("row not gated again: needs=%q disabled=%v", it.Needs, it.Disabled)
	}
	if !strings.Contains(it.Info, "needs X") {
		t.Fatalf("note not restored: %q", it.Info)
	}
}

// A row whose archive was present at startup is watched too, so deleting the
// file greys it without any prior "ready" event.
func TestAssetGoneRegreysUngatedRow(t *testing.T) {
	m := initialModel()
	m.setupItems = []SetupItemRec{{Folder: "apps", Key: "k", Info: "desc"}}
	m.setupByValue = map[string]SetupItemRec{setupValue("apps", "k"): m.setupItems[0]}
	m.asset.notes["k"] = "needs X in code/modules/Apps/k/"

	m.setAssetGated("k")
	it := m.setupItems[0]
	if it.Needs != "k" || !it.Disabled {
		t.Fatalf("row not gated: needs=%q disabled=%v", it.Needs, it.Disabled)
	}
	if !strings.Contains(it.Info, "needs X") {
		t.Fatalf("note not added: %q", it.Info)
	}
}

// learnAssets registers the globs of a row that is NOT greyed, so the watcher
// can notice its archive disappearing.
func TestLearnAssetsWatchesPresentRow(t *testing.T) {
	m := initialModel()
	m.setupItems = []SetupItemRec{{
		Folder: "apps", Key: "k", NeedsFiles: []string{"/tmp/x/*.zip"}, NeedsNote: "needs x",
	}}
	m.learnAssets()
	if got := m.asset.globs["k"]; len(got) != 1 || got[0] != "/tmp/x/*.zip" {
		t.Fatalf("globs not learned: %v", got)
	}
	if m.asset.notes["k"] != "needs x" {
		t.Fatalf("note not learned: %q", m.asset.notes["k"])
	}
}
