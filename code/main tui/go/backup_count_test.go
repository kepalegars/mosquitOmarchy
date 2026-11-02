package main

import (
	"os"
	"regexp"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	tuikit "mosquitomarchy.local/tui-kit"
)

var selectedCountRE = regexp.MustCompile(`Packages, Themes & tweaks: (\d+) selected`)

// backupCountShown reads the "N selected" figure off the Backup options screen.
// Read from the picker's own rows, not from the rendered view: Info and the
// option list render a viewport, so a short terminal would scroll the count out
// of view and the assertion would be testing the terminal size instead.
func backupCountShown(t *testing.T, m model) string {
	t.Helper()
	for _, it := range m.backupOptPicker.items {
		if mt := selectedCountRE.FindStringSubmatch(it.Display); len(mt) == 2 {
			return mt[1]
		}
	}
	t.Fatalf("no row says how many apps are selected; rows=%v", m.backupOptPicker.items)
	return ""
}

func backupCountModel() model {
	m := initialModel()
	m.nav = []screen{scrMain, scrBackup, scrBackupOptions}
	m.w, m.h = 120, 40
	m.backupOpts = BackupOpts{VST: "list", Keepass: true, HasKeep: true}
	m.backupFolders = []FolderRec{{Folder: "apps", Label: "Apps"}}
	m.backupItems = []SetupItemRec{
		{Folder: "apps", Key: "APP reaper", Label: "reaper", Checked: true},
		{Folder: "apps", Key: "APP vlc", Label: "vlc", Checked: false},
	}
	m.backupChecked = map[string]bool{setupValue("apps", "APP reaper"): true}
	m.backupOpen = map[string]bool{"apps": true}
	m.backupOptPicker = m.rebuildBackupOptions()
	m.backupAppsPicker = m.rebuildBackupApps()
	return m
}

// TestEscFromRestoreListShowsTheBackupPage pins the reported bug: Esc on the
// restore list changed the title but left the archive rows in the body, because
// the Backup page's picker was never rebuilt.
func TestEscFromRestoreListShowsTheBackupPage(t *testing.T) {
	m := initialModel()
	m.nav = []screen{scrMain, scrBackup, scrBackupRestore}
	m.w, m.h = 120, 40
	m.backupRecs = []BackupRec{{File: "mosquitomarchy-backup-x.tar.gz", Size: "1M", Date: "2026-01-01 10:00"}}
	m.backupPicker = newNavPicker("", m.backupsList()).SetSize(m.contentSize())
	m, _ = m.update(tuikit.PickerResultMsg{Canceled: true})
	if m.top() != scrBackup {
		t.Fatalf("esc should land on the Backup page, top is %v", m.top())
	}
	if got := m.backupPicker.SelectedValue(); got != "backup" {
		t.Fatalf("the Backup page still shows the archive list (row %q)", got)
	}
}

