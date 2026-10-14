package main

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/lipgloss"
	tuikit "mosquitomarchy.local/tui-kit"
)

func (m model) View() string {
	if m.quit {
		return ""
	}

	var b strings.Builder
	_, ch := m.contentSize()

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
		b.WriteString("\n" + tuikit.StyleMuted.Render("loading..."))
	}

	content := strings.TrimRight(b.String(), " \t\n")
	lines := strings.Count(content, "\n") + 1

	if ch > lines {
		content = lipgloss.PlaceVertical(ch, lipgloss.Center, content)
	}

	return content
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
		return tuikit.StyleHelp.Render("\u2191/\u2193 move \xb7 enter open \xb7 q quit")
	}
	hint := "\u2191/\u2193 \xb7 enter \xb7 \u2190/\u2192 adjust \xb7 m mixer \xb7 s save \xb7 ? help"
	return tuikit.StyleHelp.Render(strings.Join(parts, " — ") + "\n" + hint)
}
