package main

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/lipgloss"
	tuikit "mosquitomarchy.local/tui-kit"
)

// appVersion is the version of this SCRIPT (the mosquitOmarchy module), shown
// top-left on the first page. It is not the version of anything it installs.
const appVersion = "1.0.0"

// contentPolicy is the shared sizing policy (tuikit.ManagerContent). Declared
// here once so the setup TUI and the four managers agree on how wide and how
// tall a panel is allowed to be.
var contentPolicy = tuikit.ManagerContent

// header renders the mosquitomarchy banner at a rung that FITS maxW.
//
// It used to be tuikit.MosquitOmarchyTitle(maxW), which rendered the
// 121-column wordmark and let lipgloss wrap it — in every tile narrower than
// 121 columns, which is most tiles, the wordmark was shredded into glyph
// fragments. Now the ladder picks the biggest form that fits and the title
// degrades: full wordmark, then a compact box, then plain text. Never wrapped.
func header(maxW int) string {
	return titleLadder(maxW).Render(maxW, 9)
}

// homeBannerReserve is how many rows the home title actually occupies RIGHT
// NOW. It used to be a hardcoded 14 (8 banner + 5 subtitle + 1 blank) chosen
// by a magic w<74 || h<24 threshold, which meant the reserve and the drawn
// title could disagree — and when they did, the title was what got clipped.
// It is now measured off the rung the ladder chose.
func (m *model) homeBannerReserve() int {
	return m.homeLayout().TitleRows
}

// filterBarLine composes the filter zone for the Setup/Uninstall screens:
// when open ('f'), a small ACCENT-framed box (slightly taller than a plain
// row) sits right above the shortcut hint bar. The empty state shows ONLY
// the grey word "filter" — in the SAME grey the unusable picker rows use
// (ColorDisabled, not ColorMuted), so a placeholder that is not a real
// control does not read as a brighter, more actionable one. It is replaced
// by the typed text the moment you start typing. No extra help text inside —
// the shortcuts bar already documents the keys.
func (m model) filterBarLine(hint string) string {
	if !m.filterOpen {
		return hint
	}
	inner := m.filterText + "▏"
	if m.filterText == "" {
		inner = lipgloss.NewStyle().Foreground(tuikit.ColorDisabled).Render("filter")
	}
	// Fixed 44-col field, centered: the box NEVER grows with the text, so
	// there is no alternating left/right widening (a plain Align(Center)
	// flipped the growth side every other keystroke).
	inner = lipgloss.NewStyle().Width(44).Align(lipgloss.Center).Render(inner)
	box := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(tuikit.ColorAccent).
		Foreground(tuikit.ColorAccent).
		Padding(0, 4).
		Render(inner)
	w := m.contentSizeW()
	return lipgloss.NewStyle().Width(w).Align(lipgloss.Center).Render(box) + "\n" + hint
}

