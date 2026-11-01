package main

import (
	"strings"

	"github.com/charmbracelet/lipgloss"
	tuikit "mosquitomarchy.local/tui-kit"
)

// header renders the boxed "mosquito" label (white on theme accent, see
// tuikit.BoxedMosquito) plus an accent-colored subtitle line "move manager".
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
// "move manager" subtitle when the tile allows, then the subtitle alone in a
// compact box, then plain text. Rungs are measured once here and chosen by fit,
// so the banner is never rendered too wide and wrapped.
func titleLadder(width int) tuikit.TitleLadder {
	return tuikit.StackedLadder(tuikit.BoxedMosquito(), "move manager", width)
}

// headerRows is the tallest the home banner may be: the full stacked title
// block. It is a CAP now, not an estimate — the actual reserve is whatever rung
// the ladder picked, measured at homeBannerReserve. That was the bug: a fixed
// 15 reserved against a header that rendered 13 rows on one terminal and 4 on
// another, so the two disagreed and the title was what got clipped.
const headerRows = 15

// statusRows is the extra row the home screen needs under the list for the
// connection line ("move.local ●"), which is drawn as part of the body.
const statusRows = 1

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

// contentSize caps how wide/tall a screen's own component (picker, runner)
// is told to render, so it reads as a centered, natural-sized panel rather
// than a box stretched edge-to-edge in the terminal window.
//
// The home screen's budget is computed from the REAL title height (the
// boxed "mosquito" art is 8 rows, the Small-font subtitle is 5 rows at
// wide panels and collapses to one row on narrow ones — a hardcoded
// reserve number can never track all of that). The formula subtracts,
// in order: title rows, the status line that sits UNDER the options
// ("move.local ●"), the one-row toast/shortcut bar, the picker frame's
// own 2-row padding, and 2 spare rows — so the composed FrameScreen
// output is always exactly the window height and never overflows.
func (m *model) contentSize() (int, int) {
	return m.contentSizeFor(m.top() == scrMain)
}

// mainContentSize is contentSize() as it would be on the home screen, no
// matter which screen is currently on top. The home picker is rebuilt by a
// background status refresh that can land while a sub-screen is up; laying
// it out at that sub-screen's budget (often taller, so every row fits and
// no pagination row is reserved) left it one frame out of step when the
// user popped back — the boxed exit row appeared then vanished on the next
// rebuild. The home picker is now always sized for the home budget, so the
// pop frame and the frame that follows are identical.
func (m *model) mainContentSize() (int, int) {
	return m.contentSizeFor(true)
}

func (m *model) contentSizeFor(isMain bool) (int, int) {
	if isMain {
		p := contentPolicy
		p.ExtraRows = statusRows
		return p.Size(m.w, m.h, m.homeLayout().TitleRows)
	}
	return contentPolicy.Size(m.w, m.h, subScreenTitleRows)
}

// subScreenTitleRows: every screen except the home menu uses a single accent
// line as its title.
const subScreenTitleRows = 1

// appVersion is the version of this SCRIPT (the ableton-move-manager module),
// shown top-left on the first page — not the version of Move/Bitwig/Ableton.
const appVersion = "1.0.0"

