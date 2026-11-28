package main

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/lipgloss"
	"mosquitomarchy.local/mosquitomixbay-tui/drivers"
	tuikit "mosquitomarchy.local/tui-kit"
)

// appVersion is the version of this SCRIPT (the mosquitomixbay module),
// pinned top-left on every screen like the other managers. The installer
// injects the root VERSION with -X main.appVersion.
var appVersion = "dev"

// versionRow renders the script version at column 0 of a full-width row, so
// it stays glued to the top-left corner even inside centered blocks.
func versionRow(w int) string {
	ver := tuikit.StyleHelp.Render("v" + appVersion)
	pad := w - lipgloss.Width(ver)
	if pad < 0 {
		pad = 0
	}
	return ver + strings.Repeat(" ", pad)
}

func (m model) View() string {
	if m.quit {
		return ""
	}

	var b strings.Builder
	w, h := m.contentSize()

	switch m.top() {
	case scrDevices:
		title, rows := m.screenBudget(h)
		m.picker = m.picker.SetSize(w, rows)
		b.WriteString(centerBlock(title, w))
		b.WriteString("\n")
		b.WriteString(m.picker.View())
		b.WriteString("\n")
		b.WriteString(m.statusLine(w))
	case scrControls:
		switch m.controlModel() {
		case modelGrid:
			return m.evoView()
		case modelSingle:
			return m.ugmView()
		case modelLevels:
			if m.isMoveDevice() {
				return m.moveView()
			}
			return m.levelsOnlyView("")
		}
		titleText := "Controls"
		if m.status.Spec.Display != "" {
			titleText = m.status.Spec.Display
			if m.status.Spec.Version != "" {
				titleText += " - " + m.status.Spec.Version
			}
			// An action-only card (RME) has no control rows: its screen is
			// the mixer integration, not "controls".
			if hasControls(m.status) {
				titleText += " — controls"
			}
		}
		title, rows := m.accentBudget(h, titleText)
		m.picker = m.picker.SetSize(w, rows)
		b.WriteString(centerBlock(title, w))
		b.WriteString("\n")
		b.WriteString(m.picker.View())
		b.WriteString("\n")
		b.WriteString(m.statusLine(w))
	case scrMixer:
		if m.controlModel() == modelGrid {
			return m.evoView()
		}
		titleText := "Loopback mixer"
		if m.status.Spec.Display != "" {
			titleText = m.status.Spec.Display
			if m.status.Spec.Version != "" {
				titleText += " - " + m.status.Spec.Version
			}
			titleText += " — " + drivers.BusLabelFor(m.status.Spec, m.mixBus)
		}
		title, rows := m.accentBudget(h, titleText)
		m.picker = m.picker.SetSize(w, rows)
		b.WriteString(centerBlock(title, w))
		b.WriteString("\n")
		b.WriteString(m.picker.View())
		b.WriteString("\n")
		b.WriteString(m.statusLine(w))
	case scrSettings:
		title, rows := m.settingsBudget(h)
		m.picker = m.picker.SetSize(w, rows)
		b.WriteString(centerBlock(title, w))
		b.WriteString("\n")
		b.WriteString(m.picker.View())
		b.WriteString("\n")
		b.WriteString(m.footer(w, ""))
	case scrAggregate, scrAggregatePick:
		titleText := "Aggregate devices"
		if m.top() == scrAggregatePick {
			titleText = "Pick the interfaces to aggregate"
		}
		title, rows := m.accentBudget(h, titleText)
		m.picker = m.picker.SetSize(w, rows)
		b.WriteString(centerBlock(title, w))
		b.WriteString("\n")
		b.WriteString(m.picker.View())
		b.WriteString("\n")
		b.WriteString(m.footer(w, ""))
	case scrFoundation:
		title, rows := m.accentBudget(h, "Audio foundation settings")
		m.picker = m.picker.SetSize(w, rows)
		b.WriteString(centerBlock(title, w))
		b.WriteString("\n")
		b.WriteString(m.picker.View())
		b.WriteString("\n")
		b.WriteString(m.footer(w, ""))
	case scrFoundationDefault:
		title, rows := m.accentBudget(h, "Default audio interface")
		m.picker = m.picker.SetSize(w, rows)
		b.WriteString(centerBlock(title, w))
		b.WriteString("\n")
		b.WriteString(m.picker.View())
		b.WriteString("\n")
		b.WriteString(m.footer(w, ""))
	case scrAddInterface:
		title, rows := m.accentBudget(h, "Add an audio interface")
		m.picker = m.picker.SetSize(w, rows)
		b.WriteString(centerBlock(title, w))
		b.WriteString("\n")
		b.WriteString(m.picker.View())
		b.WriteString("\n")
		b.WriteString(m.footer(w, ""))
	case scrLibrary:
		title, rows := m.accentBudget(h-1-libraryFilterRows, "Audio interface profiles")
		m.picker = m.picker.SetSize(w, rows)
		b.WriteString(centerBlock(title, w))
		b.WriteString("\n")
		b.WriteString(m.libraryTabs(w))
		b.WriteString("\n")
		b.WriteString(m.picker.View())
		b.WriteString("\n")
		b.WriteString(m.libraryFilterBar(w))
		b.WriteString("\n")
		b.WriteString(m.footer(w, ""))
	case scrInput:
		return centerModal(m.text.View(), w, h)
	case scrInfo:
		// Modals return directly: centerModal already fills exactly h
		// rows. Routing them through the TrimRight + re-center below
		// eats their bottom padding and shifts them down a second time
		// (the "prompt sits too low" bug). The hint row is the same one
		// mosquitOmarchy's log screen shows: scroll, copy, continue.
		rows := h - 1
		if rows < 1 {
			rows = 1
		}
		m.info = m.info.SetSize(w, rows)
		// The copy confirmation takes over the hint row while it is up,
		// exactly like the footer toast: Info owns the screen, so this is
		// the only row left to show the user that `c` did something.
		hint := m.info.ShortcutsHint()
		if notify := m.toast.View(); notify != "" {
			hint = notify
		}
		return centerModal(m.info.View(), w, rows) + "\n" + centerTrunc(hint, w)
	case scrConfirm:
		return centerModal(m.confirm.View(), w, h)
	}

	content := strings.TrimRight(b.String(), " \t\n")
	lines := strings.Count(content, "\n") + 1

	// The version owns row 0, detached from the title: it is window chrome
	// at the same place on every screen, never part of the centred block.
	// Confirm/info modals own the whole window (no version over a prompt).
	ver := ""
	// The card screens already carry the card's own version next to its name;
	// showing the Mixbay script version there too made two versions appear in
	// the same interface. Keep the script version on the list/settings chrome
	// only.
	if m.top() == scrDevices || m.top() == scrSettings || m.top() == scrAggregate || m.top() == scrAggregatePick || m.top() == scrFoundation || m.top() == scrFoundationDefault || m.top() == scrAddInterface {
		ver = versionRow(w)
		ch := h - 1
		if ch < 1 {
			ch = 1
		}
		if h > lines {
			content = lipgloss.PlaceVertical(ch, lipgloss.Center, content)
		}
		return ver + "\n" + content
	}

	if h > lines {
		content = lipgloss.PlaceVertical(h, lipgloss.Center, content)
	}

	return content
}

