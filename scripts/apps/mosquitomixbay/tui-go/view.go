package main

import (
	"fmt"
	"strings"

	tuikit "mosquitomarchy.local/tui-kit"
)

func (m model) View() string {
	if m.quit {
		return ""
	}
	var b strings.Builder
	cw, _ := m.contentSize()
	_ = cw

	// Mosquito banner line (text, no ASCII art needed here — the device
	// picker carries its own title).
	switch m.top() {
	case scrDevices, scrControls, scrMixer:
		b.WriteString(m.picker.View())
		b.WriteString("\n")
		b.WriteString(m.statusLine())
	case scrInfo:
		b.WriteString(m.info.View())
	case scrConfirm:
		b.WriteString(m.confirm.View())
	}
	if t := m.toast.View(); t != "" {
		b.WriteString("\n" + t)
	}
	if m.loading {
		b.WriteString("\n" + tuikit.StyleMuted.Render("loading…"))
	}
	return b.String()
}

func (m model) statusLine() string {
	parts := []string{}
	if m.status.Spec.Display != "" {
		state := "demo"
		if m.status.Online {
			state = "● online"
		}
		parts = append(parts, fmt.Sprintf("%s [%s]", m.status.Spec.Display, state))
	}
	if m.status.Note != "" {
		parts = append(parts, m.status.Note)
	}
	if len(parts) == 0 {
		return tuikit.StyleHelp.Render("↑/↓ move · enter open · q quit")
	}
	hint := "↑/↓ · enter · ←/→ adjust · m mixer · s save · ? help"
	return tuikit.StyleHelp.Render(strings.Join(parts, " — ") + "\n" + hint)
}
