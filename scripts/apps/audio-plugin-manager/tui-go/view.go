package main

import (
	"github.com/charmbracelet/lipgloss"
	tuikit "mosquitomarchy.local/tui-kit"
)

// header renders the boxed "mosquito" label (white on theme accent, see
// tuikit.BoxedMosquito) plus an accent-colored subtitle line "audio plugin manager".
// The font (the "Small" patorjk figlet, same shadow family as the boxed
// "mosquito" label so the whole title reads as one cohesive block) and the
// accent color follow the active Omarchy theme. maxW is the picker's
// content width: a subtitle whose art would overflow it falls back to a
// one-line label (never clipped). BoxedMosquito ends with its bottom
// accent strip + a trailing newline so the subtitle sits flush below it
// (no extra blank line between the box and the subtitle — tighter, more
// compact title block per the user's layout reinforcement request).
func header(maxW int) string {
	return tuikit.MosquitoStackedHeader(tuikit.BoxedMosquito(), "audio plugin manager", maxW)
}

// headerRows is the vertical space the header reserves on the home screen
// (8 framed-mosquito rows + 1 blank + 4 subtitle rows + 1 status row +
// 1 slack). The home screen subtracts it from the picker budget so the
// ASCII art is never clipped, even on short terminals (on terminals too
// narrow to fit the full boxed label the header collapses to the
// subtitle only).
const headerRows = 15

// narrowHeaderRows is the budget when the terminal is shorter than the
// full boxed art: we drop the boxed label and keep only the subtitle line
// (rounded to a 2-row block so the picker always has room to breathe).
const narrowHeaderRows = 4

// homeBannerReserve is the row budget the home screen keeps for the boxed
// "mosquito" title (or just the subtitle on short terminals) so bubbletea
// never clips its top rows. Width-aware: too narrow → skip the box.
func (m model) homeBannerReserve() int {
	if m.w < 74 {
		return narrowHeaderRows
	}
	if m.h < 22 {
		return narrowHeaderRows
	}
	return headerRows
}

// contentSize caps how wide/tall a screen's own component (picker, runner)
// is told to render, so it reads as a centered, natural-sized panel rather
// than a box stretched edge-to-edge in the terminal window. The home
// screen's budget is computed from the REAL title height (see the move
// manager's contentSize for the formula rationale).
func (m model) contentSize() (int, int) {
	w := m.w - 8
	if w > 92 {
		w = 92
	}
	if w < 20 {
		w = m.w
	}
	h := m.h - 8
	if h > 26 {
		h = 26
	}
	if h < 8 {
		h = m.h - 4
	}
	if m.top() == scrMain {
		th := lipgloss.Height(header(w))
		reserved := m.h - th - 2 /*bar: notify+hint*/ - 2 /*frame pad*/ - 2 /*spare*/
		if reserved > 26 {
			reserved = 26
		}
		if reserved >= 8 {
			h = reserved
		}
	}
	return w, h
}

// appVersion is the version of this SCRIPT (the audio-plugin-manager module).
const appVersion = "1.0.0"

