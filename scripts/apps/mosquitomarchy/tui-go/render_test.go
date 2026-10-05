package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	tuikit "mosquitomarchy.local/tui-kit"
)

// TestEscAtMainConfirms checks Esc at the main menu opens the exit
// confirmation instead of quitting outright.
func TestEscAtMainConfirms(t *testing.T) {
	m := initialModel()
	m.w, m.h = 120, 40
	m, _ = m.update(tuikit.PickerResultMsg{Canceled: true})
	if m.top() != scrConfirm || m.pendingAction != "close" {
		t.Fatalf("esc at main should open the close confirm: top=%d action=%s", m.top(), m.pendingAction)
	}
}

// TestBackupOptionsArrows checks Left/Right cycles/toggles the focused Backup
// option.
func TestBackupOptionsArrows(t *testing.T) {
	m := initialModel()
	m.nav = []screen{scrMain, scrBackup, scrBackupOptions}
	m.w, m.h = 120, 40
	m.backupOpts = BackupOpts{VST: "list", Keepass: true, HasKeep: true}
	m.backupOptPicker = m.rebuildBackupOptions()
	// Select the VST row BY VALUE, not by index. The rows have been reordered
	// before (the archive-name row was added above it) and the index form broke
	// silently: the test still ran, it just drove a different row, so a change
	// to this list could break what the test was checking without failing it.
	m.backupOptPicker = m.backupOptPicker.SelectValue("vst")
	if got := m.backupOptPicker.SelectedValue(); got != "vst" {
		t.Fatalf("could not select the VST row, cursor is on %q", got)
	}
	m, _ = m.update(tuikit.PickerSortMsg{Dir: 1})
	if m.backupOpts.VST != "full" {
		t.Fatalf("right should cycle VST list->full, got %q", m.backupOpts.VST)
	}
	m, _ = m.update(tuikit.PickerSortMsg{Dir: -1})
	if m.backupOpts.VST != "list" {
		t.Fatalf("left should cycle VST back to list, got %q", m.backupOpts.VST)
	}
}

// TestSetupLevel1Markers checks the Setup level-1 rows: a category with
// checked items shows a ■ and its selected count, and "Install selection" is
// disabled while nothing is checked.
func TestSetupLevel1Markers(t *testing.T) {
	// Setup is ONE flat page now: category rows with their modules indented
	// under them. This checks the parts that survived the rework — the "n/m"
	// count on a category, the tree rows, and the removal of the
	// "Install selection" row that Enter and `a` replaced.
	newModel := func(selectReaper bool, open map[string]bool) model {
		m := initialModel()
		m.nav = []screen{scrMain, scrSetup}
		m.w, m.h = 120, 40
		m.setupFolders = []FolderRec{{Folder: "apps", Label: "Apps"}, {Folder: "tuis", Label: "TUIs"}}
		m.setupItems = []SetupItemRec{
			{Folder: "apps", Key: "reaper", Label: "reaper"},
			{Folder: "tuis", Key: "bat", Label: "bat"},
		}
		if selectReaper {
			m.selected[setupValue("apps", "reaper")] = true
		}
		for k, v := range open {
			m.folderOpen[k] = v
		}
		m.setupPicker = m.rebuildSetup()
		return m
	}
	find := func(m model, value string) tuikit.PickerItem {
		for _, it := range m.setupPicker.items {
			if it.Value == value {
				return it
			}
		}
		t.Fatalf("row %q not found in %d rows", value, len(m.setupPicker.items))
		return tuikit.PickerItem{}
	}

	// Open the "apps" folder so its module row is present.
	m := newModel(true, map[string]bool{"apps": true})
	apps := find(m, folderValue("apps"))
	if !strings.Contains(apps.Suffix, "1/1") {
		t.Fatalf("apps row should count its selection: suffix=%q", apps.Suffix)
	}
	if !apps.Folder {
		t.Fatal("apps row must be flagged Folder")
	}
	// The module lives on the SAME page now, indented under its category.
	leaf := find(m, setupValue("apps", "reaper"))
	if !strings.Contains(leaf.Display, "reaper") {
		t.Fatalf("module row missing on the flat page: %q", leaf.Display)
	}
	// A collapsed folder shows no children.
	closed := newModel(true, map[string]bool{"apps": false})
	for _, it := range closed.setupPicker.items {
		if it.Value == setupValue("apps", "reaper") {
			t.Fatal("collapsed folder should not list its children")
		}
	}
	// The "Install selection" row is gone; Enter / `a` apply directly.
	for _, it := range m.setupPicker.items {
		if it.Value == "install-selection" || it.Value == "uninstall-selection" {
			t.Fatalf("selection row %q should no longer exist", it.Value)
		}
	}
	if got := m.applyPlanCat("apps"); len(got) != 1 || !strings.Contains(got[0], "reaper") {
		t.Fatalf("applyPlanCat(apps) = %q", got)
	}
}

// TestUpdateBodyNoDuplicate checks the Update screen states both "no update"
// cases exactly once and keeps no placeholder row (it used to print the same
// "no changed installed modules" twice).
func TestUpdateBodyNoDuplicate(t *testing.T) {
	m := initialModel()
	m.nav = []screen{scrMain, scrUpdate}
	m.w, m.h = 120, 40
	m.updateRec = UpdateRec{}
	m.updatePicker = m.rebuildUpdate()
	for _, it := range m.updatePicker.items {
		if strings.Contains(it.Display, "no changed installed modules") {
			t.Fatal("placeholder row still present in the Update picker")
		}
	}
	body := m.updateBody()
	if n := strings.Count(body, "nothing to re-apply for the installed modules"); n != 1 {
		t.Fatalf("expected exactly one 'no update for installed modules' line, got %d:\n%s", n, body)
	}
	if n := strings.Count(body, "all scripts are up to date!"); n != 1 {
		t.Fatalf("expected the up-to-date line once, got %d:\n%s", n, body)
	}
}

// Setup must NOT carry an Update row, ever. It used to appear only when a
// background check had already found something, so it popped in and out of the
// tree and moved every other row when it did. Update is its own entry on the
// main menu, and this asserts Setup stays free of it.
func TestSetupHasNoUpdateRow(t *testing.T) {
	for _, rec := range []UpdateRec{{}, {RepoUpdate: true}, {Modules: []ItemRec{{Key: "reaper"}}}} {
		m := initialModel()
		m.nav = []screen{scrMain, scrSetup}
		m.w, m.h = 120, 40
		m.setupFolders = []FolderRec{{Folder: "apps", Label: "Apps"}}
		m.setupItems = []SetupItemRec{{Folder: "apps", Key: "x", Label: "x"}}
		m.updateRec = rec
		m.setupPicker = m.rebuildSetup()
		for _, it := range m.setupPicker.items {
			if it.Value == "updates" {
				t.Fatalf("Setup grew an Update row back (update=%+v)", rec)
			}
		}
	}
}