func (m model) View() string {
	if m.quit {
		return ""
	}
	var body, title, bar string
	var version string
	w, _ := m.contentSize()

	// contentSize() walks the nav stack and re-derives the budget; it was being
	// called nineteen times per frame through here and through contentSizeW(),
	// and contentSize() alone showed up as 1.8ms in a CPU profile. One call per
	// frame is enough.
	cw := w
	barLine := func(hint string) string {
		return tuikit.BottomBar(m.toast.View(), hint, cw)
	}

	// Re-size ONLY the pickers this frame can actually draw.
	//
	// This used to SetSize all seventeen of them on every frame, "defensively".
	// SetSize is not free: each call re-runs bubbles' pagination four times to
	// settle PerPage/TotalPages, so seventeen of them cost roughly sixty-eight
	// list measurements per frame. In Setup that alone was 13ms of the ~16ms
	// frame budget, which is why moving the cursor there felt like it had a
	// delay while the very same list was instant on the Status screen.
	//
	// Sizing the top screen's picker (plus the root menu, which a few overlays
	// fall back to) is enough: a picker is laid out the moment its screen is
	// entered, and a hidden one cannot be seen to be mis-sized.
	m.mainPicker = m.mainPicker.SetSize(m.mainContentSize())
	switch m.top() {
	case scrMain, scrSettings, scrBackupRestore:
		m.pickPicker = m.pickPicker.SetSize(m.contentSize())
	case scrSetup:
		m.setupPicker = m.setupPicker.SetSize(m.contentSize())
	case scrSetupCat:
		m.setupCatPicker = m.setupCatPicker.SetSize(m.contentSize())
	case scrStatus:
		m.statusPicker = m.statusPicker.SetSize(m.contentSize())
	case scrUpdate:
		m.updatePicker = m.updatePicker.SetSize(m.contentSize())
	case scrHealth:
		m.healthPicker = m.healthPicker.SetSize(m.contentSize())
	case scrKB:
		m.kbPicker = m.kbPicker.SetSize(m.contentSize())
	case scrKBList:
		m.kbListPicker = m.kbListPicker.SetSize(m.contentSize())
	case scrKBCat:
		m.kbCatPicker = m.kbCatPicker.SetSize(m.contentSize())
	case scrKBItems:
		m.kbItemPicker = m.kbItemPicker.SetSize(m.contentSize())
	case scrKBKeys, scrKBInput:
		m.kbKeyPicker = m.kbKeyPicker.SetSize(m.contentSize())
	case scrBackup:
		m.backupPicker = m.backupPicker.SetSize(m.contentSize())
	case scrBackupOptions:
		m.backupOptPicker = m.backupOptPicker.SetSize(m.contentSize())
	case scrBackupApps:
		m.backupAppsPicker = m.backupAppsPicker.SetSize(m.contentSize())
	case scrPreinstalls:
		m.preinstallPicker = m.preinstallPicker.SetSize(m.contentSize())
	case scrMenuEntries:
		m.menuEntriesPicker = m.menuEntriesPicker.SetSize(m.contentSize())
	case scrThemeFolder:
		m.themeFolderPicker = m.themeFolderPicker.SetSize(m.contentSize())
	case scrThemeImage:
		m.themeImagePicker = m.themeImagePicker.SetSize(m.contentSize())
	case scrThemeDone:
		m.themeDonePicker = m.themeDonePicker.SetSize(m.contentSize())
	}
	// The info overlay and the runner are drawn on top of whatever screen is
	// current, so they always need the current budget.
	m.info = m.info.SetSize(m.contentSize())
	m.runner = m.runner.SetSize(m.contentSize())

	switch m.top() {
	case scrMain:
		title = m.homeTitle()
		body = m.mainPicker.View()
		bar = barLine(m.mainPicker.ShortcutsHint())
		version = "v" + appVersion
	case scrStatus:
		title = screenTitle("Status", w)
		body = m.statusPicker.View()
		bar = barLine(m.statusPicker.ShortcutsHint())
	case scrSetup:
		if m.treeMode == "uninstall" {
			title = screenTitle("Uninstall", w)
		} else {
			title = screenTitle("Setup", w)
		}
		body = m.setupPicker.View()
		bar = barLine(m.filterBarLine(m.setupPicker.ShortcutsHint()))
	case scrSetupCat:
		if m.treeMode == "uninstall" {
			title = screenTitle("Uninstall — "+m.setupCatLabel(), w)
		} else {
			title = screenTitle("Setup — "+m.setupCatLabel(), w)
		}
		body = m.setupCatPicker.View()
		bar = barLine(m.filterBarLine(m.setupCatPicker.ShortcutsHint()))
	case scrUpdate:
		title = screenTitle("Update", w)
		body = m.updateBody()
		bar = barLine(m.updatePicker.ShortcutsHint())
	case scrHealth:
		title = screenTitle("Health check", w)
		body = m.healthPicker.View()
		bar = barLine(m.healthPicker.ShortcutsHint())
	case scrKB:
		title = screenTitle("Keybindings", w)
		body = m.kbPicker.View()
		bar = barLine(m.kbPicker.ShortcutsHint())
	case scrKBList:
		title = screenTitle("Keybindings — managed", w)
		body = m.kbListPicker.View()
		bar = barLine(m.kbListPicker.ShortcutsHint())
	case scrKBCat:
		title = screenTitle("Keybindings — add", w)
		body = m.kbCatPicker.View()
		bar = barLine(m.kbCatPicker.ShortcutsHint())
	case scrKBItems:
		title = screenTitle("Keybindings — add", w)
		body = m.kbItemPicker.View()
		bar = barLine(m.kbItemPicker.ShortcutsHint())
	case scrKBKeys:
		title = screenTitle("Keybindings — pick a key", w)
		body = m.kbKeyPicker.View()
		bar = barLine(m.kbKeyPicker.ShortcutsHint())
	case scrKBInput:
		title = screenTitle("Keybindings — custom command", w)
		body = m.kbInput.View()
		bar = barLine(m.kbInput.ShortcutsHint())
	case scrSettings:
		title = screenTitle("Extras", w)
		body = m.pickPicker.View()
		bar = barLine(m.pickPicker.ShortcutsHint())
	case scrThemeFolder:
		title = screenTitle("Create a theme from an image", w)
		body = m.themeFolderPicker.View()
		bar = barLine(m.themeFolderPicker.ShortcutsHint())
	case scrThemeImage:
		title = screenTitle("Create a theme from an image", w)
		body = m.themeImagePicker.View()
		bar = barLine(m.themeImagePicker.ShortcutsHint())
	case scrThemeInput:
		title = screenTitle("Create a theme — image folder", w)
		body = m.themeInput.View()
		bar = barLine(m.themeInput.ShortcutsHint())
	case scrThemeName:
		title = screenTitle("Create a theme — name", w)
		body = m.themeInput.View()
		bar = barLine(m.themeInput.ShortcutsHint())
	case scrThemeDone:
		title = screenTitle("Create a theme from an image", w)
		body = m.themeDonePicker.View()
		bar = barLine(m.themeDonePicker.ShortcutsHint())
	case scrThemeUnlock:
		title = screenTitle("Theming", w)
		body = m.themeUnlockPicker.View()
		bar = barLine(m.themeUnlockPicker.ShortcutsHint())
	case scrThemeUninstall:
		title = screenTitle("Uninstall themes", w)
		body = m.themeUninstallPicker.View()
		bar = barLine(m.themeUninstallPicker.ShortcutsHint())
	case scrThemeRestore:
		title = screenTitle("Restore the stock Omarchy themes", w)
		body = m.themeRestorePicker.View()
		bar = barLine(m.themeRestorePicker.ShortcutsHint())
	case scrBackup:
		title = screenTitle("Backup / Restore", w)
		body = m.backupBody()
		bar = barLine(m.backupPicker.ShortcutsHint())
	case scrPreinstalls:
		title = screenTitle("Choose which Omarchy preinstalls to remove", w)
		body = m.preinstallPicker.View()
		bar = barLine(m.preinstallPicker.ShortcutsHint())
	case scrMenuEntries:
		title = screenTitle("Menu entries", w)
		// The stored picker, not a fresh rebuild: pickPicker2View/…Hint each
		// called rebuildMenuEntriesPicker and discarded the result, so the rows
		// on screen were a throwaway object with no cursor and no key routing.
		// Before the first fetch lands it is empty, so fall back to a build so
		// the "loading…" row is not a blank body.
		me := m.menuEntriesPicker
		if me.Len() == 0 {
			me = m.rebuildMenuEntriesPicker()
		}
		body = me.View()
		bar = barLine(me.ShortcutsHint())
	case scrQuickFixes:
		title = screenTitle("Fixes", w)
		// The stored picker, like Menu entries above: rebuilding for the draw
		// would throw away the cursor and the tick marks the user just made.
		qf := m.quickFixPicker
		if qf.Len() == 0 {
			qf = m.rebuildQuickFixes()
		}
		body = qf.View()
		bar = barLine(qf.ShortcutsHint())
	case scrBackupRestore:
		title = screenTitle("Restore a backup", w)
		body = m.backupPicker.View()
		bar = barLine(m.backupPicker.ShortcutsHint())
	case scrBackupOptions:
		title = screenTitle("Backup options", w)
		body = m.backupOptPicker.View()
		bar = barLine(m.backupOptPicker.ShortcutsHint())
	case scrBackupApps:
		title = screenTitle("Backup content — apps / TUIs / webapps", w)
		body = m.backupAppsPicker.View()
		bar = barLine(m.backupAppsPicker.ShortcutsHint())
	case scrPassphrase:
		title = screenTitle("Passphrase", w)
		body = m.passInput.View()
		bar = barLine(m.passInput.ShortcutsHint())
	case scrConfirm:
		title = screenTitle("Confirm", w)
		body = m.confirm.View()
		bar = barLine(m.confirm.ShortcutsHint())
	case scrInfo:
		title = screenTitle("Info", w)
		body = m.info.View()
		bar = barLine(m.info.ShortcutsHint())
	case scrWorking:
		title = screenTitle("Working…", w)
		body = m.runner.View()
		bar = barLine(m.runner.ShortcutsHint())
	}

	if m.w == 0 || m.h == 0 {
		return title + "\n" + body + "\n" + bar
	}
	return tuikit.FrameScreenVersion(m.w, m.h, title, body, bar, version)
}