// titleLadder is the home banner: the boxed mosquito ASCII plus the mixbay
// subtitle when the window allows, degrading exactly like the other
// managers (compact box, then plain text — never wrapped, never clipped).
func titleLadder(width int) tuikit.TitleLadder {
	return tuikit.StackedLadder(tuikit.BoxedMosquito(), "mixbay", width)
}

// titleRows measures the rung the ladder picks at this width, so the budget
// below always matches what is drawn.
func (m model) titleRows() int {
	w, _ := m.contentSize()
	l := tuikit.LayoutForLadder(w, m.h, titleLadder(w))
	return l.TitleRows
}

// screenBudget splits the window into the ASCII title, the status footer and
// the picker body. The picker is sized to what is LEFT, never to the whole
// window: handing it the full height made the frame run over and the
// vertical centering cropped the head of the list.
// footerReserve is everything that is not title or list rows: the 2-row
// status footer, the picker's own 2 chrome rows, and the 2 blank separators
// between the three blocks.
func screenBudgetConst() int { return statusRows() + pickerChromeRows() + 2 }

func (m model) screenBudget(h int) (string, int) {
	w, _ := m.contentSize()
	// Lie to the ladder about the height by the fixed costs (version row
	// included), so the rung it picks always leaves room for at least one
	// list row: at h=12 the 9-row stacked banner must degrade to the
	// one-line subtitle.
	l := tuikit.LayoutForLadder(w, h-screenBudgetConst()-2, titleLadder(w))
	title := l.RenderLadder(w, titleLadder(w))
	rows := h - (l.TitleRows + 1) - screenBudgetConst()
	if rows < 1 {
		rows = 1
	}
	return title, rows
}

// settingsBudget is the same split for the small settings screen, whose
// title is one accent line under the detached version row.
func (m model) settingsBudget(h int) (string, int) {
	w, _ := m.contentSize()
	rows := h - 2 - screenBudgetConst()
	if rows < 1 {
		rows = 1
	}
	return screenTitle("Settings", w), rows
}

// accentBudget is the same split for the other sub-screens (controls, mixer):
// one accent-colored line names the page you are on, under the detached
// version row. Only the devices page keeps the boxed mosquito + mixbay
// banner.
func (m model) accentBudget(h int, title string) (string, int) {
	w, _ := m.contentSize()
	rows := h - 2 - screenBudgetConst()
	if rows < 1 {
		rows = 1
	}
	return screenTitle(title, w), rows
}

// centerBlock centers every line of a composed title block in the window
// WITHOUT re-styling it: the ASCII art carries its own colors, and wrapping
// it in the accent style would repaint the whole box.
func centerBlock(s string, w int) string {
	return lipgloss.NewStyle().Width(w).Align(lipgloss.Center).Render(s)
}