// TestStatusScroll checks the status screen actually scrolls, and that the
// TestStatusScroll asserts the Status picker is navigable and its render never
// panics across the full module list. (It used to be a static Info dump with a
// scroll offset; the screen is a real cursor-bearing picker now.)
func TestStatusScroll(t *testing.T) {
	m := initialModel()
	m.nav = []screen{scrMain, scrStatus}
	m.w, m.h = 100, 24
	recs := make([]StatusRec, 60)
	for i := range recs {
		recs[i] = StatusRec{Id: fmt.Sprintf("m%02d", i), State: "ok", Category: "apps"}
	}
	m.statusRecs = recs
	m.statusPicker = m.rebuildStatus()
	if len(m.statusPicker.items) == 0 {
		t.Fatal("status picker is empty")
	}
	first := m.statusPicker.Index()
	view := m.statusPicker.View()
	if view == "" {
		t.Fatal("status rendered an empty frame")
	}
	m, _ = m.update(tea.KeyMsg{Type: tea.KeyDown})
	if m.statusPicker.Index() == first {
		t.Fatal("status did not move the cursor down")
	}
}

// TestViewRenders covers the render path for every screen: a WindowSizeMsg
// then a View() must never panic or produce an empty frame, even before any
// backend data arrives (all fetch commands fail to launch and show toasts in
// this headless test — the screens must still render).
func TestViewRenders(t *testing.T) {
	screens := []screen{scrMain, scrStatus, scrSetup, scrSetupCat, scrUpdate, scrBackup,
		scrBackupRestore, scrBackupOptions, scrBackupApps, scrConfirm, scrWorking, scrPassphrase, scrInfo}
	for _, s := range screens {
		m := initialModel()
		m.nav = []screen{s}
		m, _ = m.update(tea.WindowSizeMsg{Width: 120, Height: 40})
		switch s {
		case scrStatus:
			m.statusRecs = []StatusRec{
				{Id: "reaper", State: "ok", Category: "apps"},
				{Id: "bad", State: "missing", Category: "apps", Detail: "no binary"}}
			m.statusPicker = m.rebuildStatus()
		case scrSetup:
			m.setupFolders = []FolderRec{{Folder: "apps", Label: "Apps"}, {Folder: "mosquito", Label: "mosquito", Accent: true}}
			m.setupItems = []SetupItemRec{
				{Folder: "apps", Key: "reaper", Label: "reaper", Info: "REAPER integration"},
				{Folder: "mosquito", Key: "live-mode", Label: "mosquito-live-mode", Info: "Live mode"},
			}
			m.setupPicker = m.rebuildSetup()
		case scrSetupCat:
			m.setupFolders = []FolderRec{{Folder: "mosquito", Label: "mosquito", Accent: true}}
			m.setupItems = []SetupItemRec{
				{Folder: "mosquito", Key: "live-mode", Label: "mosquito-live-mode", Info: "Live mode"},
			}
			m.setupCat = "mosquito"
			m.folderOpen["mosquito"] = true
			m.setupCatPicker = m.rebuildSetupCat()
		case scrUpdate:
			m.updateRec = UpdateRec{Modules: []ItemRec{{Key: "b", Label: "Mod B"}}}
			m.updatePicker = m.rebuildUpdate()
		case scrBackup:
			m.backupPicker = newNavPicker("", backupActions()).SetSize(m.contentSize())
		case scrBackupRestore:
			m.backupRecs = []BackupRec{{File: "omarchy-backup-x.tar.gz", Size: "1M", Date: "2026-09-18"}}
			m.backupPicker = newNavPicker("", m.backupsList()).SetSize(m.contentSize())
		case scrBackupOptions:
			m.backupOpts.HasKeep = true
			m.backupOptPicker = m.rebuildBackupOptions()
		case scrBackupApps:
			m.backupFolders = []FolderRec{{Folder: "apps", Label: "Apps"}}
			m.backupItems = []SetupItemRec{{Folder: "apps", Key: "APP reaper", Label: "reaper", Checked: true}}
			m.backupChecked[setupValue("apps", "APP reaper")] = true
			m.backupOpen["apps"] = true
			m.backupAppsPicker = m.rebuildBackupApps()
		case scrConfirm:
			m.confirm = tuikit.NewConfirm("Really?", "Cancel", "Yes")
		case scrPassphrase:
			m.passInput = tuikit.NewPasswordInput("Passphrase", "")
		case scrInfo:
			m.info = tuikit.NewInfo("Some info about the highlighted item.").SetSize(m.contentSize())
		case scrWorking:
			m.runner = tuikit.NewRunner().SetSize(m.contentSize())
		}
		m, _ = m.update(tea.WindowSizeMsg{Width: 120, Height: 40})
		out := m.View()
		if out == "" {
			t.Fatalf("screen %d rendered empty", s)
		}
		if m.quit {
			t.Fatalf("screen %d unexpectedly set quit", s)
		}
		if s == scrMain && !strings.Contains(out, "mosquit") && !strings.Contains(out, "m a r c h y") {
			t.Logf("main frame (banner folded to subtitle):\n%s", out)
		}
	}
}

// TestSetupTreeToggles exercises the Setup tree: expanding a folder, toggling
// one item and a whole folder, and building the apply plan.
func TestSetupTreeToggles(t *testing.T) {
	m := initialModel()
	m.nav = []screen{scrMain, scrSetup, scrSetupCat}
	m.setupFolders = []FolderRec{{Folder: "apps", Label: "Apps"}}
	m.setupItems = []SetupItemRec{
		{Folder: "apps", Key: "reaper", Label: "reaper"},
		{Folder: "apps", Key: "zen", Label: "zen"},
	}
	m.setupByValue = map[string]SetupItemRec{}
	for _, it := range m.setupItems {
		m.setupByValue[setupValue(it.Folder, it.Key)] = it
	}
	m.setupCat = "apps"

	// Expand the folder, then toggle one child.
	m.folderOpen["apps"] = true
	m.setupCatPicker = m.rebuildSetupCat()
	m, _ = m.update(tuikit.PickerToggleMsg{Value: setupValue("apps", "reaper")})
	if !m.selected[setupValue("apps", "reaper")] {
		t.Fatal("item toggle did not register")
	}

	// Toggling the folder when not all children are marked marks them all.
	m, _ = m.update(tuikit.PickerToggleMsg{Value: folderValue("apps")})
	if !m.selected[setupValue("apps", "zen")] {
		t.Fatal("folder select-all did not mark every child")
	}

	plan := m.applyPlan()
	if len(plan) != 1 || !strings.HasPrefix(plan[0], "apps\t") {
		t.Fatalf("unexpected apply plan: %q", plan)
	}
	if !strings.Contains(plan[0], "reaper") || !strings.Contains(plan[0], "zen") {
		t.Fatalf("apply plan missing keys: %q", plan)
	}
}

