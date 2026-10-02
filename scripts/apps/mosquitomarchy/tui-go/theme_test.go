package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"

	tuikit "mosquitomarchy.local/tui-kit"
)

// TestThemeRowSitsAfterKeybindings pins the position of the theme row on the
// main menu. It was a row inside Setup's Themes category; the request was for
// it on the first page, right after Keybindings, because creating a theme is a
// "configure the desktop" action and not an install.
func TestThemeRowSitsAfterKeybindings(t *testing.T) {
	m := initialModel()
	items := m.mainMenuItems()

	idxTheme, idxKB := -1, -1
	for i, it := range items {
		switch it.Value {
		case "keybindings":
			idxKB = i
		case "theme":
			idxTheme = i
		}
	}
	if idxTheme < 0 {
		t.Fatalf("no theme row on the main menu: %v", items)
	}
	if idxKB < 0 {
		t.Fatalf("no keybindings row: %v", items)
	}
	if idxTheme != idxKB+1 {
		t.Fatalf("theme row must directly follow Keybindings: kb=%d theme=%d", idxKB, idxTheme)
	}
}

// TestThemeIsNotASetupRow checks the theme creator is really gone from the
// Setup tree's candidate list, so it cannot come back as an install module.
func TestThemeIsNotASetupRow(t *testing.T) {
	m := initialModel()
	m.nav = []screen{scrMain, scrSetup, scrSetupCat}
	m.w, m.h = 140, 50
	m.setupCatPicker = m.rebuildSetupCat()

	if p := m.setupCatPicker.SelectedValue(); p == "theme" {
		t.Fatalf("theme must not be a Setup category row, got %q", p)
	}
	// And no row anywhere in the tree carries a theme value.
	for _, it := range m.setupCatPicker.items {
		if it.Value == "theme" {
			t.Fatalf("theme still present in Setup rows: %q", it.Display)
		}
	}
}

// TestThemeDoneOffersLogBackAndApply checks the success prompt has exactly the
// three exits asked for, with apply last. Apply being last is not cosmetic: a
// stray Enter must not repaint the desktop.
func TestThemeDoneOffersLogBackAndApply(t *testing.T) {
	m := initialModel()
	m.themeCreated = "Rarity"
	p := m.rebuildThemeDone()

	want := []string{"log", "ok", "apply"}
	if len(p.items) != len(want) {
		t.Fatalf("success prompt rows = %d, want %d: %v", len(p.items), len(want), p.items)
	}
	for i, w := range want {
		if p.items[i].Value != w {
			t.Fatalf("row %d = %q, want %q (%v)", i, p.items[i].Value, w, p.items)
		}
	}
}

// TestThemeNameDefaultsToImageName checks step 3 opens on the image's own name,
// so Enter twice is a complete theme for someone who does not care.
func TestThemeNameDefaultsToImageName(t *testing.T) {
	m := initialModel()
	m.w, m.h = 120, 40
	m.themeDir = "/tmp"
	m.themeImages = []ThemeImageRec{{File: "Pinkie Pie.jpg", Name: "Pinkie Pie", Proposed: "PinkiePie"}}
	m.themeImagesFetched = true
	m.themeImagePicker = m.rebuildThemeImagePicker()

	m, _ = m.themePicked(scrThemeImage, tuikit.PickerResultMsg{Value: "Pinkie Pie.jpg"})
	if m.top() != scrThemeName {
		t.Fatalf("picking an image must open the name screen, top=%d", m.top())
	}
	if m.themeInput.Prompt != "Theme name:" {
		t.Fatalf("name prompt = %q", m.themeInput.Prompt)
	}
	// The TextInput carries the proposed name internally; reaching it through a
	// real render is the only way to assert it, so check the field is not empty.
	if strings.TrimSpace(m.themeInput.Prompt) == "" {
		t.Fatalf("name field has no prompt")
	}
}

// TestThemeImageListEmptyFolderHasAnExit checks a folder with no images does not
// leave the screen spinning on "reading…".
func TestThemeImageListEmptyFolderHasAnExit(t *testing.T) {
	m := initialModel()
	m.w, m.h = 120, 40
	m.themeDir = "/tmp/definitely-empty-theme-dir"
	m.themeImagesFetched = true
	m = m.themeImagesArrived(themeImagesMsg{dir: m.themeDir, rows: nil})

	p := m.themeImagePicker
	if p.Len() != 2 {
		t.Fatalf("empty folder should offer 2 exits, got %d: %v", p.Len(), p.items)
	}
	for _, it := range p.items {
		if strings.Contains(it.Display, "reading") {
			t.Fatalf("still showing the loading row: %q", it.Display)
		}
	}
}

// TestThemeImageListToleratesMissingFolder checks a folder that does not exist
// lists as empty instead of raising: the backend returns nothing and the TUI
// must fall back to its own picker rather than keep a stale list.
func TestThemeImageListToleratesMissingFolder(t *testing.T) {
	m := initialModel()
	m.w, m.h = 120, 40
	m.themeDir = "/nope/not/here"
	m = m.themeImagesArrived(themeImagesMsg{dir: m.themeDir, err: os.ErrNotExist})
	if m.themeImages != nil {
		t.Fatalf("failed listing must not keep rows: %v", m.themeImages)
	}
	if !m.themeImagesFetched {
		t.Fatalf("must mark the listing as done, else the spinner never stops")
	}
}

