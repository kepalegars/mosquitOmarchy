// Command mosquitomarchy-tui is the terminal interface for the
// mosquitOmarchy setup launcher (see ../../mosquitomarchy-setup.sh for what
// this does) — a real Bubble Tea program on the same kit the other mosquito
// managers use, replacing the previous bash+gum launcher. The TUI is the
// ONLY interface. One persistent tea.Program for the whole session: every
// screen is a state in this program's own model, not a separate
// subprocess, so there is nothing to leave half-drawn — ctrl+c and esc
// are ordinary key cases, never a special-cased signal handler.
//
// Business logic (modules, categories, status, backup/restore, uninstall,
// repo updates) is NOT reimplemented here — see mosquitomarchy-actions,
// which sources the exact same mosquitomarchy-setup.sh the launcher used and
// exposes it as plain, scriptable subcommands this program calls once every
// decision (which category, which items, confirm/cancel) has already been
// made here.
//
// Not meant to be launched directly under normal use — the stable
// mosquitomarchy dispatcher routes every no-argument launch straight here.
// Runs standalone fine too (no-args via the dispatcher and a plain run are
// equivalent).
package main

import (
	"fmt"
	"os"

	tea "github.com/charmbracelet/bubbletea"
)

func main() {
	// Headless mode: `mosquitomarchy-tui --status` prints the status JSON
	// lines and exits WITHOUT any terminal UI. This is what boot-time hooks
	// (the update-check watchdog) call, so the plugin never opens a Foot
	// window on the desktop just to print a small JSON blob.
	if len(os.Args) > 1 {
		for _, a := range os.Args[1:] {
			if a == "--status" || a == "status" {
				out, err := runQuick("status")
				if err != nil {
					fmt.Fprintln(os.Stderr, "mosquitomarchy-tui:", err)
					os.Exit(1)
				}
				fmt.Print(string(out))
				return
			}
			if a == "--help" || a == "-h" {
				fmt.Println("mosquitomarchy-tui: the manager TUI. Headless: --status (print the module status JSON lines).")
				return
			}
		}
	}
	p := tea.NewProgram(initialModel(), tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		fmt.Fprintln(os.Stderr, "mosquitomarchy-tui:", err)
		os.Exit(1)
	}
}