// TestBackupPassphraseTwice checks the encrypted-backup flow asks the
// passphrase a second time and only starts on a match.
func TestBackupPassphraseTwice(t *testing.T) {
	newModel := func() model {
		m := initialModel()
		m.nav = []screen{scrMain, scrBackup, scrBackupOptions, scrPassphrase}
		m.w, m.h = 120, 40
		m.pendingAction = "backup-encrypted"
		m.passInput = tuikit.NewPasswordInput("Backup passphrase", "")
		return m
	}
	m := newModel()
	m, _ = m.update(tuikit.InputResultMsg{Value: "secret"})
	if m.top() != scrPassphrase || m.pendingAction != "backup-encrypted-confirm" || m.pendingPass != "secret" {
		t.Fatalf("first entry should ask to confirm: top=%d action=%s", m.top(), m.pendingAction)
	}
	m, _ = m.update(tuikit.InputResultMsg{Value: "wrong"})
	if m.top() == scrWorking || m.passphraseSet {
		t.Fatal("mismatch must not start the run")
	}

	m2 := newModel()
	m2, _ = m2.update(tuikit.InputResultMsg{Value: "secret"})
	m2, _ = m2.update(tuikit.InputResultMsg{Value: "secret"})
	if m2.top() != scrWorking || !m2.passphraseSet {
		t.Fatalf("matching passphrases should start the run: top=%d set=%v", m2.top(), m2.passphraseSet)
	}
	os.Unsetenv("OMARCHY_BACKUP_PASSPHRASE")
}

func TestSetupInfoKey(t *testing.T) {
	m := initialModel()
	m.nav = []screen{scrMain, scrSetup, scrSetupCat}
	m.w, m.h = 120, 40
	m.setupFolders = []FolderRec{{Folder: "apps", Label: "Apps"}}
	m.setupItems = []SetupItemRec{{Folder: "apps", Key: "reaper", Label: "reaper", Info: "REAPER + Wayland integration"}}
	m.setupByValue = map[string]SetupItemRec{}
	for _, it := range m.setupItems {
		m.setupByValue[setupValue(it.Folder, it.Key)] = it
	}
	m.setupCat = "apps"
	m.folderOpen["apps"] = true                           // expand so the child row exists
	m.setupCatPicker = m.rebuildSetupCat().SelectIndex(1) // first child row
	m, _ = m.update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("i")})
	if m.top() != scrInfo {
		t.Fatalf("i did not open info (top=%d)", m.top())
	}
	if !strings.Contains(m.info.View(), "Wayland integration") {
		t.Fatalf("info does not contain the description: %q", m.info.View())
	}
}

// TestCategoryInfoKey covers the rows that used to swallow "i": a category row
// at the top level and a folder row inside a tree. Before, only a leaf item
// answered, so there was no way to read what a category covers without
// opening it and reading every row.
func TestCategoryInfoKey(t *testing.T) {
	build := func() model {
		m := initialModel()
		m.nav = []screen{scrMain, scrSetup, scrSetupCat}
		m.w, m.h = 120, 40
		m.setupFolders = []FolderRec{{Folder: "apps", Label: "Apps"}}
		m.setupItems = []SetupItemRec{
			{Folder: "apps", Key: "reaper", Label: "reaper - v8.0.0", Info: "REAPER + Wayland integration"},
			{Folder: "apps", Key: "handbrake", Label: "handbrake - v1.9.0", Info: "video transcoder"},
		}
		m.setupByValue = map[string]SetupItemRec{}
		for _, it := range m.setupItems {
			m.setupByValue[setupValue(it.Folder, it.Key)] = it
		}
		m.setupCat = "apps"
		m.folderOpen["apps"] = true
		return m
	}

	// Top level: the category row itself. (nav has to END on scrSetup here --
	// ending on scrSetupCat would exercise the folder row instead.)
	m := build()
	m.nav = []screen{scrMain, scrSetup}
	m.setupPicker = m.rebuildSetup().SelectIndex(0)
	// "i" is Enter now, so the info popup moved to "?". It used to be "i", and
	// "i" on a category row is where the binding looked like it worked — which
	// is exactly why nobody noticed it did nothing on a module row.
	m, _ = m.update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("?")})
	if m.top() != scrInfo {
		t.Fatalf("? on a top-level category did not open info (top=%d)", m.top())
	}
	txt := m.info.View()
	for _, want := range []string{"Apps", "2 items", "REAPER + Wayland integration", "video transcoder"} {
		if !strings.Contains(txt, want) {
			t.Fatalf("category info missing %q: %q", want, txt)
		}
	}

	// Inside the tree: the folder row.
	m = build()
	m.setupCatPicker = m.rebuildSetupCat().SelectIndex(0) // the folder row
	m, _ = m.update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("i")})
	if m.top() != scrInfo {
		t.Fatalf("i on a folder row did not open info (top=%d)", m.top())
	}
	if !strings.Contains(m.info.View(), "2 items") {
		t.Fatalf("folder info does not list the items: %q", m.info.View())
	}
}