// homeTitle renders the pinned-top banner on the main menu. It draws the SAME
// rung homeBannerReserve() budgeted for, so the reserved rows and the drawn
// rows are the same number by construction.
func (m *model) homeTitle() string {
	w := m.titleWidth()
	title := m.homeLayout().RenderLadder(w, titleLadder(w))
	return lipgloss.NewStyle().Width(m.w).Align(lipgloss.Center).Render(title)
}

// updateBody shows the update zone's findings above the picker.
func (m model) updateBody() string {
	// Two clear status lines: the mosquitOmarchy scripts/repo first, then the
	// installed modules (apps/tuis/…). Each says explicitly when it is current,
	// so "nothing to do" is never ambiguous (and never duplicated as a row).
	var lines []string
	if m.updateRec.RepoUpdate {
		lines = append(lines, tuikit.StyleWarn.Render("● update available!"))
	} else {
		lines = append(lines, tuikit.StyleOK.Render("all scripts are up to date!"))
	}
	if n := len(m.updateRec.Modules); n == 0 {
		lines = append(lines, tuikit.StyleMuted.Render("nothing to re-apply for the installed modules"))
	} else {
		lines = append(lines, tuikit.StyleAccent.Render(fmt.Sprintf("● %d installed module(s) have updates — press i for the list, tab on the list to skip some", n)))
	}
	return lipgloss.JoinVertical(lipgloss.Center,
		lipgloss.NewStyle().Width(m.contentSizeW()).Align(lipgloss.Center).Render(strings.Join(lines, "\n")),
		"",
		m.updatePicker.View(),
	)
}