func (m model) View() string {
	if m.quit {
		return ""
	}
	// Discretion (hidden watchdog) mode renders NOTHING: the manager's window
	// is on a silent special workspace and the program is event-driven only,
	// so there is no frame to draw and no periodic tick to drive one.
	if m.discretion {
		return ""
	}
	// Size the picker this frame will actually draw, not all five. SetSize
	// re-runs bubbles' pagination to settle PerPage/TotalPages, so sizing the
	// hidden ones cost real frame time for no visible result; and the model
	// here is ~190KB, which a value receiver copies on every call.
	m.mainPicker = m.mainPicker.SetSize(m.mainContentSize())
	switch m.top() {
	case scrSettings:
		m.settingsPicker = m.settingsPicker.SetSize(m.contentSize())
	case scrAbletonVersion:
		m.abletonPicker = m.abletonPicker.SetSize(m.contentSize())
	case scrBundlePick:
		m.bundlePicker = m.bundlePicker.SetSize(m.contentSize())
	case scrRoutePick:
		m.routePicker = m.routePicker.SetSize(m.contentSize())
	}
	var body, title, bar string
	var version string
	// The Toast replaces the shortcut hint in the bottom bar whenever it's
	// active — the bar is a fixed one-row floor, so a notification never
	// pushes the layout around (the user's rule: an appearing notification
	// must never move the rest of the interface, which it did when the
	// toast used to be appended to the centred body).
	// The toast lives on its own reserved row just ABOVE the shortcut hint
	// (tuikit.BottomBar), so a notification never hides the shortcuts and
	// never moves the interface when it auto-disappears.
	barLine := func(hint string) string {
		return tuikit.BottomBar(m.toast.View(), hint, m.contentSizeW())
	}
	switch m.top() {
	case scrMain:
		version = "v" + appVersion
		if m.loading && m.status.Host == "" {
			title = m.homeTitle()
			body = "loading…"
		} else {
			title = m.homeTitle()
			// Options first, connection status ("move.local ●") BELOW the
			// selectable rows. One extra blank row after the status
			// lifts it off the shortcut hint (the user's rule: status
			// reads with its own air, never glued to the hint bar).
			// m.loading drives the ORANGE dot while a "Refresh connection
			// status" fetch is in flight (the user's rule).
			body = m.mainPicker.View() + "\n" + lipgloss.NewStyle().
				Width(m.contentSizeW()).
				Align(lipgloss.Center).
				Render(tuikit.StyleMuted.Render(headerFor(m.status, m.loading))) + "\n"
			bar = barLine(m.mainPicker.ShortcutsHint())
		}
	case scrSettings:
		title = screenTitle("Settings", m.contentSizeW())
		body = m.settingsPicker.View()
		bar = barLine(m.settingsPicker.ShortcutsHint())
	case scrAbletonVersion:
		title = screenTitle("Choose Ableton version", m.contentSizeW())
		if m.loading {
			body = "looking for Ableton installations…"
		} else {
			body = m.abletonPicker.View()
			bar = barLine(m.abletonPicker.ShortcutsHint())
		}
	case scrBundlePick:
		title = screenTitle("Pick a set", m.contentSizeW())
		if m.loading {
			body = "scanning for sets…"
		} else {
			body = m.bundlePicker.View()
			bar = barLine(m.bundlePicker.ShortcutsHint())
		}
	case scrRoutePick:
		title = screenTitle("Convert to:", m.contentSizeW())
		if m.loading {
			body = "checking for a running Ableton…"
		} else {
			body = m.routePicker.View()
			bar = barLine(m.routePicker.ShortcutsHint())
		}
	case scrConvertPresetSource:
		title = screenTitle("Convert a preset", m.contentSizeW())
		body = m.convertPresetPckr.View()
		bar = barLine(m.convertPresetPckr.ShortcutsHint())
	case scrConvertPresetPicking:
		title = screenTitle("Convert a preset", m.contentSizeW())
		if m.presetKind == "bitwig" {
			body = tuikit.StyleFrame.Render(strings.Join([]string{
				tuikit.StyleAccent.Render("● pick a Bitwig preset (.bwpreset)…"),
				"",
				"Add one or more .bwpreset files (a second prompt lets you",
				"keep adding). The converted preset lands in the Presets",
				"folder of the manager's working directory.",
			}, "\n"))
		} else {
			body = tuikit.StyleFrame.Render(strings.Join([]string{
				tuikit.StyleAccent.Render("● pick an Ableton Live preset (.adg)…"),
				"",
				"Add one or more .adg files (a second prompt lets you",
				"keep adding). They go to the preset folder of the",
				"Ableton version chosen in Settings.",
			}, "\n"))
		}
		bar = barLine(tuikit.StyleHelp.Render("esc to cancel"))
	case scrSchwungMenu:
		title = screenTitle("Schwung", m.contentSizeW())
		if m.loading {
			body = "checking the Move for Schwung…"
		} else {
			body = m.schwungPicker.View()
			bar = barLine(m.schwungPicker.ShortcutsHint())
		}
	case scrBitwigMenu:
		title = screenTitle("Move as Bitwig controller", m.contentSizeW())
		if m.loading {
			body = "checking Bitwig and the Move…"
		} else {
			body = m.bitwigPicker.View()
			bar = barLine(m.bitwigPicker.ShortcutsHint())
		}
	case scrBitwigTipWait:
		title = screenTitle("Bitwig controller ready", m.contentSizeW())
		body = m.tipInfo.View()
		bar = barLine(tuikit.StyleHelp.Render("esc to go back"))
	case scrAddress:
		title = screenTitle("Move address", m.contentSizeW())
		body = m.addressInput.View()
		bar = barLine(m.addressInput.ShortcutsHint())
	case scrClearAlsConfirm, scrQuitConfirm, scrSuperfileInstallConfirm,
		scrBundleEmptyConfirm, scrAbletonConflictConfirm,
		scrManagerDownloadConfirm, scrAbletonCloseRetryConfirm,
		scrConvertRetryConfirm, scrNoAlsConfirm, scrConvertPresetAddMore,
		scrPresetUploadConfirm,
		scrSchwungUninstallConfirm, scrBitwigUninstallConfirm,
		scrBitwigModuleUninstallConfirm, scrBitwigTipConfirm:
		body = m.confirm.View()
		bar = barLine(m.confirm.ShortcutsHint())
	case scrPresetUpload:
		title = screenTitle("Preset converted", m.contentSizeW())
		body = m.presetUploadView()
		bar = barLine(tuikit.StyleHelp.Render("esc to go back to the main menu"))
	case scrPresetNoMove:
		title = screenTitle("Preset converted — Move not connected", m.contentSizeW())
		body = m.presetNoMovePicker.View()
		bar = barLine(m.presetNoMovePicker.ShortcutsHint())
	case scrConverting, scrWorkingDirRunning, scrSuperfileInstalling,
		scrAbletonClosing, scrBitwigOpening, scrPresetConverting,
		scrSchwungInstalling, scrSchwungUninstalling, scrBitwigInstalling,
		scrBitwigUninstalling, scrBitwigModuleUninstalling:
		title = screenTitle("Working…", m.contentSizeW())
		body = m.runner.View()
		bar = barLine(m.runner.ShortcutsHint())
	case scrManagerWait:
		if !m.managerWaiting {
			title = screenTitle("Working…", m.contentSizeW())
			body = m.runner.View()
			bar = barLine(m.runner.ShortcutsHint())
		} else {
			title = screenTitle("Waiting for the Move Manager", m.contentSizeW())
			body = m.managerWaitView()
			bar = barLine(tuikit.StyleHelp.Render("esc to stop waiting"))
		}
	}
	if m.w == 0 || m.h == 0 {
		return title + "\n" + body + "\n" + bar
	}
	return tuikit.FrameScreenVersion(m.w, m.h, title, body, bar, version)
}