// TestPreinstallsNeedConfirm covers the gate in front of `pacman -Rns`. The
// picker used to remove the ticked preinstalls on Enter AND on back, with no
// question in between; both now go through one confirmation naming the
// packages, and only an explicit "Remove them" reaches the backend.
func TestPreinstallsNeedConfirm(t *testing.T) {
	base := func() model {
		m := initialModel()
		m.treeMode = "uninstall"
		m.nav = []screen{scrMain, scrSetup, scrSetupCat, scrPreinstalls}
		m.w, m.h = 120, 40
		m.preinstalls = []PreinstallRec{
			{Name: "obsidian", Label: "Obsidian", Installed: true, Removable: true},
			{Name: "pinta", Label: "Pinta", Installed: true, Removable: true},
			{Name: "omacalc", Label: "Calculator", Installed: true, Protected: true},
		}
		m.preinstallChecked = map[string]bool{"obsidian": true, "pinta": false, "omacalc": true}
		m.preinstallPicker = m.rebuildPreinstallPicker()
		return m
	}

	// Enter: must ask, and the question must name the removable ticked apps.
	m := base()
	m, _ = m.update(tuikit.PickerResultMsg{Value: "apply"})
	if m.top() != scrConfirm {
		t.Fatalf("Enter did not ask for confirmation (top=%d)", m.top())
	}
	txt := m.confirm.View()
	for _, want := range []string{"obsidian", "pacman -Rns"} {
		if !strings.Contains(txt, want) {
			t.Fatalf("confirmation missing %q: %q", want, txt)
		}
	}
	// A protected app is never in the list handed to the backend, even though
	// its row was ticked.
	for _, a := range m.pendingArgs {
		if a == "omacalc" {
			t.Fatalf("protected app in the removal list: %v", m.pendingArgs)
		}
	}

	// Back CANCELS. It used to ask the same question Enter does, which meant
	// there was no way to open the preinstalls and change your mind: the only
	// exit removed something. Backing out now drops the uninstall this page
	// was in front of and asks nothing.
	m = base()
	m.uninstallWait = []string{"live-mode"}
	m.uninstallMsg = "Uninstall live-mode?"
	m, _ = m.update(tuikit.PickerResultMsg{Value: "back"})
	if m.top() == scrConfirm {
		t.Fatalf("back asked for confirmation instead of cancelling")
	}
	if len(m.uninstallWait) != 0 {
		t.Fatalf("back left the uninstall waiting: %q", m.uninstallWait)
	}

	// Nothing ticked: no confirmation, and the uninstall it was in front of
	// carries on — declining the preinstalls is a decision about the
	// preinstalls, not about the uninstall.
	m = base()
	m.uninstallWait = []string{"live-mode"}
	m.uninstallMsg = "Uninstall live-mode?"
	m.preinstallChecked = map[string]bool{"obsidian": false, "pinta": false, "omacalc": true}
	m.preinstallPicker = m.rebuildPreinstallPicker()
	m, _ = m.update(tuikit.PickerResultMsg{Value: "apply"})
	if m.top() != scrConfirm {
		t.Fatalf("nothing ticked: top=%d, want the uninstall confirmation", m.top())
	}
	if m.pendingAction != "uninstall" {
		t.Fatalf("pendingAction = %q, want uninstall", m.pendingAction)
	}
}

// TestMenuEntriesReachableFromSetup guards the routing of the level-1
// "Menu entries" row. It is not a category folder, so it needs its own
// branch in screenPicked: without one the value fell through to the
// category path, folderOfValue() returned "" and Setup opened an empty
// category screen — the menu-entries screen was never pushed, so the
// screen looked simply broken.
func TestMenuEntriesReachableFromSetup(t *testing.T) {
	m := initialModel()
	m.nav = []screen{scrMain, scrSetup}
	m.w, m.h = 120, 40

	// The tree value, i.e. what the row under the cursor actually carries. The
	// old "menu-entries" (no cat: prefix) never matched anything: the folder
	// row is built as cat:<id>, so Enter on it fell into the generic
	// "a folder row does nothing" guard and the screen was never pushed. That
	// is the bug this test now guards — it passed for years against a value
	// no row could produce.
	m, cmd := m.update(tuikit.PickerResultMsg{Value: tuikit.TreeValue(tuikit.TreeFolderPrefix, menuEntriesFolder)})
	if m.top() != scrMenuEntries {
		t.Fatalf("top = %d, want scrMenuEntries(%d)", m.top(), scrMenuEntries)
	}
	if cmd == nil {
		t.Fatal("no fetch command: the list would stay empty forever")
	}
	// Before the reply lands the screen must say so, not show a lone "Back".
	if v := m.View(); !strings.Contains(v, "loading") {
		t.Fatalf("expected a loading row, got:\n%s", v)
	}

	rows := []MenuEntryRec{
		{Name: "mega-caffeine", Present: true, Label: "Mega caffeine"},
		{Name: "live-mode", Present: false, Label: "Live mode entries"},
	}
	m, _ = m.update(menuEntriesMsg{rows: rows})
	if !m.menuEntriesLoaded {
		t.Fatal("menuEntriesLoaded not set after a successful reply")
	}
	// The default must be the real installed state, otherwise a row cannot
	// be re-ticked and the strip half of the screen is unreachable.
	if !m.menuEntryChecked["mega-caffeine"] || m.menuEntryChecked["live-mode"] {
		t.Fatalf("ticks should mirror the installed state, got %v", m.menuEntryChecked)
	}
	// The dot carries the state, so the rows must be distinguishable by it:
	// ● for the entry that is in the menu, ○ for the one that is not. The
	// words "installed"/"not installed" are deliberately absent — they only
	// restated the dot and doubled the width of every line.
	v := m.View()
	if strings.Contains(v, "installed") {
		t.Fatalf("the (installed) wording is back:\n%s", v)
	}
	for _, want := range []string{"Mega caffeine", "Live mode entries", "Back"} {
		if !strings.Contains(v, want) {
			t.Fatalf("menu-entries screen missing %q:\n%s", want, v)
		}
	}
	rowsOnScreen := []string{}
	for _, l := range strings.Split(v, "\n") {
		if strings.Contains(l, "Mega caffeine") || strings.Contains(l, "Live mode entries") {
			rowsOnScreen = append(rowsOnScreen, strings.TrimSpace(l))
		}
	}
	if len(rowsOnScreen) != 2 {
		t.Fatalf("want both entry rows, got %v", rowsOnScreen)
	}
	if !strings.Contains(rowsOnScreen[0], "●") {
		t.Fatalf("installed entry should be a filled dot: %q", rowsOnScreen[0])
	}
	if !strings.Contains(rowsOnScreen[1], "○") {
		t.Fatalf("absent entry should be an empty dot: %q", rowsOnScreen[1])
	}
}

// TestMenuEntriesBackendFailure checks a failed fetch does not leave the
// screen stuck on "loading…" forever.
func TestMenuEntriesBackendFailure(t *testing.T) {
	m := initialModel()
	m.nav = []screen{scrMain, scrSetup, scrMenuEntries}
	m.w, m.h = 120, 40
	m, _ = m.update(menuEntriesMsg{err: fmt.Errorf("boom")})
	if v := m.View(); strings.Contains(v, "loading") {
		t.Fatalf("still loading after a failure:\n%s", v)
	}
}