// TestRestoreOptionsRouting covers the new per-archive page: full is the
// default, switching to safe swaps the notice, and the choices reach the
// backend as flags.
func TestRestoreOptionsRouting(t *testing.T) {
	m := initialModel()
	m.nav = []screen{scrMain, scrBackup, scrBackupRestore}
	m.w, m.h = 120, 40
	m.backupRecs = []BackupRec{{File: "mosquitomarchy-backup-x.tar.gz.gpg", Size: "1M", Date: "2026-01-01 10:00 [encrypted]"}}
	m.backupPicker = newNavPicker("", m.backupsList()).SetSize(m.contentSize())
	m, _ = m.update(tuikit.PickerResultMsg{Value: "mosquitomarchy-backup-x.tar.gz.gpg"})
	if m.top() != scrPassphrase {
		t.Fatalf("an encrypted archive should ask for the passphrase first, top is %v", m.top())
	}
	m, _ = m.update(tuikit.InputResultMsg{Value: "secret"})
	m, _ = m.update(backupManifestMsg{manifest: BackupManifest{
		Config: true, VST: true, Reaper: true, Zen: true, Keepass: true,
		VSTFiles: true, VSTList: true,
		Themes: true, OmarchyPlugins: true, Hyprland: true, Keybindings: "all",
		InstallGroups: []BackupInstallGroup{{Folder: "apps", Items: []string{"douze", "reaper"}}},
	}})
	if m.restoreManifest.Keybindings != "all" {
		t.Fatalf("manifest was not stored: %+v", m.restoreManifest)
	}
	m, _ = m.update(restoreUpdateCheckMsg{})
	if m.top() != scrRestoreOptions {
		t.Fatalf("the restore options should open after the archive is read, top is %v", m.top())
	}
	if m.restoreOpts.Mode != "full" || !strings.Contains(m.restoreNotice, "Full") {
		t.Fatalf("full should be the default with its warning, mode=%q notice=%q", m.restoreOpts.Mode, m.restoreNotice)
	}
	m.restorePicker = m.restorePicker.SelectValue("mode")
	m, _ = m.update(tuikit.PickerResultMsg{Value: "mode"})
	if m.restoreOpts.Mode != "safe" || !strings.Contains(m.restoreNotice, "Safe") {
		t.Fatalf("switching mode should swap the notice, mode=%q notice=%q", m.restoreOpts.Mode, m.restoreNotice)
	}
	m, _ = m.update(tuikit.PickerResultMsg{Value: "restore"})
	if m.top() != scrConfirm {
		t.Fatalf("restore now should show its review prompt first, top is %v", m.top())
	}
	if len(m.confirm.List) < 4 || !strings.Contains(m.confirm.List[0], "PACKAGES") || !strings.Contains(m.confirm.List[1], "Apps") {
		t.Fatalf("restore review must start with the expanded package list: %v", m.confirm.List)
	}
	if len(m.confirm.List) <= m.confirm.ListMaxRows {
		t.Fatalf("long restore plan should be scrollable: %d rows, window %d", len(m.confirm.List), m.confirm.ListMaxRows)
	}
	if !strings.Contains(strings.Join(m.confirm.List, "\n"), "Omawrite at the end") {
		t.Fatalf("restore review omitted the VST list action: %v", m.confirm.List)
	}
	joined := strings.Join(m.pendingArgs, " ")
	for _, want := range []string{"--mode=safe", "--vst=yes", "--reaper=yes", "--zen=yes", "--keepass=yes", "--themes=yes", "--omarchy-plugins=yes", "--hyprland=yes", "--keybindings=all"} {
		if !strings.Contains(joined, want) {
			t.Fatalf("restore args missing %s: %v", want, m.pendingArgs)
		}
	}
	m, cmd := m.update(tea.KeyMsg{Type: tea.KeyEnter})
	if cmd == nil {
		t.Fatal("Enter did not activate the default Restore button")
	}
	answer, ok := cmd().(tuikit.ConfirmResultMsg)
	if !ok || !answer.Yes {
		t.Fatalf("default confirmation answer = %#v, want Restore/Yes", answer)
	}
	m, _ = m.update(answer)
	if m.top() != scrWorking {
		t.Fatalf("confirming the review should start restore, top is %v", m.top())
	}
}

// TestSplitInstallStages pins the ordered prompt+install contract: ordinary
// modules first, then DaVinci, then Guitar Pro, and Ableton last.
func TestSplitInstallStages(t *testing.T) {
	plan := []string{"apps\treaper\tdavinci-resolve\tguitarpro\tableton\tzen"}
	first, stages := splitInstallStages(plan)
	if len(first) != 1 || !strings.Contains(first[0], "reaper") || !strings.Contains(first[0], "zen") {
		t.Fatalf("ordinary modules should run first, got %v", first)
	}
	if strings.Contains(first[0], "davinci") || strings.Contains(first[0], "guitarpro") || strings.Contains(first[0], "ableton") {
		t.Fatalf("special apps leaked into the first stage: %v", first)
	}
	want := []string{"davinci", "guitarpro", "ableton"}
	if len(stages) != len(want) {
		t.Fatalf("expected %d special stages, got %v", len(want), stages)
	}
	for i, k := range want {
		if stages[i].kind != k {
			t.Fatalf("stage %d is %q, want %q", i, stages[i].kind, k)
		}
	}
}