// statusRows is the footer height under the list: the note line plus the
// centered legend line. Fixed, so the budget never disagrees with the draw.
func statusRows() int { return 2 }

// pickerChromeRows is what the picker itself adds around its rows
// (pagination + frame): measured, not guessed — SetSize(h) renders h+2.
func pickerChromeRows() int { return 2 }

func (m model) statusLine(w int) string {
	return m.footer(w, m.statusNote())
}

// statusNote is the persistent device note (dial prompt / DEMO etc.). A toast
// takes over its row while it is up.
func (m model) statusNote() string {
	note := m.status.Note
	// The device list is a picker, not a device page: the selected driver's
	// DEMO/offline note ("… not found. State is simulated…") belongs on that
	// driver's screen, never on the home page.
	if m.top() == scrDevices {
		note = ""
	}
	if note == "" {
		note = " "
	}
	if m.numBuf != "" {
		note = fmt.Sprintf("dial: %s_  (enter/l applies · esc/h cancels)", m.numBuf)
	}
	return note
}

// footer reserves the notification row above the shortcut legend, exactly like
// tuikit.BottomBar: a toast never moves the body, never sits after the legend
// and always appears at the same place, horizontally centred.
func (m model) footer(w int, note string) string {
	notify := m.toast.View()
	if notify == "" && m.loading {
		notify = tuikit.StyleMuted.Render("loading...")
	}
	if notify == "" {
		notify = note
	}
	if notify == "" {
		notify = " "
	}
	return tuikit.BottomBar(notify, m.legendLine(w), w)
}

func (m model) legendLine(w int) string {
	var hint string
	switch m.top() {
	case scrDevices:
		hint = "↑/k up · ↓/j down · enter/l open · h/q quit · r refresh"
	case scrControls:
		if hasControls(m.status) {
			if m.controlModel() == modelGrid {
				// The EVO grid is one of the two real 2D surfaces: h/l move
				// columns, j/k move rows, and they keep meaning here.
				hint = "Tab mixer · j/k rows · h/l cols · enter · [ ] adjust · { } big · digits dial · esc back · s/o save/load · ? help"
			} else {
				hint = "Tab mixer · ↑/k up · ↓/j down · enter/l · [ ] adjust · { } big · digits dial · esc/h back · s/o save/load · ? help"
			}
		} else {
			hint = "↑/k up · ↓/j down · enter/l open · esc/h back · r refresh · ? help"
		}
	case scrMixer:
		if m.controlModel() == modelGrid {
			hint = "Tab controls · j/k rows · h/l sources · [ ] vol · { }/,/. pan · digits dial · bus row switches MIX · esc back · ? help"
		} else {
			hint = "Tab controls · ↑/k up · ↓/j down · enter/l · [ ] vol · { }/,/. pan · digits dial · bus row switches MIX · esc/h back · ? help"
		}
	case scrSettings:
		hint = "←/→/enter/l toggle · esc/h back"
	case scrAggregate:
		hint = "n new · a activate/deactivate · d delete · p repair · A lock · s save links · r refresh · esc/h back"
	case scrAggregatePick:
		hint = "j/k row · h/l column · space/enter toggle · n name & save · esc back"
	case scrFoundation:
		hint = "enter/l install/remove · d default · r refresh · esc/h back"
		if _, ok := m.selectedSplitCard(); ok {
			hint = "enter/l install/remove · s split on/off · d default · r refresh · esc/h back"
		}
	case scrFoundationDefault:
		hint = "enter/l choose · esc/h back"
	case scrAddInterface:
		hint = "enter/l add as beta · r rescan · esc/h back"
	case scrLibrary:
		if m.libraryFilterOpen {
			// h/j/k/l are literal characters in the live filter.
			hint = "type to filter · enter action · esc close"
		} else if m.libraryTab == libAvailable {
			hint = "←/→/h/l tabs · tab select · enter install · F search · O open repo · i info · r refresh · esc back"
		} else {
			hint = "←/→/h/l tabs · tab select · enter update · F search · e export · D uninstall · i info · r refresh · esc back"
		}
	default:
		hint = "↑/k up · ↓/j down · enter/l · q quit"
	}
	return tuikit.StyleHelp.Render(centerTrunc(hint, w))
}

func centerTrunc(s string, w int) string {
	return lipgloss.NewStyle().Width(w).Align(lipgloss.Center).Render(tuikit.TruncateLine(s, w))
}

func screenTitle(text string, maxW int) string {
	// Kept for the small (non-ASCII) screens: one accent line, centered.
	return lipgloss.NewStyle().
		Width(maxW).
		Align(lipgloss.Center).
		Render(tuikit.StyleAccent.Bold(true).Render(text))
}

// centerModal puts a dialog (confirm/info) dead-center in the window so a
// prompt never reads left-aligned against an empty screen.
func centerModal(s string, w, h int) string {
	return lipgloss.Place(w, h, lipgloss.Center, lipgloss.Center, s)
}