// TestHealthScreenIsReadable covers the three things that made the Health
// check page unclear: raw module ids instead of names, a header that named
// the mechanism rather than the result, and no way out but Esc.
func TestHealthScreenIsReadable(t *testing.T) {
	m := initialModel()
	m.nav = []screen{scrMain}
	m.w, m.h = 120, 40
	items := []HealthRec{
		{Kind: "module", ID: "live-mode",
			Label:  "Live mode — performance session mode (stay-awake + thermal guard)",
			Detail: "missing /etc/sudoers.d/live-mode (needs root)"},
		{Kind: "infra", ID: "menu", Label: "Omarchy menu entry", Detail: "the row is missing"},
	}
	m, _ = m.update(healthMsg{items: items})
	if m.top() != scrHealth {
		t.Fatalf("top = %d, want scrHealth(%d)", m.top(), scrHealth)
	}
	v := m.View()
	// A Back row: this screen is a page, and every other page has one.
	if !strings.Contains(v, "Back") {
		t.Fatalf("no Back row on the health screen:\n%s", v)
	}
	// The short name, not the whole catalog sentence.
	if !strings.Contains(v, "Live mode") {
		t.Fatalf("short label missing:\n%s", v)
	}
	if strings.Contains(v, "stay-awake + thermal guard") {
		t.Fatalf("the long catalog sentence is still in the row list:\n%s", v)
	}
	// The finding, not the mechanism.
	if !strings.Contains(v, "needs root") {
		t.Fatalf("detail not shown:\n%s", v)
	}
	if !strings.Contains(v, "2 pieces need attention") {
		t.Fatalf("headline does not state the finding:\n%s", v)
	}
	// Enter on Back leaves instead of opening the re-apply confirmation.
	m, _ = m.update(tuikit.PickerResultMsg{Value: "back"})
	if m.top() == scrHealth {
		t.Fatal("Back did not leave the health screen")
	}
}

// TestHealthBackCannotBeTicked makes sure the navigation row cannot be
// selected for re-apply, which would heal an id that is not a module.
func TestHealthBackCannotBeTicked(t *testing.T) {
	m := initialModel()
	m.nav = []screen{scrMain, scrHealth}
	m.w, m.h = 120, 40
	m.healthItems = []HealthRec{{Kind: "infra", ID: "menu", Label: "Omarchy menu entry"}}
	m.healthChecked = map[string]bool{"menu": true}
	m, _ = m.update(tuikit.PickerToggleMsg{Value: "back"})
	if m.healthChecked["back"] {
		t.Fatal("Back was ticked as if it were a healable piece")
	}
	if keys := m.healthKeys(); len(keys) != 1 || keys[0] != "menu" {
		t.Fatalf("healthKeys = %v, want [menu]", keys)
	}
}

// TestHealthCursorStaysOnTheTitle guards the health page's marker. Each fix is
// drawn on two lines (name, then what is wrong with it), and the row marker
// used to be redrawn on the description line as well — so a row showed its ●
// twice and the marker appeared to travel down the list as the cursor moved.
// The marker belongs to the name alone.
func TestHealthCursorStaysOnTheTitle(t *testing.T) {
	m := initialModel()
	m.nav = []screen{scrMain, scrHealth}
	m.w, m.h = 120, 40
	m.healthItems = []HealthRec{
		{Kind: "infra", ID: "menu", Label: "Omarchy menu", Detail: "missing its menu entry"},
		{Kind: "infra", ID: "sudo", Label: "Live Mode", Detail: "/etc/sudoers.d/live-mode needs root"},
	}
	m, _ = m.update(healthMsg{items: m.healthItems})

	lines := strings.Split(m.View(), "\n")
	for _, l := range lines {
		if strings.Contains(l, "needs root") && strings.Contains(l, "●") {
			t.Fatalf("row marker leaked onto the description line: %q", l)
		}
	}
	marked := 0
	for _, l := range lines {
		if strings.Contains(l, "●") {
			marked++
			if strings.Contains(l, "missing its menu entry") || strings.Contains(l, "needs root") {
				t.Fatalf("marker on a description line: %q", l)
			}
		}
	}
	if marked != 2 {
		t.Fatalf("want one marker per ticked row (2), got %d:\n%s", marked, m.View())
	}
}

// TestSetupFilterKeepsTheCursor covers the search bug: rebuildFilteredSetup
// returned a picker with no SelectIndex, so the ~1s blink that repaints the
// mosquito row rebuilt the filtered list at row 0 and threw the cursor back to
// the first match about a second after the user moved it.
func TestSetupFilterKeepsTheCursor(t *testing.T) {
	m := initialModel()
	m.nav = []screen{scrMain, scrSetup}
	m.w, m.h = 120, 40
	m.treeMode = "install"
	m.filterOpen = true
	m.setupFolders = []FolderRec{{Folder: "wifi"}, {Folder: "webcam"}, {Folder: "wacom"}}
	m.setupItems = []SetupItemRec{
		{Folder: "wifi", Key: "iwd", Label: "wpa supplicant"},
		{Folder: "webcam", Key: "tool", Label: "webcam tools"},
		{Folder: "wacom", Key: "tablet", Label: "tablet driver"},
	}
	m, _ = m.update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'w'}})
	if m.filterText != "w" || m.setupPicker.Len() < 2 {
		t.Fatalf("filter 'w' gave %q over %d rows", m.filterText, m.setupPicker.Len())
	}
	m, _ = m.update(tea.KeyMsg{Type: tea.KeyDown})
	moved := m.setupPicker.SelectedValue()
	if moved == "item:wifi:iwd" {
		t.Fatal("down did not move the cursor")
	}
	// The blink repaints the list; the cursor must survive it.
	m.setupPicker = m.rebuildSetup()
	if got := m.setupPicker.SelectedValue(); got != moved {
		t.Fatalf("blink reset the cursor: %q -> %q", moved, got)
	}
	// Narrowing the filter keeps the cursor when the row still matches.
	m.filterText = "web"
	m.setupPicker = m.rebuildSetup()
	if got, want := m.setupPicker.SelectedValue(), "item:webcam:tool"; got != want {
		t.Fatalf("narrowing the filter moved the cursor to %q, want %q", got, want)
	}
}

// TestMenuEntriesRespondsToKeys is the freeze. The screen rendered rows from a
// picker rebuilt inside View() and thrown away, and the Update case fell
// through into scrBackupRestore, so arrows drove the backup picker and the
// screen looked frozen. It must now keep a stored picker and answer keys.
func TestMenuEntriesRespondsToKeys(t *testing.T) {
	m := initialModel()
	m.nav = []screen{scrMain, scrSetup}
	m.w, m.h = 120, 40
	m, _ = m.update(tuikit.PickerResultMsg{Value: tuikit.TreeValue(tuikit.TreeFolderPrefix, menuEntriesFolder)})
	m, _ = m.update(menuEntriesMsg{rows: []MenuEntryRec{
		{Name: "mosquitomarchy", Present: true, Label: "mosquitOmarchy"},
		{Name: "live-mode", Present: true, Label: "Live Mode Manager"},
		{Name: "mega-caffeine", Present: false, Label: "Mega caffeine"},
	}})
	m, _ = m.update(tea.KeyMsg{Type: tea.KeyDown})
	if got := m.menuEntriesPicker.SelectedValue(); got != "mentry:live-mode" {
		t.Fatalf("down key went elsewhere: %q", got)
	}
	// Tab toggles without throwing the cursor back to the top.
	m, _ = m.update(tuikit.PickerToggleMsg{Value: "mentry:live-mode"})
	if got := m.menuEntriesPicker.SelectedValue(); got != "mentry:live-mode" {
		t.Fatalf("toggle reset the cursor: %q", got)
	}
	if m.menuEntryChecked["live-mode"] {
		t.Fatal("tab did not clear the tick")
	}
	// Dots, not checkboxes.
	if v := m.View(); strings.Contains(v, "☑") || strings.Contains(v, "☐") {
		t.Fatalf("checkbox glyphs still on screen:\n%s", v)
	}
}