// TestBackupListAlignsParentheses pins the restore list's layout: the
// "(size, date)" block lives in Suffix, starts at the same character on every
// row, and is not part of the marqueed filename.
func TestBackupListAlignsParentheses(t *testing.T) {
	m := initialModel()
	m.backupRecs = []BackupRec{
		{File: "mosquitomarchy-backup-20260101-101010.tar.gz", Size: "1.2G", Date: "2026-01-01 10:10"},
		{File: "mosquitomarchy-backup-20260101-101011-long-name.tar.gz.gpg", Size: "9K", Date: "2026-01-01 10:10 [encrypted]"},
	}
	items := m.backupsList()
	first := strings.Index(items[0].Suffix, "(")
	for _, it := range items[:len(m.backupRecs)] {
		if got := strings.Index(it.Suffix, "("); got != first {
			t.Fatalf("parentheses are not aligned: %d vs %d in %q", got, first, it.Suffix)
		}
		if len(it.Suffix) != len(items[0].Suffix) {
			t.Fatalf("suffixes are not padded to the same width")
		}
		if len(it.Display) != len(items[0].Display) {
			t.Fatalf("names are not padded to the same width")
		}
		if strings.Contains(it.Display, "(") {
			t.Fatalf("the parenthetical leaked into the marqueed title: %q", it.Display)
		}
	}
}

// TestBackupCountRefreshesOnLeavingTheSubmenu pins when the "N selected" figure
// changes.
//
// It must NOT move while you are picking inside the sub-menu, and it must be
// right by the time you are back on the options screen. A figure that updates on
// every keystroke in a list you are still editing is answering a question you
// have not finished asking, and it is distracting on a list where every row is a
// toggle.
func TestBackupCountRefreshesOnLeavingTheSubmenu(t *testing.T) {
	m := backupCountModel()
	if got := backupCountShown(t, m); got != "1" {
		t.Fatalf("expected the initial figure to be 1, got %q", got)
	}

	m, _ = m.update(tuikit.PickerResultMsg{Value: "apps"})
	if m.top() != scrBackupApps {
		t.Fatalf("the sub-menu did not open, top is %v", m.top())
	}
	if got := backupCountShown(t, m); got != "1" {
		t.Fatalf("opening the sub-menu changed the figure to %q", got)
	}

	// Arrows move the cursor. They must not move the number.
	for _, k := range []tea.KeyMsg{{Type: tea.KeyDown}, {Type: tea.KeyUp}} {
		m, _ = m.update(k)
		if got := backupCountShown(t, m); got != "1" {
			t.Fatalf("a cursor key changed the figure to %q", got)
		}
	}

	// Tick one more app while still inside.
	m, _ = m.update(tuikit.PickerToggleMsg{Value: "item:apps:APP vlc"})
	if got := backupCountShown(t, m); got != "1" {
		t.Fatalf("ticking a row changed the figure to %q before leaving the sub-menu", got)
	}

	// Leaving is the moment it catches up.
	m, _ = m.update(tuikit.PickerResultMsg{Value: ""})
	if m.top() != scrBackupOptions {
		t.Fatalf("did not return to the options screen, top is %v", m.top())
	}
	if got := backupCountShown(t, m); got != "2" {
		t.Fatalf("expected 2 once back on the options screen, got %q", got)
	}
}