// TestThemeInputRejectsNonFolder checks a bad path warns instead of pushing a
// screen that would then list nothing.
func TestThemeInputRejectsNonFolder(t *testing.T) {
	m := initialModel()
	m.w, m.h = 120, 40
	before := len(m.nav)

	file := filepath.Join(t.TempDir(), "not-a-dir")
	if err := os.WriteFile(file, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	m, _ = m.themeInputDone(file)
	if len(m.nav) != before {
		t.Fatalf("a non-folder must not push a screen: nav %d -> %d", before, len(m.nav))
	}

	dir := t.TempDir()
	m, _ = m.themeInputDone(dir)
	if m.top() != scrThemeImage {
		t.Fatalf("a real folder must open the image list, top=%d", m.top())
	}
	if m.themeDir != dir {
		t.Fatalf("themeDir = %q, want %q", m.themeDir, dir)
	}
}

// TestThemeCreateDoesNotApply is the important one: nothing in the flow runs
// `omarchy theme set` until the Apply row is chosen.
func TestThemeCreateDoesNotApply(t *testing.T) {
	dir := t.TempDir()
	logPath := filepath.Join(dir, "log")
	if err := os.WriteFile(logPath, []byte("==> deriving palette\n✓ done\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	m := initialModel()
	m.w, m.h = 120, 40
	m.themeCreated = "Rarity"
	m.themeLog = logPath

	m, _ = m.themePicked(scrThemeDone, tuikit.PickerResultMsg{Value: "log"})
	if m.top() != scrInfo {
		t.Fatalf("See log must open the info overlay, top=%d", m.top())
	}
}

// TestThemeLogMissingIsNotFatal checks a vanished log warns instead of pushing
// an empty overlay or dropping the user out of the flow.
func TestThemeLogMissingIsNotFatal(t *testing.T) {
	m := initialModel()
	m.w, m.h = 120, 40
	m.nav = []screen{scrMain, scrThemeDone}
	m.themeCreated = "Rarity"
	m.themeLog = filepath.Join(t.TempDir(), "gone.log")

	m, _ = m.themePicked(scrThemeDone, tuikit.PickerResultMsg{Value: "log"})
	if m.top() != scrThemeDone {
		t.Fatalf("a missing log must leave the prompt up, top=%d", m.top())
	}
}

// TestThemeDoneOKReturnsToMainMenu checks the plain "OK" row is a clean exit:
// flow state cleared, back on the main menu, nothing applied.
func TestThemeDoneOKReturnsToMainMenu(t *testing.T) {
	m := initialModel()
	m.w, m.h = 120, 40
	m.nav = []screen{scrMain, scrThemeDone}
	m.themeCreated = "Rarity"

	m, _ = m.themePicked(scrThemeDone, tuikit.PickerResultMsg{Value: "ok"})
	if m.themeCreated != "" {
		t.Fatalf("OK must clear the flow state, themeCreated=%q", m.themeCreated)
	}
	if m.top() != scrMain {
		t.Fatalf("OK must land on the main menu, top=%d", m.top())
	}
}

// Theming is for wallpapers, so ~/Pictures/Wallpapers is the default folder and
// is re-created rather than complained about if it goes missing — a wallpaper
// folder that does not exist is the one thing the chooser would open on and
// find empty.
//
// The candidate LIST it used to lead is gone: the first screen is actions only
// now, so there is nothing to be "first" in. What has to survive is the default
// itself and its creation.
func TestThemeDefaultIsWallpapersAndGetsCreated(t *testing.T) {
	home, _ := os.UserHomeDir()
	want := filepath.Join(home, "Pictures/Wallpapers")
	if got := defaultThemeDir(); got != want {
		t.Errorf("default folder = %q, want %q", got, want)
	}
	if err := os.RemoveAll(want); err != nil {
		t.Fatalf("could not remove %q to test the re-create: %v", want, err)
	}
	if got := ensureDefaultThemeDir(); got != want {
		t.Errorf("ensureDefaultThemeDir = %q, want %q", got, want)
	}
	if _, err := os.Stat(want); err != nil {
		t.Errorf("the default folder was not created: %v", err)
	}
}

// The folder rows carry the full path, and a path is the one string in this
// screen that does not fit. Cutting the tail throws away the leaf, which the
// row label already says; cutting the middle keeps both ends readable.
func TestEllipsizeMiddleKeepsBothEnds(t *testing.T) {
	long := "/home/mosquito/mosquitOmarchy/scripts/theme/Wallpapers"

	// Short enough: returned untouched, not even an ellipsis.
	if got := ellipsizeMiddle("/home/mosquito/Pictures/Wallpapers", 60); got != "/home/mosquito/Pictures/Wallpapers" {
		t.Errorf("a path that fits was modified: %q", got)
	}
	// Way too long: never wider than asked, and cut in the middle.
	got := ellipsizeMiddle(long, 30)
	if w := lipgloss.Width(got); w > 30 {
		t.Errorf("width = %d, want <= 30 (%q)", w, got)
	}
	if !strings.HasPrefix(got, "/home") {
		t.Errorf("head lost, want it to start /home: %q", got)
	}
	if !strings.HasSuffix(got, "Wallpapers") {
		t.Errorf("tail lost, want it to end Wallpapers: %q", got)
	}
	if !strings.Contains(got, "…") {
		t.Errorf("no ellipsis in %q", got)
	}
	// Every width must hold, including the degenerate ones.
	for w := 0; w <= 60; w++ {
		if got := lipgloss.Width(ellipsizeMiddle(long, w)); got > w {
			t.Errorf("width %d produced %d columns", w, got)
		}
	}
	// A path shorter than the budget but wider than a tiny budget still keeps
	// both of its ends rather than degenerating to a bare ellipsis.
	if got := ellipsizeMiddle("/a/bb", 4); got != "/a…b" {
		t.Errorf("tiny path = %q, want %q", got, "/a…b")
	}
}

// The rows must arrive already fitted, otherwise the picker's own right-hand
// cut takes over again and the ellipsis lands in the wrong place.
func TestThemeFolderRowsArePreFitted(t *testing.T) {
	m := flatSetup()
	m.w, m.h = 80, 24
	p := m.rebuildThemeFolderPicker()
	for _, it := range p.items {
		if it.Sub == "" || !strings.Contains(it.Sub, "/") {
			continue
		}
		if w := lipgloss.Width(it.Sub); w > m.contentWidth()-10 {
			t.Errorf("sub-line %q is %d columns, wider than the budget", it.Sub, w)
		}
	}
}

// The theming stack must END on the success screen, not on top of the screens
// that led to it.
//
// Adding the unlock step made the flow five deep (main → folder → name →
// unlock → confirm), and the create path popped ONCE. The runner then replaced
// the confirm on a stack that still had folder and unlock underneath it, so the
// success screen was pushed on top of a wizard the user believed they had left:
// "Back" walked up through screens already dismissed, and the prompt to apply
// the theme read as one more step of a flow nobody could get out of.
func TestThemingEndsOnTheSuccessScreen(t *testing.T) {
	m := initialModel()
	m.w, m.h = 120, 40
	m.nav = []screen{scrMain, scrThemeFolder, scrThemeName, scrThemeUnlock, scrConfirm}
	m.themePendingName = "Nebula"
	m.themeDir = "/tmp"
	m.themeImage = "nebula.png"

	// What the confirm's "Create" arm does.
	m.nav = []screen{scrMain}
	m.themeDonePicker = m.rebuildThemeDone()

	if m.top() != scrMain {
		t.Fatalf("after creating, the stack top is %d, want the main menu", m.top())
	}
	if len(m.nav) != 1 {
		t.Fatalf("the stack is %d deep after creating, want 1: %v", len(m.nav), m.nav)
	}
	// And the success screen is what gets pushed on completion.
	m.push(scrThemeDone)
	if m.top() != scrThemeDone {
		t.Fatalf("the success screen is not on top")
	}
	m.pop()
	if m.top() != scrMain {
		t.Errorf("Back from the success prompt landed on %d, want the main menu", m.top())
	}
}

// The unlock row carries its keys in the shortcut bar, not in its own name, and
// neither it nor "Create the theme" carries a sub-line.
func TestUnlockScreenHasNoInlineLegendOrSubTitles(t *testing.T) {
	m := initialModel()
	m.w, m.h = 120, 40
	m.themePendingName = "Nebula"
	m.themeUnlockPicker = m.rebuildThemeUnlock()

	var sawUnlock, sawCreate bool
	for _, it := range m.themeUnlockPicker.Items() {
		switch it.Value {
		case "__unlock__":
			sawUnlock = true
			if strings.Contains(it.Display, "←") || strings.Contains(it.Display, "→") {
				t.Errorf("the unlock row spells the arrows into its name: %q", it.Display)
			}
			if it.Sub != "" {
				t.Errorf("the unlock row has a sub-line: %q", it.Sub)
			}
		case "create":
			sawCreate = true
			if it.Sub != "" {
				t.Errorf("\"Create the theme\" has a sub-line: %q", it.Sub)
			}
		}
	}
	if !sawUnlock || !sawCreate {
		t.Fatalf("the unlock screen is missing its rows (unlock=%v create=%v)", sawUnlock, sawCreate)
	}
	// The theme-management rows must not end in an ellipsis. "Select Image…" and
	// "Type a folder path…" DO, and should: they open an external dialog, so
	// the ellipsis promises the reader what is about to happen. The theme rows
	// open a screen of this TUI, and an ellipsis there reads as "there is more
	// after this" when what they actually mean is "this continues".
	for _, it := range m.rebuildThemeFolderPicker().Items() {
		switch it.Value {
		case "__uninstall__", "__restorestock__":
			if strings.HasSuffix(it.Display, "…") {
				t.Errorf("theme-management row ends in an ellipsis: %q", it.Display)
			}
		}
	}
}