// TestHealthCursorDoesNotDrift is the "the cursor jumps when I tick" report.
// rebuildHealth carried a raw index and decremented it "to compensate for the
// headline row", but it always prepends that headline, so the index it read
// already counted it: every repaint moved the cursor up one row. Ticking a fix
// therefore marked a row that was not the focused one, and the next tick looked
// like it jumped again.
func TestHealthCursorDoesNotDrift(t *testing.T) {
	m := initialModel()
	m.nav = []screen{scrMain, scrHealth}
	m.w, m.h = 120, 40
	m.healthItems = []HealthRec{
		{Kind: "infra", ID: "menu", Label: "Omarchy menu", Detail: "d1"},
		{Kind: "infra", ID: "sudo", Label: "Live Mode", Detail: "d2"},
		{Kind: "infra", ID: "vm", Label: "macOS VMs", Detail: "d3"},
	}
	m, _ = m.update(healthMsg{items: m.healthItems})
	// The disabled headline must not hold the cursor on open, or the screen
	// looks like it has no cursor at all.
	if got := m.healthPicker.SelectedValue(); got == "" {
		t.Fatalf("cursor is on the disabled headline row, not a fix (idx %d)", m.healthPicker.Index())
	}
	for i := 0; i < 2; i++ {
		m, _ = m.update(tea.KeyMsg{Type: tea.KeyDown})
	}
	before := m.healthPicker.SelectedValue()
	if before != "vm" {
		t.Fatalf("down x2 = %q, want vm", before)
	}
	// The rows arrive ticked (they are all there to be re-applied), so the
	// first press unticks. Alternate, so each rebuild is exercised with the row
	// both ticked and un-ticked, and check the cursor never moves.
	if !m.healthChecked["vm"] {
		t.Fatal("a freshly listed fix should start ticked")
	}
	want := true
	for n := 0; n < 3; n++ {
		m, _ = m.update(tuikit.PickerToggleMsg{Value: before})
		want = !want
		if got := m.healthPicker.SelectedValue(); got != before {
			t.Fatalf("tick %d moved the cursor to %q (was %q)", n, got, before)
		}
		if m.healthChecked["vm"] != want {
			t.Fatalf("tick %d: checked = %v, want %v", n, m.healthChecked["vm"], want)
		}
	}
	// Moving still works after a rebuild.
	m, _ = m.update(tea.KeyMsg{Type: tea.KeyUp})
	if got := m.healthPicker.SelectedValue(); got != "sudo" {
		t.Fatalf("up after rebuild = %q, want sudo", got)
	}
}

// TestUpdateScreenNamesTheSource covers the "I only see one update option and
// I cannot tell where it comes from" report. The screen offered a single
// "Update modules" row even when the only pending change was a repo
// fast-forward, and the module list was reachable only through the "i" popup.
func TestUpdateScreenNamesTheSource(t *testing.T) {
	m := initialModel()
	m.nav = []screen{scrMain, scrUpdate}
	m.w, m.h = 120, 40

	// Repo only: the module row must be greyed out (it would do nothing) and
	// the repo must be a named row of its own.
	m, _ = m.update(queryMsg{kind: "update", update: UpdateRec{RepoUpdate: true}})
	v := m.View()
	if !strings.Contains(v, "Update mosquitOmarchy (repo + scripts)") {
		t.Fatalf("no named repo row:\n%s", v)
	}
	upd := m.updatePicker
	mods := false
	for _, it := range upd.items {
		if it.Value == "update-modules" {
			mods = it.Disabled
		}
	}
	if !mods {
		t.Fatal("Update modules should be disabled when no module has changes")
	}

	// A module update must still be listed with its own row.
	m, _ = m.update(queryMsg{kind: "update", update: UpdateRec{Modules: []ItemRec{{Key: "battery", Label: "Battery"}}}})
	v = m.View()
	if !strings.Contains(v, "Battery") {
		t.Fatalf("module row missing:\n%s", v)
	}
	if strings.Contains(v, "Update mosquitOmarchy (repo + scripts)") {
		t.Fatal("repo row shown with no repo update pending")
	}
}

// TestUpdateIsVisibleFromTheMainMenu: a pending update was only ever visible
// inside the Update screen and as a long line in the Setup tree. The root list
// was built once at startup, before any check had run, and never rebuilt, so
// the square could not appear there at all.
func TestUpdateIsVisibleFromTheMainMenu(t *testing.T) {
	m := initialModel()
	m.nav = []screen{scrMain}
	m.w, m.h = 120, 40
	if v := m.View(); strings.Contains(v, "■") {
		t.Fatalf("a square is shown before anything is known:\n%s", v)
	}
	m, _ = m.update(queryMsg{kind: "update", update: UpdateRec{RepoUpdate: true}})
	if v := m.View(); !strings.Contains(v, "■") {
		t.Fatalf("no update square on the main menu after a pending repo update:\n%s", v)
	}
	// It must vanish again once nothing is pending.
	m, _ = m.update(queryMsg{kind: "update", update: UpdateRec{}})
	if v := m.View(); strings.Contains(v, "■") {
		t.Fatalf("square still there with nothing pending:\n%s", v)
	}
	// Update is reachable from the main menu, which is where it lives now — and
	// Setup has no opinion about it at all.
	m2 := initialModel()
	m2.nav = []screen{scrMain, scrSetup}
	m2.w, m2.h = 120, 40
	m2, _ = m2.update(queryMsg{kind: "update", update: UpdateRec{RepoUpdate: true}})
	for _, it := range m2.setupPicker.items {
		if it.Value == "updates" {
			t.Fatal("Setup must not carry the update row any more")
		}
	}
	m3 := initialModel()
	m3.nav = []screen{scrMain}
	m3.w, m3.h = 120, 40
	m3, _ = m3.update(queryMsg{kind: "update", update: UpdateRec{RepoUpdate: true}})
	if !strings.Contains(m3.View(), "Update") {
		t.Fatalf("the main menu no longer advertises the update:\n%s", m3.View())
	}
}