// TestBackupCountRefreshesOnEscape is the regression that mattered.
//
// ESC — how people actually leave a sub-screen — arrives as
// PickerResultMsg{Canceled: true}, which screenPicked answers BEFORE its switch
// on the screen. So the handler that rebuilds the Backup options picker was
// unreachable from that path and the "N selected" figure kept whatever it said
// when the screen was built. It caught up only when an unrelated key in the
// options screen happened to rebuild the picker.
//
// The first version of this test drove the exit with an empty Value instead of
// Canceled, so it exercised the working path, passed, and hid the bug for as
// long as nobody pressed escape.
func TestBackupCountRefreshesOnEscape(t *testing.T) {
	m := backupCountModel()
	m, _ = m.update(tuikit.PickerResultMsg{Value: "apps"})
	if m.top() != scrBackupApps {
		t.Fatalf("the sub-menu did not open, top is %v", m.top())
	}
	// Tick the second row, so the truth becomes 2 while the options picker still
	// says 1 from when it was built.
	//
	// Ending on a figure that HAPPENS to equal the stale one would make this
	// test pass against the broken code, which is how a regression test ends up
	// asserting nothing: the number has to differ, or it proves nothing.
	m, _ = m.update(tuikit.PickerToggleMsg{Value: "item:apps:APP vlc"})
	if got := backupCountShown(t, m); got != "1" {
		t.Fatalf("inside the sub-menu the options figure is still the stale 1, got %q", got)
	}

	// ESC, not Enter: Canceled takes the early return in screenPicked.
	m, _ = m.update(tuikit.PickerResultMsg{Canceled: true})
	if m.top() != scrBackupOptions {
		t.Fatalf("esc did not return to the options screen, top is %v", m.top())
	}
	if got := backupCountShown(t, m); got != "2" {
		t.Fatalf("after esc the figure should read 2, got %q — the picker was not rebuilt", got)
	}
}

// TestKeybindingsAndHyprlandAreDirectBackupRows pins the placement the user
// asked for: both are on Backup options, not in the app-specific sub-menu.
func TestKeybindingsAndHyprlandAreDirectBackupRows(t *testing.T) {
	m := initialModel()
	m.backupOpts = BackupOpts{VST: "list", Keybindings: "custom", Hyprland: true, HasKeep: true}
	main := m.rebuildBackupOptions()
	found := map[string]bool{}
	for _, it := range main.items {
		found[it.Value] = true
	}
	if !found["keybindings"] || !found["hyprland"] {
		t.Fatalf("keybindings/hyprland missing from Backup options: %v", found)
	}
	for _, it := range m.rebuildBackupAppSettings().items {
		if it.Value == "keybindings" || it.Value == "hyprland" {
			t.Fatalf("%s must not be in App specific settings", it.Value)
		}
	}
}

func TestBackupAppSettingsFollowSelectedApps(t *testing.T) {
	m := initialModel()
	m.backupOpts = BackupOpts{VST: "full", Keepass: true, KeepassSettings: true, Zen: true, Reaper: "full", HasKeep: true, HasZen: true, HasReaper: true}
	m.backupItems = []SetupItemRec{
		{Folder: "apps", Key: "APP REAPER|reaper"},
		{Folder: "apps", Key: "APP KeePassXC|keepassxc"},
		{Folder: "apps", Key: "APP Zen|zen"},
		{Folder: "audio-stack", Key: "audio-plugin-manager"},
	}
	m.backupChecked = map[string]bool{}
	for _, it := range m.backupItems {
		m.backupChecked[setupValue(it.Folder, it.Key)] = true
	}

	settings := func() map[string]bool {
		rows := map[string]bool{}
		for _, it := range m.rebuildBackupAppSettings().items {
			rows[it.Value] = true
		}
		return rows
	}
	for _, row := range []string{"reaper", "keepass", "keepass-settings", "zen", "vst"} {
		if !settings()[row] {
			t.Fatalf("selected app's backup setting %q is missing", row)
		}
	}

	delete(m.backupChecked, setupValue("apps", "APP REAPER|reaper"))
	if settings()["reaper"] {
		t.Fatal("REAPER settings remained after unselecting REAPER")
	}
	delete(m.backupChecked, setupValue("apps", "APP KeePassXC|keepassxc"))
	if rows := settings(); rows["keepass"] || rows["keepass-settings"] {
		t.Fatalf("KeePassXC settings remained after unselecting KeePassXC: %v", rows)
	}
	delete(m.backupChecked, setupValue("apps", "APP Zen|zen"))
	if settings()["zen"] {
		t.Fatal("Zen settings remained after unselecting Zen")
	}

	delete(m.backupChecked, setupValue("audio-stack", "audio-plugin-manager"))
	if got := m.effectiveBackupOpts().VST; got != "list" {
		t.Fatalf("full VST files should fall back to list-only without the audio plugin manager, got %q", got)
	}
	if got := m.cycleBackupVST(1); got != "none" {
		t.Fatalf("VST should cycle list-only to no backup without the audio plugin manager, got %q", got)
	}
}