// contentSizeW returns the content width without re-running the full
// contentSize.
func (m *model) contentSizeW() int {
	w, _ := m.contentSize()
	return w
}

// homeTitle renders the home screen's pinned-top title: the full boxed
// "mosquito" + subtitle banner when the window allows it (real height,
// not a hardcoded reserve — see contentSize), otherwise just the
// subtitle so nothing is clipped on narrow/short terminals.
func (m *model) homeTitle() string {
	// Centered across the full window, not the content lane: the version row
	// makes the title block exactly window-wide, so FrameScreen skips its own
	// re-centering pass and a narrower block would stick left.
	//
	// It renders the SAME rung homeBannerReserve budgeted for, so the reserved
	// rows and the drawn rows are the same number by construction.
	w := m.contentWidth()
	title := m.homeLayout().RenderLadder(w, titleLadder(w))
	return lipgloss.NewStyle().Width(m.w).Align(lipgloss.Center).Render(title)
}

// screenTitle renders a centered accent-colored bold title for the
// current screen, in the universal layout's pinned-top slot (FrameScreen
// pulls it up to the top of the window). Identical style to the audio
// manager's screen titles — same font weight, same accent, same centered
// alignment — so every screen's title bar looks like one cohesive title
// bar across the whole app.
func screenTitle(text string, maxW int) string {
	return lipgloss.NewStyle().
		Width(maxW).
		Align(lipgloss.Center).
		Render(tuikit.StyleAccent.Bold(true).Render(text))
}

// managerWaitView renders the poll loop shown while the Move Manager is up —
// plain text (no runner: the poll is read-only and instantaneous), telling
// the user what to do and that the prompt will pop up here when a set lands.
func (m model) managerWaitView() string {
	body := tuikit.StyleFrame.Render(strings.Join([]string{
		tuikit.StyleAccent.Render("● Waiting for the Move Manager…"),
		"",
		"Download a set on the Move and let it finish:",
		"  • the moment one appears, a prompt offers to close the Manager",
		"    and continue with it here, or",
		"  • close the Manager window yourself to jump straight to the",
		"    bundle picker.",
		"", "", "", "", "", "", "", "", "", "",
	}, "\n"))
	return body
}

// presetUploadView shows the converted preset's path(s) and tells the user
// what to do with them now that the Move Manager is open — the preset has to
// be uploaded into the Manager to land on the Move.
func (m model) presetUploadView() string {
	lines := []string{
		tuikit.StyleAccent.Render("● preset converted — upload it to the Move"),
		"",
		"Move Manager upload path:",
	}
	if len(m.presetOutputs) == 0 {
		lines = append(lines, "  "+m.presetDir)
	} else {
		for _, p := range m.presetOutputs {
			lines = append(lines, "  "+p)
		}
	}
	lines = append(lines,
		"",
		"In the Move Manager, use its upload / import action and pick the",
		"file above to copy the preset onto the Move.",
	)
	return tuikit.StyleFrame.Render(strings.Join(lines, "\n"))
}