// TestMenuEntriesAppliesBothWays: un-ticking an entry and pressing Enter did
// nothing. Enter was handled in the scrMenuEntries case of the key switch, but
// PickerResultMsg is caught by the global case and routed to screenPicked,
// which had no scrMenuEntries case, so it fell off the end. The ticks then
// looked lost on re-entry because nothing had been applied.
func TestMenuEntriesAppliesBothWays(t *testing.T) {
	build := func() model {
		m := initialModel()
		m.nav = []screen{scrMain, scrSetup, scrMenuEntries}
		m.w, m.h = 120, 40
		m, _ = m.update(menuEntriesMsg{rows: []MenuEntryRec{
			{Name: "live-mode", Present: true, Label: "Live mode entries"},
		}})
		return m
	}
	// Un-tick → Enter must ask to apply, not silently do nothing.
	m := build()
	m, _ = m.update(tuikit.PickerToggleMsg{Value: "mentry:live-mode"})
	if m.menuEntryChecked["live-mode"] {
		t.Fatal("un-tick did not take")
	}
	m, _ = m.update(tuikit.PickerResultMsg{Value: "mentry:live-mode"})
	if m.top() != scrConfirm {
		t.Fatalf("Enter went to screen %d, want the Confirm", m.top())
	}
	if m.pendingAction != "menu-entries" {
		t.Fatalf("pendingAction = %q, want menu-entries", m.pendingAction)
	}
	if len(m.pendingArgs) != 1 || m.pendingArgs[0] != "live-mode" {
		t.Fatalf("pendingArgs = %v, want [live-mode]", m.pendingArgs)
	}
	// No change → no confirm, and say so instead of popping.
	m2 := build()
	m2, _ = m2.update(tuikit.PickerResultMsg{Value: "mentry:live-mode"})
	if m2.top() == scrConfirm {
		t.Fatal("asked to apply with nothing changed")
	}
	if m2.top() != scrMenuEntries {
		t.Fatalf("no-change Enter left the screen (now %d)", m2.top())
	}
}

