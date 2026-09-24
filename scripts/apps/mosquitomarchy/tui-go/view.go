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

// header renders the full mosquitOmarchy banner: the boxed "mosquito"
// label plus the "-marchy" subtitle, side by side on wide-enough panels and
// stacked otherwise (tuikit.MosquitOmarchyTitle). maxW is the content
// width the banner may use.
func header(maxW int) string {
	return tuikit.MosquitOmarchyTitle(maxW)
}

// homeBannerReserve is how many top rows the home screen keeps for the
// banner (14 = 8 boxed rows + 5 subtitle rows + 1 blank) so it is never
// clipped; on short/narrow terminals it collapses to the subtitle only.
const homeBannerReserve = 14
const narrowReserve = 4

func (m model) homeBannerReserve() int {
	if m.w < 74 || m.h < 24 {
		return narrowReserve
	}
	return homeBannerReserve
}

// filterBarLine composes the filter zone for the Setup/Uninstall screens:
// when open ('f'), a small rectangular box with the LIVE filter text and a
// blinking-style cursor sits right above the shortcut hint bar; the type
// stream also drives the live list filter.
func (m model) filterBarLine(hint string) string {
	if !m.filterOpen {
		return hint
	}
	box := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(tuikit.ColorMuted).

		Render(fmt.Sprintf("filter: ┃ %s▏  (type to refine · esc clear · f close)", m.filterText))
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

	barLine := func(hint string) string {
		return tuikit.BottomBar(m.toast.View(), hint, m.contentSizeW())
	}

	// Defensive re-size: a picker sized at another screen's budget can
	// overflow under the banner for one frame. m is a value copy.
	m.mainPicker = m.mainPicker.SetSize(m.mainContentSize())
	m.setupPicker = m.setupPicker.SetSize(m.contentSize())
	m.setupCatPicker = m.setupCatPicker.SetSize(m.contentSize())
	m.updatePicker = m.updatePicker.SetSize(m.contentSize())
	m.backupPicker = m.backupPicker.SetSize(m.contentSize())
	m.backupOptPicker = m.backupOptPicker.SetSize(m.contentSize())
	m.backupAppsPicker = m.backupAppsPicker.SetSize(m.contentSize())
	m.info = m.info.SetSize(m.contentSize())
	m.runner = m.runner.SetSize(m.contentSize())
	m.healthPicker = m.healthPicker.SetSize(m.contentSize())
	m.kbPicker = m.kbPicker.SetSize(m.contentSize())
	m.kbListPicker = m.kbListPicker.SetSize(m.contentSize())
	m.kbCatPicker = m.kbCatPicker.SetSize(m.contentSize())
	m.kbItemPicker = m.kbItemPicker.SetSize(m.contentSize())
	m.kbKeyPicker = m.kbKeyPicker.SetSize(m.contentSize())

	switch m.top() {
	case scrMain:
		title = m.homeTitle()
		body = m.mainPicker.View()
		bar = barLine(m.mainPicker.ShortcutsHint())
		version = "v" + appVersion
	case scrStatus:
		title = screenTitle("Status", w)
		body = m.info.View()
		bar = barLine(m.info.ShortcutsHint())
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
	case scrBackup:
		title = screenTitle("Backup / Restore", w)
		body = m.backupBody()
		bar = barLine(m.backupPicker.ShortcutsHint())
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

// homeTitle renders the pinned-top banner on the main menu: the full boxed
// "mosquitomarchy" wordmark + "setup" subtitle when the window allows it,
// otherwise just the subtitle. The boxed wordmark is ~121 columns wide, so
// the banner uses the full window width rather than the 92-column content cap.
func (m model) homeTitle() string {
	w := m.w - 2
	if w < 40 {
		w = m.w
	}
	if m.homeBannerReserve() == homeBannerReserve {
		return lipgloss.NewStyle().Width(w).Align(lipgloss.Center).Render(header(w))
	}
	return lipgloss.NewStyle().Width(w).Align(lipgloss.Center).
		Render(tuikit.MosquitoSubtitle("setup", w))
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
		lines = append(lines, tuikit.StyleOK.Render("all modules & scripts are up to date!"))
	}
	if n := len(m.updateRec.Modules); n == 0 {
		lines = append(lines, tuikit.StyleMuted.Render("no update available for the installed modules"))
	} else {
		lines = append(lines, tuikit.StyleAccent.Render(fmt.Sprintf("● %d installed module(s) have updates — select them below and Apply", n)))
	}
	return lipgloss.JoinVertical(lipgloss.Center,
		lipgloss.NewStyle().Width(m.contentSizeW()).Align(lipgloss.Center).Render(strings.Join(lines, "\n")),
		"",
		m.updatePicker.View(),
	)
}

// backupBody explains how backups work, above the options.
func (m model) backupBody() string {
	explain := []string{
		"Backups are dated archives of your configuration — Hyprland, terminal,",
		"shell, Omarchy extensions and plugins, keymaps, app preferences — written",
		"to ~/omarchy-backups as omarchy-backup-<date>.tar.gz.",
		"",
		"Choose a PLAIN archive, or an ENCRYPTED one (AES-256 .gpg): the encrypted form asks for a passphrase you will re-enter to restore it.",
		"Restoring overwrites the files an archive contains with the archived versions.",
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