func (m model) View() string {
	if m.quit {
		return ""
	}
	// Always render the active picker at the CURRENT screen's budget. A
	// picker left over from a previous screen (sized for that screen's
	// one-line title) would otherwise overflow once the 8-row home banner
	// is back on screen — the "interface too high, title hidden briefly"
	// bug when navigating back to page 1. View is a value receiver, so
	// this SetSize only affects the local copy.
	m.picker = m.picker.SetSize(m.contentSize())
	m.infoConfirm = m.infoConfirm.SetSize(m.contentSize())
	var body, title, bar string
	var version string
	// The toast lives on its own reserved row just ABOVE the shortcut hint
	// (tuikit.BottomBar), so a notification never hides the shortcuts and
	// never moves the interface when it auto-disappears.
	barLine := func(hint string) string {
		return tuikit.BottomBar(m.toast.View(), hint, m.contentSizeW())
	}
	homeTitle := func() string {
		// Center the banner across the FULL window width (m.w - 2), the same
		// rule as the mosquitomarchy home screen. The content width (92-col
		// cap) would center it inside the content lane only — and because the
		// version row makes the title block exactly window-wide, FrameScreen
		// skips its own re-centering pass, so the banner would stick left.
		w := m.w - 2
		if w < 40 {
			w = m.w
		}
		if m.homeBannerReserve() == headerRows {
			return lipgloss.NewStyle().Width(w).Align(lipgloss.Center).Render(header(w))
		}
		return lipgloss.NewStyle().Width(w).Align(lipgloss.Center).
			Render(tuikit.MosquitoSubtitle("audio plugin manager", w))
	}
	switch m.top() {
	case scrMain:
		version = "v" + appVersion
		title = homeTitle()
		if m.loading {
			body = "loading…"
		} else {
			body = m.picker.View()
			bar = barLine(m.picker.ShortcutsHint())
		}
	case scrSettings:
		title = screenTitle("Settings", m.contentSizeW())
		body = m.picker.View()
		bar = barLine(m.picker.ShortcutsHint())
	case scrVstMenu:
		title = screenTitle("Windows VST Plugins", m.contentSizeW())
		body = m.picker.View()
		bar = barLine(m.picker.ShortcutsHint())
	case scrPluginList:
		title = screenTitleWithSub("Installed plugins",
			"Tab hides/shows · s sort · ←/→ folders · sort: "+sortModeLabel(m.status.SortMode),
			m.contentSizeW())
		if m.loading {
			body = "loading…"
		} else {
			body = m.picker.View()
			bar = barLine(m.picker.ShortcutsHint())
		}
	case scrFixPluginPick:
		title = screenTitleWithSub("Plugin fixes",
			"□ = no fixes applied · ■ = fixes applied · enter choose · s sort · ←/→ folders · sort: "+sortModeLabel(m.status.SortMode),
			m.contentSizeW())
		if m.loading {
			body = "loading…"
		} else {
			body = m.picker.View()
			bar = barLine(m.picker.ShortcutsHint())
		}
	case scrFixChoose:
		title = screenTitleWithSub("Choose the fixes to apply or remove for "+m.fixPlugin,
			"Tab toggle · s sort · ←/→ folders · enter apply · sort: "+fixSortLabel(m.fixSortDesc),
			m.contentSizeW())
		if m.loading {
			body = "loading…"
		} else {
			body = m.picker.View()
			bar = barLine(m.picker.ShortcutsHint())
		}
	case scrUninstallPick:
		title = screenTitleWithSub("Uninstall which plugin(s)?",
			"Tab select · s sort · ←/→ folders · x open folder · sort: "+sortModeLabel(m.status.SortMode),
			m.contentSizeW())
		if m.loading {
			body = "loading…"
		} else {
			body = m.picker.View()
			bar = barLine(m.picker.ShortcutsHint())
		}
	case scrPrefixMovePluginPick:
		title = screenTitle("Manage prefixes — move a plugin", m.contentSizeW())
		if m.loading {
			body = "loading…"
		} else {
			body = m.picker.View()
			bar = barLine(m.picker.ShortcutsHint())
		}
	case scrPrefixMoveTargetPick:
		title = screenTitle("Move to which prefix?", m.contentSizeW())
		if m.loading {
			body = "loading…"
		} else {
			body = m.picker.View()
			bar = barLine(m.picker.ShortcutsHint())
		}
	case scrStandalonePick:
		title = screenTitle("Launch a standalone plugin", m.contentSizeW())
		if m.loading {
			body = "loading…"
		} else {
			body = m.picker.View()
			bar = barLine(m.picker.ShortcutsHint())
		}
	case scrExecsToggle:
		title = screenTitle("Toggle which executables appear in the menu", m.contentSizeW())
		if m.loading {
			body = "loading…"
		} else {
			body = m.picker.View()
			bar = barLine(m.picker.ShortcutsHint())
		}
	case scrReconcileOrphansTick:
		title = screenTitle("Found on disk but not tracked", m.contentSizeW())
		if m.loading {
			body = "loading…"
		} else {
			body = m.picker.View()
			bar = barLine(m.picker.ShortcutsHint())
		}
	case scrInfo:
		body = m.info.View()
		bar = barLine(m.info.ShortcutsHint())
	case scrPluginHandlerConfirm:
		// The global-rules confirmation shares the Readme/Info frame (a
		// bounded, wrapping modal) but keeps Yes/No semantics.
		body = m.infoConfirm.View()
		bar = barLine(m.infoConfirm.ShortcutsHint())
	case scrReconcileMissingInfo, scrReconcileMissingRemove,
		scrUninstallConfirm, scrInstallPrefixChoice, scrPrefixMoveConfirm,
		scrSuperfileInstallConfirm, scrPluginListSaveConfirm,
		scrPluginsRootConfirm, scrRunnerSuccessConfirm, scrQuitConfirm,
		scrWizardRoot, scrInstallFixesConfirm:
		body = m.confirm.View()
		bar = barLine(m.confirm.ShortcutsHint())
	case scrInstallPrefixName, scrPrefixMoveTargetName:
		body = m.input.View()
		bar = barLine(m.input.ShortcutsHint())
	case scrUninstalling, scrInstalling, scrMoving, scrSuperfileInstalling, scrPluginsRootMigrating:
		title = screenTitle("Working…", m.contentSizeW())
		body = m.runner.View()
		bar = barLine(m.runner.ShortcutsHint())
	case scrWizardDaw:
		title = screenTitle("First launch — pointing your DAWs at the plugins folder", m.contentSizeW())
		body = m.runner.View()
		bar = barLine(m.runner.ShortcutsHint())
	}

	// NOTE: the toast is rendered once, by barLine -> tuikit.BottomBar,
	// on its own reserved row above the shortcut hint. It must NOT also be
	// appended to the body (a leftover duplicate did exactly that here,
	// which both showed the notification twice and shoved the centred body
	// around whenever one appeared).
	if m.w == 0 || m.h == 0 {
		return title + "\n" + body + "\n" + bar
	}
	return tuikit.FrameScreenVersion(m.w, m.h, title, body, bar, version)
}

