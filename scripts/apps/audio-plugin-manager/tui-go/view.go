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
	return titleLadder(maxW).Render(maxW, headerRows)
}

// contentPolicy is the shared panel-sizing policy (tuikit.ManagerContent), so
// this TUI and the other four cannot drift apart on the arithmetic again.
var contentPolicy = tuikit.ManagerContent

// titleLadder is the home banner: the full stacked boxed mosquito plus the
// "audio plugin manager" subtitle when the tile allows, then the subtitle
// alone in a compact box, then plain text. Rungs are measured once and chosen
// by fit, so the banner is never rendered too wide and wrapped.
func titleLadder(width int) tuikit.TitleLadder {
	return tuikit.StackedLadder(tuikit.BoxedMosquito(), "audio plugin manager", width)
}

// headerRows is the tallest the home banner may be: the full stacked title
// block. It is a CAP now, not an estimate — the actual reserve is whatever rung
// the ladder picked, measured at homeBannerReserve. That was the bug: a fixed
// 15 reserved against a header that rendered 13 rows on one terminal and 4 on
// another, so the two disagreed and the title was what got clipped.
const headerRows = 15

// homeLayout picks the banner rung that fits and returns the matching budget.
func (m *model) homeLayout() tuikit.Layout {
	w := m.contentWidth()
	return tuikit.LayoutForLadder(w, m.h, titleLadder(w))
}

// contentWidth is the one width number every part of this TUI measures
// against, so the ladder and the panel are never sized against different widths.
func (m *model) contentWidth() int {
	return contentPolicy.ContentWidth(m.w)
}

// homeBannerReserve is how many rows the home banner actually occupies right
// now — the rung the ladder chose, not a guess about what would fit.
func (m *model) homeBannerReserve() int {
	return m.homeLayout().TitleRows
}

// homeTitle renders the pinned-top banner, centered across the full window
// rather than the content lane: the version row makes the title block exactly
// window-wide, so FrameScreen skips its own re-centering pass and a narrower
// block would stick left.
//
// It renders the SAME rung homeBannerReserve budgeted for, so the reserved
// rows and the drawn rows agree by construction.
func (m *model) homeTitle() string {
	w := m.contentWidth()
	title := m.homeLayout().RenderLadder(w, titleLadder(w))
	return lipgloss.NewStyle().Width(m.w).Align(lipgloss.Center).Render(title)
}

// contentSize caps how wide/tall a screen's own component (picker, runner)
// is told to render, so it reads as a centered, natural-sized panel rather
// than a box stretched edge-to-edge in the terminal window. The home
// screen's budget is computed from the REAL title height (see the move
// manager's contentSize for the formula rationale).
func (m model) contentSize() (int, int) {
	if m.top() == scrMain {
		return contentPolicy.Size(m.w, m.h, m.homeLayout().TitleRows)
	}
	return contentPolicy.Size(m.w, m.h, subScreenTitleRows)
}

// subScreenTitleRows: every screen except the home menu uses a single accent
// line as its title.
const subScreenTitleRows = 1

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

	switch m.top() {
	case scrMain:
		version = "v" + appVersion
		title = m.homeTitle()
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
	case scrStandaloneManage:
		title = screenTitle("Registered standalones", m.contentSizeW())
		if m.loading {
			body = "loading…"
		} else {
			body = m.picker.View()
			bar = barLine(m.picker.ShortcutsHint())
		}
	case scrInstallPick:
		title = screenTitle("Install a plugin", m.contentSizeW())
		body = "waiting for the file picker…\n\nesc goes back"
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
		// The sub-title keeps the sort state and the □/■ symbol legend (which
		// is not a key legend) but drops the key list: the keys already live in
		// the bottom bar (picker.ShortcutsHint). Two shortcut zones on one page
		// drift apart -- this one had started claiming "enter choose" while the
		// bar said something else.
		title = screenTitleWithSub("Plugin fixes",
			"□ = no fixes applied · ■ = fixes applied · sort: "+sortModeLabel(m.status.SortMode),
			m.contentSizeW())
		if m.loading {
			body = "loading…"
		} else {
			body = m.picker.View()
			bar = barLine(m.picker.ShortcutsHint())
		}
	case scrFixChoose:
		// The title names what the fixes are ABOUT, in the wording the user
		// asked for: the plugin stem for a single-plugin visit, the suite for a
		// whole-vendor one.
		//
		// It used to print m.fixPlugin raw, which is a picker VALUE
		// ("vst:<type>:<full/path>") — so the title carried the plugin's entire
		// path across the panel, and on a vendor visit it was the empty string
		// and the sentence ended on a dangling "for ". m.fixScope is that noun,
		// resolved once when the catalog lands.
		question := "Choose the fixes to apply or remove to " + m.fixScope
		if m.fixVendor != "" {
			question = "Choose the fixes to apply or remove to every " + m.fixScope + " plugin"
		}
		// The picker's own header is left empty: it carried the same sentence,
		// so the page said it twice, once of them with the wrong name.
		title = screenTitleWithSub(question,
			"sort: "+fixSortLabel(m.fixSortDesc),
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
	case scrLaunchExePick:
		title = screenTitle("Launch an executable in the default prefix", m.contentSizeW())
		body = m.picker.View()
		bar = barLine(m.picker.ShortcutsHint())
	case scrLaunchExeBrowse:
		// There is no body of our own while the file manager is up: the screen
		// is a hand-off, and saying "loading…" over it would claim the manager
		// is fetching something. The picker is stale from the previous screen.
		title = screenTitle("Pick an executable — "+baseName(m.launchExePrefix), m.contentSizeW())
		body = "  Waiting for the file manager…\n\n  It only chooses the file. This manager launches it\n  through wine in "+baseName(m.launchExePrefix)+"."
		bar = barLine("")
	case scrLaunchExeList:
		title = screenTitle("Launch which executable?", m.contentSizeW())
		if m.loading {
			body = "loading…"
		} else {
			body = m.picker.View()
			bar = barLine(m.picker.ShortcutsHint())
		}
	case scrPrefixPrefPick:
		title = screenTitle("Default wine prefix", m.contentSizeW())
		if m.loading {
			body = "loading…"
		} else {
			body = m.picker.View()
			bar = barLine(m.picker.ShortcutsHint())
		}
	case scrPrefixPrefRisk:
		title = screenTitle("Change the default wine prefix?", m.contentSizeW())
		body = m.confirm.View()
		bar = barLine(m.confirm.ShortcutsHint())
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
		scrWizardRoot, scrInstallFixesConfirm, scrInstallFixesHow, scrFixApplyConfirm,
		scrCleanupConfirm, scrQuarantineClearConfirm,
		scrQuarantineClearDone:
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
