package main

import (
	"fmt"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// diskChecking is the placeholder the confirm shows while the backend runs.
// It is replaced in place by the spaceMsg handler, so the message layout and
// the focused button never move.
const diskChecking = "\n\nDisk: checking…"

// notEnough is the shortfall phrase shown in red, blinking, like the
// "mosquito" row in Setup. It is deliberately not part of spaceLine so the
// blink can repaint only this phrase.
const notEnough = "NOT enough free space"

// spaceBananas is the user-facing stand-in for a size the backend cannot
// prove. It keeps the confirm honest without sounding like an error.
const spaceBananas = "a bunch of bananas"

// withSpace appends the placeholder to a confirm message and returns the
// command that will fill it in. Best effort by design: the answer only ever
// displays, it never blocks or refuses an action.
func (m *model) withSpace(base, op string, keys []string) (string, tea.Cmd) {
	m.spaceSeq++
	m.spaceOp = op
	m.spaceBase = base
	m.spaceArmed = true
	m.spaceShort = false
	m.spaceBlinkOn = false
	m.spaceLineText = ""
	return base + diskChecking, fetchSpaceCmd(op, keys, m.spaceSeq)
}

func formatKiB(kb int64) string {
	switch {
	case kb >= 1024*1024:
		return fmt.Sprintf("%.1f GiB", float64(kb)/(1024*1024))
	case kb >= 1024:
		return fmt.Sprintf("%.0f MiB", float64(kb)/1024)
	default:
		return fmt.Sprintf("%d KiB", kb)
	}
}

func spaceLine(op string, r DiskRec) string {
	free := "unknown"
	if !r.FreeUnknown {
		free = formatKiB(r.FreeKB)
	}
	if op == "install" {
		need := spaceBananas
		if !r.NeedUnknown {
			need = "~" + formatKiB(r.NeedKB)
		} else if r.NeedKB > 0 {
			need = "~" + formatKiB(r.NeedKB) + " and some bananas"
		}
		return fmt.Sprintf("Disk: %s free · needs %s", free, need)
	}
	freed := spaceBananas
	if !r.FreedUnknown {
		freed = "~" + formatKiB(r.FreedKB)
	} else if r.FreedKB > 0 {
		freed = "~" + formatKiB(r.FreedKB) + " and some bananas"
	}
	// An uninstall has no useful "free" half: the only number that matters is
	// what the removal gives back.
	return fmt.Sprintf("Disk: frees %s", freed)
}

func spaceWarning(r DiskRec) bool {
	// A partially-known need is a lower bound: if that already exceeds free,
	// the rest can only make it worse. Requiring NeedUnknown to be false hid
	// the warning exactly when a folder mixed known and unknown modules.
	return !r.FreeUnknown && r.NeedKB > r.FreeKB
}

// warningText keeps the phrase red in both blink phases. The "on" phase adds
// a red fill (the highlight); the "off" phase keeps the red text, so the
// warning never borrows the theme accent or disappears.
func warningText(on bool) string {
	s := lipgloss.NewStyle().Foreground(lipgloss.Color("196")).Bold(true)
	if on {
		s = s.Background(lipgloss.Color("196")).Foreground(lipgloss.Color("231"))
	}
	return s.Render(notEnough)
}

// refreshSpaceMessage rebuilds the confirm body from the stable base message,
// so a blink only changes the warning styling and never the question.
func (m *model) refreshSpaceMessage() {
	if m.spaceBase == "" {
		return
	}
	msg := m.spaceBase + "\n\n" + m.spaceLineText
	if m.spaceShort {
		// The blinking phrase gets its own line unconditionally: appended to
		// the disk line it could be split across a wrap, so half of it flashed
		// on one row and half on the next.
		msg += "\n\n" + warningText(m.spaceBlinkOn)
	}
	m.pendingMsg = msg
	m.confirm.Message = msg
}

func (m *model) applySpaceMsg(msg spaceMsg) {
	if len(m.nav) == 0 || m.top() != scrConfirm || msg.seq != m.spaceSeq || m.spaceBase == "" {
		return
	}
	line := "Disk: estimate unavailable"
	if msg.err == nil {
		line = spaceLine(m.spaceOp, msg.rec)
	}
	m.spaceLineText = line
	m.spaceShort = msg.err == nil && m.spaceOp == "install" && spaceWarning(msg.rec)
	m.spaceBlinkOn = m.spaceShort
	m.refreshSpaceMessage()
}