func TestBackupContentInfoKey(t *testing.T) {
	newModel := func() model {
		m := initialModel()
		m.nav = []screen{scrMain, scrBackup, scrBackupOptions, scrBackupApps}
		m.w, m.h = 120, 40
		m.backupFolders = []FolderRec{{Folder: "apps", Label: "Apps"}}
		m.backupItems = []SetupItemRec{{Folder: "apps", Key: "reaper", Label: "REAPER", Info: "DAW integration details"}}
		m.backupChecked = map[string]bool{setupValue("apps", "reaper"): true}
		m.backupOpen = map[string]bool{"apps": true}
		m.backupAppsPicker = m.rebuildBackupApps()
		return m
	}

	m := newModel()
	idx := indexOfValue(m.backupAppsPicker, folderValue("apps"))
	if idx < 0 {
		t.Fatal("backup category row missing")
	}
	m.backupAppsPicker = m.backupAppsPicker.SelectIndex(idx)
	m, _ = m.update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("i")})
	if m.top() != scrInfo || !strings.Contains(m.info.View(), "Full desktop applications") || !strings.Contains(m.info.View(), "DAW integration details") {
		t.Fatalf("category info did not reuse Setup details: %q", m.info.View())
	}

	m = newModel()
	idx = indexOfValue(m.backupAppsPicker, setupValue("apps", "reaper"))
	if idx < 0 {
		t.Fatal("backup module row missing")
	}
	m.backupAppsPicker = m.backupAppsPicker.SelectIndex(idx)
	m, _ = m.update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("i")})
	if m.top() != scrInfo || !strings.Contains(m.info.View(), "DAW integration details") {
		t.Fatalf("module info missing: %q", m.info.View())
	}
}

func TestBackupOptionsShowsInfoShortcut(t *testing.T) {
	m := backupCountModel()
	if hint := m.backupOptPicker.ShortcutsHint(); !strings.Contains(hint, "i") || !strings.Contains(hint, "info") {
		t.Fatalf("backup legend omits i/info: %q", hint)
	}
	m.backupOptPicker = m.backupOptPicker.SelectValue("apps")
	m, _ = m.update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("i")})
	if m.top() != scrInfo || !strings.Contains(m.info.View(), "install.list") {
		t.Fatalf("i on Packages did not show its info: top=%d info=%q", m.top(), m.info.View())
	}
}

func TestBackupReaperSettingsLabel(t *testing.T) {
	m := initialModel()
	m.backupOpts = BackupOpts{HasReaper: true, Reaper: "settings"}
	m.backupItems = []SetupItemRec{{Folder: "apps", Key: "reaper"}}
	m.backupChecked = map[string]bool{setupValue("apps", "reaper"): true}
	for _, row := range m.rebuildBackupAppSettings().items {
		if row.Value == "reaper" {
			if !strings.HasPrefix(row.Display, "Reaper ressources:") {
				t.Fatalf("unexpected Reaper backup label: %q", row.Display)
			}
			return
		}
	}
	t.Fatal("Reaper resources option missing")
}

func TestBeginBackupGatesAppSettingsBySelection(t *testing.T) {
	m := initialModel()
	m.nav = []screen{scrMain, scrBackup, scrBackupOptions}
	m.backupOpts = BackupOpts{VST: "full", Keepass: true, KeepassSettings: true, Zen: true, Reaper: "full", HasKeep: true, HasZen: true, HasReaper: true}
	m.backupItems = []SetupItemRec{{Folder: "audio-stack", Key: "audio-plugin-manager"}}
	var cmd tea.Cmd
	m, cmd = m.beginBackup()
	if cmd != nil {
		t.Fatal("unencrypted backup should not prompt for a passphrase")
	}
	defer os.Remove(m.backupSelFile)
	got := strings.Join(m.pendingArgs, " ")
	for _, want := range []string{"--vst=list", "--keepass=no", "--keepass-settings=no", "--zen=no", "--reaper=none"} {
		if !strings.Contains(got, want) {
			t.Fatalf("unselected app settings were not excluded (%s): %s", want, got)
		}
	}
}
