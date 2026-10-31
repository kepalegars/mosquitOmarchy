// Command mosquito-move-manager-tui is the terminal interface for the
// mosquito Move Manager workflow (see ../lib-move-manager-core.sh for what
// this does) — a real Bubble Tea program, built the same way the user's
// own omagrab is (charmbracelet/bubbletea + bubbles + lipgloss),
// replacing the previous bash+gum implementation. The TUI is the ONLY
// interface. One persistent tea.Program for the whole session: every
// screen is a state in this program's own model, not a separate
// subprocess, so there is nothing to leave half-drawn — ctrl+c and esc
// are ordinary key cases (see screens.go), never a special-cased signal
// handler.
//
// Business logic (Wine/Ableton/Bitwig orchestration, state prefs, file
// scanning) is NOT reimplemented here — see mosquito-move-manager-actions,
// which sources the exact same lib-move-manager-core.sh this program's own
// backend uses and exposes it as plain, scriptable subcommands this
// program calls once every decision (which bundle, which route, confirm/
// cancel) has already been made here.
//
// Not meant to be launched directly under normal use — the stable
// mosquito-move-manager dispatcher routes every no-argument launch
// straight here. Runs standalone fine too (no-args via the dispatcher and
// a plain run are equivalent).
package main

import (
	"fmt"
	"os"

	tea "github.com/charmbracelet/bubbletea"
)

func main() {
	p := tea.NewProgram(initialModel(), tea.WithAltScreen())
	_, err := p.Run()
	// Drop this instance's marker on any exit path so a normal quit can never
	// leave a stale "busy"/"discretion" file behind for the detector to prune
	// later. The dispatcher prunes dead PIDs too; this just makes it immediate.
	removeDiscretionMarker(os.Getpid())
	if err != nil {
		fmt.Fprintln(os.Stderr, "mosquito-move-manager-tui:", err)
		os.Exit(1)
	}
}