// sandboxMenu points the actions backend at a throwaway menu file for the
// duration of a test. This is mandatory, not a nicety: `apply` really does
// run the strip/restore code, and without the override the test suite was
// editing the user's LIVE omarchy-menu.jsonc — which is how `move-converter`
// and `live-mode` came to be missing from the real menu.
func sandboxMenu(t *testing.T, present ...string) string {
	t.Helper()
	dir := t.TempDir()
	menu := filepath.Join(dir, "omarchy-menu.jsonc")
	var b strings.Builder
	b.WriteString("{\n")
	for _, k := range present {
		fmt.Fprintf(&b, "  %q: {\n    \"label\": \"%s\",\n    \"action\": \"/bin/true\"\n  },\n", k, k)
	}
	b.WriteString("  \"unrelated\": { \"label\": \"keep me\", \"action\": \"/bin/true\" }\n}\n")
	if err := os.WriteFile(menu, []byte(b.String()), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("MOSQUITOMARCHY_MENU_DIR", dir)
	t.Setenv("MOSQUITOMARCHY_MENU_JSONC", menu)
	return menu
}

// Regression: the reported "I ticked it back and it said no changes to
// apply". The tick baseline was seeded once and then left stale, so after a
// real strip the backend correctly reported the entry absent while the
// baseline still said present — re-ticking it then looked like no change.
func TestMenuEntriesRestoresAfterARealStrip(t *testing.T) {
	menu := sandboxMenu(t, "setup.mosquito.live", "setup.mosquito.jamjamjam")
	m := initialModel()
	m.nav = []screen{scrMain, scrSetup, scrMenuEntries}
	m.w, m.h = 120, 40
	// Entry is installed: both maps say so.
	m, _ = m.update(menuEntriesMsg{rows: []MenuEntryRec{
		{Name: "live-mode", Present: true, Label: "Live mode entries"},
		{Name: "jamjamjam", Present: true, Label: "JamJamJam"},
	}})
	// User un-ticks it, applies: the picker runs the strip.
	m, _ = m.update(tuikit.PickerToggleMsg{Value: "mentry:live-mode"})
	m, _ = m.update(tuikit.PickerResultMsg{Value: "mentry:live-mode"})
	if m.pendingAction != "menu-entries" {
		t.Fatalf("strip not queued (pendingAction = %q)", m.pendingAction)
	}
	m, _ = m.update(tuikit.ConfirmResultMsg{Yes: true})
	// The apply really hit the backend, on the sandbox file.
	if raw, rerr := os.ReadFile(menu); rerr != nil {
		t.Fatal(rerr)
	} else if strings.Contains(string(raw), "setup.mosquito.live") {
		t.Fatalf("apply did not strip the entry from the menu file:\n%s", raw)
	}
	// The list now comes back from the menu file saying it is gone.
	m, _ = m.update(menuEntriesMsg{rows: []MenuEntryRec{
		{Name: "live-mode", Present: false, Label: "Live mode entries"},
		{Name: "jamjamjam", Present: true, Label: "JamJamJam"},
	}})
	if m.menuEntryOrig["live-mode"] {
		t.Fatal("baseline still claims a stripped entry is present")
	}
	if m.menuEntryChecked["live-mode"] {
		t.Fatal("stripped entry is still shown as selected")
	}
	// The user ticks it back to restore it. This is the exact moment the
	// screen used to claim there was nothing to apply.
	m, _ = m.update(tuikit.PickerToggleMsg{Value: "mentry:live-mode"})
	if m.menuEntryChecked["live-mode"] == m.menuEntryOrig["live-mode"] {
		t.Fatal("re-ticking a stripped entry produced no delta")
	}
	m, _ = m.update(tuikit.PickerResultMsg{Value: "mentry:live-mode"})
	if m.top() != scrConfirm {
		t.Fatalf("restore went to screen %d, want the Confirm", m.top())
	}
	if len(m.pendingArgs) != 1 || m.pendingArgs[0] != "live-mode" {
		t.Fatalf("pendingArgs = %v, want [live-mode]", m.pendingArgs)
	}
	// Confirm the restore too: the whole point of the fix is that the second
	// half of the round trip works.
	m, _ = m.update(tuikit.ConfirmResultMsg{Yes: true})
	if raw, rerr := os.ReadFile(menu); rerr != nil {
		t.Fatal(rerr)
	} else if !strings.Contains(string(raw), "setup.mosquito.live") {
		t.Fatalf("apply did not restore the entry to the menu file:\n%s", raw)
	}
}

// TestBackupOptionsPersistAcrossSessions is the test for "the options are
// remembered".
//
// The bug it pins: the choices lived in the model, so they survived leaving the
// page but died with the process. loadBackupOpts() must read them back, and a
// missing or corrupt file must fall back to the DEFAULTS rather than to a
// half-read struct — a stored false for keepass/zen is a legitimate choice,
// while an absent field decoding to false is not, so the loader treats "no file"
// and "file we did not write" as the same thing.
func TestBackupOptionsPersistAcrossSessions(t *testing.T) {
	// The real backend, not a stub: persistence here is the backend writing
	// a file, and a save that fails silently (which it does, by design — a
	// backup must still be a valid backup if it cannot record its settings)
	// would make this test pass for the wrong reason on a bare PATH.
	setUpBackend(t)

	// No file at all -> defaults, and NOT an error.
	def := loadBackupOpts()
	if def.VST != "list" || !def.Keepass || !def.Zen {
		t.Fatalf("no stored file should give the defaults, got %+v", def)
	}

	// What the user chose must come back.
	saved := BackupOpts{VST: "none", Keepass: false, Zen: true, Encrypt: true, Name: "avant upgrade"}
	saveBackupOpts(saved)
	back := loadBackupOpts()
	if back != saved {
		t.Fatalf("round trip changed the options:\n saved %+v\n got   %+v", saved, back)
	}

	// The detection flags are never persisted, so a stale "installed" cannot
	// resurrect a row for a program that is no longer there.
	if back.HasKeep || back.HasZen {
		t.Fatalf("detection flags must not be persisted, got %+v", back)
	}
}

// TestBackupNameReachesTheBackendArgs checks the name survives the whole trip
// to the command line, including the encrypted detour where pendingArgs is
// reused. A name that only works on the unencrypted path would be a name that
// silently disappears exactly when the archive matters most.
func TestBackupNameReachesTheBackendArgs(t *testing.T) {
	m := initialModel()
	m.nav = []screen{scrMain, scrBackup, scrBackupOptions}
	m.w, m.h = 120, 40
	m.backupOpts = BackupOpts{VST: "list", Name: "Avant upgrade REAPER", Encrypt: true}
	m.backupOpts.HasKeep, m.backupOpts.HasZen = false, false

	m, _ = m.beginBackup()
	// Encrypting detours through the passphrase screen and comes back to the
	// same pendingArgs, so assert on the state the run will actually use.
	found := false
	for _, a := range m.pendingArgs {
		if a == "--name=Avant upgrade REAPER" {
			found = true
		}
	}
	if !found {
		t.Fatalf("--name missing from %v", m.pendingArgs)
	}
	if m.pendingAction != "backup-encrypted" {
		t.Fatalf("expected the encrypted path, got %q", m.pendingAction)
	}
}

// TestHomeInfoKeyDescribesThePageUnderTheCursor pins `i` on the home screen.
//
// Three things it guards:
//
//   - the key does not collide with something the home screen already used;
//   - it is wired as a DESCRIPTION and not as an action — the `i` key used to
//     re-dispatch Enter, so describing a page would have installed it (the same
//     mistake TestInfoKeyDescribesAModuleRow guards on Setup);
//   - it describes the page under the CURSOR. It used to print every page at
//     once, which meant standing on Backup buried its own paragraph twenty lines
//     up; scoping it to the row is what every other screen already does.
func TestHomeInfoKeyDescribesThePageUnderTheCursor(t *testing.T) {
	m := initialModel()
	m.w, m.h = 120, 40

	// The cursor starts on Status.
	m, _ = m.update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("i")})
	if m.top() != scrInfo {
		t.Fatalf("i on the home screen should open the page guide, top is %v", m.top())
	}
	if m.pendingAction != "" {
		t.Errorf("describing a page must not queue an action, got %q", m.pendingAction)
	}
	if m.info.View() == "" {
		t.Error("the popup rendered nothing")
	}
	status := m.homePageInfo()
	if !strings.Contains(status, "Status") {
		t.Errorf("the guide for the first row does not mention Status: %q", status)
	}
	// Scoped: the other pages must NOT be in there.
	for _, unwanted := range []string{"Backup / Restore", "Uninstall", "Keybindings"} {
		if strings.Contains(status, unwanted) {
			t.Errorf("the guide for Status leaks %q — it is not scoped to the cursor", unwanted)
		}
	}

	// Moving the cursor changes the answer, and only that page's text comes back.
	//
	// esc does not pop directly: Info.Update returns an InfoDismissedMsg through
	// a tea.Cmd, so the command has to be run and its message fed back before the
	// screen is actually gone. Discarding the cmd left the popup open and the rest
	// of the test asserting against a model still inside it.
	m, cmd := m.update(tea.KeyMsg{Type: tea.KeyEsc})
	if cmd == nil {
		t.Fatal("esc on the popup produced no command to dismiss it")
	}
	m, _ = m.update(cmd())
	if m.top() != scrMain {
		t.Fatalf("esc should leave the popup, top is %v", m.top())
	}
	if got := m.mainPicker.SelectedValue(); got != "status" {
		t.Fatalf("expected the cursor to still be on status, got %q", got)
	}
	m.mainPicker = m.mainPicker.SelectValue("backup")
	m, _ = m.update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("i")})
	backup := m.homePageInfo()
	if !strings.Contains(backup, "Backup / Restore") {
		t.Errorf("the guide on Backup does not describe Backup: %q", backup)
	}
	if strings.Contains(backup, "Uninstall") {
		t.Errorf("the guide for Backup leaks Uninstall: %q", backup)
	}
	// Restoring is the irreversible one, so the warning has to sit on the page
	// that restores rather than somewhere in a wall of text.
	if !strings.Contains(backup, "OVERWRITES") {
		t.Error("the Backup guide does not warn that a restore overwrites files")
	}
}

// TestHomeInfoOnCloseShowsEveryPage keeps the whole map reachable now that `i`
// is scoped. The Close row has no page of its own, so it is where "what does
// each page do" is answered.
func TestHomeInfoOnCloseShowsEveryPage(t *testing.T) {
	all := homePageInfoFor("close")
	for _, want := range []string{"Backup", "Restore", "Setup", "Uninstall", "Keybindings"} {
		if !strings.Contains(all, want) {
			t.Errorf("the full map does not mention %q", want)
		}
	}
	if !strings.Contains(all, "OVERWRITES") {
		t.Error("the full map does not warn that a restore overwrites files")
	}
	// Every real page must answer for itself too, or `i` would fall through to
	// the map and quietly print all ten pages again.
	for _, page := range []string{"status", "update", "setup", "uninstall", "keybindings", "theme", "health", "backup", "settings"} {
		if got := homePageInfoFor(page); got == all {
			t.Errorf("page %q falls through to the full map instead of its own text", page)
		}
	}
}