// screenTitle renders a centered accent-colored bold title for the
// current screen, in the universal layout's pinned-top slot (FrameScreen
// pulls it up to the top of the window). Identical style to the live
// manager's screen titles — same font weight, same accent, same centered
// alignment — so every screen's title bar looks like one cohesive title
// bar across the whole app.
func screenTitle(text string, maxW int) string {
	return lipgloss.NewStyle().
		Width(maxW).
		Align(lipgloss.Center).
		Render(tuikit.StyleAccent.Bold(true).Render(text))
}

// screenTitleWithSub renders the same accent title as screenTitle with a
// second, muted subtitle line under it — used where the screen's own
// behaviour needs spelling out (e.g. the "Installed plugins" list's
// hide/show key). Both lines are centered in the same maxW block so they
// read as one title unit.
func screenTitleWithSub(title, sub string, maxW int) string {
	t := lipgloss.NewStyle().Width(maxW).Align(lipgloss.Center).
		Render(tuikit.StyleAccent.Bold(true).Render(title))
	s := lipgloss.NewStyle().Width(maxW).Align(lipgloss.Center).
		Render(tuikit.StyleHelp.Render(sub))
	return t + "\n" + s
}

// contentSizeW returns the content width without re-running the full
// contentSize (it doesn't depend on homeBannerReserve in a way that
// matters for header centering).
func (m model) contentSizeW() int {
	w, _ := m.contentSize()
	return w
}