// backupBody explains how backups work, above the options.
func (m model) backupBody() string {
	// Kept deliberately short. The body is vertically centred in the gap
	// between the title and the shortcut bar, so a tall paragraph overflows
	// that gap on a normal terminal: the centring collapses and the help
	// text glues straight to the title, which is the one thing the layout
	// rule forbids — and it made this screen read as a wall of text with
	// no title rather than as a titled page like every other screen.
	explain := []string{
		"Dated archives of your configuration, written to",
		"~/omarchy-backups as omarchy-backup-<date>.tar.gz — plain, or",
		"ENCRYPTED (AES-256 .gpg, asks for a passphrase).",
		"Restoring overwrites the files an archive contains.",
	}
	head := lipgloss.NewStyle().Width(m.contentSizeW()).Align(lipgloss.Center).
		Render(tuikit.StyleHelp.Render(strings.Join(explain, "\n")))
	return lipgloss.JoinVertical(lipgloss.Center, head, "", m.backupPicker.View())
}

// screenTitle renders a centered accent-colored bold title for the current
// screen (FrameScreen pins it to the top of the window).
func screenTitle(text string, maxW int) string {
	return lipgloss.NewStyle().
		Width(maxW).
		Align(lipgloss.Center).
		Render(tuikit.StyleAccent.Bold(true).Render(text))
}

// pickPicker2View renders the menu-entries picker body.
func (m model) pickPicker2View() string {
	p := m.rebuildMenuEntriesPicker()
	return p.View()
}

func (m model) pickPicker2Hint() string {
	p := m.rebuildMenuEntriesPicker()
	return p.ShortcutsHint()
}
