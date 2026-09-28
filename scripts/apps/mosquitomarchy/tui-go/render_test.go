package main

import (
	"fmt"
	"os"
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
	m.backupOptPicker = m.rebuildBackupOptions().SelectIndex(1) // the VST row
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
	newModel := func(selectReaper bool) model {
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
		m.setupPicker = m.rebuildSetup()
		return m
	}
	find := func(m model, value string) tuikit.PickerItem {
		for _, it := range m.setupPicker.items {
			if it.Value == value {
				return it
			}
		}
		t.Fatalf("row %q not found", value)
		return tuikit.PickerItem{}
	}

	m := newModel(true)
	apps := find(m, folderValue("apps"))
	if apps.TrailingBadge != "■" || !strings.Contains(apps.Suffix, "1/1") {
		t.Fatalf("apps row should mark its selection: badge=%q suffix=%q", apps.TrailingBadge, apps.Suffix)
	}
	if find(m, folderValue("tuis")).TrailingBadge != "" {
		t.Fatal("tuis row should have no selection marker")
	}
	if find(m, "install-selection").Disabled {
		t.Fatal("Install selection should be enabled when something is checked")
	}
	if got := m.applyPlanCat("apps"); len(got) != 1 || !strings.Contains(got[0], "reaper") {
		t.Fatalf("applyPlanCat(apps) = %q", got)
	}

	if find(newModel(false), "install-selection").Disabled != true {
		t.Fatal("Install selection should be disabled with no selection")
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

// TestSetupUpdatesOption checks Setup advertises available updates.
func TestSetupUpdatesOption(t *testing.T) {
	m := initialModel()
	m.nav = []screen{scrMain, scrSetup}
	m.w, m.h = 120, 40
	m.setupFolders = []FolderRec{{Folder: "apps", Label: "Apps"}}
	m.setupItems = []SetupItemRec{{Folder: "apps", Key: "x", Label: "x"}}
	m.updateRec = UpdateRec{RepoUpdate: true}
	m.setupPicker = m.rebuildSetup()
	found := false
	for _, it := range m.setupPicker.items {
		if it.Value == "updates" {
			found = true
		}
	}
	if !found {
		t.Fatal("Setup should advertise available updates")
	}
}

// TestStatusScroll checks the status screen actually scrolls, and that the
// scroll offset survives the defensive SetSize the host performs every render
// (the bug that made it snap back to the top).
func TestStatusScroll(t *testing.T) {
	m := initialModel()
	m.nav = []screen{scrMain, scrStatus}
	m.w, m.h = 100, 24
	recs := make([]StatusRec, 60)
	for i := range recs {
		recs[i] = StatusRec{Id: fmt.Sprintf("m%02d", i), Label: fmt.Sprintf("Module %02d", i), State: "ok"}
	}
	m.statusRecs = recs
	m.info = tuikit.NewInfo(m.statusView()).SetSize(m.contentSize())
	before := m.info.View()
	m, _ = m.update(tea.KeyMsg{Type: tea.KeyDown})
	// The host re-sizes defensively on every render; the offset must survive.
	m.info = m.info.SetSize(m.contentSize())
	if m.info.View() == before {
		t.Fatal("status did not scroll")
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
			m.statusRecs = []StatusRec{{Id: "reaper", Label: "REAPER", State: "ok"},
				{Id: "bad", Label: "Bad thing", State: "missing"}}
			m.info = tuikit.NewInfo(m.statusView()).SetSize(m.contentSize())
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
	m, _ = m.update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("i")})
	if m.top() != scrInfo {
		t.Fatalf("i on a top-level category did not open info (top=%d)", m.top())
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

	// Back: same question, not a silent removal.
	m = base()
	m, _ = m.update(tuikit.PickerResultMsg{Value: "back"})
	if m.top() != scrConfirm {
		t.Fatalf("back did not ask for confirmation (top=%d)", m.top())
	}

	// Nothing ticked: leaving must not ask anything.
	m = base()
	m.preinstallChecked = map[string]bool{"obsidian": false, "pinta": false, "omacalc": true}
	m.preinstallPicker = m.rebuildPreinstallPicker()
	m, _ = m.update(tuikit.PickerResultMsg{Value: "back"})
	if m.top() == scrConfirm {
		t.Fatalf("asked for confirmation with nothing ticked")
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

	m, cmd := m.update(tuikit.PickerResultMsg{Value: "menu-entries"})
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
	v := m.View()
	for _, want := range []string{"Mega caffeine", "Live mode entries", "installed", "not installed", "Back"} {
		if !strings.Contains(v, want) {
			t.Fatalf("menu-entries screen missing %q:\n%s", want, v)
		}
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
